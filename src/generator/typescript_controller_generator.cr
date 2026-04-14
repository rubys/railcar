# Generates TypeScript controller files from Rails controller source.
#
# Pipeline: Ruby source → Prism → Crystal AST → shared filters →
#           ControllerBoilerplateTypeScript filter → Cr2Ts emitter →
#           TypeScript Express route handlers.

require "./inflector"
require "./source_parser"
require "../filters/shared_controller_filters"
require "../filters/controller_boilerplate_typescript"
require "../emitter/typescript/cr2ts"

module Railcar
  class TypeScriptControllerGenerator
    getter app : AppModel
    getter rails_dir : String
    getter emitter : Cr2Ts::Emitter

    def initialize(@app, @rails_dir, @emitter = Cr2Ts::Emitter.new)
    end

    def generate(output_dir : String)
      controllers_dir = File.join(output_dir, "controllers")
      Dir.mkdir_p(controllers_dir)

      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        source_path = File.join(rails_dir, "app/controllers/#{controller_name}_controller.rb")
        next unless File.exists?(source_path)

        model_name = Inflector.classify(Inflector.singularize(controller_name))
        singular = Inflector.singularize(controller_name)
        plural = Inflector.pluralize(controller_name)
        nested_parent = app.routes.nested_parent_for(plural)

        # Parse and filter through AST pipeline
        ast = SourceParser.parse(source_path)
        ast = SharedControllerFilters.apply(ast)
        ast = ast.transform(ControllerBoilerplateTypeScript.new(
          controller_name, model_name, nested_parent, info.before_actions))

        # Emit TypeScript
        io = IO::Memory.new

        # Imports
        io << "import type { Request, Response } from \"express\";\n"
        io << "import { #{model_name} } from \"../models/#{Inflector.underscore(model_name)}.js\";\n"
        if nested_parent
          parent_model = Inflector.classify(nested_parent)
          io << "import { #{parent_model} } from \"../models/#{nested_parent}.js\";\n"
        end
        io << "import * as helpers from \"../helpers.js\";\n"
        io << "import * as views from \"../views/#{plural}.js\";\n"
        io << "\n"

        # Emit each function from the filtered AST
        emit_controller_functions(ast, io, singular)

        out_path = File.join(controllers_dir, "#{controller_name}.ts")
        File.write(out_path, io.to_s)
        puts "  controllers/#{controller_name}.ts"
      end
    end

    private def emit_controller_functions(ast : Crystal::ASTNode, io : IO, singular : String)
      defs = case ast
             when Crystal::Expressions then ast.expressions
             else [ast]
             end

      defs.each do |node|
        next unless node.is_a?(Crystal::Def)
        emit_function(node.as(Crystal::Def), io, singular)
      end
    end

    private def emit_function(defn : Crystal::Def, io : IO, singular : String)
      name = defn.name
      ret_type = ": void"

      # Build parameter list
      params = defn.args.map do |arg|
        case arg.name
        when "req"  then "req: Request"
        when "res"  then "res: Response"
        when "data"
          if arg.default_value
            "data?: Record<string, string[]>"
          else
            "data: Record<string, string[]>"
          end
        else "#{arg.name}: unknown"
        end
      end

      io << "export function #{name}(#{params.join(", ")})#{ret_type} {\n"
      emit_function_body(defn.body, io, singular)
      io << "}\n\n"
    end

    private def emit_function_body(node : Crystal::ASTNode, io : IO, singular : String, indent : String = "  ")
      case node
      when Crystal::Expressions
        node.expressions.each { |e| emit_stmt(e, io, singular, indent) }
      when Crystal::Nop
        # empty
      else
        emit_stmt(node, io, singular, indent)
      end
    end

    private def emit_stmt(node : Crystal::ASTNode, io : IO, singular : String, indent : String = "  ")
      case node
      when Crystal::Assign
        target = emit_value(node.target)
        value = emit_value(node.value)
        # Don't redeclare function parameters (e.g., data)
        target_name = node.target.is_a?(Crystal::Var) ? node.target.as(Crystal::Var).name : ""
        keyword = {"data", "req", "res"}.includes?(target_name) ? "" : "const "
        io << "#{indent}#{keyword}#{target} = #{value};\n"

      when Crystal::If
        cond = emit_condition(node.cond)
        io << "#{indent}if (#{cond}) {\n"
        emit_function_body(node.then, io, singular, indent + "  ")
        if node.else && !node.else.is_a?(Crystal::Nop)
          io << "#{indent}} else {\n"
          emit_function_body(node.else, io, singular, indent + "  ")
        end
        io << "#{indent}}\n"

      when Crystal::Call
        io << "#{indent}#{emit_value(node)};\n"

      when Crystal::Return
        if exp = node.exp
          io << "#{indent}return #{emit_value(exp)};\n"
        else
          io << "#{indent}return;\n"
        end

      when Crystal::Nop
        # skip

      else
        io << "#{indent}// TODO: #{node.class.name}\n"
      end
    end

    private def emit_value(node : Crystal::ASTNode) : String
      case node
      when Crystal::Var
        node.name
      when Crystal::Path
        node.names.join(".")
      when Crystal::StringLiteral
        node.value.inspect
      when Crystal::NumberLiteral
        node.value.to_s.gsub(/_i64|_i32/, "")
      when Crystal::NilLiteral
        "null"
      when Crystal::BoolLiteral
        node.value.to_s
      when Crystal::SymbolLiteral
        node.value.inspect
      when Crystal::Call
        emit_call(node)
      when Crystal::Not
        "!#{emit_value(node.exp)}"
      when Crystal::And
        "#{emit_value(node.left)} && #{emit_value(node.right)}"
      when Crystal::Or
        "#{emit_value(node.left)} || #{emit_value(node.right)}"
      else
        "/* TODO: #{node.class.name} */"
      end
    end

    private def emit_call(node : Crystal::Call) : String
      name = node.name
      obj = node.obj
      args = node.args.map { |a| emit_value(a) }

      # Special cases
      case name
      when "nil?"
        obj_str = obj ? emit_value(obj) : "this"
        return "#{obj_str} == null"
      when "params", "body"
        # Express: req.params, req.body are properties not methods
        obj_str = obj ? emit_value(obj) : "req"
        return "#{obj_str}.#{name}"
      when "read"
        # request.read → req.body (Express uses body, not read)
        obj_str = obj ? emit_value(obj) : "req"
        return "#{obj_str}.body"
      when "Number"
        return "Number(#{args.join(", ")})"
      when "[]"
        obj_str = obj ? emit_value(obj) : ""
        return "#{obj_str}[#{args.join}]"
      when "parseForm"
        return "helpers.parseForm(#{args.join(", ")})"
      when "extractModelParams"
        return "helpers.extractModelParams(#{args.join(", ")})"
      when "layout"
        return "helpers.layout(#{args.join(", ")})"
      when "find"
        obj_str = obj ? emit_value(obj) : ""
        return "#{obj_str}.find(#{args.join(", ")})"
      when "new"
        obj_str = obj ? emit_value(obj) : ""
        return "new #{obj_str}(#{args.join(", ")})"
      when "save"
        obj_str = obj ? emit_value(obj) : "this"
        return "#{obj_str}.save()"
      when "update"
        obj_str = obj ? emit_value(obj) : "this"
        return "#{obj_str}.update(#{args.join(", ")})"
      when "destroy"
        obj_str = obj ? emit_value(obj) : "this"
        return "#{obj_str}.destroy()"
      when "build"
        obj_str = obj ? emit_value(obj) : "this"
        return "#{obj_str}.build(#{args.join(", ")})"
      when "all"
        obj_str = obj ? emit_value(obj) : ""
        return "#{obj_str}.all(#{args.join(", ")})"
      when "redirect"
        obj_str = obj ? emit_value(obj) : "res"
        return "#{obj_str}.redirect(#{args.join(", ")})"
      when "send"
        obj_str = obj ? emit_value(obj) : "res"
        return "#{obj_str}.send(#{args.join(", ")})"
      when "status"
        obj_str = obj ? emit_value(obj) : "res"
        return "#{obj_str}.status(#{args.join(", ")})"
      end

      # Path helpers → helpers.namePath()
      if name.ends_with?("Path")
        return "helpers.#{name}(#{args.join(", ")})"
      end

      # View render functions → views.renderName()
      if name.starts_with?("render")
        return "views.#{name}(#{args.join(", ")})"
      end

      # Association calls need cast (article.comments() etc.)
      if obj && {"comments", "articles", "build", "destroy_all"}.includes?(name)
        obj_str = emit_value(obj)
        ts_name = name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
        return "(#{obj_str} as any).#{ts_name}(#{args.join(", ")})"
      end

      # Generic call
      if obj
        obj_str = emit_value(obj)
        ts_name = name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
        "#{obj_str}.#{ts_name}(#{args.join(", ")})"
      else
        ts_name = name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
        "#{ts_name}(#{args.join(", ")})"
      end
    end

    private def emit_condition(node : Crystal::ASTNode) : String
      case node
      when Crystal::Call
        if node.name == "nil?"
          obj_str = node.obj ? emit_value(node.obj.not_nil!) : "this"
          "#{obj_str} == null"
        elsif node.name == "save" || node.name == "update"
          emit_call(node)
        else
          emit_value(node)
        end
      when Crystal::Not
        "!(#{emit_condition(node.exp)})"
      when Crystal::And
        "(#{emit_condition(node.left)} && #{emit_condition(node.right)})"
      when Crystal::Or
        "(#{emit_condition(node.left)} || #{emit_condition(node.right)})"
      when Crystal::Var
        node.name
      else
        emit_value(node)
      end
    end
  end
end
