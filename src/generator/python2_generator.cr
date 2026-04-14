# Python2Generator — generates Python from typed Crystal AST via PyAST.
#
# Pipeline:
#   1. Build Crystal AST: runtime source + model ASTs (via filter chain)
#   2. program.semantic() with synthetic calls → types on all nodes
#   3. Extract Railcar nodes, apply filters, emit Python via PyAST
#
# Built layer by layer:
#   Layer 1: Runtime (ApplicationRecord, ValidationErrors)
#   Layer 2: Models (Article, Comment — from Rails metadata + filters)
#   Layer 3: Tests
#   Layer 4: Controllers
#   Layer 5: Views
#   Layer 6: App (server, routing, static files)

require "./app_model"
require "./schema_extractor"
require "./inflector"
require "./source_parser"
require "../semantic"
require "../filters/model_boilerplate_python"
require "../filters/broadcasts_to"
require "../filters/controller_boilerplate_python"
require "./erb_compiler"
require "../filters/instance_var_to_local"
require "../filters/view_cleanup"
require "../filters/buf_to_interpolation"
require "../filters/rails_helpers"
require "../filters/link_to_path_helper"
require "../filters/button_to_path_helper"
require "../filters/render_to_partial"
require "../filters/form_to_html"
require "../filters/python_constructor"
require "../filters/python_view"
require "../filters/params_expect"
require "../filters/respond_to_html"
require "../filters/strong_params"
require "../filters/minitest_to_pytest"
require "../emitter/python/py_ast"
require "../emitter/python/cr2py"
require "../emitter/python/filters/db_filter"
require "../emitter/python/filters/pyast_dunder_filter"
require "../emitter/python/filters/pyast_return_filter"
require "../emitter/python/filters/pyast_async_filter"

