# RustViewEmitter — walks filtered Crystal view AST and emits Rust source.
#
# Parallel to GoViewEmitter. The pipeline:
#   ERB → ErbCompiler → Crystal AST → shared view filters → ViewCleanup
#   → RustViewEmitter → Rust function body.
#
# Views become Rust functions returning `String` and appending to
# `buf: String`. Method calls, loops, and conditionals emit plain Rust
# rather than going through a template engine (same approach as
# GoViewEmitter).
#
# Receiver-type resolution is delegated to TypeResolver: given an object
# expression, the resolver returns "String", "Array", "Hash", a model
# name, or "Any", and MethodMap provides the Rust equivalent.

require "compiler/crystal/syntax"
require "./app_model"
require "./inflector"
require "./type_resolver"
require "../filters/method_map"

module Railcar
  class RustViewEmitter
    getter app : AppModel
    getter singular : String
    getter resolver : TypeResolver

    def initialize(@app : AppModel, @singular : String, @resolver : TypeResolver)
    end

    # Emit the body of a view function. Entry point called by RustGenerator.
    def emit_body(node : Crystal::ASTNode, io : IO, indent : String = "    ") : Nil
      case node
      when Crystal::Expressions
        node.expressions.each { |e| emit_body(e, io, indent) }
      when Crystal::Assign
        target = node.target
        value = node.value
        if target.is_a?(Crystal::Var) && target.name == "_buf"
          if value.is_a?(Crystal::StringLiteral) && value.value == ""
            io << "#{indent}let mut buf = String::new();\n"
          end
        else
          val_str = to_rust(value)
          io << "#{indent}let #{target} = #{val_str};\n"
        end
      when Crystal::OpAssign
        target = node.target
        if target.is_a?(Crystal::Var) && target.name == "_buf"
          value = node.value
          if value.is_a?(Crystal::StringLiteral)
            escaped = value.value.gsub("\\", "\\\\").gsub("\"", "\\\"")
            io << "#{indent}buf.push_str(\"#{escaped}\");\n"
          elsif value.is_a?(Crystal::Call) && value.name == "str" && value.args.size == 1
            expr = to_rust(value.args[0])
            io << "#{indent}buf.push_str(&#{expr});\n"
          else
            expr = to_rust(value)
            io << "#{indent}buf.push_str(&#{expr});\n"
          end
        end
      when Crystal::Call
        if node.name == "each" && node.block
          emit_loop(node, io, indent)
        end
      when Crystal::If
        cond = to_rust_condition(node.cond)
        if cond == "false"
          return
        end
        io << "#{indent}if #{cond} {\n"
        emit_body(node.then, io, indent + "    ")
        if node.else && !node.else.is_a?(Crystal::Nop)
          io << "#{indent}} else {\n"
          emit_body(node.else.not_nil!, io, indent + "    ")
        end
        io << "#{indent}}\n"
      when Crystal::Var
        if node.name == "_buf"
          io << "#{indent}buf\n"
        end
      when Crystal::Nop
        # skip
      end
    end

    # Emit a Rust expression for an AST node.
    def to_rust(node : Crystal::ASTNode) : String
      case node
      when Crystal::StringLiteral
        "\"#{node.value.gsub("\"", "\\\"")}\".to_string()"
      when Crystal::NumberLiteral
        node.value.to_s.gsub(/_i64|_i32/, "")
      when Crystal::Var
        node.name == "_buf" ? "buf" : node.name
      when Crystal::InstanceVar
        "self.#{node.name.lchop("@")}"
      when Crystal::Call
        to_rust_call(node)
      when Crystal::StringInterpolation
        emit_interp(node)
      else
        "/* TODO: #{node.class.name} */"
      end
    end

    private def emit_loop(call : Crystal::Call, io : IO, indent : String)
      block = call.block.not_nil!
      block_arg = block.args.first?.try(&.name) || "item"
      collection = call.obj

      is_result = collection.is_a?(Crystal::Call) && collection.as(Crystal::Call).obj != nil &&
                  collection.as(Crystal::Call).name != "errors" &&
                  app.models.values.any? { |m| m.associations.any? { |a| a.name == collection.as(Crystal::Call).name } }

      # Determine the element type for the loop binding (for nested type-aware lookups).
      element_type = "Any"
      if collection
        coll_type = resolver.resolve(collection)
        if coll_type == "Array" && collection.is_a?(Crystal::Call)
          coll_name = collection.as(Crystal::Call).name
          # For a has_many assoc, element type is singular classified.
          element_type = Inflector.classify(Inflector.singularize(coll_name))
          # If that's not actually a model, fall back.
          element_type = "Any" unless app.models.has_key?(element_type)
        end
      end

      inner = self.class.new(app, singular, resolver.with_binding(block_arg, element_type))

      if is_result
        obj_str = to_rust(collection.as(Crystal::Call).obj.not_nil!)
        method = collection.as(Crystal::Call).name
        io << "#{indent}if let Ok(#{block_arg}s) = #{obj_str}.#{method}() {\n"
        io << "#{indent}    for #{block_arg} in &#{block_arg}s {\n"
        if body = block.body
          inner.emit_body(body, io, indent + "        ")
        end
        io << "#{indent}    }\n"
        io << "#{indent}}\n"
      else
        coll_str = collection ? to_rust(collection) : "items"
        io << "#{indent}for #{block_arg} in #{coll_str} {\n"
        if body = block.body
          inner.emit_body(body, io, indent + "    ")
        end
        io << "#{indent}}\n"
      end
    end

    private def to_rust_condition(node : Crystal::ASTNode) : String
      case node
      when Crystal::Var
        return "false" if {"notice", "flash"}.includes?(node.name)
        "!#{node.name}.is_empty()"
      when Crystal::Call
        if node.name == "any?" && node.obj
          "!#{to_rust(node.obj.not_nil!)}.is_empty()"
        elsif node.name == "present?" && node.obj
          "!#{to_rust(node.obj.not_nil!)}.is_empty()"
        else
          to_rust(node)
        end
      when Crystal::Not
        "!(#{to_rust_condition(node.exp)})"
      else
        to_rust(node)
      end
    end

    private def to_rust_call(node : Crystal::Call) : String
      name = node.name
      obj = node.obj
      args = node.args.map { |a| to_rust(a) }

      # Named args
      if named = node.named_args
        if name == "button_to"
          method_val = "\"post\""
          form_cls = "\"\""
          cls = "\"\""
          confirm = "\"\""
          named.each do |na|
            case na.name
            when "method"              then method_val = "\"#{na.value.to_s.strip(':').strip('"')}\""
            when "form_class"          then form_cls = "\"#{na.value.to_s.strip('"')}\""
            when "class"               then cls = "\"#{na.value.to_s.strip('"')}\""
            when "data_turbo_confirm"  then confirm = "\"#{na.value.to_s.strip('"')}\""
            end
          end
          args << method_val << form_cls << cls << confirm
        else
          named.each do |na|
            case na.name
            when "class", "form_class" then args << "\"#{na.value.to_s.strip('"')}\""
            when "model" then args.unshift(to_rust(na.value))
            when "length" then args << na.value.to_s
            end
          end
        end
      end

      # Special call names
      case name
      when "new"
        if obj.is_a?(Crystal::Path)
          model = obj.as(Crystal::Path).names.last
          return "#{model}::new()"
        end
        return "\"\".to_string()"
      when "str", "to_s"
        return obj ? to_rust(obj) : (args.first? || "\"\"".inspect)
      when "link_to"
        return "helpers::link_to(#{args.map { |a| view_arg(a) }.join(", ")})"
      when "button_to"
        return "helpers::button_to(#{args.map { |a| view_arg(a) }.join(", ")})"
      when "truncate"
        return "helpers::truncate(#{view_arg(args[0])}, #{args[1]? || "30"})"
      when "dom_id"
        prefix = args[1]?
        if prefix
          prefix = prefix.chomp(".to_string()")
          prefix = "&#{prefix}" unless prefix.starts_with?("\"")
        end
        return "helpers::dom_id(&#{args[0]}, #{args[0]}.id, #{prefix || "\"\""})"
      when "pluralize"
        return "helpers::pluralize(#{args[0]}, #{view_arg(args[1]? || "\"item\"")})"
      when "turbo_stream_from", "turbo_cable_stream_tag"
        return "helpers::turbo_stream_from(#{view_arg(args[0])})"
      when "form_with_open_tag"
        return "helpers::form_with_open_tag(\"#{Inflector.singularize(args[0]? || "item")}\", #{args[0]? || "item"}.id, #{args[1]? || "\"\""})"
      when "form_submit_tag"
        return "helpers::form_submit_tag(\"#{Inflector.singularize(args[0]? || "item")}\", #{args[0]? || "item"}.id, #{args[1]? || "\"\""})"
      when "errors"
        obj_str = obj ? to_rust(obj) : ""
        return "#{obj_str}.errors()"
      when "full_message"
        obj_str = obj ? to_rust(obj) : ""
        return "#{obj_str}.full_message()"
      end

      # MethodMap lookup, now driven by TypeResolver.
      if obj
        obj_str = to_rust(obj)
        mapping = Railcar.lookup_method(:rust, resolver.resolve(obj), name)
        if mapping
          return Railcar.apply_mapping(mapping, obj_str, args)
        end
      end

      # Path helpers
      if !obj && name.ends_with?("_path")
        return "helpers::#{name}(#{args.map { |a| "#{a}.id" }.join(", ")})"
      end

      # Render partials
      if !obj && name.starts_with?("render_") && name.ends_with?("_partial")
        return "#{name}(#{args.map { |a| "&#{a}" }.join(", ")})"
      end

      # Method on object — field or method access
      if obj
        obj_str = to_rust(obj)
        field = name
        if app.column_names.includes?(field) || field == "id"
          return "#{obj_str}.#{field}"
        end
        # Association methods return Result — unwrap
        if app.models.values.any? { |m| m.associations.any? { |a| a.name == field } }
          return "#{obj_str}.#{field}().unwrap_or_default()"
        end
        return "#{obj_str}.#{field}()"
      end

      # Bare variable
      return node.name if args.empty? && !node.block && !node.named_args

      "#{name}(#{args.join(", ")})"
    end

    private def emit_interp(node : Crystal::StringInterpolation) : String
      format_parts = [] of String
      format_args = [] of String
      node.expressions.each do |part|
        case part
        when Crystal::StringLiteral
          format_parts << part.value.gsub("\\", "\\\\").gsub("\"", "\\\"").gsub("{", "{{").gsub("}", "}}")
        else
          format_parts << "{}"
          format_args << to_rust(part)
        end
      end
      if format_args.empty?
        "\"#{format_parts.join}\".to_string()"
      else
        "format!(\"#{format_parts.join}\", #{format_args.join(", ")})"
      end
    end

    # Convert a view expression to a function argument — strip .to_string() for string literals
    private def view_arg(expr : String) : String
      if expr.starts_with?("\"") && expr.ends_with?(".to_string()")
        expr.chomp(".to_string()")
      elsif expr.starts_with?("\"")
        expr
      else
        "&#{expr}"
      end
    end

  end
end
