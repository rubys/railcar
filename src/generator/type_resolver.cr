# TypeResolver — maps Crystal AST nodes to normalized receiver-type names.
#
# The normalized type name feeds MethodMap lookups, so a view expression
# like `@article.title.size` resolves to "String" (→ `len(title)` in Go,
# `.len()` in Rust), while `@article.comments.size` resolves to "Array"
# (→ `len(...)` but through the slice helper path).
#
# Sources of type information, in priority order:
#   1. Literal node kinds (StringLiteral → "String", ArrayLiteral → "Array", …)
#   2. Locally bound names (loop block args, explicit assignments)
#   3. AppModel metadata (schemas for columns, associations for has_many/belongs_to)
#   4. Fallback to "Any"
#
# This is metadata-driven rather than semantic-AST-driven. It covers every
# pattern currently emitted by the blog demo without requiring
# `program.semantic()` for the Go/Rust targets, and leaves room for a
# typed-AST override in the future.

require "compiler/crystal/syntax"
# semantic is required so `node.type?` resolves — the primary-path for
# typed-AST resolution depends on it.
require "../semantic"
require "./app_model"
require "./schema_extractor"
require "./inflector"

module Railcar
  class TypeResolver
    getter app : AppModel
    # local variable name → normalized type name
    getter locals : Hash(String, String)
    # schema table name (plural, e.g. "articles") → TableSchema
    getter schemas : Hash(String, TableSchema)

    def initialize(@app : AppModel)
      @locals = {} of String => String
      @schemas = {} of String => TableSchema
      @app.schemas.each { |s| @schemas[s.name] = s }
    end

    # Bind a local variable's type.
    def bind(name : String, type : String) : Nil
      @locals[name] = type
    end

    # Return a copy with one additional binding — convenient for scope-limited
    # additions (e.g., each-block block args).
    def with_binding(name : String, type : String) : TypeResolver
      copy = TypeResolver.new(@app)
      copy.locals.merge!(@locals)
      copy.bind(name, type)
      copy
    end

    # Resolve an AST node to a normalized receiver-type name.
    # Returns one of: "String", "Numeric", "Array", "Hash", "Bool", "Nil",
    # a model name (e.g., "Article"), or "Any".
    #
    # When the node carries a semantic type (`node.type?` populated by a
    # prior `program.semantic()` pass), the authoritative answer comes
    # from Crystal's type inference. Otherwise this falls back to
    # metadata-based resolution derived from AppModel + local bindings.
    def resolve(node : Crystal::ASTNode) : String
      if resolved = resolve_semantic(node)
        return resolved
      end

      case node
      when Crystal::StringLiteral, Crystal::StringInterpolation
        "String"
      when Crystal::NumberLiteral
        "Numeric"
      when Crystal::ArrayLiteral
        "Array"
      when Crystal::HashLiteral
        "Hash"
      when Crystal::BoolLiteral
        "Bool"
      when Crystal::NilLiteral
        "Nil"
      when Crystal::SymbolLiteral
        "String"
      when Crystal::Var
        resolve_var(node.name)
      when Crystal::InstanceVar
        resolve_var(node.name.lchop("@"))
      when Crystal::Path
        # A bare path (e.g., `Article`) refers to the class itself.
        # Treat as "Class<ModelName>" so MethodMap ignores it (no entries)
        # and the emitter's class-method path takes over. Return "Any" so
        # lookups cleanly fall back.
        "Any"
      when Crystal::Call
        resolve_call(node)
      else
        "Any"
      end
    end

    # If the node has a type set by Crystal's semantic analyzer, return its
    # normalized form. Otherwise return nil so the metadata path takes over.
    private def resolve_semantic(node : Crystal::ASTNode) : String?
      t = node.type? rescue nil
      return nil unless t
      normalized = TypeResolver.normalize_crystal_type(t.to_s)
      return nil if normalized == "Any"
      normalized
    end

    # Resolve a bare name — loop var, controller-ivar-turned-local, or
    # model-singular (e.g., `article` in the show view).
    private def resolve_var(name : String) : String
      if type = @locals[name]?
        return type
      end

      # A name matching a model's singular underscore form → that model.
      # e.g., "article" → "Article"
      @app.models.each_key do |model_name|
        return model_name if Inflector.underscore(model_name) == name
      end

      # A name matching a model's plural underscore form → Array of that model.
      @app.models.each_key do |model_name|
        plural = Inflector.pluralize(Inflector.underscore(model_name))
        return "Array" if plural == name
      end

      "Any"
    end

    # Resolve a method-call node: the type of what this call returns.
    private def resolve_call(node : Crystal::Call) : String
      obj = node.obj
      name = node.name

      # No receiver → treat as bare variable reference (ViewCleanup.calls_to_vars
      # hasn't always run). Only treat as variable if no args/block/named_args.
      if obj.nil? && node.args.empty? && node.block.nil? && node.named_args.nil?
        return resolve_var(name)
      end

      # With a receiver, we may still know the return type.
      if obj
        recv_type = resolve(obj)

        # Schema column access on a model
        if schema = schema_for_model(recv_type)
          if col = schema.columns.find { |c| c.name == name }
            return normalize_crystal_type(SchemaExtractor.crystal_type(col.type))
          end
          # `id` is implicit on every model
          return "Numeric" if name == "id"
        end

        # Association access
        if model = @app.models[recv_type]?
          if assoc = model.associations.find { |a| a.name == name }
            case assoc.kind
            when :has_many
              return "Array"
            when :belongs_to, :has_one
              return Inflector.classify(assoc.name)
            end
          end
        end

        # String methods returning known types
        if recv_type == "String"
          case name
          when "chars", "lines", "split", "bytes"
            return "Array"
          when "size", "length", "bytesize", "to_i", "to_f"
            return "Numeric"
          when "empty?", "include?", "start_with?", "end_with?"
            return "Bool"
          when "downcase", "upcase", "strip", "lstrip", "rstrip", "gsub", "sub", "reverse", "capitalize"
            return "String"
          end
        end

        # Array methods
        if recv_type == "Array"
          case name
          when "size", "length", "count"
            return "Numeric"
          when "empty?", "any?", "include?"
            return "Bool"
          when "join"
            return "String"
          when "flatten", "compact", "reverse", "sort", "uniq", "map", "select", "reject"
            return "Array"
          end
        end

        # Hash methods
        if recv_type == "Hash"
          case name
          when "size", "length", "count"
            return "Numeric"
          when "empty?", "has_key?"
            return "Bool"
          when "keys", "values"
            return "Array"
          when "merge"
            return "Hash"
          end
        end
      end

      "Any"
    end

    # Look up the schema for a given model name (e.g., "Article" → articles table).
    private def schema_for_model(type_name : String) : TableSchema?
      return nil if type_name == "Any" || type_name == "String" || type_name == "Array" ||
                    type_name == "Hash" || type_name == "Numeric" || type_name == "Bool" ||
                    type_name == "Nil"
      table_name = Inflector.pluralize(Inflector.underscore(type_name))
      @schemas[table_name]?
    end

    # Normalize a Crystal type name into a MethodMap receiver-type name.
    # Exposed at class level so emitters that already have semantic type info
    # (Cr2Py, Cr2Ts, Cr2Ex) can share the same normalization.
    def self.normalize_crystal_type(crystal_type : String) : String
      # Strip nullable suffix for lookup purposes.
      ct = crystal_type.chomp("?")
      # Array(X) → Array; Hash(K, V) → Hash
      return "Array" if ct.starts_with?("Array(")
      return "Hash" if ct.starts_with?("Hash(")
      # Union types like "String | Nil" — pick the non-Nil branch if there's one
      if ct.includes?(" | ")
        parts = ct.split(" | ").reject { |p| p == "Nil" || p == "NoReturn" }
        return normalize_crystal_type(parts.first) if parts.size == 1
        return "Any"
      end
      case ct
      when "String"             then "String"
      when "Int32", "Int64",
           "Float32", "Float64" then "Numeric"
      when "Bool"               then "Bool"
      when "Time"               then "Any" # no dedicated Time table yet
      when "Bytes"              then "Any"
      else                           ct # already a model name or similar
      end
    end

    private def normalize_crystal_type(crystal_type : String) : String
      TypeResolver.normalize_crystal_type(crystal_type)
    end
  end
end