module Railcar
  class Python2Generator
    getter app : AppModel
    getter rails_dir : String

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      puts "Generating Python (v2) from #{rails_dir}..."
      Dir.mkdir_p(output_dir)

      # Build model ASTs from Rails source
      model_asts = build_model_asts

      # Compile runtime + models together
      program, typed_ast = compile(model_asts)
      unless program && typed_ast
        STDERR.puts "Cannot generate Python without typed AST"
        return
      end

      # Set up filters
      emitter = Cr2Py::Emitter.new(program)
      serializer = PyAST::Serializer.new
      db_filter = Cr2Py::DbFilter.new
      dunder_filter = Cr2Py::PyAstDunderFilter.new
      return_filter = Cr2Py::PyAstReturnFilter.new
      filters = {db_filter, dunder_filter, return_filter}

      # Build model_columns for property detection on untyped variables
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }
      cols = {} of String => Set(String)
      app.models.each_key do |name|
        table = Inflector.pluralize(Inflector.underscore(name))
        if schema = schema_map[table]?
          props = Set(String).new
          schema.columns.each { |c| props << c.name }
          props << "id"
          cols[name] = props
        end
      end
      emitter.model_columns = cols

      # Emit
      nodes = extract_railcar_nodes(typed_ast)
      emit_runtime(nodes, output_dir, emitter, serializer, filters)
      emit_helpers(nodes, output_dir, emitter, serializer, filters)
      emit_models(nodes, output_dir, emitter, serializer, filters)
      emit_controllers(output_dir, emitter, serializer, filters)
      emit_views(output_dir, emitter, serializer, filters)
      emit_app(output_dir)
      emit_pyproject(output_dir)
      copy_static_assets(output_dir)
      emit_tests(output_dir, emitter, serializer, filters)

      # __init__.py files
      Dir.glob(File.join(output_dir, "**/*")).each do |path|
        next unless File.directory?(path)
        init = File.join(path, "__init__.py")
        File.write(init, "") unless File.exists?(init)
      end

      puts "Done! Output in #{output_dir}/"
    end

    # ── Build model ASTs from Rails source ──

    private def build_model_asts : Array(Crystal::ASTNode)
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      asts = [] of Crystal::ASTNode
      app.models.each do |name, model|
        source_path = File.join(rails_dir, "app/models/#{Inflector.underscore(name)}.rb")
        next unless File.exists?(source_path)

        schema = schema_map[Inflector.pluralize(Inflector.underscore(name))]?
        next unless schema

        # Parse Rails model → Crystal AST → filter chain (no macros)
        ast = SourceParser.parse(source_path)
        ast = ast.transform(BroadcastsTo.new)
        ast = ast.transform(ModelBoilerplatePython.new(schema, model))

        asts << ast
      end
      asts
    end

    # ── Compile runtime + models ──

    private def compile(model_asts : Array(Crystal::ASTNode)) : {Crystal::Program?, Crystal::ASTNode?}
      location = Crystal::Location.new("src/app.cr", 1, 1)

      runtime_dir = File.join(File.dirname(__FILE__), "..", "runtime", "python")
      runtime_source = File.read(File.join(runtime_dir, "base.cr"))
      helpers_source = File.read(File.join(runtime_dir, "helpers.cr"))

      source = String.build do |io|
        # DB shard stub
        io << "module DB\n"
        io << "  alias Any = Bool | Float32 | Float64 | Int32 | Int64 | String | Nil\n"
        io << "  class Database\n"
        io << "    def exec(sql : String, *args) end\n"
        io << "    def exec(sql : String, args : Array) end\n"
        io << "    def scalar(sql : String, *args) : Int64; 0_i64; end\n"
        io << "    def query_one(sql : String, *args); nil; end\n"
        io << "    def query_all(sql : String, *args) : Array(Hash(String, DB::Any)); [] of Hash(String, DB::Any); end\n"
        io << "  end\n"
        io << "end\n\n"
        # Runtime source (strip requires)
        [runtime_source, helpers_source].each do |src|
          src.lines.each do |line|
            next if line.strip.starts_with?("require ")
            io << line << "\n"
          end
        end
      end

      all_nodes = [
        Crystal::Require.new("prelude").at(location),
        Crystal::Parser.parse(source),
      ] of Crystal::ASTNode

      # Add models wrapped in module Railcar
      if model_asts.size > 0
        all_nodes << Crystal::ModuleDef.new(
          Crystal::Path.new("Railcar"),
          body: Crystal::Expressions.new(model_asts.map(&.as(Crystal::ASTNode)))
        )
      end

      # Synthetic calls to force typing
      all_nodes.concat(build_synthetic_calls(model_asts))

      nodes = Crystal::Expressions.new(all_nodes)

      program = Crystal::Program.new
      compiler = Crystal::Compiler.new
      compiler.no_codegen = true
      program.compiler = compiler

      normalized = program.normalize(nodes)
      typed = program.semantic(normalized)

      puts "  semantic analysis: OK"
      {program, typed}
    rescue ex
      STDERR.puts "  semantic analysis failed: #{ex.message}"
      STDERR.puts ex.backtrace.first(15).join("\n")
      {nil, nil}
    end

    private def build_synthetic_calls(model_asts : Array(Crystal::ASTNode)) : Array(Crystal::ASTNode)
      calls = [] of Crystal::ASTNode

      # Runtime methods
      calls << Crystal::Parser.parse(<<-CR)
        _ve = Railcar::ValidationErrors.new
        _ve.add("field", "message")
        _ve.any?
        _ve.empty?
        _ve.full_messages
        _ve["field"]
        _ve.clear
        _ar = Railcar::ApplicationRecord.new
        _ar.id
        _ar.persisted?
        _ar.new_record?
        _ar.attributes
        _ar.errors
        _ar.valid?
        _ar.save
        _ar.run_validations
        Railcar::ApplicationRecord.table_name
        Railcar::ApplicationRecord.count
        Railcar::ApplicationRecord.all
        Railcar::ApplicationRecord.find(1_i64)
        _cp = Railcar::CollectionProxy.new(_ar, "fk", "Test")
        _cp.model_class
        _cp.destroy_all
        _cp.size
      CR

      # Model methods — call create, save, find, count on each model
      model_asts.each do |ast|
        if ast.is_a?(Crystal::ClassDef)
          name = ast.name.names.last
          calls << Crystal::Parser.parse(<<-CR)
            _m_#{name.downcase} = Railcar::#{name}.new
            _m_#{name.downcase}.save
            _m_#{name.downcase}.valid?
            _m_#{name.downcase}.run_validations
            Railcar::#{name}.table_name
          CR
        end
      end

      calls
    end

    # ── Emit runtime ──

    private def emit_runtime(nodes : Array(Crystal::ASTNode), output_dir : String,
                             emitter : Cr2Py::Emitter,
                             serializer : PyAST::Serializer,
                             filters : Tuple)
      runtime_dir = File.join(output_dir, "runtime")
      Dir.mkdir_p(runtime_dir)

      # Emit the hand-written Python runtime (not transpiled from Crystal).
      # Crystal base.cr is used only for program.semantic() type checking.
      runtime_source = File.join(File.dirname(__FILE__), "..", "runtime", "python", "base_runtime.py")
      File.copy(runtime_source, File.join(runtime_dir, "base.py"))
      File.write(File.join(runtime_dir, "__init__.py"), "")
      puts "  runtime/base.py"
    end

    # ── Emit helpers ──

    private def emit_helpers(nodes : Array(Crystal::ASTNode), output_dir : String,
                             emitter : Cr2Py::Emitter,
                             serializer : PyAST::Serializer,
                             filters : Tuple)
      # Collect module-level Defs and Assigns (helpers, constants)
      helper_nodes = nodes.select { |n| n.is_a?(Crystal::Def) || n.is_a?(Crystal::Assign) }

      # Add route helpers (generated from app metadata)
      if !helper_nodes.empty?
        emit_file(helper_nodes, "helpers.py", output_dir, emitter, serializer, filters)
      else
        File.write(File.join(output_dir, "helpers.py"), "")
        puts "  helpers.py"
      end

      # Append hand-written Python helpers (route helpers, form helpers, utils)
      helpers_path = File.join(output_dir, "helpers.py")
      File.open(helpers_path, "a") do |f|
        f << "\n# Route helpers\n"
        append_route_helpers(f)
        f << "\n# Python-specific helpers\n"
        f << "import json as _json\n"
        f << "import base64 as _base64\n"
        f << "from urllib.parse import parse_qs, urlencode\n\n"
        f << "def turbo_stream_from(channel):\n"
        f << "    signed = _base64.b64encode(_json.dumps(channel).encode()).decode()\n"
        f << "    return f'<turbo-cable-stream-source channel=\"Turbo::StreamsChannel\" signed-stream-name=\"{signed}\"></turbo-cable-stream-source>'\n\n"
        f << "def truncate(text, length=30, omission='...'):\n"
        f << "    if text is None:\n"
        f << "        return ''\n"
        f << "    if len(text) <= length:\n"
        f << "        return text\n"
        f << "    return text[:length - len(omission)] + omission\n\n"
        f << "def parse_form(body_bytes):\n"
        f << "    return parse_qs(body_bytes.decode('utf-8'), keep_blank_values=True)\n\n"
        f << "def form_value(data, key):\n"
        f << "    return data.get(key, [''])[0]\n\n"
        f << "def extract_model_params(data, model):\n"
        f << "    result = {}\n"
        f << "    prefix = f'{model}['\n"
        f << "    for key, values in data.items():\n"
        f << "        if key.startswith(prefix) and key.endswith(']'):\n"
        f << "            field = key[len(prefix):-1]\n"
        f << "            result[field] = values[0]\n"
        f << "    return result\n\n"
        f << "def encode_params(params):\n"
        f << "    flat = {}\n"
        f << "    for outer_key, inner in params.items():\n"
        f << "        if isinstance(inner, dict):\n"
        f << "            for k, v in inner.items():\n"
        f << "                flat[f'{outer_key}[{k}]'] = v\n"
        f << "        else:\n"
        f << "            flat[outer_key] = inner\n"
        f << "    return urlencode(flat)\n\n"
        f << "def form_with_open_tag(**kwargs):\n"
        f << "    model = kwargs.get('model')\n"
        f << "    css = kwargs.get('class_', kwargs.get('class', ''))\n"
        f << "    cls_attr = f' class=\"{css}\"' if css else ''\n"
        f << "    name = type(model).__name__.lower()\n"
        f << "    plural = name + 's'\n"
        f << "    if model.id:\n"
        f << "        return (f'<form action=\"/{plural}/{model.id}\" method=\"post\"{cls_attr}>'\n"
        f << "                f'<input type=\"hidden\" name=\"_method\" value=\"patch\">')\n"
        f << "    return f'<form action=\"/{plural}\" method=\"post\"{cls_attr}>'\n\n"
        f << "def form_submit_tag(**kwargs):\n"
        f << "    model = kwargs.get('model')\n"
        f << "    css = kwargs.get('class_', kwargs.get('class', ''))\n"
        f << "    cls_attr = f' class=\"{css}\"' if css else ''\n"
        f << "    name = type(model).__name__\n"
        f << "    action = 'Update' if model.id else 'Create'\n"
        f << "    return f'<input type=\"submit\" value=\"{action} {name}\"{cls_attr}>'\n"
      end
    end

    private def append_route_helpers(f : IO)
      app.models.each_key do |name|
        singular = Inflector.underscore(name)
        plural = Inflector.pluralize(singular)

        f << "def #{singular}_path(model):\n"
        f << "    return f'/#{plural}/{model.id}'\n\n"
        f << "def edit_#{singular}_path(model):\n"
        f << "    return f'/#{plural}/{model.id}/edit'\n\n"
        f << "def #{plural}_path():\n"
        f << "    return '/#{plural}'\n\n"
        f << "def new_#{singular}_path():\n"
        f << "    return '/#{plural}/new'\n\n"
      end

      # Nested resource helpers
      app.models.each do |name, model|
        model.associations.each do |assoc|
          if assoc.kind == :has_many
            child = Inflector.singularize(assoc.name)
            child_plural = assoc.name
            parent = Inflector.underscore(name)
            parent_plural = Inflector.pluralize(parent)

            f << "def #{parent}_#{child_plural}_path(parent):\n"
            f << "    return f'/#{parent_plural}/{parent.id}/#{child_plural}'\n\n"
            f << "def #{parent}_#{child}_path(parent, child):\n"
            f << "    return f'/#{parent_plural}/{parent.id}/#{child_plural}/{child.id}'\n\n"
          end
        end
      end
    end

    # ── Emit models ──

    private def emit_models(nodes : Array(Crystal::ASTNode), output_dir : String,
                            emitter : Cr2Py::Emitter,
                            serializer : PyAST::Serializer,
                            filters : Tuple)
      models_dir = File.join(output_dir, "models")
      Dir.mkdir_p(models_dir)

      skip = %w[ValidationErrors ApplicationRecord CollectionProxy]
      nodes.each do |node|
        next unless node.is_a?(Crystal::ClassDef)
        class_name = node.name.names.last
        next if skip.includes?(class_name)

        py_path = "models/#{Inflector.underscore(class_name)}.py"
        emit_file([node], py_path, output_dir, emitter, serializer, filters)

        # Append broadcast callbacks extracted from the original Rails source
        append_broadcast_callbacks(class_name, output_dir, py_path)
      end

      File.write(File.join(models_dir, "__init__.py"), "")
    end

    private def append_broadcast_callbacks(class_name : String, output_dir : String, py_path : String)
      source_path = File.join(rails_dir, "app/models/#{Inflector.underscore(class_name)}.rb")
      return unless File.exists?(source_path)

      # Parse and run BroadcastsTo to get after_save/after_destroy nodes
      ast = SourceParser.parse(source_path)
      ast = ast.transform(BroadcastsTo.new)

      callbacks = [] of String
      exprs = case ast
              when Crystal::ClassDef
                case ast.body
                when Crystal::Expressions then ast.body.as(Crystal::Expressions).expressions
                else [ast.body]
                end
              else [] of Crystal::ASTNode
              end

      exprs.each do |expr|
        next unless expr.is_a?(Crystal::Call)
        call = expr.as(Crystal::Call)
        next unless {"after_save", "after_destroy"}.includes?(call.name)
        next unless block = call.block

        # Extract the broadcast call from the block body
        broadcast_call = extract_broadcast_expr(block.body)
        next unless broadcast_call

        callback_type = call.name
        callbacks << "#{class_name}.#{callback_type}(lambda self: self.#{broadcast_call})"
      end

      return if callbacks.empty?

      out_path = File.join(output_dir, py_path)
      File.open(out_path, "a") do |f|
        f << "\n# Turbo Streams broadcast callbacks\n"
        callbacks.each { |cb| f << cb << "\n" }
      end
    end

    private def extract_broadcast_expr(body : Crystal::ASTNode) : String?
      call = case body
             when Crystal::Call then body
             when Crystal::ExceptionHandler
               body.body.is_a?(Crystal::Call) ? body.body.as(Crystal::Call) : nil
             when Crystal::Expressions
               first = body.as(Crystal::Expressions).expressions.first?
               first.is_a?(Crystal::Call) ? first.as(Crystal::Call) : nil
             else nil
             end
      return nil unless call
      return nil unless call.name.starts_with?("broadcast_")

      # Build Python expression: broadcast_replace_to("channel") or article.broadcast_replace_to("channel")
      args = call.args.map do |a|
        case a
        when Crystal::StringLiteral
          a.value.inspect
        when Crystal::StringInterpolation
          # Convert Crystal interpolation to Python f-string
          parts = a.expressions.map do |part|
            case part
            when Crystal::StringLiteral then part.value
            when Crystal::Call
              # article_id → self.article_id (rewrite bare calls to self)
              if part.obj.nil? && part.args.empty?
                "{self.#{part.name}}"
              else
                "{self.#{part.name}}"
              end
            else "{#{part}}"
            end
          end
          "f\"#{parts.join}\""
        else
          a.to_s.inspect
        end
      end

      method = call.name
      if obj = call.obj
        # article.broadcast_replace_to(...) → self.article().broadcast_replace_to(...)
        "#{obj.to_s}().#{method}(#{args.join(", ")})"
      else
        "#{method}(#{args.join(", ")})"
      end
    end

    # ── Emit controllers ──

    private def emit_controllers(output_dir : String,
                                 emitter : Cr2Py::Emitter,
                                 serializer : PyAST::Serializer,
                                 filters : Tuple)
      controllers_dir = File.join(output_dir, "controllers")
      Dir.mkdir_p(controllers_dir)

      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        source_path = File.join(rails_dir, "app/controllers/#{controller_name}_controller.rb")
        next unless File.exists?(source_path)

        model_name = Inflector.classify(Inflector.singularize(controller_name))
        nested_parent = find_nested_parent(controller_name)

        # Parse and filter
        ast = SourceParser.parse(source_path)
        ast = ast.transform(InstanceVarToLocal.new)
        ast = ast.transform(ParamsExpect.new)
        ast = ast.transform(RespondToHTML.new)
        ast = ast.transform(StrongParams.new)
        ast = ast.transform(ControllerBoilerplatePython.new(controller_name, model_name, nested_parent, info.before_actions))

        # Emit
        py_nodes = emitter.to_nodes(ast)
        db_filter, dunder_filter, return_filter = filters
        py_nodes = return_filter.transform(py_nodes)

        # Apply async filter to controllers
        async_filter = Cr2Py::PyAstAsyncFilter.new
        py_nodes = async_filter.transform(py_nodes)

        mod = PyAST::Module.new(py_nodes)
        content = serializer.serialize(mod)

        # Add imports
        import_lines = Set(String).new
        import_lines << "from aiohttp import web"
        import_lines << "from models.#{Inflector.underscore(model_name)} import #{model_name}"
        import_lines << "from helpers import *"
        import_lines << "from views.#{Inflector.pluralize(controller_name)} import *"
        if nested_parent
          parent_model = Inflector.classify(nested_parent)
          import_lines << "from models.#{Inflector.underscore(parent_model)} import #{parent_model}"
        end
        app.models.each_key do |name|
          next if name == model_name
          if content.includes?(name)
            import_lines << "from models.#{Inflector.underscore(name)} import #{name}"
          end
        end
        imports = import_lines.join("\n") + "\n\n"

        out_path = File.join(controllers_dir, "#{controller_name}.py")
        File.write(out_path, imports + content)
        puts "  controllers/#{controller_name}.py"
      end

      File.write(File.join(controllers_dir, "__init__.py"), "")
    end

    private def find_nested_parent(controller_name : String) : String?
      app.routes.routes.each do |route|
        if route.controller == Inflector.pluralize(controller_name) && route.path.includes?(":")
          parts = route.path.split("/").reject(&.empty?)
          parts.each_with_index do |part, i|
            if part.starts_with?(":") && i > 0
              parent = Inflector.singularize(parts[i - 1])
              return parent if parent != controller_name
            end
          end
        end
      end
      nil
    end

    # ── Emit views ──

    private def emit_views(output_dir : String,
                           emitter : Cr2Py::Emitter,
                           serializer : PyAST::Serializer,
                           filters : Tuple)
      views_dir = File.join(output_dir, "views")
      Dir.mkdir_p(views_dir)

      rails_views = File.join(rails_dir, "app/views")

      # Group templates by controller
      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        template_dir = File.join(rails_views, Inflector.pluralize(controller_name))
        next unless Dir.exists?(template_dir)

        model_name = Inflector.classify(Inflector.singularize(controller_name))
        singular = Inflector.singularize(controller_name)
        view_nodes = [] of PyAST::Node

        Dir.glob(File.join(template_dir, "*.html.erb")).sort.each do |erb_path|
          basename = File.basename(erb_path, ".html.erb")
          func_name = if basename.starts_with?("_")
                        "render_#{basename.lstrip('_')}_partial"
                      else
                        "render_#{basename}"
                      end

          # ERB → Ruby _buf code → Crystal AST
          erb_source = File.read(erb_path)
          ruby_code = ErbCompiler.new(erb_source).src

          begin
            ast = SourceParser.parse_source(ruby_code)
            # Same filter chain as --python0
            ast = ast.transform(InstanceVarToLocal.new)
            ast = ast.transform(RailsHelpers.new)
            ast = ast.transform(LinkToPathHelper.new)
            ast = ast.transform(ButtonToPathHelper.new)
            ast = ast.transform(RenderToPartial.new)
            ast = ast.transform(FormToHTML.new)
            ast = ast.transform(PythonConstructor.new)
            locals = [singular]
            ast = ast.transform(PythonView.new(locals))
            ast = ast.transform(ViewCleanup.new)
            # Convert bare calls matching parameter names to Var nodes
            plural = Inflector.pluralize(singular)
            ast = ViewCleanup.calls_to_vars(ast, [singular, plural, "_buf", "notice", "flash", "form"])
            ast = ast.transform(BufToInterpolation.new)

            # Strip def render wrapper (kept for BufToInterpolation to process)
            body = ast
            while body.is_a?(Crystal::Def) && body.name == "render"
              body = body.body
            end

            # Build function args
            is_partial = basename.starts_with?("_")
            if is_partial
              # Partials use *args to accept optional parent
              args = [Crystal::Arg.new("*args")]
            else
              # Index templates use plural (articles), others use singular (article)
              param_name = basename == "index" ? Inflector.pluralize(singular) : singular
              args = [Crystal::Arg.new(param_name)]
              notice_arg = Crystal::Arg.new("notice")
              notice_arg.default_value = Crystal::NilLiteral.new
              args << notice_arg
            end
            func_def = Crystal::Def.new(func_name, args,
              body, return_type: Crystal::Path.new("String"))

            py_func_nodes = emitter.to_nodes(func_def)

            # For partials, prepend the *args unpack
            if is_partial && py_func_nodes.first?.is_a?(PyAST::Func)
              func = py_func_nodes.first.as(PyAST::Func)
              func.body.unshift(PyAST::Assign.new(singular, "args[-1] if args else None"))
            end
            view_nodes.concat(py_func_nodes)
          rescue ex
            # If ERB compilation fails, emit a stub
            STDERR.puts "  WARN: #{func_name}: #{ex.message}"
            view_nodes << PyAST::Func.new(func_name, [singular], [
              PyAST::Return.new("f'<!-- #{basename} template -->'"),
            ] of PyAST::Node, "str")
          end
        end

        next if view_nodes.empty?

        # Apply filters
        db_filter, dunder_filter, return_filter = filters
        view_nodes = return_filter.transform(view_nodes)

        mod = PyAST::Module.new(view_nodes)
        content = serializer.serialize(mod)

        imports = "from helpers import *\n"
        app.models.each_key do |name|
          imports += "from models.#{Inflector.underscore(name)} import #{name}\n"
        end
        # Import other view modules if referenced (e.g., render_comment_partial)
        app.controllers.each do |other_info|
          other_name = Inflector.underscore(other_info.name).chomp("_controller")
          next if other_name == controller_name
          other_plural = Inflector.pluralize(other_name)
          if content.includes?("render_#{Inflector.singularize(other_name)}_partial")
            imports += "from views.#{other_plural} import *\n"
          end
        end
        imports += "\n"

        out_path = File.join(views_dir, "#{Inflector.pluralize(controller_name)}.py")
        File.write(out_path, imports + content)
        puts "  views/#{Inflector.pluralize(controller_name)}.py"
      end

      File.write(File.join(views_dir, "__init__.py"), "")
    end

    # ── Emit app.py ──

    private def emit_app(output_dir : String)
      io = IO::Memory.new
      io << "from aiohttp import web\n"
      io << "import aiohttp\n"
      io << "import os\n"
      io << "import json\n"
      io << "import base64\n"
      io << "import asyncio\n"
      io << "import time\n"
      io << "import sqlite3\n"
      io << "from runtime.base import ApplicationRecord\n"
      io << "from helpers import *\n"

      # Controller imports
      controller_names = [] of String
      app.controllers.each do |info|
        name = Inflector.underscore(info.name).chomp("_controller")
        controller_names << name
        io << "from controllers import #{name} as #{name}_controller\n"
      end
      io << "\n"

      # ActionCable server for Turbo Streams
      io << "class CableServer:\n"
      io << "    def __init__(self):\n"
      io << "        self.channels = {}\n"
      io << "\n"
      io << "    def subscribe(self, ws, channel, identifier):\n"
      io << "        self.channels.setdefault(channel, set()).add((ws, identifier))\n"
      io << "\n"
      io << "    def unsubscribe_all(self, ws):\n"
      io << "        for channel in list(self.channels):\n"
      io << "            self.channels[channel] = {(w, i) for w, i in self.channels[channel] if w is not ws}\n"
      io << "\n"
      io << "    async def broadcast(self, channel, html):\n"
      io << "        for ws, identifier in list(self.channels.get(channel, set())):\n"
      io << "            msg = json.dumps({'type': 'message', 'identifier': identifier, 'message': html})\n"
      io << "            try:\n"
      io << "                await ws.send_str(msg)\n"
      io << "            except Exception:\n"
      io << "                pass\n"
      io << "\n"
      io << "cable = CableServer()\n"
      io << "ApplicationRecord._broadcaster = cable\n\n"

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

      # DB init
      io << "def init_db():\n"
      io << "    db = sqlite3.connect(os.path.join(os.path.dirname(__file__), 'blog.db'))\n"
      io << "    db.row_factory = sqlite3.Row\n"
      io << "    db.execute('PRAGMA foreign_keys = ON')\n"
      app.schemas.each do |schema|
        all_cols = [{name: "id", type: "INTEGER"}]
        schema.columns.each { |c| all_cols << {name: c.name, type: c.type} }
        col_defs = all_cols.map do |c|
          parts = "#{c[:name]} #{c[:type]}"
          parts += " PRIMARY KEY AUTOINCREMENT" if c[:name] == "id"
          parts += " NOT NULL" unless c[:name] == "id"
          parts
        end
        io << "    db.execute('''CREATE TABLE IF NOT EXISTS #{schema.name} (\n"
        io << "        #{col_defs.join(",\n        ")}\n"
        io << "    )''')\n"
      end
      io << "    ApplicationRecord.db = db\n"
      io << "    return db\n\n"

      # Seed data — prefer db/seeds.rb, fall back to fixtures
      seeds_path = File.join(rails_dir, "db/seeds.rb")
      io << "def seed_db():\n"
      if File.exists?(seeds_path)
        generate_seed_from_seeds_rb(io, seeds_path)
      else
        io << "    pass\n"
      end
      io << "\n"

      # Wire broadcast partials

      # Route dispatch
      io << "def create_app():\n"
      # Wire broadcast partials
      app.models.each_key do |name|
        singular = Inflector.underscore(name)
        plural = Inflector.pluralize(singular)
        io << "    from views.#{plural} import render_#{singular}_partial\n"
        io << "    from models.#{singular} import #{name}\n"
        io << "    #{name}.render_partial = render_#{singular}_partial\n"
      end
      io << "    application = web.Application()\n"

      app.routes.routes.each do |route|
        controller = Inflector.underscore(route.controller)
        action = route.action
        path = route.path.gsub(/:(\w+)/, "{\\1}")

        case route.method.upcase
        when "GET"
          io << "    application.router.add_get('#{path}', #{controller}_controller.#{action})\n"
        when "POST"
          io << "    application.router.add_post('#{path}', #{controller}_controller.#{action})\n"
        when "PATCH", "PUT"
          io << "    application.router.add_patch('#{path}', #{controller}_controller.#{action})\n"
        when "DELETE"
          io << "    application.router.add_delete('#{path}', #{controller}_controller.#{action})\n"
        end
      end

      # Root route
      if rc = app.routes.root_controller
        ra = app.routes.root_action || "index"
        io << "    application.router.add_get('/', #{rc}_controller.#{ra})\n"
      end

      # ActionCable WebSocket endpoint
      io << "    application.router.add_get('/cable', cable_handler)\n"
      # Static files
      io << "    application.router.add_static('/static', os.path.join(os.path.dirname(__file__), 'static'))\n"
      io << "    return application\n\n"

      # Main
      io << "if __name__ == '__main__':\n"
      io << "    init_db()\n"
      io << "    seed_db()\n"
      io << "    print('Blog running at http://localhost:3000')\n"
      io << "    web.run_app(create_app(), host='0.0.0.0', port=3000, print=lambda _: None)\n"

      File.write(File.join(output_dir, "app.py"), io.to_s)
      puts "  app.py"
    end

    # ── Seed data generators ──

    private def generate_seed_from_seeds_rb(io : IO, seeds_path : String)
      source = File.read(seeds_path)
      ast = Prism.parse(source)
      stmts = ast.statements
      return unless stmts.is_a?(Prism::StatementsNode)

      # Collect model imports
      models_seen = Set(String).new
      stmts.body.each do |stmt|
        scan_for_models(stmt, models_seen)
      end
      models_seen.each do |name|
        io << "    from models.#{Inflector.underscore(name)} import #{name}\n"
      end

      stmts.body.each do |stmt|
        case stmt
        when Prism::CallNode
          next if stmt.name == "return" || stmt.name == "puts"
        when Prism::IfNode, Prism::GenericNode
          next
        end
        emit_seed_stmt(stmt, io, "    ")
      end
    end

    private def scan_for_models(node : Prism::Node, models : Set(String))
      case node
      when Prism::ConstantReadNode
        models << node.name
      when Prism::CallNode
        if recv = node.receiver
          scan_for_models(recv, models)
        end
        node.arg_nodes.each { |a| scan_for_models(a, models) }
      when Prism::LocalVariableWriteNode
        scan_for_models(node.value, models)
      end
    end

    private def emit_seed_stmt(node : Prism::Node, io : IO, indent : String)
      case node
      when Prism::LocalVariableWriteNode
        io << indent << node.name << " = " << seed_expr(node.value) << "\n"
      when Prism::CallNode
        io << indent << seed_expr(node) << "\n"
      end
    end

    private def seed_expr(node : Prism::Node) : String
      case node
      when Prism::CallNode
        receiver = node.receiver
        method = node.name
        args = node.arg_nodes
        recv_str = receiver ? seed_expr(receiver) : nil

        case method
        when "create!", "create"
          kwargs = args.map { |a| seed_kwargs(a) }.join(", ")
          recv_str ? "#{recv_str}.create(#{kwargs})" : "create(#{kwargs})"
        else
          if recv_str
            arg_strs = args.map { |a| seed_expr(a) }
            arg_strs.empty? ? "#{recv_str}.#{method}()" : "#{recv_str}.#{method}(#{arg_strs.join(", ")})"
          else
            arg_strs = args.map { |a| seed_expr(a) }
            arg_strs.empty? ? method : "#{method}(#{arg_strs.join(", ")})"
          end
        end
      when Prism::ConstantReadNode
        node.name
      when Prism::LocalVariableReadNode
        node.name
      when Prism::StringNode
        node.value.inspect
      when Prism::IntegerNode
        node.value.to_s
      when Prism::SymbolNode
        node.value.inspect
      else
        "None"
      end
    end

    private def seed_kwargs(node : Prism::Node) : String
      case node
      when Prism::KeywordHashNode
        node.elements.compact_map do |el|
          next nil unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
          "#{el.key.as(Prism::SymbolNode).value}=#{seed_expr(el.value_node)}"
        end.join(", ")
      else
        seed_expr(node)
      end
    end

    # ── Emit pyproject.toml ──

    private def emit_pyproject(output_dir : String)
      io = IO::Memory.new
      io << "[project]\n"
      io << "name = \"blog\"\n"
      io << "version = \"0.1.0\"\n"
      io << "requires-python = \">=3.11\"\n"
      io << "dependencies = [\"aiohttp\"]\n\n"
      io << "[project.optional-dependencies]\n"
      io << "test = [\"pytest\", \"pytest-aiohttp\", \"pytest-asyncio\"]\n\n"
      io << "[tool.pytest.ini_options]\n"
      io << "asyncio_mode = \"auto\"\n"

      File.write(File.join(output_dir, "pyproject.toml"), io.to_s)
      puts "  pyproject.toml"
    end

    # ── Static assets: Tailwind CSS + Turbo.js ──

    private def copy_static_assets(output_dir : String)
      static_dir = File.join(output_dir, "static")
      Dir.mkdir_p(static_dir)
      generate_tailwind(output_dir, static_dir)
      copy_turbo_js(static_dir)
    end

    private def generate_tailwind(output_dir : String, static_dir : String)
      File.write(File.join(output_dir, "input.css"), "@import \"tailwindcss\";\n")

      tailwind = find_tailwind
      unless tailwind
        puts "  tailwind: not found (skipping CSS generation)"
        puts "  Install: gem install tailwindcss-rails"
        return
      end

      err_io = IO::Memory.new
      result = Process.run(tailwind,
        ["--input", "input.css", "--output", "static/app.css", "--minify"],
        chdir: output_dir,
        output: Process::Redirect::Close,
        error: err_io)

      if result.success?
        size = File.size(File.join(static_dir, "app.css"))
        puts "  static/app.css (#{size} bytes)"
      else
        puts "  tailwind: build failed"
        err_msg = err_io.to_s.strip
        puts "  #{err_msg}" unless err_msg.empty?
      end
    end

    private def find_tailwind : String?
      path = Process.find_executable("tailwindcss")
      return path if path

      begin
        output = IO::Memory.new
        result = Process.run("ruby",
          ["-e", "puts Gem::Specification.find_by_name('tailwindcss-rails').bin_dir + '/tailwindcss'"],
          output: output, error: Process::Redirect::Close)
        if result.success?
          bin = output.to_s.strip
          return bin if File.exists?(bin)
        end
      rescue
      end
      nil
    end

    private def copy_turbo_js(static_dir : String)
      turbo_js = find_turbo_js
      unless turbo_js
        puts "  turbo.min.js: not found (skipping)"
        puts "  Install: gem install turbo-rails"
        return
      end

      dst = File.join(static_dir, "turbo.min.js")
      File.write(dst, File.read(turbo_js))
      size = File.size(dst)
      puts "  static/turbo.min.js (#{size} bytes)"
    end

    private def find_turbo_js : String?
      begin
        output = IO::Memory.new
        result = Process.run("ruby",
          ["-e", "puts Gem::Specification.find_by_name('turbo-rails').gem_dir + '/app/assets/javascripts/turbo.min.js'"],
          output: output, error: Process::Redirect::Close)
        if result.success?
          path = output.to_s.strip
          return path if File.exists?(path)
        end
      rescue
      end
      nil
    end

    # ── Layer 3: Tests ──

    private def emit_tests(output_dir : String,
                           emitter : Cr2Py::Emitter,
                           serializer : PyAST::Serializer,
                           filters : Tuple)
      tests_dir = File.join(output_dir, "tests")
      Dir.mkdir_p(tests_dir)

      # Generate conftest.py (db setup + fixtures)
      generate_conftest(tests_dir)

      # Convert model tests
      test_filter = MinitestToPytest.new
      model_tests_dir = File.join(rails_dir, "test/models")
      if Dir.exists?(model_tests_dir)
        Dir.glob(File.join(model_tests_dir, "*_test.rb")).each do |path|
          basename = File.basename(path, ".rb")
          py_name = "test_#{basename.chomp("_test")}.py"

          ast = SourceParser.parse(path)
          ast = ast.transform(test_filter)

          py_nodes = emitter.to_nodes(ast)
          db_filter, dunder_filter, return_filter = filters
          py_nodes = return_filter.transform(py_nodes)

          mod = PyAST::Module.new(py_nodes)
          content = serializer.serialize(mod)

          # Add test imports
          imports = String.build do |io|
            io << "import sys\nimport os\n"
            io << "sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))\n\n"
            app.models.each_key do |name|
              io << "from models.#{Inflector.underscore(name)} import #{name}\n"
            end
            io << "from tests.conftest import *\n\n"
          end

          out_path = File.join(tests_dir, py_name)
          File.write(out_path, imports + content)
          puts "  tests/#{py_name}"
        end
      end

      # Convert controller tests
      controller_tests_dir = File.join(rails_dir, "test/controllers")
      if Dir.exists?(controller_tests_dir)
        Dir.glob(File.join(controller_tests_dir, "*_test.rb")).each do |path|
          basename = File.basename(path, ".rb")
          py_name = "test_#{basename.chomp("_test")}.py"

          ast = SourceParser.parse(path)
          ast = ast.transform(InstanceVarToLocal.new)
          ast = ast.transform(test_filter)

          py_nodes = emitter.to_nodes(ast)
          db_filter, dunder_filter, return_filter = filters
          py_nodes = return_filter.transform(py_nodes)

          imports = String.build do |io|
            io << "import pytest\n"
            io << "import sys\nimport os\n"
            io << "sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))\n\n"
            io << "from aiohttp import web\n"
            io << "from aiohttp.test_utils import TestClient, TestServer\n"
            io << "import app as app_module\n"
            app.models.each_key do |name|
              io << "from models.#{Inflector.underscore(name)} import #{name}\n"
            end
            io << "from helpers import *\n"
            io << "from tests.conftest import *\n\n"
          end

          # Apply async filter to controller tests
          async_filter = Cr2Py::PyAstAsyncFilter.new
          py_nodes = async_filter.transform(py_nodes)

          mod = PyAST::Module.new(py_nodes)
          content = serializer.serialize(mod)

          out_path = File.join(tests_dir, py_name)
          File.write(out_path, imports + content)
          puts "  tests/#{py_name}"
        end
      end

      File.write(File.join(tests_dir, "__init__.py"), "")
    end

    private def generate_conftest(tests_dir : String)
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      io = IO::Memory.new
      io << "import sqlite3\n"
      io << "import sys\nimport os\n"
      io << "sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))\n\n"
      io << "from runtime.base import ApplicationRecord\n"
      app.models.each_key do |name|
        io << "from models.#{Inflector.underscore(name)} import #{name}\n"
      end
      io << "\n"

      # setup_db function
      io << "def setup_db():\n"
      io << "    db = sqlite3.connect(':memory:')\n"
      io << "    db.row_factory = sqlite3.Row\n"
      io << "    db.execute('PRAGMA foreign_keys = ON')\n"
      app.schemas.each do |schema|
        cols = schema.columns.map { |c| "#{c.name} #{c.type}" }
        # Add constraints
        # Always add id column (Rails makes it implicit)
        all_cols = [Column.new("id", "INTEGER")] + schema.columns
        col_defs = all_cols.map do |c|
          parts = "#{c.name} #{c.type}"
          parts += " PRIMARY KEY AUTOINCREMENT" if c.name == "id"
          parts += " NOT NULL" unless c.name == "id"
          parts
        end
        io << "    db.execute('''CREATE TABLE IF NOT EXISTS #{schema.name} (\n"
        io << "        #{col_defs.join(",\n        ")}\n"
        io << "    )''')\n"
      end
      io << "    ApplicationRecord.db = db\n"
      io << "    return db\n\n"

      # Pytest fixture that auto-runs setup for every test
      io << "import pytest\n\n"
      io << "@pytest.fixture(autouse=True)\n"
      io << "def _setup_test_db():\n"
      io << "    db = setup_db()\n"
      io << "    setup_fixtures()\n"
      io << "    yield\n"
      io << "    db.close()\n\n"

      # Fixture setup
      fixture_table_names = app.fixtures.map(&.name).to_set
      association_fields = Set(String).new
      app.models.each do |_, model|
        model.associations.each do |assoc|
          association_fields << Inflector.singularize(assoc.name) if assoc.kind == :belongs_to
        end
      end

      io << "def setup_fixtures():\n"
      app.fixtures.each do |fixture|
        model_name = Inflector.classify(Inflector.singularize(fixture.name))
        fixture.records.each do |record|
          fields = record.fields.reject { |k, _| k == "id" }
          field_strs = fields.map do |k, v|
            if association_fields.includes?(k) && fixture_table_names.includes?(Inflector.pluralize(k))
              ref_fixture = Inflector.pluralize(k)
              "#{k}_id=#{ref_fixture}_#{v}.id"
            else
              "#{k}=#{v.inspect}"
            end
          end
          io << "    global #{fixture.name}_#{record.label}\n"
          io << "    #{fixture.name}_#{record.label} = #{model_name}.create(#{field_strs.join(", ")})\n"
        end
      end
      io << "\n"

      # Fixture accessor functions
      app.fixtures.each do |fixture|
        model_name = Inflector.classify(Inflector.singularize(fixture.name))
        io << "def #{fixture.name}(name):\n"
        io << "    all_records = #{model_name}.all()\n"
        fixture.records.each_with_index do |record, i|
          io << "    if name == '#{record.label}':\n"
          io << "        return all_records[#{i}]\n"
        end
        io << "    raise ValueError(f'Unknown fixture: {name}')\n\n"
      end

      File.write(File.join(tests_dir, "conftest.py"), io.to_s)
      puts "  tests/conftest.py"
    end

    # ── Shared ──

    private def extract_railcar_nodes(ast : Crystal::ASTNode) : Array(Crystal::ASTNode)
      nodes = [] of Crystal::ASTNode
      case ast
      when Crystal::Expressions
        ast.expressions.each do |expr|
          if expr.is_a?(Crystal::ModuleDef) && expr.name.names.includes?("Railcar")
            case expr.body
            when Crystal::Expressions
              nodes.concat(expr.body.as(Crystal::Expressions).expressions)
            else
              nodes << expr.body
            end
          end
        end
      end
      nodes
    end

    private def emit_file(nodes : Array(Crystal::ASTNode), py_path : String,
                          output_dir : String,
                          emitter : Cr2Py::Emitter,
                          serializer : PyAST::Serializer,
                          filters : Tuple)
      db_filter, dunder_filter, return_filter = filters

      py_nodes = [] of PyAST::Node
      nodes.each do |node|
        transformed = node.transform(db_filter)
        py_nodes.concat(emitter.to_nodes(transformed))
      end
      py_nodes = dunder_filter.transform(py_nodes)
      py_nodes = return_filter.transform(py_nodes)

      mod = PyAST::Module.new(py_nodes)
      content = serializer.serialize(mod)
      imports = generate_imports(content, py_path)

      out_path = File.join(output_dir, py_path)
      Dir.mkdir_p(File.dirname(out_path))
      File.write(out_path, imports + content)
      puts "  #{py_path}"
    end

    private def generate_imports(content : String, py_path : String = "") : String
      imports = [] of String
      imports << "from __future__ import annotations" if content.includes?("->") || content.includes?(": ")
      imports << "from typing import Any" if content.includes?("Any")
      imports << "import sqlite3" if content.includes?("sqlite3.")
      imports << "import logging" if content.includes?("logging.")
      imports << "from datetime import datetime" if content.includes?("datetime.")

      # Cross-file imports based on content scanning
      code = content.lines.reject(&.strip.starts_with?("#")).join("\n")

      if py_path.starts_with?("models/") && !py_path.includes?("__init__")
        imports << "from runtime.base import ApplicationRecord" if code.includes?("ApplicationRecord")
        imports << "from runtime.base import CollectionProxy" if code.includes?("CollectionProxy")
        imports << "from runtime.base import MODEL_REGISTRY" if code.includes?("MODEL_REGISTRY")
        # No cross-model imports — models use MODEL_REGISTRY for lazy resolution
      end

      imports.empty? ? "" : imports.join("\n") + "\n\n"
    end
  end
end
