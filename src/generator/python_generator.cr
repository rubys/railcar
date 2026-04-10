# Generates a Python application from a Rails app.
#
# Produces:
#   app.py        — HTTP application with route dispatch
#   models.py     — SQLite-backed model classes
#   templates/    — HTML templates (simple string formatting)

require "./app_model"
require "./schema_extractor"
require "./python_seed_extractor"
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
      generate_templates(output_dir)
      generate_tailwind(output_dir)
      copy_turbo_js(output_dir)

      puts "Done! Output in #{output_dir}/"
      puts "  python3 #{File.join(output_dir, "app.py")}"
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
      io << "from http.server import HTTPServer, BaseHTTPRequestHandler\n"
      io << "from socketserver import ThreadingMixIn\n"
      io << "from urllib.parse import parse_qs\n"
      io << "import mimetypes\n"
      io << "import re\n"
      io << "import os\n"
      io << "import threading\n"
      io << "import queue\n"
      io << "import time\n"
      io << "from models import *\n\n"

      # Template helper
      io << "TEMPLATE_DIR = os.path.join(os.path.dirname(__file__), 'templates')\n\n"

      io << "def render_template(name, **context):\n"
      io << "    path = os.path.join(TEMPLATE_DIR, name)\n"
      io << "    with open(path) as f:\n"
      io << "        template = f.read()\n"
      io << "    for key, value in context.items():\n"
      io << "        template = template.replace('{{' + key + '}}', str(value))\n"
      io << "    return template\n\n"

      io << "def layout(content, title='Blog'):\n"
      io << "    return render_template('layout.html', content=content, title=title)\n\n"

      # Broadcast hub for SSE
      io << "# Turbo Streams broadcast hub\n"
      io << "class BroadcastHub:\n"
      io << "    def __init__(self):\n"
      io << "        self.lock = threading.Lock()\n"
      io << "        self.channels = {}  # channel_name -> [queue.Queue]\n\n"

      io << "    def subscribe(self, channel):\n"
      io << "        q = queue.Queue()\n"
      io << "        with self.lock:\n"
      io << "            self.channels.setdefault(channel, []).append(q)\n"
      io << "        return q\n\n"

      io << "    def unsubscribe(self, channel, q):\n"
      io << "        with self.lock:\n"
      io << "            if channel in self.channels:\n"
      io << "                self.channels[channel] = [x for x in self.channels[channel] if x is not q]\n\n"

      io << "    def broadcast(self, channel, html):\n"
      io << "        with self.lock:\n"
      io << "            for q in self.channels.get(channel, []):\n"
      io << "                q.put(html)\n\n"

      io << "hub = BroadcastHub()\n\n"

      # Parse form data
      io << "def parse_form(body_bytes):\n"
      io << "    return parse_qs(body_bytes.decode('utf-8'))\n\n"

      io << "def form_value(data, key):\n"
      io << "    return data.get(key, [''])[0]\n\n"

      # Render article partial for broadcasts
      io << "def render_article_card(a):\n"
      io << "    return (\n"
      io << "        f'<div id=\"article_{a.id}\" class=\"flex flex-col sm:flex-row justify-between items-center pb-5 sm:pb-0\">'\n"
      io << "        f'<div class=\"p-4 border rounded mb-4 flex-grow\">'\n"
      io << "        f'<h2 class=\"text-xl font-bold\"><a href=\"/articles/{a.id}\" class=\"text-blue-600 hover:underline\">{a.title}</a></h2>'\n"
      io << "        f'<p class=\"text-gray-700 mt-2\">{(a.body or \"\")[:100]}</p></div>'\n"
      io << "        f'<div class=\"w-full sm:w-auto flex flex-col sm:flex-row space-x-2 space-y-2\">'\n"
      io << "        f'<a href=\"/articles/{a.id}\" class=\"w-full sm:w-auto text-center rounded-md px-3.5 py-2.5 bg-gray-100 hover:bg-gray-50 inline-block font-medium\">Show</a>'\n"
      io << "        f'<a href=\"/articles/{a.id}/edit\" class=\"w-full sm:w-auto text-center rounded-md px-3.5 py-2.5 bg-gray-100 hover:bg-gray-50 inline-block font-medium\">Edit</a>'\n"
      io << "        f'</div></div>'\n"
      io << "    )\n\n"

      io << "def render_comment_partial(c, article_id):\n"
      io << "    return (\n"
      io << "        f'<div id=\"comment_{c.id}\" class=\"p-4 bg-gray-50 rounded\">'\n"
      io << "        f'<p class=\"font-semibold\">{c.commenter}</p>'\n"
      io << "        f'<p class=\"text-gray-700\">{c.body}</p>'\n"
      io << "        f'<form method=\"post\" action=\"/articles/{article_id}/comments/{c.id}\" class=\"inline\" data-turbo-confirm=\"Are you sure?\">'\n"
      io << "        f'<input type=\"hidden\" name=\"_method\" value=\"delete\">'\n"
      io << "        f'<button type=\"submit\" class=\"text-red-600 text-sm mt-2\">Delete</button></form></div>'\n"
      io << "    )\n\n"

      # Broadcast helpers
      io << "def broadcast_article_append(article):\n"
      io << "    html = render_article_card(article)\n"
      io << "    stream = f'<turbo-stream action=\"prepend\" target=\"articles\"><template>{html}</template></turbo-stream>'\n"
      io << "    hub.broadcast('articles', stream)\n\n"

      io << "def broadcast_article_replace(article):\n"
      io << "    html = render_article_card(article)\n"
      io << "    stream = f'<turbo-stream action=\"replace\" target=\"article_{article.id}\"><template>{html}</template></turbo-stream>'\n"
      io << "    hub.broadcast('articles', stream)\n\n"

      io << "def broadcast_article_remove(article_id):\n"
      io << "    stream = f'<turbo-stream action=\"remove\" target=\"article_{article_id}\"></turbo-stream>'\n"
      io << "    hub.broadcast('articles', stream)\n\n"

      io << "def broadcast_comment_append(comment, article_id):\n"
      io << "    html = render_comment_partial(comment, article_id)\n"
      io << "    stream = f'<turbo-stream action=\"append\" target=\"comments\"><template>{html}</template></turbo-stream>'\n"
      io << "    hub.broadcast(f'article_{article_id}_comments', stream)\n"
      io << "    # Also update article card on index (comment count changed)\n"
      io << "    article = Article.find(article_id)\n"
      io << "    broadcast_article_replace(article)\n\n"

      io << "def broadcast_comment_remove(comment_id, article_id):\n"
      io << "    stream = f'<turbo-stream action=\"remove\" target=\"comment_{comment_id}\"></turbo-stream>'\n"
      io << "    hub.broadcast(f'article_{article_id}_comments', stream)\n"
      io << "    article = Article.find(article_id)\n"
      io << "    broadcast_article_replace(article)\n\n"

      # HTTP Handler
      io << "class BlogHandler(BaseHTTPRequestHandler):\n"
      io << "    def do_GET(self):\n"
      io << "        path = self.path.split('?')[0]\n"
      io << "\n"
      io << "        # SSE streams\n"
      io << "        match = re.match(r'^/streams/(.+)$', path)\n"
      io << "        if match:\n"
      io << "            return self.handle_sse(match.group(1))\n"
      io << "\n"
      io << "        # Static files\n"
      io << "        if path.startswith('/static/'):\n"
      io << "            return self.serve_static(path)\n"
      io << "\n"

      # GET routes
      io << "        match = re.match(r'^/articles/(\\d+)/edit$', path)\n"
      io << "        if match:\n"
      io << "            return self.articles_edit(int(match.group(1)))\n"
      io << "\n"
      io << "        match = re.match(r'^/articles/(\\d+)$', path)\n"
      io << "        if match:\n"
      io << "            return self.articles_show(int(match.group(1)))\n"
      io << "\n"
      io << "        if path == '/articles/new':\n"
      io << "            return self.articles_new()\n"
      io << "\n"
      io << "        if path in ('/', '/articles'):\n"
      io << "            return self.articles_index()\n"
      io << "\n"
      io << "        self.send_error(404)\n"
      io << "\n"

      io << "    def do_POST(self):\n"
      io << "        path = self.path.split('?')[0]\n"
      io << "        body = self.read_body()\n"
      io << "        data = parse_form(body)\n"
      io << "        method_override = form_value(data, '_method').upper()\n"
      io << "\n"

      # POST routes
      io << "        match = re.match(r'^/articles/(\\d+)/comments/(\\d+)$', path)\n"
      io << "        if match and method_override == 'DELETE':\n"
      io << "            return self.comments_destroy(int(match.group(1)), int(match.group(2)))\n"
      io << "\n"
      io << "        match = re.match(r'^/articles/(\\d+)/comments$', path)\n"
      io << "        if match:\n"
      io << "            return self.comments_create(int(match.group(1)), data)\n"
      io << "\n"
      io << "        match = re.match(r'^/articles/(\\d+)$', path)\n"
      io << "        if match:\n"
      io << "            id = int(match.group(1))\n"
      io << "            if method_override in ('PATCH', 'PUT'):\n"
      io << "                return self.articles_update(id, data)\n"
      io << "            elif method_override == 'DELETE':\n"
      io << "                return self.articles_destroy(id)\n"
      io << "\n"
      io << "        if path == '/articles':\n"
      io << "            return self.articles_create(data)\n"
      io << "\n"
      io << "        self.send_error(404)\n"
      io << "\n"

      # Helper methods
      io << "    def read_body(self):\n"
      io << "        length = int(self.headers.get('Content-Length', 0))\n"
      io << "        return self.rfile.read(length)\n"
      io << "\n"

      io << "    def respond(self, status, content_type, body):\n"
      io << "        self.send_response(status)\n"
      io << "        self.send_header('Content-Type', content_type)\n"
      io << "        self.end_headers()\n"
      io << "        self.wfile.write(body.encode() if isinstance(body, str) else body)\n"
      io << "\n"

      io << "    def redirect(self, location, status=302):\n"
      io << "        self.send_response(status)\n"
      io << "        self.send_header('Location', location)\n"
      io << "        self.end_headers()\n"
      io << "\n"

      io << "    def serve_static(self, path):\n"
      io << "        static_path = os.path.join(os.path.dirname(__file__), path.lstrip('/'))\n"
      io << "        if os.path.isfile(static_path):\n"
      io << "            content_type = mimetypes.guess_type(static_path)[0] or 'application/octet-stream'\n"
      io << "            with open(static_path, 'rb') as f:\n"
      io << "                self.respond(200, content_type, f.read())\n"
      io << "        else:\n"
      io << "            self.send_error(404)\n"
      io << "\n"

      # SSE handler
      io << "    def handle_sse(self, channel):\n"
      io << "        self.send_response(200)\n"
      io << "        self.send_header('Content-Type', 'text/event-stream')\n"
      io << "        self.send_header('Cache-Control', 'no-cache')\n"
      io << "        self.send_header('Connection', 'keep-alive')\n"
      io << "        self.send_header('X-Accel-Buffering', 'no')\n"
      io << "        self.end_headers()\n"
      io << "        q = hub.subscribe(channel)\n"
      io << "        try:\n"
      io << "            while True:\n"
      io << "                try:\n"
      io << "                    message = q.get(timeout=30)\n"
      io << "                    self.wfile.write(f'data: {message}\\n\\n'.encode())\n"
      io << "                    self.wfile.flush()\n"
      io << "                except queue.Empty:\n"
      io << "                    # Send keepalive\n"
      io << "                    self.wfile.write(b':\\n\\n')\n"
      io << "                    self.wfile.flush()\n"
      io << "        except (BrokenPipeError, ConnectionResetError):\n"
      io << "            pass\n"
      io << "        finally:\n"
      io << "            hub.unsubscribe(channel, q)\n"
      io << "\n"

      io << "    def log_message(self, format, *args):\n"
      io << "        print(f'{self.command} {self.path} {args[1] if len(args) > 1 else \"\"}'.strip())\n"
      io << "\n"

      # Controller actions as handler methods
      generate_articles_handlers(io)
      generate_comments_handlers(io)

      # Seed data from db/seeds.rb if it exists
      seeds_path = File.join(rails_dir, "db/seeds.rb")
      has_seeds = File.exists?(seeds_path)
      if has_seeds
        first_model = app.models.keys.first? || "Article"
        io << PythonSeedExtractor.generate(seeds_path, first_model)
      end

      # Threaded server
      io << "class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):\n"
      io << "    daemon_threads = True\n\n"

      # Main
      io << "if __name__ == '__main__':\n"
      io << "    init_db()\n"
      io << "    seed_db()\n" if has_seeds
      io << "    print('Blog running at http://localhost:3000')\n"
      io << "    server = ThreadedHTTPServer(('0.0.0.0', 3000), BlogHandler)\n"
      io << "    server.serve_forever()\n"

      File.write(File.join(output_dir, "app.py"), io.to_s)
      puts "  app.py"
    end

    private def generate_articles_handlers(io : IO::Memory)
      # index
      io << "    def articles_index(self):\n"
      io << "        articles = Article.all(order_by='created_at DESC')\n"
      io << "        article_list = '\\n'.join(render_article_card(a) for a in articles)\n"
      io << "        article_list = article_list or '<p class=\"text-center my-10\">No articles found.</p>'\n"
      io << "        content = render_template('articles_index.html', article_list=article_list)\n"
      io << "        self.respond(200, 'text/html', layout(content))\n\n"

      # show
      io << "    def articles_show(self, id):\n"
      io << "        article = Article.find(id)\n"
      io << "        comments = article.comments()\n"
      io << "        comments_html = '\\n'.join(render_comment_partial(c, id) for c in comments)\n"
      io << "        comments_html = comments_html or '<p class=\"text-gray-500\">No comments yet.</p>'\n"
      io << "        content = render_template('articles_show.html',\n"
      io << "            id=article.id, title=article.title, body=article.body,\n"
      io << "            comments_html=comments_html)\n"
      io << "        self.respond(200, 'text/html', layout(content))\n\n"

      # new
      io << "    def articles_new(self):\n"
      io << "        content = render_template('articles_form.html',\n"
      io << "            form_title='New Article', title='', body='',\n"
      io << "            action='/articles', method_field='')\n"
      io << "        self.respond(200, 'text/html', layout(content))\n\n"

      # create
      io << "    def articles_create(self, data):\n"
      io << "        article = Article(title=form_value(data, 'article[title]'), body=form_value(data, 'article[body]'))\n"
      io << "        if article.save():\n"
      io << "            broadcast_article_append(article)\n"
      io << "            self.redirect(f'/articles/{article.id}')\n"
      io << "        else:\n"
      io << "            content = render_template('articles_form.html',\n"
      io << "                form_title='New Article', title=article.title, body=article.body,\n"
      io << "                action='/articles', method_field='')\n"
      io << "            self.respond(422, 'text/html', layout(content))\n\n"

      # edit
      io << "    def articles_edit(self, id):\n"
      io << "        article = Article.find(id)\n"
      io << "        content = render_template('articles_form.html',\n"
      io << "            form_title='Edit Article', title=article.title, body=article.body,\n"
      io << "            action=f'/articles/{id}',\n"
      io << "            method_field='<input type=\"hidden\" name=\"_method\" value=\"patch\">')\n"
      io << "        self.respond(200, 'text/html', layout(content))\n\n"

      # update
      io << "    def articles_update(self, id, data):\n"
      io << "        article = Article.find(id)\n"
      io << "        article.title = form_value(data, 'article[title]')\n"
      io << "        article.body = form_value(data, 'article[body]')\n"
      io << "        if article.save():\n"
      io << "            broadcast_article_replace(article)\n"
      io << "            self.redirect(f'/articles/{article.id}', 303)\n"
      io << "        else:\n"
      io << "            content = render_template('articles_form.html',\n"
      io << "                form_title='Edit Article', title=article.title, body=article.body,\n"
      io << "                action=f'/articles/{id}',\n"
      io << "                method_field='<input type=\"hidden\" name=\"_method\" value=\"patch\">')\n"
      io << "            self.respond(422, 'text/html', layout(content))\n\n"

      # destroy
      io << "    def articles_destroy(self, id):\n"
      io << "        article = Article.find(id)\n"
      io << "        article.destroy_comments()\n"
      io << "        article.destroy()\n"
      io << "        broadcast_article_remove(id)\n"
      io << "        self.redirect('/articles', 303)\n\n"
    end

    private def generate_comments_handlers(io : IO::Memory)
      # create
      io << "    def comments_create(self, article_id, data):\n"
      io << "        article = Article.find(article_id)\n"
      io << "        comment = Comment(article_id=article.id, commenter=form_value(data, 'comment[commenter]'), body=form_value(data, 'comment[body]'))\n"
      io << "        comment.save()\n"
      io << "        broadcast_comment_append(comment, article_id)\n"
      io << "        self.redirect(f'/articles/{article_id}')\n\n"

      # destroy
      io << "    def comments_destroy(self, article_id, id):\n"
      io << "        comment = Comment.find(id)\n"
      io << "        comment.destroy()\n"
      io << "        broadcast_comment_remove(id, article_id)\n"
      io << "        self.redirect(f'/articles/{article_id}', 303)\n\n"
    end

    private def generate_templates(output_dir : String)
      templates_dir = File.join(output_dir, "templates")

      # Layout (matches Rails app/views/layouts/application.html.erb)
      File.write(File.join(templates_dir, "layout.html"), <<-HTML)
      <!DOCTYPE html>
      <html>
      <head>
        <title>{{title}}</title>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="action-cable-url" content="">
        <link rel="stylesheet" href="/static/app.css">
        <script type="module" src="/static/turbo.min.js"></script>
      </head>
      <body>
        <main class="container mx-auto mt-28 px-5 flex flex-col">
          {{content}}
        </main>
      </body>
      </html>
      HTML
      puts "  templates/layout.html"

      # Articles index (matches Rails index.html.erb + _article.html.erb)
      File.write(File.join(templates_dir, "articles_index.html"), <<-'HTML')
      <turbo-stream-source src="/streams/articles"></turbo-stream-source>
      <div class="w-full">
        <div class="flex justify-between items-center">
          <h1 class="font-bold text-4xl">Articles</h1>
          <a href="/articles/new" class="rounded-md px-3.5 py-2.5 bg-blue-600 hover:bg-blue-500 text-white block font-medium">New article</a>
        </div>
        <div id="articles" class="min-w-full divide-y divide-gray-200 space-y-5">
          {{article_list}}
        </div>
      </div>
      HTML
      puts "  templates/articles_index.html"

      # Articles show (matches Rails show.html.erb + _comment.html.erb)
      File.write(File.join(templates_dir, "articles_show.html"), <<-'HTML')
      <div class="md:w-2/3 w-full">
        <h1 class="font-bold text-4xl">{{title}}</h1>
        <div class="my-4">
          <p class="text-gray-700">{{body}}</p>
        </div>
        <a href="/articles/{{id}}/edit" class="w-full sm:w-auto text-center rounded-md px-3.5 py-2.5 bg-gray-100 hover:bg-gray-50 inline-block font-medium">Edit this article</a>
        <a href="/articles" class="w-full sm:w-auto text-center mt-2 sm:mt-0 sm:ml-2 rounded-md px-3.5 py-2.5 bg-gray-100 hover:bg-gray-50 inline-block font-medium">Back to articles</a>
        <form method="post" action="/articles/{{id}}" class="sm:inline-block mt-2 sm:mt-0 sm:ml-2" data-turbo-confirm="Are you sure?">
          <input type="hidden" name="_method" value="delete">
          <button type="submit" class="w-full rounded-md px-3.5 py-2.5 text-white bg-red-600 hover:bg-red-500 font-medium cursor-pointer">Destroy this article</button>
        </form>
      </div>
      <hr class="my-8">
      <h2 class="text-xl font-bold mb-4">Comments</h2>
      <turbo-stream-source src="/streams/article_{{id}}_comments"></turbo-stream-source>
      <div id="comments" class="space-y-4 mb-8">
        {{comments_html}}
      </div>
      <h3 class="text-lg font-semibold mb-2">Add a Comment</h3>
      <form method="post" action="/articles/{{id}}/comments" class="space-y-4">
        <div>
          <label class="block font-medium">Commenter</label>
          <input type="text" name="comment[commenter]" class="block w-full border rounded p-2">
        </div>
        <div>
          <label class="block font-medium">Body</label>
          <textarea name="comment[body]" rows="3" class="block w-full border rounded p-2"></textarea>
        </div>
        <button type="submit" class="bg-blue-600 text-white px-4 py-2 rounded">Add Comment</button>
      </form>
      HTML
      puts "  templates/articles_show.html"

      # Article form (matches Rails _form.html.erb)
      File.write(File.join(templates_dir, "articles_form.html"), <<-'HTML')
      <div class="md:w-2/3 w-full">
        <h1 class="font-bold text-4xl">{{form_title}}</h1>
        <form method="post" action="{{action}}" class="contents">
          {{method_field}}
          <div class="my-5">
            <label>Title</label>
            <input type="text" name="article[title]" value="{{title}}" class="block shadow-sm rounded-md border border-gray-400 focus:outline-blue-600 px-3 py-2 mt-2 w-full">
          </div>
          <div class="my-5">
            <label>Body</label>
            <textarea name="article[body]" rows="4" class="block shadow-sm rounded-md border border-gray-400 focus:outline-blue-600 px-3 py-2 mt-2 w-full">{{body}}</textarea>
          </div>
          <div class="inline">
            <button type="submit" class="w-full sm:w-auto rounded-md px-3.5 py-2.5 bg-blue-600 hover:bg-blue-500 text-white inline-block font-medium cursor-pointer">Save Article</button>
          </div>
        </form>
        <a href="/articles" class="w-full sm:w-auto text-center mt-2 sm:mt-0 sm:ml-2 rounded-md px-3.5 py-2.5 bg-gray-100 hover:bg-gray-50 inline-block font-medium">Back to articles</a>
      </div>
      HTML
      puts "  templates/articles_form.html"
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
