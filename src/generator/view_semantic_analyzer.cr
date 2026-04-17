# ViewSemanticAnalyzer — runs Crystal's semantic analyzer over view function
# ASTs so that every expression inside a view body gets `.type?` populated.
#
# Why this matters: TypeResolver and MethodMap lookups currently rely on
# metadata (schemas, associations, local bindings) to resolve receiver
# types. That's accurate for the blog demo but has an inherent ceiling —
# for example, it can't see through a `@articles.first.title` chain where
# `@articles` is a user-declared local, or through a custom model method
# that isn't a column.
#
# Crystal's semantic analyzer already resolves these cases perfectly when
# invoked with appropriate stubs. This class wraps that machinery for
# view ASTs specifically.
#
# Usage:
#   analyzer = ViewSemanticAnalyzer.new(app)
#   analyzer.add_view("articles/show", show_view_def)
#   analyzer.add_view("articles/_comment", comment_partial_def)
#   if analyzer.analyze
#     typed_body = analyzer.typed_body_for("articles/show")
#     # typed_body's expressions now have .type? populated
#   end
#
# Key constraint: Crystal types methods lazily at call sites. The original
# Def's body nodes do NOT receive types; instead, each call is given a
# `target_defs` array pointing to the typed instantiation. This class
# constructs an invocation for each registered view and retrieves
# `target_defs.first.body` as the typed view body.

require "../semantic"
require "./app_model"
require "./schema_extractor"
require "./inflector"

module Railcar
  class ViewSemanticAnalyzer
    getter app : AppModel

    # view id (e.g., "articles/show") → Def supplied by caller
    getter views : Hash(String, Crystal::Def) = {} of String => Crystal::Def

    # Populated after analyze: view id → typed body of that view
    getter typed_bodies : Hash(String, Crystal::ASTNode) = {} of String => Crystal::ASTNode

    # Populated after analyze: the Crystal::Program that did the typing
    # (kept alive so typed AST nodes remain valid).
    getter program : Crystal::Program?

    def initialize(@app : AppModel)
    end

    # Register a view Def for analysis. `id` can be anything caller-meaningful
    # (controller/basename is typical); it's used as the lookup key.
    # The def's args must have restrictions (e.g., `comment : Comment`) so
    # semantic analysis can instantiate the method.
    def add_view(id : String, view_def : Crystal::Def) : Nil
      @views[id] = view_def
    end

    # Run program.semantic() over all registered views. Returns true on
    # success, false if Crystal's type inference failed.
    def analyze : Bool
      return true if @views.empty?

      program = Crystal::Program.new
      compiler = Crystal::Compiler.new
      compiler.no_codegen = true
      program.compiler = compiler
      @program = program

      location = Crystal::Location.new("views.cr", 1, 1)

      # Assemble: prelude + model stubs + renamed view defs + invocations.
      # We rename each view def to a unique identifier (slugifying the id)
      # to avoid collisions when multiple controllers have same-named views.
      stub_source = build_stub_source
      stub_ast = Crystal::Parser.parse(stub_source)

      defs = [] of Crystal::ASTNode
      invocations = [] of {String, Crystal::Call}

      @views.each do |id, view_def|
        mangled = mangle(id)
        renamed = rename_def(view_def, mangled)
        defs << renamed

        # Build invocation: __view_<mangled> = <mangled>(<Type>.new, ...)
        call_args = renamed.args.map do |arg|
          type_name = type_name_of(arg)
          Crystal::Call.new(
            Crystal::Path.new(type_name),
            "new"
          ).as(Crystal::ASTNode)
        end
        invocation = Crystal::Call.new(nil.as(Crystal::ASTNode?), mangled, call_args)
        wrapper = Crystal::Assign.new(
          Crystal::Var.new("__view_#{mangled}"),
          invocation
        )
        defs << wrapper
        invocations << {id, invocation}
      end

      full_ast = Crystal::Expressions.new([
        Crystal::Require.new("prelude").at(location).as(Crystal::ASTNode),
        stub_ast,
      ] + defs)

      begin
        program.semantic(program.normalize(full_ast))
      rescue ex
        STDERR.puts "  view semantic analysis failed: #{ex.message.to_s.lines.first}"
        return false
      end

      # Collect typed bodies from each invocation's target_defs
      invocations.each do |id, call|
        targets = call.target_defs
        next unless targets && !targets.empty?
        @typed_bodies[id] = targets.first.body
      end

      true
    end

    # Typed body for a view id, or nil if analyze hasn't run / it wasn't
    # successfully typed.
    def typed_body_for(id : String) : Crystal::ASTNode?
      @typed_bodies[id]?
    end

    # Extract the Crystal type name (as a String) from an Arg's restriction.
    # Returns "Object" as a safe fallback when no restriction is present.
    private def type_name_of(arg : Crystal::Arg) : String
      if r = arg.restriction
        case r
        when Crystal::Path
          r.names.join("::")
        else
          r.to_s
        end
      else
        "Object"
      end
    end

    # Create a new Def with a different name, keeping body/args/return type.
    private def rename_def(original : Crystal::Def, new_name : String) : Crystal::Def
      Crystal::Def.new(
        new_name,
        original.args,
        original.body,
        return_type: original.return_type,
      )
    end

    # Mangle a view id into a legal method name.
    # "articles/show"     → "view_articles_show"
    # "articles/_comment" → "view_articles__comment"
    private def mangle(id : String) : String
      "view_" + id.gsub('/', '_').gsub('-', '_').gsub('.', '_')
    end

    # Minimal stubs: prelude is added separately; here we emit just enough
    # typed class definitions for models used by views. View helpers (link_to,
    # button_to, path helpers, etc.) are added incrementally as generators
    # start using this analyzer against real blog views.
    private def build_stub_source : String
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      String.build do |io|
        app.models.each do |name, model|
          table_name = Inflector.pluralize(Inflector.underscore(name))
          schema = schema_map[table_name]?

          io << "class #{name}\n"
          io << "  property id : Int64 = 0\n"

          if schema
            schema.columns.each do |col|
              next if col.name == "id"
              ct = SchemaExtractor.crystal_type(col.type)
              default = default_for(ct)
              io << "  property #{col.name} : #{ct} = #{default}\n"
            end
          end

          # Association accessors
          model.associations.each do |assoc|
            case assoc.kind
            when :has_many
              target = Inflector.classify(Inflector.singularize(assoc.name))
              io << "  def #{assoc.name} : Array(#{target})\n"
              io << "    [] of #{target}\n"
              io << "  end\n"
            when :belongs_to
              target = Inflector.classify(assoc.name)
              io << "  def #{assoc.name} : #{target}\n"
              io << "    #{target}.new\n"
              io << "  end\n"
            when :has_one
              target = Inflector.classify(assoc.name)
              io << "  def #{assoc.name} : #{target}\n"
              io << "    #{target}.new\n"
              io << "  end\n"
            end
          end

          io << "  def errors : Array(String)\n    [] of String\n  end\n"
          io << "end\n\n"
        end
      end
    end

    private def default_for(crystal_type : String) : String
      base = crystal_type.chomp("?")
      case base
      when "String"  then "\"\""
      when "Int32", "Int64", "Float32", "Float64"
        "0"
      when "Bool"    then "false"
      when "Time"    then "Time.utc"
      when "Bytes"   then "Bytes.new(0)"
      else                "nil.as(#{crystal_type})"
      end
    end
  end
end
