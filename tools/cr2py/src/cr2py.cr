# cr2py — Crystal to Python transpiler
#
# Reads a compiled Crystal application (via Compiler.no_codegen),
# walks the typed AST, and emits equivalent Python source.
#
# Usage: cr2py path/to/crystal-app/src/app.cr output-dir
#
# The input must be a compilable Crystal application with shards installed.

require "../../../src/semantic"
require "../../../src/generator/python_emitter"
require "../../../src/generator/python_model_runtime"
require "../../../src/generator/inflector"
require "file_utils"

module Cr2Py
  class Transpiler
    getter program : Crystal::Program
    getter typed_ast : Crystal::ASTNode
    getter railcar : Crystal::Type
    getter app_dir : String
    getter output_dir : String

    def initialize(@program, @typed_ast, @railcar, @app_dir, @output_dir)
    end

    def run
      Dir.mkdir_p(output_dir)

      models = [] of {String, Crystal::Type}
      controllers = [] of {String, Crystal::Type}

      railcar.types.each do |name, type|
        if name.ends_with?("Controller") && !%w[Router].includes?(name)
          controllers << {name, type}
        elsif !runtime_type?(name)
          models << {name, type}
        end
      end

      puts "  models: #{models.map(&.[0]).join(", ")}"
      puts "  controllers: #{controllers.map(&.[0]).join(", ")}"

      emit_models(models)
      emit_helpers(models)
      emit_controllers(controllers, models)
      emit_views(controllers)
      emit_app(controllers, models)
      emit_pyproject
    end

    private def runtime_type?(name : String) : Bool
      %w[ErrorEntry Errors TurboBroadcast Broadcasts Log ValidationError
         RecordNotFound ApplicationRecord Relation CollectionProxy
         RouteHelpers ViewHelpers Router].includes?(name)
    end

    # --- Models ---

    private def emit_models(models : Array({String, Crystal::Type}))
      models_dir = File.join(output_dir, "models")
      Dir.mkdir_p(models_dir)

      # base.py — ApplicationRecord runtime
      File.write(File.join(models_dir, "base.py"), Railcar::PythonModelRuntime.generate)
      puts "  models/base.py"

      # __init__.py
      init = String.build do |io|
        io << "import sqlite3\n"
        io << "import os\n\n"
        io << "DB_PATH = os.path.join(os.path.dirname(__file__), '..', '#{File.basename(output_dir)}.db')\n\n"
        io << "def get_db():\n"
        io << "    conn = sqlite3.connect(DB_PATH)\n"
        io << "    conn.row_factory = sqlite3.Row\n"
        io << "    conn.execute('PRAGMA foreign_keys = ON')\n"
        io << "    return conn\n\n"
        io << "def init_db():\n"
        io << "    db = get_db()\n"

        # DDL from model types
        models.each do |name, type|
          table = Railcar::Inflector.pluralize(Railcar::Inflector.underscore(name))
          columns = extract_columns(type)
          io << "    db.execute('''\n"
          io << "        CREATE TABLE IF NOT EXISTS #{table} (\n"
          io << "            id INTEGER PRIMARY KEY AUTOINCREMENT"
          columns.each do |col_name, col_type|
            sql_type = crystal_to_sql_type(col_type)
            io << ",\n            #{col_name} #{sql_type}"
            if col_name.ends_with?("_id")
              ref_table = Railcar::Inflector.pluralize(col_name.chomp("_id"))
              io << " REFERENCES #{ref_table}(id)"
            end
          end
          io << "\n        )\n    ''')\n"
        end

        io << "    db.commit()\n"
        io << "    db.close()\n\n"

        models.each do |name, _|
          filename = Railcar::Inflector.underscore(name)
          io << "from .#{filename} import #{name}\n"
        end
      end

      File.write(File.join(models_dir, "__init__.py"), init)
      puts "  models/__init__.py"

      # Individual model files
      models.each do |name, type|
        emit_model(name, type, models, models_dir)
      end
    end

    private def emit_model(name : String, type : Crystal::Type, all_models : Array({String, Crystal::Type}), models_dir : String)
      table = Railcar::Inflector.pluralize(Railcar::Inflector.underscore(name))
      columns = extract_columns(type)
      validations = extract_validations(type)
      associations = extract_associations(name, type, all_models)

      io = String.build do |io|
        io << "from .base import ApplicationRecord\n\n\n"
        io << "class #{name}(ApplicationRecord):\n"
        io << "    TABLE = '#{table}'\n"
        io << "    COLUMNS = #{columns.map(&.[0].inspect).to_a}\n"
        io << "    VALIDATIONS = #{validations}\n"
        io << "    ASSOCIATIONS = #{associations}\n"

        # Association methods
        type.defs.try &.each do |method_name, defs_list|
          defs_list.each do |d|
            ret = d.def.return_type || d.def.body.try(&.type?)
            next unless ret
            ret_str = ret.to_s

            if ret_str.starts_with?("Railcar::CollectionProxy(")
              # has_many
              target = ret_str.gsub(/.*CollectionProxy\(Railcar::(\w+)\).*/, "\\1")
              fk = Railcar::Inflector.underscore(name) + "_id"
              io << "\n    def #{method_name}(self):\n"
              io << "        from .#{Railcar::Inflector.underscore(target)} import #{target}\n"
              io << "        return #{target}.where(#{fk}=self.id)\n"
            elsif ret_str =~ /Railcar::(\w+)/ && method_name != "destroy" && d.def.args.empty?
              target = $1
              if all_models.any? { |m, _| m == target } && method_name != name.downcase
                # belongs_to
                io << "\n    def #{method_name}(self):\n"
                io << "        from .#{Railcar::Inflector.underscore(target)} import #{target}\n"
                io << "        return #{target}.find(self.#{method_name}_id)\n"
              end
            end
          end
        end
      end

      filename = Railcar::Inflector.underscore(name)
      File.write(File.join(models_dir, "#{filename}.py"), io)
      puts "  models/#{filename}.py"
    end

    # --- Helpers ---

    private def emit_helpers(models : Array({String, Crystal::Type}))
      io = String.build do |io|
        io << "import base64\n"
        io << "import json\n"
        io << "from urllib.parse import parse_qs\n\n"

        io << "def parse_form(body_bytes):\n"
        io << "    return parse_qs(body_bytes.decode('utf-8'))\n\n"

        io << "def form_value(data, key):\n"
        io << "    return data.get(key, [''])[0]\n\n"

        # Layout
        io << "LAYOUT_HEAD = '''<!DOCTYPE html>\n<html>\n<head>\n"
        io << "  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
        io << "  <meta name=\"action-cable-url\" content=\"/cable\">\n"
        io << "  <link rel=\"stylesheet\" href=\"/static/app.css\">\n"
        io << "  <script type=\"module\" src=\"/static/turbo.min.js\"></script>\n"
        io << "</head>\n<body>\n  <main class=\"container mx-auto mt-28 px-5 flex flex-col\">'''\n\n"
        io << "LAYOUT_TAIL = '''  </main>\n</body>\n</html>'''\n\n"
        io << "def layout(content, title='Blog'):\n"
        io << "    head = LAYOUT_HEAD.replace('<head>', f'<head>\\n  <title>{title}</title>', 1)\n"
        io << "    return head + content + LAYOUT_TAIL\n\n"

        # View helpers — read from the Crystal type info
        emit_view_helpers(io)

        # Path helpers from RouteHelpers
        emit_path_helpers(io, models)

        # form helpers
        emit_form_helpers(io)
      end

      File.write(File.join(output_dir, "helpers.py"), io)
      puts "  helpers.py"
    end

    private def emit_view_helpers(io : IO)
      io << "def link_to(text, url, **kwargs):\n"
      io << "    if 'class_' in kwargs:\n"
      io << "        kwargs['class'] = kwargs.pop('class_')\n"
      io << "    attrs = ''.join(f' {k}=\"{v}\"' for k, v in kwargs.items())\n"
      io << "    return f'<a href=\"{url}\"{attrs}>{text}</a>'\n\n"

      io << "def button_to(text, url, **kwargs):\n"
      io << "    method = kwargs.pop('method', 'post')\n"
      io << "    btn_class = kwargs.pop('class_', kwargs.pop('class', ''))\n"
      io << "    confirm = kwargs.pop('data_turbo_confirm', '')\n"
      io << "    form_class = kwargs.pop('form_class', '')\n"
      io << "    form_attrs = f' class=\"{form_class}\"' if form_class else ''\n"
      io << "    confirm_attr = f' data-turbo-confirm=\"{confirm}\"' if confirm else ''\n"
      io << "    cls_attr = f' class=\"{btn_class}\"' if btn_class else ''\n"
      io << "    return (\n"
      io << "        f'<form method=\"post\" action=\"{url}\"{form_attrs}{confirm_attr}>'\n"
      io << "        f'<input type=\"hidden\" name=\"_method\" value=\"{method}\">'\n"
      io << "        f'<button type=\"submit\"{cls_attr}>{text}</button>'\n"
      io << "        f'</form>')\n\n"

      io << "def dom_id(obj, prefix=None):\n"
      io << "    name = type(obj).__name__.lower()\n"
      io << "    if prefix:\n"
      io << "        return f'{prefix}_{name}_{obj.id}'\n"
      io << "    return f'{name}_{obj.id}'\n\n"

      io << "def pluralize(count, singular, plural=None):\n"
      io << "    if plural is None:\n"
      io << "        plural = singular + 's'\n"
      io << "    return f'{count} {singular if count == 1 else plural}'\n\n"

      io << "def truncate(text, length=30, omission='...'):\n"
      io << "    if text is None:\n"
      io << "        return ''\n"
      io << "    if len(text) <= length:\n"
      io << "        return text\n"
      io << "    return text[:length - len(omission)] + omission\n\n"

      io << "def turbo_stream_from(channel):\n"
      io << "    signed = base64.b64encode(json.dumps(channel).encode()).decode()\n"
      io << "    return f'<turbo-cable-stream-source channel=\"Turbo::StreamsChannel\" signed-stream-name=\"{signed}\"></turbo-cable-stream-source>'\n\n"
    end

    private def emit_path_helpers(io : IO, models : Array({String, Crystal::Type}))
      # Read path helpers from the RouteHelpers type
      route_helpers = railcar.types["RouteHelpers"]?
      if route_helpers
        route_helpers.defs.try &.each do |method_name, defs_list|
          defs_list.each do |d|
            args = d.def.args
            if args.empty?
              io << "def #{method_name}():\n"
              # Infer path from method name
              if method_name.starts_with?("new_")
                model = method_name.gsub(/^new_|_path$/, "")
                plural = Railcar::Inflector.pluralize(model)
                io << "    return '/#{plural}/new'\n\n"
              else
                plural = method_name.chomp("_path")
                io << "    return '/#{plural}'\n\n"
              end
            else
              param = args[0].name
              if method_name.starts_with?("edit_")
                model = method_name.gsub(/^edit_|_path$/, "")
                plural = Railcar::Inflector.pluralize(model)
                io << "def #{method_name}(#{param}):\n"
                io << "    return f'/#{plural}/{#{param}.id}/edit'\n\n"
              elsif method_name.includes?("_") && args.size == 2
                # Nested: article_comment_path(article, comment)
                parts = method_name.chomp("_path").split("_")
                parent_plural = Railcar::Inflector.pluralize(parts[0])
                child_plural = Railcar::Inflector.pluralize(parts[1])
                p1 = args[0].name
                p2 = args[1].name
                io << "def #{method_name}(#{p1}_or_id, #{p2}):\n"
                io << "    pid = #{p1}_or_id.id if hasattr(#{p1}_or_id, 'id') else #{p1}_or_id\n"
                io << "    return f'/#{parent_plural}/{pid}/#{child_plural}/{#{p2}.id}'\n\n"
              elsif method_name.includes?("_") && !method_name.starts_with?("edit_") && !method_name.starts_with?("new_")
                # Nested collection: article_comments_path(article)
                parts = method_name.chomp("_path").split("_")
                if parts.size >= 2
                  parent_plural = Railcar::Inflector.pluralize(parts[0])
                  child = parts[1..]
                  io << "def #{method_name}(#{param}):\n"
                  io << "    return f'/#{parent_plural}/{#{param}.id}/#{child.join("_")}'\n\n"
                end
              else
                model = method_name.chomp("_path")
                plural = Railcar::Inflector.pluralize(model)
                io << "def #{method_name}(#{param}):\n"
                io << "    return f'/#{plural}/{#{param}.id}'\n\n"
              end
            end
          end
        end
      end
    end

    private def emit_form_helpers(io : IO)
      io << "def form_with_open_tag(**kwargs):\n"
      io << "    model = kwargs.get('model')\n"
      io << "    css = kwargs.get('class_', kwargs.get('class', ''))\n"
      io << "    cls_attr = f' class=\"{css}\"' if css else ''\n"
      io << "    name = type(model).__name__.lower()\n"
      io << "    plural = name + 's'\n"
      io << "    if model.id:\n"
      io << "        return (f'<form action=\"/{plural}/{model.id}\" method=\"post\"{cls_attr}>'\n"
      io << "                f'<input type=\"hidden\" name=\"_method\" value=\"patch\">')\n"
      io << "    return f'<form action=\"/{plural}\" method=\"post\"{cls_attr}>'\n\n"

      io << "def form_submit_tag(**kwargs):\n"
      io << "    model = kwargs.get('model')\n"
      io << "    css = kwargs.get('class_', kwargs.get('class', ''))\n"
      io << "    cls_attr = f' class=\"{css}\"' if css else ''\n"
      io << "    name = type(model).__name__\n"
      io << "    action = 'Update' if model.id else 'Create'\n"
      io << "    return f'<input type=\"submit\" value=\"{action} {name}\"{cls_attr}>'\n\n"

      io << "def form_with(**kwargs):\n"
      io << "    model = kwargs.get('model')\n"
      io << "    css = kwargs.get('class_', kwargs.get('class', ''))\n"
      io << "    cls_attr = f' class=\"{css}\"' if css else ''\n"
      io << "    if isinstance(model, list) and len(model) == 2:\n"
      io << "        parent, child = model\n"
      io << "        parent_name = type(parent).__name__.lower()\n"
      io << "        child_name = type(child).__name__.lower()\n"
      io << "        action = f'/{parent_name}s/{parent.id}/{child_name}s'\n"
      io << "        return f'<form action=\"{action}\" method=\"post\"{cls_attr}>'\n"
      io << "    elif model is not None:\n"
      io << "        name = type(model).__name__.lower()\n"
      io << "        plural = name + 's'\n"
      io << "        if model.id:\n"
      io << "            return (f'<form action=\"/{plural}/{model.id}\" method=\"post\"{cls_attr}>'\n"
      io << "                    f'<input type=\"hidden\" name=\"_method\" value=\"patch\">')\n"
      io << "        else:\n"
      io << "            return f'<form action=\"/{plural}\" method=\"post\"{cls_attr}>'\n"
      io << "    return f'<form method=\"post\"{cls_attr}>'\n\n"
    end

    # --- Controllers ---

    private def emit_controllers(controllers : Array({String, Crystal::Type}), models : Array({String, Crystal::Type}))
      controllers_dir = File.join(output_dir, "controllers")
      Dir.mkdir_p(controllers_dir)
      File.write(File.join(controllers_dir, "__init__.py"), "")

      controllers.each do |name, type|
        emit_controller(name, type, models, controllers_dir)
      end
    end

    private def emit_controller(name : String, type : Crystal::Type, models : Array({String, Crystal::Type}), controllers_dir : String)
      controller_name = Railcar::Inflector.underscore(name).chomp("_controller")
      model_name = Railcar::Inflector.classify(Railcar::Inflector.singularize(controller_name))

      io = String.build do |io|
        io << "from aiohttp import web\n"
        io << "from models import *\n"
        io << "from helpers import *\n"
        io << "from views.#{controller_name} import *\n\n"

        # Emit each action method
        type.defs.try &.each do |method_name, defs_list|
          defs_list.each do |d|
            args = d.def.args
            # Skip non-action methods (helpers injected by ControllerBoilerplate)
            next if %w[extract_model_params layout].includes?(method_name)
            next if method_name.starts_with?("render_")

            # Only emit actions that take HTTP::Server::Response
            next unless args.any? { |a| a.restriction.to_s.includes?("Response") }

            emit_action(io, method_name, d.def, controller_name, model_name)
          end
        end
      end

      File.write(File.join(controllers_dir, "#{controller_name}.py"), io)
      puts "  controllers/#{controller_name}.py"
    end

    private def emit_action(io : IO, name : String, method_def : Crystal::Def,
                             controller_name : String, model_name : String)
      singular = Railcar::Inflector.underscore(model_name).downcase
      args = method_def.args

      # Determine parameters
      has_id = args.any? { |a| a.name == "id" }
      has_params = args.any? { |a| a.name == "params" }
      has_parent_id = args.any? { |a| a.name.ends_with?("_id") && a.name != "id" }
      needs_data = has_params || name == "destroy"

      if needs_data
        io << "async def #{name}(request, data=None):\n"
      else
        io << "async def #{name}(request):\n"
      end

      # Extract route params
      if has_parent_id
        parent_param = args.find { |a| a.name.ends_with?("_id") && a.name != "id" }.not_nil!.name
        io << "    #{parent_param} = int(request.match_info['#{parent_param}'])\n"
      end
      if has_id
        io << "    id = int(request.match_info['id'])\n"
      end

      # Parse form data
      if needs_data
        io << "    if data is None:\n"
        io << "        data = parse_form(await request.read())\n"
      end

      # Emit body using the Python emitter on the typed AST
      emitter = Railcar::PythonEmitter.new(indent: 1)
      body = method_def.body
      if body
        # Filter out flash/notice/response boilerplate and emit the core logic
        emit_action_body(io, body, name, controller_name, model_name, singular)
      end

      io << "\n"
    end

    private def emit_action_body(io : IO, body : Crystal::ASTNode, action_name : String,
                                  controller_name : String, model_name : String, singular : String)
      plural = Railcar::Inflector.pluralize(singular)

      case body
      when Crystal::Expressions
        body.expressions.each do |expr|
          emit_action_statement(io, expr, action_name, controller_name, model_name, singular, plural)
        end
      else
        emit_action_statement(io, body, action_name, controller_name, model_name, singular, plural)
      end
    end

    private def emit_action_statement(io : IO, node : Crystal::ASTNode, action_name : String,
                                       controller_name : String, model_name : String,
                                       singular : String, plural : String)
      case node
      when Crystal::Assign
        target = node.target
        value = node.value

        # Skip flash/notice assignments
        target_str = target.to_s
        return if target_str.includes?("flash") || target_str.includes?("notice") || target_str.includes?("FLASH_STORE")

        # article = Railcar::Article.find(id)
        if value.is_a?(Crystal::Call)
          io << "    #{emit_assign_value(target_str, value, model_name, singular, plural)}\n"
        end

      when Crystal::Call
        call = node
        obj = call.obj

        # response.print(layout(...)) → return web.Response(...)
        if obj.to_s == "response" && call.name == "print"
          io << "    return web.Response(text=#{emit_render_call(call, action_name, singular)}, content_type='text/html')\n"
          return
        end

        # response.status_code = 302 → raise web.HTTPFound/HTTPSeeOther
        if obj.to_s == "response" && call.name == "status_code="
          # The redirect location follows in the next statement — handled by emit_redirect
          return
        end

        # response.headers["Location"] = path
        if obj.to_s == "response.headers" || (obj.is_a?(Crystal::Call) && obj.name == "headers")
          # Extract the path value
          path_expr = call.args[1]? || call.args[0]?
          if path_expr
            io << "    raise web.HTTPSeeOther(#{emit_path_expr(path_expr, singular, plural)})\n"
          end
          return
        end

        # FLASH_STORE assignment
        return if call.to_s.includes?("FLASH_STORE")

        # article.save, article.destroy!, etc
        if obj
          io << "    #{emit_call_expr(call, singular, plural)}\n"
        end

      when Crystal::If
        emit_if_statement(io, node, action_name, controller_name, model_name, singular, plural)

      end
    end

    private def emit_if_statement(io : IO, node : Crystal::If, action_name : String,
                                   controller_name : String, model_name : String,
                                   singular : String, plural : String)
      cond = node.cond
      io << "    if #{emit_cond_expr(cond, singular)}:\n"

      # Then branch
      then_body = node.then
      case then_body
      when Crystal::Expressions
        then_body.expressions.each do |expr|
          io << "    "
          emit_action_statement(io, expr, action_name, controller_name, model_name, singular, plural)
        end
      else
        io << "    "
        emit_action_statement(io, then_body, action_name, controller_name, model_name, singular, plural)
      end

      # Else branch
      if else_body = node.else
        unless else_body.is_a?(Crystal::Nop)
          io << "    else:\n"
          case else_body
          when Crystal::Expressions
            else_body.expressions.each do |expr|
              io << "    "
              emit_action_statement(io, expr, action_name, controller_name, model_name, singular, plural)
            end
          else
            io << "    "
            emit_action_statement(io, else_body, action_name, controller_name, model_name, singular, plural)
          end
        end
      end
    end

    private def emit_assign_value(target : String, value : Crystal::Call, model_name : String,
                                   singular : String, plural : String) : String
      obj = value.obj
      name = value.name
      args = value.args

      # Railcar::Article.find(id) → Article.find(id)
      if obj.to_s.starts_with?("Railcar::") && name == "find"
        return "#{target} = #{model_name}.find(#{args.map(&.to_s).join(", ")})"
      end

      # Railcar::Article.new(extract_model_params(...)) → Article(field=form_value(...), ...)
      if obj.to_s.starts_with?("Railcar::") && name == "new"
        if args.size == 1 && args[0].is_a?(Crystal::Call) && args[0].as(Crystal::Call).name == "extract_model_params"
          columns = extract_data_columns(model_name)
          field_args = columns.map { |c| "#{c}=form_value(data, '#{singular}[#{c}]')" }.join(", ")
          return "#{target} = #{model_name}(#{field_args})"
        elsif args.empty?
          return "#{target} = #{model_name}()"
        end
      end

      # Railcar::Article.includes(...).order(...)  → Article.all(order_by=...)
      if obj.to_s.starts_with?("Railcar::") || (obj.is_a?(Crystal::Call) && obj.to_s.includes?("includes"))
        return "#{target} = #{model_name}.all(order_by='created_at DESC')"
      end

      "#{target} = #{value.to_s}"
    end

    private def emit_cond_expr(cond : Crystal::ASTNode, singular : String) : String
      case cond
      when Crystal::Call
        if cond.name == "save" && cond.obj
          return "#{singular}.save()"
        elsif cond.name == "update" && cond.obj
          return "#{singular}.save()"
        end
      end
      cond.to_s
    end

    private def emit_render_call(call : Crystal::Call, action_name : String, singular : String) : String
      "layout(render_#{action_name}(#{singular}=#{singular}))"
    end

    private def emit_path_expr(expr : Crystal::ASTNode, singular : String, plural : String) : String
      expr_str = expr.to_s
      if expr_str.includes?("_path")
        expr_str.gsub("Railcar::", "").gsub(/(\w+)_path\b/) { "#{$1}_path(#{singular})" }
                .gsub("#{plural}_path(#{singular})", "#{plural}_path()")
      else
        expr_str
      end
    end

    private def emit_call_expr(call : Crystal::Call, singular : String, plural : String) : String
      obj = call.obj.to_s.gsub("Railcar::", "")
      name = call.name
      args = call.args

      if name == "destroy!"
        "#{obj.downcase}.destroy()"
      elsif name == "update"
        columns = extract_data_columns(obj)
        assignments = columns.map { |c| "#{obj.downcase}.#{c} = form_value(data, '#{singular}[#{c}]')" }
        assignments.join("\n    ")
      else
        "#{obj}.#{name}(#{args.map(&.to_s).join(", ")})"
      end
    end

    # --- Views ---

    private def emit_views(controllers : Array({String, Crystal::Type}))
      views_dir = File.join(output_dir, "views")
      Dir.mkdir_p(views_dir)
      File.write(File.join(views_dir, "__init__.py"), "")

      # TODO: Read ECR files from app_dir and transpile
      # For now, create stub view files
      controllers.each do |name, type|
        controller_name = Railcar::Inflector.underscore(name).chomp("_controller")
        io = String.build do |io|
          io << "from helpers import *\n"
          io << "from models import *\n\n"
          io << "# TODO: Transpile views from ECR templates\n"
          io << "# Views will be populated from #{app_dir}/src/views/#{controller_name}/\n"
        end
        File.write(File.join(views_dir, "#{controller_name}.py"), io)
        puts "  views/#{controller_name}.py (stub)"
      end
    end

    # --- App ---

    private def emit_app(controllers : Array({String, Crystal::Type}), models : Array({String, Crystal::Type}))
      io = String.build do |io|
        io << "from aiohttp import web\n"
        io << "import aiohttp\n"
        io << "import os\n"
        io << "import json\n"
        io << "import base64\n"
        io << "import asyncio\n"
        io << "import time\n"
        io << "from models import *\n"
        io << "from helpers import *\n"

        controllers.each do |name, _|
          cn = Railcar::Inflector.underscore(name).chomp("_controller")
          io << "from controllers import #{cn} as #{cn}_controller\n"
        end
        io << "\n"

        # Cable server (same as railcar --python)
        io << "# ActionCable server for Turbo Streams\n"
        io << "class CableServer:\n"
        io << "    def __init__(self):\n"
        io << "        self.channels = {}\n\n"
        io << "    def subscribe(self, ws, channel, identifier):\n"
        io << "        self.channels.setdefault(channel, set()).add((ws, identifier))\n\n"
        io << "    def unsubscribe_all(self, ws):\n"
        io << "        for channel in list(self.channels):\n"
        io << "            self.channels[channel] = {(w, i) for w, i in self.channels[channel] if w is not ws}\n\n"
        io << "    async def broadcast(self, channel, html):\n"
        io << "        for ws, identifier in list(self.channels.get(channel, set())):\n"
        io << "            msg = json.dumps({'type': 'message', 'identifier': identifier, 'message': html})\n"
        io << "            try:\n"
        io << "                await ws.send_str(msg)\n"
        io << "            except Exception:\n"
        io << "                pass\n\n"
        io << "cable = CableServer()\n\n"

        # Cable handler
        io << "async def cable_handler(request):\n"
        io << "    ws = web.WebSocketResponse(protocols=['actioncable-v1-json'])\n"
        io << "    await ws.prepare(request)\n"
        io << "    await ws.send_str(json.dumps({'type': 'welcome'}))\n"
        io << "    async def ping():\n"
        io << "        try:\n"
        io << "            while not ws.closed:\n"
        io << "                await asyncio.sleep(3)\n"
        io << "                if not ws.closed:\n"
        io << "                    await ws.send_str(json.dumps({'type': 'ping', 'message': int(time.time())}))\n"
        io << "        except Exception:\n"
        io << "            pass\n"
        io << "    ping_task = asyncio.create_task(ping())\n"
        io << "    try:\n"
        io << "        async for msg in ws:\n"
        io << "            if msg.type == aiohttp.WSMsgType.TEXT:\n"
        io << "                data = json.loads(msg.data)\n"
        io << "                if data.get('command') == 'subscribe':\n"
        io << "                    identifier = data['identifier']\n"
        io << "                    id_data = json.loads(identifier)\n"
        io << "                    signed = id_data.get('signed_stream_name', '')\n"
        io << "                    channel = json.loads(base64.b64decode(signed.split('--')[0]))\n"
        io << "                    cable.subscribe(ws, channel, identifier)\n"
        io << "                    await ws.send_str(json.dumps({'type': 'confirm_subscription', 'identifier': identifier}))\n"
        io << "    finally:\n"
        io << "        ping_task.cancel()\n"
        io << "        cable.unsubscribe_all(ws)\n"
        io << "    return ws\n\n"

        # Middleware
        io << "@web.middleware\n"
        io << "async def log_middleware(request, handler):\n"
        io << "    response = await handler(request)\n"
        io << "    print(f'{request.method} {request.path} {response.status}')\n"
        io << "    return response\n\n"

        # create_app
        io << "def create_app():\n"
        io << "    application = web.Application(middlewares=[log_middleware])\n"
        io << "    application.router.add_get('/cable', cable_handler)\n"

        # TODO: Read routes from the Crystal Router type
        # For now, hardcode blog routes
        io << "    application.router.add_get('/articles', articles_controller.index)\n"
        io << "    application.router.add_get('/articles/new', articles_controller.new)\n"
        io << "    application.router.add_get('/articles/{id}', articles_controller.show)\n"
        io << "    application.router.add_get('/articles/{id}/edit', articles_controller.edit)\n"
        io << "    application.router.add_post('/articles', articles_controller.create)\n"
        io << "    # TODO: PATCH/DELETE dispatch\n"
        io << "    application.router.add_get('/', articles_controller.index)\n"
        io << "    application.router.add_static('/static', os.path.join(os.path.dirname(__file__), 'static'))\n"
        io << "    return application\n\n"

        io << "if __name__ == '__main__':\n"
        io << "    init_db()\n"
        io << "    print('Blog running at http://localhost:3000')\n"
        io << "    web.run_app(create_app(), host='0.0.0.0', port=3000, print=lambda _: None)\n"
      end

      File.write(File.join(output_dir, "app.py"), io)
      puts "  app.py"
    end

    private def emit_pyproject
      project_name = File.basename(output_dir)
      File.write(File.join(output_dir, "pyproject.toml"),
        "[project]\n" \
        "name = \"#{project_name}\"\n" \
        "version = \"0.1.0\"\n" \
        "requires-python = \">=3.10\"\n" \
        "dependencies = [\"aiohttp\"]\n" \
        "\n" \
        "[project.optional-dependencies]\n" \
        "test = [\"pytest\", \"pytest-aiohttp\", \"pytest-asyncio\"]\n" \
        "\n" \
        "[tool.pytest.ini_options]\n" \
        "asyncio_mode = \"auto\"\n")
      puts "  pyproject.toml"
    end

    # --- Type extraction helpers ---

    private def extract_columns(type : Crystal::Type) : Array({String, String})
      columns = [] of {String, String}
      type.defs.try &.each do |method_name, defs_list|
        # Look for getter methods that have matching setter methods (properties)
        next if method_name.ends_with?("=") || method_name.starts_with?("_")
        next if %w[id comments article allowed_columns run_validations destroy
                    render_broadcast_partial run_after_save_callbacks
                    run_after_destroy_callbacks].includes?(method_name)

        has_setter = type.defs.try &.has_key?("#{method_name}=")
        next unless has_setter

        defs_list.each do |d|
          ret = d.def.return_type || d.def.body.try(&.type?)
          if ret
            columns << {method_name, ret.to_s}
          end
        end
      end
      columns
    end

    private def extract_validations(type : Crystal::Type) : String
      validations = [] of String
      type.defs.try &.each do |method_name, _|
        if method_name == "run_validations"
          # Parse the validation body to extract rules
          # For now, derive from the Crystal model's validate_* class methods
          type.metaclass.defs.try &.each do |cls_method, _|
            if cls_method.starts_with?("validate_presence_")
              field = cls_method.sub("validate_presence_", "")
              validations << "{'field': '#{field}', 'kind': 'presence'}"
            elsif cls_method.starts_with?("validate_length_")
              field = cls_method.sub("validate_length_", "")
              # TODO: extract minimum from the method body
              validations << "{'field': '#{field}', 'kind': 'length', 'minimum': 10}"
            end
          end
        end
      end
      "[#{validations.join(", ")}]"
    end

    private def extract_associations(name : String, type : Crystal::Type,
                                      all_models : Array({String, Crystal::Type})) : String
      associations = [] of String
      type.defs.try &.each do |method_name, defs_list|
        defs_list.each do |d|
          ret = d.def.return_type || d.def.body.try(&.type?)
          next unless ret
          ret_str = ret.to_s

          if ret_str.includes?("CollectionProxy")
            target = ret_str.gsub(/.*CollectionProxy\(Railcar::(\w+)\).*/, "\\1")
            mod = Railcar::Inflector.underscore(target)
            # Check for dependent: :destroy
            has_destroy = type.defs.try(&.has_key?("destroy"))
            dep = has_destroy ? ", 'dependent': 'destroy'" : ""
            associations << "{'kind': 'has_many', 'name': '#{method_name}', 'class_name': '#{target}', 'module': '#{mod}'#{dep}}"
          elsif ret_str =~ /Railcar::(\w+)/ && d.def.args.empty? && method_name != "destroy"
            target = $1
            if all_models.any? { |m, _| m == target } && method_name != name.downcase
              mod = Railcar::Inflector.underscore(target)
              associations << "{'kind': 'belongs_to', 'name': '#{method_name}', 'class_name': '#{target}', 'module': '#{mod}'}"
            end
          end
        end
      end
      "[#{associations.join(", ")}]"
    end

    private def extract_data_columns(model_name : String) : Array(String)
      type = railcar.types[model_name]?
      return [] of String unless type
      extract_columns(type).map(&.[0]).reject { |c| %w[created_at updated_at].includes?(c) }
    end

    private def crystal_to_sql_type(crystal_type : String) : String
      case crystal_type
      when "String"    then "TEXT"
      when "Int64", "Int32" then "INTEGER"
      when "Float64"   then "REAL"
      when "Bool"      then "INTEGER"
      when "Time"      then "TEXT"
      when /Int64 \| ::Nil/ then "INTEGER"
      else "TEXT"
      end
    end
  end
end

# --- Main ---

entry = ARGV[0]?
output_dir = ARGV[1]?

unless entry && output_dir
  STDERR.puts "Usage: cr2py <crystal-app-entry> <output-dir>"
  exit 1
end

unless File.exists?(entry)
  STDERR.puts "File not found: #{entry}"
  exit 1
end

full_path = File.expand_path(entry)
app_dir = File.dirname(File.dirname(full_path))

puts "cr2py: analyzing #{entry}"

compiler = Crystal::Compiler.new
compiler.no_codegen = true

saved_dir = Dir.current
Dir.cd(app_dir)

source = Crystal::Compiler::Source.new(
  "src/" + File.basename(full_path),
  File.read(full_path)
)

begin
  result = compiler.compile(source, "cr2py_analyze")
rescue ex
  STDERR.puts "Compilation failed: #{ex.message.try(&.lines.first)}"
  exit 1
end

Dir.cd(saved_dir)

puts "cr2py: semantic analysis OK"

railcar = result.program.types["Railcar"]?
unless railcar
  STDERR.puts "No Railcar module found"
  exit 1
end

transpiler = Cr2Py::Transpiler.new(result.program, result.node, railcar, app_dir, output_dir)
transpiler.run

puts "cr2py: done"
