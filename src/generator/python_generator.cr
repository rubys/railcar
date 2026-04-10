# Generates a Python application from a Rails app.
#
# Produces:
#   app.py        — HTTP application with route dispatch
#   models.py     — SQLite-backed model classes
#   templates/    — Jinja2 templates (converted from ERB)

require "./app_model"
require "./schema_extractor"
require "./python_seed_extractor"
require "./python_erb_converter"
require "./inflector"

module Railcar
  class PythonGenerator
    getter app : AppModel
    getter rails_dir : String

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      Dir.mkdir_p(output_dir) unless Dir.exists?(output_dir)
      Dir.mkdir_p(File.join(output_dir, "templates")) unless Dir.exists?(File.join(output_dir, "templates"))
      Dir.mkdir_p(File.join(output_dir, "static")) unless Dir.exists?(File.join(output_dir, "static"))

      puts "Generating Python app from #{rails_dir}..."

      generate_models(output_dir)
      generate_app(output_dir)
      generate_pyproject(output_dir)
      convert_templates(output_dir)
      generate_tailwind(output_dir)
      copy_turbo_js(output_dir)

      puts "Done! Output in #{output_dir}/"
      puts "  cd #{output_dir} && uv run python3 app.py"
    end

    private def generate_models(output_dir : String)
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      io = IO::Memory.new
      io << "import sqlite3\n"
      io << "import os\n"
      io << "from datetime import datetime\n\n"
      io << "DB_PATH = os.path.join(os.path.dirname(__file__), 'blog.db')\n\n"

      io << "def get_db():\n"
      io << "    conn = sqlite3.connect(DB_PATH)\n"
      io << "    conn.row_factory = sqlite3.Row\n"
      io << "    conn.execute('PRAGMA foreign_keys = ON')\n"
      io << "    return conn\n\n"

      io << "def init_db():\n"
      io << "    db = get_db()\n"

      # DDL from schemas
      app.schemas.each do |schema|
        io << "    db.execute('''\n"
        io << "        CREATE TABLE IF NOT EXISTS #{schema.name} (\n"
        io << "            id INTEGER PRIMARY KEY AUTOINCREMENT"
        schema.columns.each do |col|
          next if col.name == "id"
          sql_type = python_sql_type(col.type)
          io << ",\n            #{col.name} #{sql_type}"
          if col.type == "references"
            ref_table = Inflector.pluralize(col.name.chomp("_id"))
            io << " REFERENCES #{ref_table}(id)"
          end
        end
        io << "\n        )\n"
        io << "    ''')\n"
      end

      io << "    db.commit()\n"
      io << "    db.close()\n\n"

      # Model classes
      app.models.each do |name, model|
        table_name = Inflector.pluralize(Inflector.underscore(name))
        schema = schema_map[table_name]?
        next unless schema

        columns = schema.columns.reject { |c| c.name == "id" }
        column_names = columns.map(&.name)

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

        # from_row class method
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

        # save (insert or update)
        io << "    def save(self):\n"
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

        # destroy
        io << "    def destroy(self):\n"
        io << "        db = get_db()\n"
        io << "        db.execute(f'DELETE FROM {self.TABLE} WHERE id = ?', (self.id,))\n"
        io << "        db.commit()\n"
        io << "        db.close()\n\n"

        # Association methods
        model.associations.each do |assoc|
          case assoc.kind
          when :has_many
            target_class = Inflector.classify(Inflector.singularize(assoc.name))
            fk = Inflector.underscore(name) + "_id"
            io << "    def #{assoc.name}(self):\n"
            io << "        return #{target_class}.where(#{fk}=self.id)\n\n"

            # dependent: :destroy
            if assoc.options["dependent"]? == "destroy"
              io << "    def destroy_#{assoc.name}(self):\n"
              io << "        for item in self.#{assoc.name}():\n"
              io << "            item.destroy()\n\n"
            end
          when :belongs_to
            target_class = Inflector.classify(assoc.name)
            fk = assoc.name + "_id"
            io << "    def #{assoc.name}(self):\n"
            io << "        return #{target_class}.find(self.#{fk})\n\n"
          end
        end
      end

      File.write(File.join(output_dir, "models.py"), io.to_s)
      puts "  models.py"
    end

    private def generate_app(output_dir : String)
      io = IO::Memory.new
      io << "from aiohttp import web\n"
      io << "from urllib.parse import parse_qs\n"
      io << "import aiohttp\n"
      io << "import jinja2\n"
      io << "import os\n"
      io << "import json\n"
      io << "import base64\n"
      io << "import asyncio\n"
      io << "import time\n"
      io << "from models import *\n\n"

      # Jinja2 setup
      io << "TEMPLATE_DIR = os.path.join(os.path.dirname(__file__), 'templates')\n"
      io << "env = jinja2.Environment(loader=jinja2.FileSystemLoader(TEMPLATE_DIR))\n\n"

      # Template helper functions
      io << "def link_to(text, url, **kwargs):\n"
      io << "    attrs = ''.join(f' {k.replace(\"_\", \"-\")}=\"{v}\"' for k, v in kwargs.items())\n"
      io << "    return f'<a href=\"{url}\"{attrs}>{text}</a>'\n\n"

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

      io << "def dom_id(obj, prefix=None):\n"
      io << "    name = type(obj).__name__.lower()\n"
      io << "    if prefix:\n"
      io << "        return f'{prefix}_{name}_{obj.id}'\n"
      io << "    return f'{name}_{obj.id}'\n\n"

      io << "def pluralize(count, singular, plural=None):\n"
      io << "    if plural is None:\n"
      io << "        plural = singular + 's'\n"
      io << "    return f'{count} {singular if count == 1 else plural}'\n\n"

      io << "def turbo_stream_from(channel):\n"
      io << "    signed = base64.b64encode(json.dumps(channel).encode()).decode()\n"
      io << "    return f'<turbo-cable-stream-source channel=\"Turbo::StreamsChannel\" signed-stream-name=\"{signed}\"></turbo-cable-stream-source>'\n\n"

      # Path helpers
      io << "def article_path(article):\n"
      io << "    return f'/articles/{article.id}'\n\n"

      io << "def edit_article_path(article):\n"
      io << "    return f'/articles/{article.id}/edit'\n\n"

      io << "def articles_path():\n"
      io << "    return '/articles'\n\n"

      io << "def new_article_path():\n"
      io << "    return '/articles/new'\n\n"

      io << "def article_comments_path(article):\n"
      io << "    return f'/articles/{article.id}/comments'\n\n"

      io << "def article_comment_path(article_id, comment):\n"
      io << "    return f'/articles/{article_id}/comments/{comment.id}'\n\n"

      # Register Jinja2 globals
      io << "env.globals.update(\n"
      io << "    link_to=link_to, button_to=button_to, dom_id=dom_id,\n"
      io << "    pluralize=pluralize, turbo_stream_from=turbo_stream_from,\n"
      io << "    article_path=article_path, edit_article_path=edit_article_path,\n"
      io << "    articles_path=articles_path, new_article_path=new_article_path,\n"
      io << "    article_comments_path=article_comments_path, article_comment_path=article_comment_path,\n"
      io << ")\n\n"

      io << "def render(template_name, **context):\n"
      io << "    return env.get_template(template_name).render(**context)\n\n"

      # Parse form data
      io << "def parse_form(body_bytes):\n"
      io << "    return parse_qs(body_bytes.decode('utf-8'))\n\n"

      io << "def form_value(data, key):\n"
      io << "    return data.get(key, [''])[0]\n\n"

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

      # Broadcast helpers
      io << "async def broadcast_article_append(article):\n"
      io << "    html = render('articles/_article.html', article=article)\n"
      io << "    stream = f'<turbo-stream action=\"prepend\" target=\"articles\"><template>{html}</template></turbo-stream>'\n"
      io << "    await cable.broadcast('articles', stream)\n\n"

      io << "async def broadcast_article_replace(article):\n"
      io << "    html = render('articles/_article.html', article=article)\n"
      io << "    stream = f'<turbo-stream action=\"replace\" target=\"article_{article.id}\"><template>{html}</template></turbo-stream>'\n"
      io << "    await cable.broadcast('articles', stream)\n\n"

      io << "async def broadcast_article_remove(article_id):\n"
      io << "    stream = f'<turbo-stream action=\"remove\" target=\"article_{article_id}\"></turbo-stream>'\n"
      io << "    await cable.broadcast('articles', stream)\n\n"

      io << "async def broadcast_comment_append(comment, article_id):\n"
      io << "    html = render('comments/_comment.html', comment=comment)\n"
      io << "    stream = f'<turbo-stream action=\"append\" target=\"comments\"><template>{html}</template></turbo-stream>'\n"
      io << "    await cable.broadcast(f'article_{article_id}_comments', stream)\n"
      io << "    article = Article.find(article_id)\n"
      io << "    await broadcast_article_replace(article)\n\n"

      io << "async def broadcast_comment_remove(comment_id, article_id):\n"
      io << "    stream = f'<turbo-stream action=\"remove\" target=\"comment_{comment_id}\"></turbo-stream>'\n"
      io << "    await cable.broadcast(f'article_{article_id}_comments', stream)\n"
      io << "    article = Article.find(article_id)\n"
      io << "    await broadcast_article_replace(article)\n\n"

      # WebSocket handler for /cable
      io << "# ActionCable WebSocket handler\n"
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

      # Route handlers
      io << "# Route handlers\n"
      io << "async def articles_index(request):\n"
      io << "    articles = Article.all(order_by='created_at DESC')\n"
      io << "    return web.Response(text=render('articles/index.html', articles=articles), content_type='text/html')\n\n"

      io << "async def articles_show(request):\n"
      io << "    id = int(request.match_info['id'])\n"
      io << "    article = Article.find(id)\n"
      io << "    return web.Response(text=render('articles/show.html', article=article), content_type='text/html')\n\n"

      io << "async def articles_new(request):\n"
      io << "    article = Article()\n"
      io << "    return web.Response(text=render('articles/new.html', article=article), content_type='text/html')\n\n"

      io << "async def articles_create(request):\n"
      io << "    data = parse_form(await request.read())\n"
      io << "    article = Article(title=form_value(data, 'article[title]'), body=form_value(data, 'article[body]'))\n"
      io << "    if article.save():\n"
      io << "        await broadcast_article_append(article)\n"
      io << "        raise web.HTTPFound(f'/articles/{article.id}')\n"
      io << "    return web.Response(text=render('articles/new.html', article=article), content_type='text/html', status=422)\n\n"

      io << "async def articles_edit(request):\n"
      io << "    id = int(request.match_info['id'])\n"
      io << "    article = Article.find(id)\n"
      io << "    return web.Response(text=render('articles/edit.html', article=article), content_type='text/html')\n\n"

      io << "async def articles_update_or_destroy(request):\n"
      io << "    id = int(request.match_info['id'])\n"
      io << "    data = parse_form(await request.read())\n"
      io << "    method = form_value(data, '_method').upper()\n"
      io << "    if method == 'DELETE':\n"
      io << "        article = Article.find(id)\n"
      io << "        article.destroy_comments()\n"
      io << "        article.destroy()\n"
      io << "        await broadcast_article_remove(id)\n"
      io << "        raise web.HTTPSeeOther('/articles')\n"
      io << "    article = Article.find(id)\n"
      io << "    article.title = form_value(data, 'article[title]')\n"
      io << "    article.body = form_value(data, 'article[body]')\n"
      io << "    if article.save():\n"
      io << "        await broadcast_article_replace(article)\n"
      io << "        raise web.HTTPSeeOther(f'/articles/{article.id}')\n"
      io << "    return web.Response(text=render('articles/edit.html', article=article), content_type='text/html', status=422)\n\n"

      io << "async def comments_create(request):\n"
      io << "    article_id = int(request.match_info['id'])\n"
      io << "    data = parse_form(await request.read())\n"
      io << "    article = Article.find(article_id)\n"
      io << "    comment = Comment(article_id=article.id, commenter=form_value(data, 'comment[commenter]'), body=form_value(data, 'comment[body]'))\n"
      io << "    comment.save()\n"
      io << "    await broadcast_comment_append(comment, article_id)\n"
      io << "    raise web.HTTPFound(f'/articles/{article_id}')\n\n"

      io << "async def comments_destroy(request):\n"
      io << "    article_id = int(request.match_info['article_id'])\n"
      io << "    id = int(request.match_info['id'])\n"
      io << "    data = parse_form(await request.read())\n"
      io << "    method = form_value(data, '_method').upper()\n"
      io << "    if method == 'DELETE':\n"
      io << "        comment = Comment.find(id)\n"
      io << "        comment.destroy()\n"
      io << "        await broadcast_comment_remove(id, article_id)\n"
      io << "    raise web.HTTPSeeOther(f'/articles/{article_id}')\n\n"

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

      # Main
      io << "if __name__ == '__main__':\n"
      io << "    init_db()\n"
      io << "    seed_db()\n" if has_seeds
      io << "    app = web.Application(middlewares=[log_middleware])\n"
      io << "    app.router.add_get('/cable', cable_handler)\n"
      io << "    app.router.add_get('/articles/new', articles_new)\n"
      io << "    app.router.add_get('/articles/{id}/edit', articles_edit)\n"
      io << "    app.router.add_get('/articles/{id}', articles_show)\n"
      io << "    app.router.add_get('/', articles_index)\n"
      io << "    app.router.add_get('/articles', articles_index)\n"
      io << "    app.router.add_post('/articles', articles_create)\n"
      io << "    app.router.add_post('/articles/{id}', articles_update_or_destroy)\n"
      io << "    app.router.add_post('/articles/{id}/comments', comments_create)\n"
      io << "    app.router.add_post('/articles/{article_id}/comments/{id}', comments_destroy)\n"
      io << "    app.router.add_static('/static', os.path.join(os.path.dirname(__file__), 'static'))\n"
      io << "    print('Blog running at http://localhost:3000')\n"
      io << "    web.run_app(app, host='0.0.0.0', port=3000, print=lambda _: None)\n"

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
        "dependencies = [\"aiohttp\", \"jinja2\"]\n")
      puts "  pyproject.toml"
    end

    private def convert_templates(output_dir : String)
      templates_dir = File.join(output_dir, "templates")
      views_dir = File.join(rails_dir, "app/views")

      # Generate layout (not from ERB — too Rails-specific)
      File.write(File.join(templates_dir, "layout.html"), <<-HTML)
      <!DOCTYPE html>
      <html>
      <head>
        <title>{{ title|default("Blog") }}</title>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="action-cable-url" content="/cable">
        <link rel="stylesheet" href="/static/app.css">
        <script type="module" src="/static/turbo.min.js"></script>
      </head>
      <body>
        <main class="container mx-auto mt-28 px-5 flex flex-col">
          {% block content %}{% endblock %}
        </main>
      </body>
      </html>
      HTML
      puts "  templates/layout.html"

      # Convert ERB templates
      converter = PythonErbConverter.new("articles")
      convert_view(converter, views_dir, templates_dir, "articles", "index")
      convert_view(converter, views_dir, templates_dir, "articles", "show")
      convert_view(converter, views_dir, templates_dir, "articles", "new")
      convert_view(converter, views_dir, templates_dir, "articles", "edit")
      convert_partial(converter, views_dir, templates_dir, "articles", "_article")
      convert_partial(converter, views_dir, templates_dir, "articles", "_form")

      comment_converter = PythonErbConverter.new("comments")
      convert_partial(comment_converter, views_dir, templates_dir, "comments", "_comment")
    end

    private def convert_view(converter : PythonErbConverter, views_dir : String,
                              templates_dir : String, controller : String, view : String)
      erb_path = File.join(views_dir, controller, "#{view}.html.erb")
      return unless File.exists?(erb_path)

      out_dir = File.join(templates_dir, controller)
      Dir.mkdir_p(out_dir) unless Dir.exists?(out_dir)

      source = File.read(erb_path)
      jinja = "{% extends \"layout.html\" %}\n{% block content %}\n"
      jinja += converter.convert(source)
      jinja += "\n{% endblock %}\n"

      File.write(File.join(out_dir, "#{view}.html"), jinja)
      puts "  templates/#{controller}/#{view}.html"
    end

    private def convert_partial(converter : PythonErbConverter, views_dir : String,
                                 templates_dir : String, controller : String, partial : String)
      erb_path = File.join(views_dir, controller, "#{partial}.html.erb")
      return unless File.exists?(erb_path)

      out_dir = File.join(templates_dir, controller)
      Dir.mkdir_p(out_dir) unless Dir.exists?(out_dir)

      source = File.read(erb_path)
      jinja = converter.convert(source, is_partial: true)

      File.write(File.join(out_dir, "#{partial}.html"), jinja)
      puts "  templates/#{controller}/#{partial}.html"
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
