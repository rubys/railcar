# Generates a Python application from a Rails app.
#
# Produces:
#   app.py        — HTTP application with route dispatch
#   models.py     — SQLite-backed model classes
#   templates/    — Jinja2 templates (converted from ERB)

require "./app_model"
require "./schema_extractor"
require "./python_seed_extractor"
require "./python_controller_generator"
require "./python_view_generator"
require "./python_test_generator"
require "./inflector"

module Railcar
  class PythonGenerator
    getter app : AppModel
    getter rails_dir : String

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      # Create directory tree
      %w[models controllers views static].each do |dir|
        Dir.mkdir_p(File.join(output_dir, dir)) unless Dir.exists?(File.join(output_dir, dir))
      end
      # Create view subdirectories for each controller
      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        Dir.mkdir_p(File.join(output_dir, "views", controller_name))
      end

      puts "Generating Python app from #{rails_dir}..."

      generate_models(output_dir)
      generate_helpers(output_dir)
      PythonControllerGenerator.new(app, rails_dir).generate(output_dir)
      PythonViewGenerator.new(app, rails_dir).generate(output_dir)
      PythonTestGenerator.new(app, rails_dir).generate(output_dir)
      generate_app(output_dir)
      generate_pyproject(output_dir)
      generate_tailwind(output_dir)
      copy_turbo_js(output_dir)

      puts "Done! Output in #{output_dir}/"
      puts "  cd #{output_dir} && uv run python3 app.py"
    end

    private def generate_models(output_dir : String)
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      models_dir = File.join(output_dir, "models")

      # __init__.py — db setup + imports
      init_io = IO::Memory.new
      init_io << "import sqlite3\n"
      init_io << "import os\n"
      init_io << "from datetime import datetime\n\n"
      init_io << "DB_PATH = os.path.join(os.path.dirname(__file__), '..', '#{File.basename(output_dir)}.db')\n\n"

      init_io << "def get_db():\n"
      init_io << "    conn = sqlite3.connect(DB_PATH)\n"
      init_io << "    conn.row_factory = sqlite3.Row\n"
      init_io << "    conn.execute('PRAGMA foreign_keys = ON')\n"
      init_io << "    return conn\n\n"

      init_io << "def init_db():\n"
      init_io << "    db = get_db()\n"

      app.schemas.each do |schema|
        init_io << "    db.execute('''\n"
        init_io << "        CREATE TABLE IF NOT EXISTS #{schema.name} (\n"
        init_io << "            id INTEGER PRIMARY KEY AUTOINCREMENT"
        schema.columns.each do |col|
          next if col.name == "id"
          sql_type = python_sql_type(col.type)
          init_io << ",\n            #{col.name} #{sql_type}"
          if col.type == "references"
            ref_table = Inflector.pluralize(col.name.chomp("_id"))
            init_io << " REFERENCES #{ref_table}(id)"
          end
        end
        init_io << "\n        )\n"
        init_io << "    ''')\n"
      end

      init_io << "    db.commit()\n"
      init_io << "    db.close()\n\n"

      # Import all model classes
      app.models.each_key do |name|
        filename = Inflector.underscore(name)
        init_io << "from .#{filename} import #{name}\n"
      end

      File.write(File.join(models_dir, "__init__.py"), init_io.to_s)
      puts "  models/__init__.py"

      # Individual model files
      app.models.each do |name, model|
        table_name = Inflector.pluralize(Inflector.underscore(name))
        schema = schema_map[table_name]?
        next unless schema

        columns = schema.columns.reject { |c| c.name == "id" }
        column_names = columns.map(&.name)

        io = IO::Memory.new
        io << "from . import get_db\n"
        io << "from datetime import datetime\n\n"

        io << "\nclass #{name}:\n"
        io << "    TABLE = '#{table_name}'\n\n"

        # __init__
        io << "    def __init__(self, **kwargs):\n"
        io << "        self.id = kwargs.get('id')\n"
        columns.each do |col|
          default = col.type == "references" ? "None" : python_default(col.type)
          io << "        self.#{col.name} = kwargs.get('#{col.name}', #{default})\n"
        end
        io << "\n"

        # from_row
        io << "    @classmethod\n"
        io << "    def from_row(cls, row):\n"
        io << "        if row is None:\n"
        io << "            return None\n"
        io << "        return cls(**dict(row))\n\n"

        # find
        io << "    @classmethod\n"
        io << "    def find(cls, id):\n"
        io << "        db = get_db()\n"
        io << "        row = db.execute(f'SELECT * FROM {cls.TABLE} WHERE id = ?', (id,)).fetchone()\n"
        io << "        db.close()\n"
        io << "        if row is None:\n"
        io << "            raise ValueError(f'{cls.__name__} not found: {id}')\n"
        io << "        return cls.from_row(row)\n\n"

        # all
        io << "    @classmethod\n"
        io << "    def all(cls, order_by='id'):\n"
        io << "        db = get_db()\n"
        io << "        rows = db.execute(f'SELECT * FROM {cls.TABLE} ORDER BY {order_by}').fetchall()\n"
        io << "        db.close()\n"
        io << "        return [cls.from_row(r) for r in rows]\n\n"

        # where
        io << "    @classmethod\n"
        io << "    def where(cls, **conditions):\n"
        io << "        db = get_db()\n"
        io << "        clauses = ' AND '.join(f'{k} = ?' for k in conditions)\n"
        io << "        rows = db.execute(f'SELECT * FROM {cls.TABLE} WHERE {clauses}', tuple(conditions.values())).fetchall()\n"
        io << "        db.close()\n"
        io << "        return [cls.from_row(r) for r in rows]\n\n"

        # _create (shorthand for new + save, returns the instance)
        io << "    @classmethod\n"
        io << "    def _create(cls, **kwargs):\n"
        io << "        obj = cls(**kwargs)\n"
        io << "        obj.save()\n"
        io << "        return obj\n\n"

        # count
        io << "    @classmethod\n"
        io << "    def count(cls):\n"
        io << "        return len(cls.all())\n\n"

        # last
        io << "    @classmethod\n"
        io << "    def last(cls):\n"
        io << "        records = cls.all()\n"
        io << "        return records[-1] if records else None\n\n"

        # validate
        if model.validations.any? || model.associations.any? { |a| a.kind == :belongs_to }
          io << "    def is_valid(self):\n"
          model.validations.each do |v|
            case v.kind
            when "presence"
              io << "        if not self.#{v.field}:\n"
              io << "            return False\n"
            when "length"
              if min = v.options["minimum"]?
                io << "        if self.#{v.field} is not None and len(self.#{v.field}) < #{min}:\n"
                io << "            return False\n"
              end
            end
          end
          # belongs_to FK validation
          model.associations.each do |assoc|
            if assoc.kind == :belongs_to
              fk = assoc.name + "_id"
              target_class = Inflector.classify(assoc.name)
              io << "        if self.#{fk} is not None:\n"
              io << "            try:\n"
              io << "                from .#{Inflector.underscore(target_class)} import #{target_class}\n"
              io << "                #{target_class}.find(self.#{fk})\n"
              io << "            except (ValueError, Exception):\n"
              io << "                return False\n"
            end
          end
          io << "        return True\n\n"
        end

        # save
        io << "    def save(self):\n"
        if model.validations.any? || model.associations.any? { |a| a.kind == :belongs_to }
          io << "        if not self.is_valid():\n"
          io << "            return False\n"
        end
        io << "        db = get_db()\n"
        io << "        now = datetime.now().isoformat()\n"
        io << "        if self.id is None:\n"
        if column_names.includes?("created_at")
          io << "            self.created_at = now\n"
          io << "            self.updated_at = now\n"
        end
        io << "            cols = '#{column_names.join(", ")}'\n"
        io << "            placeholders = '#{column_names.map { "?" }.join(", ")}'\n"
        io << "            values = (#{column_names.map { |c| "self.#{c}" }.join(", ")},)\n"
        io << "            cursor = db.execute(f'INSERT INTO #{table_name} ({cols}) VALUES ({placeholders})', values)\n"
        io << "            self.id = cursor.lastrowid\n"
        io << "        else:\n"
        if column_names.includes?("updated_at")
          io << "            self.updated_at = now\n"
        end
        update_cols = column_names.reject { |c| c == "created_at" }
        io << "            sets = '#{update_cols.map { |c| "#{c} = ?" }.join(", ")}'\n"
        io << "            values = (#{update_cols.map { |c| "self.#{c}" }.join(", ")}, self.id)\n"
        io << "            db.execute(f'UPDATE #{table_name} SET {sets} WHERE id = ?', values)\n"
        io << "        db.commit()\n"
        io << "        db.close()\n"
        io << "        return True\n\n"

        # destroy (with dependent: :destroy cascading)
        io << "    def destroy(self):\n"
        # Auto-cascade dependent: :destroy associations
        model.associations.each do |assoc|
          if assoc.kind == :has_many && assoc.options["dependent"]? == "destroy"
            io << "        for item in self.#{assoc.name}():\n"
            io << "            item.destroy()\n"
          end
        end
        io << "        db = get_db()\n"
        io << "        db.execute(f'DELETE FROM {self.TABLE} WHERE id = ?', (self.id,))\n"
        io << "        db.commit()\n"
        io << "        db.close()\n\n"

        # Associations
        model.associations.each do |assoc|
          case assoc.kind
          when :has_many
            target_class = Inflector.classify(Inflector.singularize(assoc.name))
            fk = Inflector.underscore(name) + "_id"
            io << "    def #{assoc.name}(self):\n"
            io << "        from .#{Inflector.underscore(target_class)} import #{target_class}\n"
            io << "        return #{target_class}.where(#{fk}=self.id)\n\n"

            if assoc.options["dependent"]? == "destroy"
              io << "    def destroy_#{assoc.name}(self):\n"
              io << "        for item in self.#{assoc.name}():\n"
              io << "            item.destroy()\n\n"
            end
          when :belongs_to
            target_class = Inflector.classify(assoc.name)
            fk = assoc.name + "_id"
            io << "    def #{assoc.name}(self):\n"
            io << "        from .#{Inflector.underscore(target_class)} import #{target_class}\n"
            io << "        return #{target_class}.find(self.#{fk})\n\n"
          end
        end

        filename = Inflector.underscore(name)
        File.write(File.join(models_dir, "#{filename}.py"), io.to_s)
        puts "  models/#{filename}.py"
      end
    end

    private def generate_helpers(output_dir : String)
      io = IO::Memory.new
      io << "import base64\n"
      io << "import json\n"
      io << "from urllib.parse import parse_qs\n\n"

      # Form parsing
      io << "def parse_form(body_bytes):\n"
      io << "    return parse_qs(body_bytes.decode('utf-8'))\n\n"

      io << "def form_value(data, key):\n"
      io << "    return data.get(key, [''])[0]\n\n"

      # Layout
      io << "LAYOUT_HEAD = '''<!DOCTYPE html>\n"
      io << "<html>\n"
      io << "<head>\n"
      io << "  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
      io << "  <meta name=\"action-cable-url\" content=\"/cable\">\n"
      io << "  <link rel=\"stylesheet\" href=\"/static/app.css\">\n"
      io << "  <script type=\"module\" src=\"/static/turbo.min.js\"></script>\n"
      io << "</head>\n"
      io << "<body>\n"
      io << "  <main class=\"container mx-auto mt-28 px-5 flex flex-col\">'''\n\n"

      io << "LAYOUT_TAIL = '''  </main>\n"
      io << "</body>\n"
      io << "</html>'''\n\n"

      io << "def layout(content, title='Blog'):\n"
      io << "    head = LAYOUT_HEAD.replace('<head>', f'<head>\\n  <title>{title}</title>', 1)\n"
      io << "    return head + content + LAYOUT_TAIL\n\n"

      # link_to
      io << "def link_to(text, url, **kwargs):\n"
      io << "    attrs = ''.join(f' {k.replace(\"_\", \"-\")}=\"{v}\"' for k, v in kwargs.items())\n"
      io << "    return f'<a href=\"{url}\"{attrs}>{text}</a>'\n\n"

      # button_to
      io << "def button_to(text, url, **kwargs):\n"
      io << "    method = kwargs.pop('method', 'post')\n"
      io << "    btn_class = kwargs.pop('class', '')\n"
      io << "    confirm = kwargs.pop('data_turbo_confirm', '')\n"
      io << "    form_class = kwargs.pop('form_class', '')\n"
      io << "    form_attrs = f' class=\"{form_class}\"' if form_class else ''\n"
      io << "    confirm_attr = f' data-turbo-confirm=\"{confirm}\"' if confirm else ''\n"
      io << "    cls_attr = f' class=\"{btn_class}\"' if btn_class else ''\n"
      io << "    return (\n"
      io << "        f'<form method=\"post\" action=\"{url}\"{form_attrs}{confirm_attr}>'\n"
      io << "        f'<input type=\"hidden\" name=\"_method\" value=\"{method}\">'\n"
      io << "        f'<button type=\"submit\"{cls_attr}>{text}</button>'\n"
      io << "        f'</form>'\n"
      io << "    )\n\n"

      # dom_id
      io << "def dom_id(obj, prefix=None):\n"
      io << "    name = type(obj).__name__.lower()\n"
      io << "    if prefix:\n"
      io << "        return f'{prefix}_{name}_{obj.id}'\n"
      io << "    return f'{name}_{obj.id}'\n\n"

      # pluralize
      io << "def pluralize(count, singular, plural=None):\n"
      io << "    if plural is None:\n"
      io << "        plural = singular + 's'\n"
      io << "    return f'{count} {singular if count == 1 else plural}'\n\n"

      # truncate
      io << "def truncate(text, length=30, omission='...'):\n"
      io << "    if text is None:\n"
      io << "        return ''\n"
      io << "    if len(text) <= length:\n"
      io << "        return text\n"
      io << "    return text[:length - len(omission)] + omission\n\n"

      # turbo_stream_from
      io << "def turbo_stream_from(channel):\n"
      io << "    signed = base64.b64encode(json.dumps(channel).encode()).decode()\n"
      io << "    return f'<turbo-cable-stream-source channel=\"Turbo::StreamsChannel\" signed-stream-name=\"{signed}\"></turbo-cable-stream-source>'\n\n"

      # Path helpers
      app.models.each_key do |name|
        singular = Inflector.underscore(name)
        plural = Inflector.pluralize(singular)
        io << "def #{singular}_path(#{singular}):\n"
        io << "    return f'/#{plural}/{#{singular}.id}'\n\n"
        io << "def edit_#{singular}_path(#{singular}):\n"
        io << "    return f'/#{plural}/{#{singular}.id}/edit'\n\n"
        io << "def #{plural}_path():\n"
        io << "    return '/#{plural}'\n\n"
        io << "def new_#{singular}_path():\n"
        io << "    return '/#{plural}/new'\n\n"
      end

      # Nested resource path helpers
      app.models.each do |name, model|
        model.associations.each do |assoc|
          next unless assoc.kind == :has_many
          parent_singular = Inflector.underscore(name)
          parent_plural = Inflector.pluralize(parent_singular)
          child_name = assoc.name
          child_singular = Inflector.singularize(child_name)

          io << "def #{parent_singular}_#{child_name}_path(#{parent_singular}):\n"
          io << "    return f'/#{parent_plural}/{#{parent_singular}.id}/#{child_name}'\n\n"
          io << "def #{parent_singular}_#{child_singular}_path(#{parent_singular}_id, #{child_singular}):\n"
          io << "    return f'/#{parent_plural}/{#{parent_singular}_id}/#{child_name}/{#{child_singular}.id}'\n\n"
        end
      end

      File.write(File.join(output_dir, "helpers.py"), io.to_s)
      puts "  helpers.py"
    end

    private def generate_app(output_dir : String)
      io = IO::Memory.new
      io << "from aiohttp import web\n"
      io << "import aiohttp\n"
      io << "import os\n"
      io << "import json\n"
      io << "import base64\n"
      io << "import asyncio\n"
      io << "import time\n"
      io << "from models import *\n"
      io << "from helpers import *\n"

      # Import controllers
      app.controllers.each do |info|
        name = Inflector.underscore(info.name).chomp("_controller")
        io << "from controllers import #{name} as #{name}_controller\n"
      end
      io << "\n"

      # ActionCable WebSocket server
      io << "# ActionCable server for Turbo Streams\n"
      io << "class CableServer:\n"
      io << "    def __init__(self):\n"
      io << "        self.channels = {}  # channel_name -> set of (ws, identifier)\n\n"

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

      # ActionCable WebSocket handler
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

      # Logging middleware
      io << "@web.middleware\n"
      io << "async def log_middleware(request, handler):\n"
      io << "    response = await handler(request)\n"
      io << "    print(f'{request.method} {request.path} {response.status}')\n"
      io << "    return response\n\n"

      # Seed data from db/seeds.rb if it exists
      seeds_path = File.join(rails_dir, "db/seeds.rb")
      has_seeds = File.exists?(seeds_path)
      if has_seeds
        first_model = app.models.keys.first? || "Article"
        io << PythonSeedExtractor.generate(seeds_path, first_model)
      end

      # create_app function (used by both main and tests)
      io << "def create_app():\n"
      io << "    application = web.Application(middlewares=[log_middleware])\n"
      io << "    application.router.add_get('/cable', cable_handler)\n"

      # Generate routes
      # Group PATCH/PUT/DELETE with POST on same path (aiohttp uses POST + method override)
      post_paths = {} of String => Array(Tuple(String, String, String))
      app.routes.routes.each do |route|
        controller = route.controller
        action = route.action
        method = route.method.downcase
        pattern = route.path.gsub(/:(\w+)/, "{\\1}")

        case method
        when "get"
          io << "    application.router.add_get('#{pattern}', #{controller}_controller.#{action})\n"
        when "post"
          post_paths[pattern] ||= [] of Tuple(String, String, String)
          post_paths[pattern] << {method, controller, action}
        when "patch", "put", "delete"
          post_paths[pattern] ||= [] of Tuple(String, String, String)
          post_paths[pattern] << {method, controller, action}
        end
      end

      # For paths that have both POST and PATCH/DELETE, generate a dispatcher
      post_paths.each do |pattern, methods|
        if methods.size == 1
          m, c, a = methods[0]
          io << "    application.router.add_post('#{pattern}', #{c}_controller.#{a})\n"
        else
          # Multiple methods on same path — need a dispatcher
          # Find the controller (should be the same for all)
          controller = methods[0][1]
          actions = methods.map { |m, c, a| {m, a} }

          post_action = actions.find { |m, a| m == "post" }
          patch_action = actions.find { |m, a| m == "patch" || m == "put" }
          delete_action = actions.find { |m, a| m == "delete" }

          # Generate inline dispatcher
          io << "    async def _dispatch_#{controller}_#{pattern.gsub(/[{}\/]/, "_").strip('_')}(request):\n"
          io << "        data = parse_form(await request.read())\n"
          io << "        method = form_value(data, '_method').upper()\n"
          if delete_action
            io << "        if method == 'DELETE':\n"
            io << "            return await #{controller}_controller.#{delete_action[1]}(request, data)\n"
          end
          if patch_action
            io << "        if method in ('PATCH', 'PUT'):\n"
            io << "            return await #{controller}_controller.#{patch_action[1]}(request, data)\n"
          end
          if post_action
            io << "        return await #{controller}_controller.#{post_action[1]}(request, data)\n"
          end
          io << "    application.router.add_post('#{pattern}', _dispatch_#{controller}_#{pattern.gsub(/[{}\/]/, "_").strip('_')})\n"
        end
      end

      # Root route
      root_controller = app.routes.routes.find { |r| r.method == "GET" && r.action == "index" }
      if root_controller
        io << "    application.router.add_get('/', #{root_controller.controller}_controller.index)\n"
      end

      io << "    application.router.add_static('/static', os.path.join(os.path.dirname(__file__), 'static'))\n"
      io << "    return application\n\n"

      # Main
      io << "if __name__ == '__main__':\n"
      io << "    init_db()\n"
      io << "    seed_db()\n" if has_seeds
      io << "    print('Blog running at http://localhost:3000')\n"
      io << "    web.run_app(create_app(), host='0.0.0.0', port=3000, print=lambda _: None)\n"

      File.write(File.join(output_dir, "app.py"), io.to_s)
      puts "  app.py"
    end

    private def generate_pyproject(output_dir : String)
      project_name = File.basename(File.expand_path(output_dir))
      File.write(File.join(output_dir, "pyproject.toml"),
        "[project]\n" \
        "name = \"#{project_name}\"\n" \
        "version = \"0.1.0\"\n" \
        "requires-python = \">=3.10\"\n" \
        "dependencies = [\"aiohttp\"]\n" \
        "\n" \
        "[project.optional-dependencies]\n" \
        "test = [\"pytest\", \"pytest-aiohttp\"]\n")
      puts "  pyproject.toml"
    end

    private def copy_turbo_js(output_dir : String)
      static_dir = File.join(output_dir, "static")

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

    private def generate_tailwind(output_dir : String)
      # Write input CSS for Tailwind
      File.write(File.join(output_dir, "input.css"), "@import \"tailwindcss\";\n")

      tailwind = find_tailwind
      unless tailwind
        puts "  tailwind: not found (skipping CSS generation)"
        puts "  Install: gem install tailwindcss-rails"
        return
      end

      err_io = IO::Memory.new
      result = Process.run(tailwind,
        ["--input", "input.css",
         "--output", "static/app.css",
         "--minify"],
        chdir: output_dir,
        output: Process::Redirect::Close,
        error: err_io
      )

      if result.success?
        size = File.size(File.join(output_dir, "static/app.css"))
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

    private def python_sql_type(rails_type : String) : String
      case rails_type
      when "string", "text"          then "TEXT"
      when "integer", "references"   then "INTEGER"
      when "float", "decimal"        then "REAL"
      when "boolean"                 then "INTEGER"
      when "datetime", "date", "time" then "TEXT"
      else                                "TEXT"
      end
    end

    private def python_default(rails_type : String) : String
      case rails_type
      when "string", "text"          then "''"
      when "integer"                 then "0"
      when "float", "decimal"        then "0.0"
      when "boolean"                 then "False"
      when "datetime", "date", "time" then "None"
      else                                "None"
      end
    end
  end
end
