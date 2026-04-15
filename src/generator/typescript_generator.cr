# TypeScriptGenerator — orchestrates TypeScript generation from Rails app.
#
# Pipeline:
#   1. Build Crystal AST: runtime source + model ASTs (via filter chain)
#   2. program.semantic() → types on all nodes
#   3. Emit models, views, controllers, tests, app entry point
#
# Delegates to sub-generators for views, controllers, and tests.

require "./app_model"
require "./schema_extractor"
require "./inflector"
require "./source_parser"
require "../semantic"
require "../filters/model_boilerplate_python"
require "../filters/broadcasts_to"
require "../emitter/typescript/cr2ts"
require "./fixture_loader"
require "./typescript_view_generator"
require "./typescript_controller_generator"
require "./typescript_test_generator"

module Railcar
  class TypeScriptGenerator
    getter app : AppModel
    getter rails_dir : String

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      puts "Generating TypeScript from #{rails_dir}..."
      Dir.mkdir_p(output_dir)

      # Build model ASTs from Rails source
      model_asts = build_model_asts

      # Compile runtime + models together for type inference
      program, typed_ast = compile(model_asts)
      unless program && typed_ast
        STDERR.puts "Cannot generate TypeScript without typed AST"
        return
      end

      emitter = Cr2Ts::Emitter.new

      # Emit
      emit_runtime(output_dir)
      emit_helpers(output_dir)
      emit_models(typed_ast, output_dir, emitter)
      emit_broadcast_callbacks(output_dir)
      TypeScriptViewGenerator.new(app, rails_dir).generate(output_dir)
      TypeScriptControllerGenerator.new(app, rails_dir, emitter).generate(output_dir)
      emit_app(output_dir)
      copy_static_assets(output_dir)
      TypeScriptTestGenerator.new(app, rails_dir).generate(output_dir)
      emit_package_json(output_dir)

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

        ast = SourceParser.parse(source_path)
        ast = ast.transform(BroadcastsTo.new)
        ast = ast.transform(ModelBoilerplatePython.new(schema, model))

        asts << ast
      end
      asts
    end

    # ── Compile runtime + models for type inference ──

    private def compile(model_asts : Array(Crystal::ASTNode)) : {Crystal::Program?, Crystal::ASTNode?}
      location = Crystal::Location.new("src/app.cr", 1, 1)

      runtime_dir = File.join(File.dirname(__FILE__), "..", "runtime", "typescript")
      runtime_source = File.read(File.join(runtime_dir, "base.cr"))

      source = String.build do |io|
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
        runtime_source.lines.each do |line|
          next if line.strip.starts_with?("require ")
          io << line << "\n"
        end
      end

      all_nodes = [
        Crystal::Require.new("prelude").at(location),
        Crystal::Parser.parse(source),
      ] of Crystal::ASTNode

      if model_asts.size > 0
        all_nodes << Crystal::ModuleDef.new(
          Crystal::Path.new("Railcar"),
          body: Crystal::Expressions.new(model_asts.map(&.as(Crystal::ASTNode)))
        )
      end

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

    private def emit_runtime(output_dir : String)
      runtime_dir = File.join(output_dir, "runtime")
      Dir.mkdir_p(runtime_dir)

      runtime_source = File.join(File.dirname(__FILE__), "..", "runtime", "typescript", "base_runtime.ts")
      File.copy(runtime_source, File.join(runtime_dir, "base.ts"))
      puts "  runtime/base.ts"
    end

    # ── Emit helpers ──

    private def emit_helpers(output_dir : String)
      io = IO::Memory.new
      io << "// View and route helpers for railcar-generated TypeScript apps.\n\n"
      io << "import ejs from \"ejs\";\n"
      io << "import path from \"path\";\n"
      io << "import { fileURLToPath } from \"url\";\n"
      io << "import type { Response } from \"express\";\n"
      io << "import { MODEL_REGISTRY } from \"./runtime/base.js\";\n"
      io << "\n"
      io << "const __helpers_dir = path.dirname(fileURLToPath(import.meta.url));\n\n"

      # Route helpers from route data model
      io << "// Route helpers\n"
      app.routes.helpers.each do |helper|
        if helper.params.empty?
          io << "export function #{helper.name.gsub(/_([a-z])/) { |_, m| m[1].upcase }}Path(): string {\n"
          io << "  return #{helper.path.inspect};\n"
          io << "}\n\n"
        else
          param_names = helper.params.map_with_index do |p, i|
            if p == "id"
              i == 0 ? "model" : "child"
            else
              p.chomp("_id")
            end
          end
          param_list = param_names.map { |n| "#{n}: { id: number | null }" }.join(", ")
          io << "export function #{helper.name.gsub(/_([a-z])/) { |_, m| m[1].upcase }}Path(#{param_list}): string {\n"
          path_expr = helper.path
          helper.params.each_with_index do |p, i|
            path_expr = path_expr.gsub(":#{p}", "${#{param_names[i]}.id}")
          end
          io << "  return `#{path_expr}`;\n"
          io << "}\n\n"
        end
      end

      # View helpers
      io << "// View helpers\n"
      io << HELPERS_SOURCE
      io << "\n"

      # Build helpers object for EJS template locals
      helper_names = %w[linkTo buttonTo turboStreamFrom turboCableStreamTag truncate domId pluralize formWithOpenTag formSubmitTag parseForm formValue extractModelParams encodeParams]
      app.routes.helpers.each do |helper|
        ts_name = helper.name.gsub(/_([a-z])/) { |_, m| m[1].upcase } + "Path"
        helper_names << ts_name
      end
      io << "// Helpers object for EJS template locals\n"
      io << "export const helpers = { #{helper_names.join(", ")}, MODEL_REGISTRY } as Record<string, unknown>;\n\n"

      File.write(File.join(output_dir, "helpers.ts"), io.to_s)
      puts "  helpers.ts"
    end

    HELPERS_SOURCE = <<-TS
    export function linkTo(text: string, url: string, opts: Record<string, string> = {}): string {
      const cls = opts.class ? ` class="${opts.class}"` : "";
      return `<a href="${url}"${cls}>${text}</a>`;
    }

    export function buttonTo(text: string, url: string, opts: Record<string, unknown> = {}): string {
      const method = (opts.method as string) || "post";
      const cls = opts.class ? ` class="${opts.class}"` : "";
      const formClass = opts.form_class ? ` class="${opts.form_class}"` : "";
      const data = (opts.data as Record<string, string>) || {};
      const confirm = data.turbo_confirm || (opts.data_turbo_confirm as string) || "";
      const confirmAttr = confirm ? ` data-turbo-confirm="${confirm}"` : "";
      return `<form method="post" action="${url}"${formClass}${confirmAttr}>` +
             `<input type="hidden" name="_method" value="${method}">` +
             `<button type="submit"${cls}>${text}</button></form>`;
    }

    export function turboStreamFrom(channel: string): string {
      const signed = Buffer.from(JSON.stringify(channel)).toString("base64");
      return `<turbo-cable-stream-source channel="Turbo::StreamsChannel" signed-stream-name="${signed}"></turbo-cable-stream-source>`;
    }

    export const turboCableStreamTag = turboStreamFrom;

    export function truncate(text: string | null, opts: { length?: number } = {}): string {
      if (!text) return "";
      const length = opts.length ?? 30;
      if (text.length <= length) return text;
      return text.slice(0, length - 3) + "...";
    }

    export function domId(obj: { id: number | null; constructor: { name: string } }, prefix?: string): string {
      const name = obj.constructor.name.toLowerCase();
      if (prefix) return `${prefix}_${name}_${obj.id}`;
      return `${name}_${obj.id}`;
    }

    export function pluralize(count: number, singular: string): string {
      return count === 1 ? `${count} ${singular}` : `${count} ${singular}s`;
    }

    export function layout(content: string, title: string = "Blog"): string {
      return `<!DOCTYPE html>
    <html>
    <head>
      <title>${title}</title>
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <meta name="action-cable-url" content="/cable">
      <link rel="stylesheet" href="/static/app.css">
      <script type="module" src="/static/turbo.min.js"></script>
    </head>
    <body>
      <main class="container mx-auto mt-28 px-5 flex flex-col">
        ${content}
      </main>
    </body>
    </html>`;
    }

    export function formWithOpenTag(model: { id: number | null; constructor: { name: string } }, opts: Record<string, string> = {}): string {
      const name = model.constructor.name.toLowerCase();
      const plural = name + "s";
      const cls = opts.class ? ` class="${opts.class}"` : "";
      if (model.id) {
        return `<form action="/${plural}/${model.id}" method="post"${cls}>` +
               `<input type="hidden" name="_method" value="patch">`;
      }
      return `<form action="/${plural}" method="post"${cls}>`;
    }

    export function formSubmitTag(model: { id: number | null; constructor: { name: string } }, opts: Record<string, string> = {}): string {
      const name = model.constructor.name;
      const cls = opts.class ? ` class="${opts.class}"` : "";
      const action = model.id ? "Update" : "Create";
      return `<input type="submit" value="${action} ${name}"${cls}>`;
    }

    export function parseForm(body: unknown): Record<string, string[]> {
      const result: Record<string, string[]> = {};
      if (!body) return result;
      // Express urlencoded parser returns an object; raw string from supertest
      if (typeof body === "object") {
        for (const [key, value] of Object.entries(body as Record<string, unknown>)) {
          result[key] = [String(value)];
        }
        return result;
      }
      const str = String(body);
      for (const pair of str.split("&")) {
        const [key, value] = pair.split("=").map(decodeURIComponent);
        if (!result[key]) result[key] = [];
        result[key].push(value ?? "");
      }
      return result;
    }

    export function formValue(data: Record<string, string[]>, key: string): string {
      return data[key]?.[0] ?? "";
    }

    export function extractModelParams(data: Record<string, unknown>, model: string): Record<string, string> {
      const result: Record<string, string> = {};
      // Handle Express extended parser (nested objects): { article: { title: "..." } }
      const nested = (data as Record<string, unknown>)[model];
      if (nested && typeof nested === "object") {
        for (const [k, v] of Object.entries(nested as Record<string, unknown>)) {
          result[k] = String(v);
        }
        return result;
      }
      // Handle flat URL-encoded: { "article[title]": ["..."] }
      const prefix = `${model}[`;
      for (const [key, values] of Object.entries(data)) {
        if (key.startsWith(prefix) && key.endsWith("]")) {
          const field = key.slice(prefix.length, -1);
          result[field] = Array.isArray(values) ? values[0] : String(values);
        }
      }
      return result;
    }

    export function encodeParams(params: Record<string, unknown>): string {
      const parts: string[] = [];
      for (const [outerKey, inner] of Object.entries(params)) {
        if (typeof inner === "object" && inner !== null) {
          for (const [k, v] of Object.entries(inner as Record<string, string>)) {
            parts.push(`${encodeURIComponent(`${outerKey}[${k}]`)}=${encodeURIComponent(v)}`);
          }
        } else {
          parts.push(`${encodeURIComponent(outerKey)}=${encodeURIComponent(String(inner))}`);
        }
      }
      return parts.join("&");
    }

    const viewsDir = path.join(__helpers_dir, "views");
    const layoutPath = path.join(viewsDir, "layouts", "application.ejs");

    import fs from "fs";

    export function renderView(res: Response, template: string, data: unknown, status: number = 200): void {
      try {
      const templatePath = path.join(viewsDir, template + ".ejs");
      const varName = template.split("/").pop()!.replace(/^_/, "");
      // Make data available under multiple names: the template-derived name,
      // and common singular/plural forms for the controller's model
      const plural = template.split("/")[0];
      const singular = plural.endsWith("s") ? plural.slice(0, -1) : plural;
      const locals: Record<string, unknown> = {
        ...helpers, helpers,
        [varName]: data, [singular]: data, [plural]: data,
        notice: null, flash: {}, MODEL_REGISTRY,
      };
      const content = ejs.render(
        fs.readFileSync(templatePath, "utf-8"),
        locals,
        { filename: templatePath }
      );
      const html = ejs.render(
        fs.readFileSync(layoutPath, "utf-8"),
        { content, title: (locals as Record<string, unknown>).title || "Blog" },
        { filename: layoutPath }
      );
      res.status(status).send(html);
      } catch (e) {
        console.error(`renderView error (${template}):`, (e as Error).message);
        if (!res.headersSent) res.status(500).send((e as Error).message);
      }
    }
    TS

    # ── Emit models ──

    private def emit_models(typed_ast : Crystal::ASTNode, output_dir : String, emitter : Cr2Ts::Emitter)
      models_dir = File.join(output_dir, "models")
      Dir.mkdir_p(models_dir)

      nodes = extract_railcar_nodes(typed_ast)

      skip = %w[ValidationErrors ApplicationRecord CollectionProxy]
      nodes.each do |node|
        next unless node.is_a?(Crystal::ClassDef)
        class_name = node.name.names.last
        next if skip.includes?(class_name)

        ts_source = emitter.emit_model(node, class_name)

        imports = "import { ApplicationRecord, CollectionProxy, MODEL_REGISTRY } from \"../runtime/base.js\";\n\n"

        out_path = File.join(models_dir, "#{Inflector.underscore(class_name)}.ts")
        File.write(out_path, imports + ts_source)
        puts "  models/#{Inflector.underscore(class_name)}.ts"
      end
    end

    # ── Emit broadcast callbacks ──

    private def emit_broadcast_callbacks(output_dir : String)
      app.models.each_key do |name|
        source_path = File.join(rails_dir, "app/models/#{Inflector.underscore(name)}.rb")
        next unless File.exists?(source_path)

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

          broadcast_call = extract_broadcast_expr(block.body)
          next unless broadcast_call

          ts_callback = call.name == "after_save" ? "afterSave" : "afterDestroy"
          callbacks << "#{name}.#{ts_callback}((record) => (record as #{name}).#{broadcast_call});"
        end

        next if callbacks.empty?

        out_path = File.join(output_dir, "models/#{Inflector.underscore(name)}.ts")
        next unless File.exists?(out_path)

        File.open(out_path, "a") do |f|
          f << "\n// Turbo Streams broadcast callbacks\n"
          callbacks.each { |cb| f << cb << "\n" }
        end
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

      method = case call.name
               when "broadcast_replace_to" then "broadcastReplaceTo"
               when "broadcast_append_to"  then "broadcastAppendTo"
               when "broadcast_prepend_to" then "broadcastPrependTo"
               when "broadcast_remove_to"  then "broadcastRemoveTo"
               else call.name
               end

      args = call.args.map do |a|
        case a
        when Crystal::StringLiteral then a.value.inspect
        when Crystal::StringInterpolation
          parts = a.expressions.map do |part|
            case part
            when Crystal::StringLiteral then part.value
            when Crystal::Call then "${record.#{part.name}}"
            else "${#{part}}"
            end
          end
          "`#{parts.join}`"
        else a.to_s.inspect
        end
      end

      if obj = call.obj
        # article.broadcast_replace_to → record.article().broadcastReplaceTo(...)
        obj_name = obj.to_s.lchop("@")
        "#{obj_name}().#{method}(#{args.join(", ")})"
      else
        "#{method}(#{args.join(", ")})"
      end
    end

    # ── Emit app entry point ──

    private def emit_app(output_dir : String)
      io = IO::Memory.new
      io << "import express from \"express\";\n"
      io << "import { createServer } from \"http\";\n"
      io << "import { WebSocketServer, WebSocket } from \"ws\";\n"
      io << "import Database from \"better-sqlite3\";\n"
      io << "import path from \"path\";\n"
      io << "import { fileURLToPath } from \"url\";\n"
      io << "import ejs from \"ejs\";\n"
      io << "import fs from \"fs\";\n"
      io << "import { ApplicationRecord, log } from \"./runtime/base.js\";\n"
      io << "import { helpers } from \"./helpers.js\";\n"

      app.controllers.each do |info|
        name = Inflector.underscore(info.name).chomp("_controller")
        io << "import * as #{name}Controller from \"./controllers/#{name}.js\";\n"
      end

      app.models.each_key do |name|
        io << "import { #{name} } from \"./models/#{Inflector.underscore(name)}.js\";\n"
      end
      io << "\n"

      io << "const __dirname = path.dirname(fileURLToPath(import.meta.url));\n"
      io << "const viewsDir = path.join(__dirname, \"views\");\n\n"

      # ActionCable server
      io << <<-TS

      // ActionCable WebSocket server for Turbo Streams
      class CableServer {
        channels = new Map<string, Set<{ ws: WebSocket; identifier: string }>>();

        subscribe(ws: WebSocket, channel: string, identifier: string) {
          if (!this.channels.has(channel)) this.channels.set(channel, new Set());
          this.channels.get(channel)!.add({ ws, identifier });
        }

        unsubscribeAll(ws: WebSocket) {
          for (const [, subs] of this.channels) {
            for (const sub of subs) {
              if (sub.ws === ws) subs.delete(sub);
            }
          }
        }

        broadcast(channel: string, html: string) {
          const subs = this.channels.get(channel);
          if (!subs) return;
          for (const { ws, identifier } of subs) {
            if (ws.readyState === WebSocket.OPEN) {
              ws.send(JSON.stringify({ type: "message", identifier, message: html }));
            }
          }
        }
      }

      const cable = new CableServer();
      ApplicationRecord._broadcaster = cable;

      TS

      # DB init
      io << "function initDb(): Database.Database {\n"
      io << "  const db = new Database(path.join(__dirname, \"blog.db\"));\n"
      io << "  db.exec(\"PRAGMA foreign_keys = ON\");\n"
      app.schemas.each do |schema|
        all_cols = [{name: "id", type: "INTEGER"}]
        schema.columns.each { |c| all_cols << {name: c.name, type: c.type} }
        col_defs = all_cols.map do |c|
          parts = "#{c[:name]} #{c[:type]}"
          parts += " PRIMARY KEY AUTOINCREMENT" if c[:name] == "id"
          parts += " NOT NULL" unless c[:name] == "id"
          parts
        end
        io << "  db.exec(`CREATE TABLE IF NOT EXISTS #{schema.name} (\n"
        io << "    #{col_defs.join(",\n    ")}\n"
        io << "  )`);\n"
      end
      io << "  ApplicationRecord.db = db;\n"
      io << "  return db;\n"
      io << "}\n\n"

      # Seeds
      seeds_path = File.join(rails_dir, "db/seeds.rb")
      io << "function seedDb(): void {\n"
      if File.exists?(seeds_path)
        emit_seeds(io, seeds_path)
      end
      io << "}\n\n"

      # Render partial helper (uses EJS + helpers)
      io << "function renderPartial(templatePath: string, varName: string, record: unknown): string {\n"
      io << "  const tmpl = fs.readFileSync(path.join(viewsDir, templatePath), \"utf-8\");\n"
      io << "  return ejs.render(tmpl, { [varName]: record, helpers }, { filename: path.join(viewsDir, templatePath) });\n"
      io << "}\n\n"

      # Create app
      io << "function createApp(): express.Application {\n"

      # Wire broadcast partials
      app.models.each_key do |name|
        singular = Inflector.underscore(name)
        plural = Inflector.pluralize(singular)
        io << "  #{name}.renderPartial = (record) => renderPartial(\"#{plural}/_#{singular}.ejs\", #{singular.inspect}, record);\n"
      end

      io << "  const app = express();\n"
      io << "  app.use(express.urlencoded({ extended: true }));\n"
      io << "  // Request logging (like Rails development mode)\n"
      io << "  app.use((req, _res, next) => {\n"
      io << "    log.info(`\\n  ${req.method} ${req.path}`);\n"
      io << "    if (req.body && Object.keys(req.body).length > 0) log.debug(\"  Parameters:\", req.body);\n"
      io << "    next();\n"
      io << "  });\n"
      io << "  app.use(\"/static\", express.static(path.join(__dirname, \"static\")));\n\n"

      # Routes
      routes_by_path = {} of String => Hash(String, {String, String})
      app.routes.routes.each do |route|
        routes_by_path[route.path] ||= {} of String => {String, String}
        routes_by_path[route.path][route.method.upcase] = {route.controller, route.action}
      end

      routes_by_path.each do |route_path, methods|
        if get = methods["GET"]?
          controller = get[0]
          action = get[1] == "new" ? "newAction" : get[1]
          io << "  app.get(\"#{route_path}\", #{controller}Controller.#{action});\n"
        end

        has_dispatch = methods.has_key?("PATCH") || methods.has_key?("PUT") || methods.has_key?("DELETE")
        if post = methods["POST"]?
          controller = post[0]
          if has_dispatch
            io << "  app.post(\"#{route_path}\", (req, res) => {\n"
            io << "    const data = req.body ?? {};\n"
            io << "    const method = (data._method ?? \"POST\").toString().toUpperCase();\n"
            if del = methods["DELETE"]?
              io << "    if (method === \"DELETE\") return #{del[0]}Controller.destroy(req, res, data);\n"
            end
            if patch = (methods["PATCH"]? || methods["PUT"]?)
              io << "    if (method === \"PATCH\" || method === \"PUT\") return #{patch[0]}Controller.update(req, res, data);\n"
            end
            io << "    #{controller}Controller.#{post[1]}(req, res, data);\n"
            io << "  });\n"
          else
            io << "  app.post(\"#{route_path}\", (req, res) => #{controller}Controller.#{post[1]}(req, res));\n"
          end
        elsif has_dispatch
          io << "  app.post(\"#{route_path}\", (req, res) => {\n"
          io << "    const data = req.body ?? {};\n"
          io << "    const method = (data._method ?? \"POST\").toString().toUpperCase();\n"
          if del = methods["DELETE"]?
            io << "    if (method === \"DELETE\") return #{del[0]}Controller.destroy(req, res, data);\n"
          end
          if patch = (methods["PATCH"]? || methods["PUT"]?)
            io << "    if (method === \"PATCH\" || method === \"PUT\") return #{patch[0]}Controller.update(req, res, data);\n"
          end
          io << "    res.status(404).send(\"Not found\");\n"
          io << "  });\n"
        end
      end

      if root_ctrl = app.routes.root_controller
        root_action = app.routes.root_action || "index"
        io << "  app.get(\"/\", #{root_ctrl}Controller.#{root_action});\n"
      end

      io << "\n  return app;\n"
      io << "}\n\n"

      # Main — start server with WebSocket upgrade
      io << "initDb();\n"
      io << "seedDb();\n"
      io << "const app = createApp();\n"
      io << "const server = createServer(app);\n"
      io << "const wss = new WebSocketServer({ server, path: \"/cable\" });\n\n"

      io << "wss.on(\"connection\", (ws) => {\n"
      io << "  log.debug(\"  ActionCable: client connected\");\n"
      io << "  ws.send(JSON.stringify({ type: \"welcome\" }));\n"
      io << "  const pingInterval = setInterval(() => {\n"
      io << "    if (ws.readyState === WebSocket.OPEN) {\n"
      io << "      ws.send(JSON.stringify({ type: \"ping\", message: Date.now() }));\n"
      io << "    }\n"
      io << "  }, 3000);\n"
      io << "  ws.on(\"message\", (raw) => {\n"
      io << "    const data = JSON.parse(raw.toString());\n"
      io << "    if (data.command === \"subscribe\") {\n"
      io << "      const identifier = data.identifier;\n"
      io << "      const idData = JSON.parse(identifier);\n"
      io << "      const signed = idData.signed_stream_name || \"\";\n"
      io << "      const channel = JSON.parse(Buffer.from(signed.split(\"--\")[0], \"base64\").toString());\n"
      io << "      cable.subscribe(ws, channel, identifier);\n"
      io << "      log.debug(`  ActionCable: subscribed to \"${channel}\"`);\n"
      io << "      ws.send(JSON.stringify({ type: \"confirm_subscription\", identifier }));\n"
      io << "    }\n"
      io << "  });\n"
      io << "  ws.on(\"close\", () => {\n"
      io << "    clearInterval(pingInterval);\n"
      io << "    cable.unsubscribeAll(ws);\n"
      io << "  });\n"
      io << "});\n\n"

      io << "server.listen(3000, () => {\n"
      io << "  console.log(\"Blog running at http://localhost:3000\");\n"
      io << "});\n"

      File.write(File.join(output_dir, "app.ts"), io.to_s)
      puts "  app.ts"
    end

    private def emit_seeds(io : IO, seeds_path : String)
      source = File.read(seeds_path)

      # Idempotency check
      io << "  if (Article.count() > 0) return;\n"

      # Join multi-line statements by tracking paren depth
      joined = [] of String
      current = ""
      depth = 0
      source.lines.each do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.starts_with?("#") || stripped.starts_with?("return") || stripped.starts_with?("puts")
        current += " " unless current.empty?
        current += stripped
        depth += stripped.count('(') - stripped.count(')')
        if depth <= 0
          joined << current
          current = ""
          depth = 0
        end
      end
      joined << current unless current.empty?

      joined.each do |stmt|
        case stmt
        when /^(\w+)\s*=\s*(\w+)\.create!\(\s*(.+)\s*\)$/m
          attrs = $3.gsub(/\s+/, " ").gsub(/(\w+):\s*/, "\\1: ")
          io << "  const #{$1} = #{$2}.create({ #{attrs} });\n"
        when /^(\w+)\.(\w+)\.create!\(\s*(.+)\s*\)$/m
          attrs = $3.gsub(/\s+/, " ").gsub(/(\w+):\s*/, "\\1: ")
          ts_assoc = $2.gsub(/_([a-z])/) { |_, m| m[1].upcase }
          io << "  #{$1}.#{ts_assoc}().create({ #{attrs} });\n"
        end
      end
    end

    # ── Copy static assets ──

    private def copy_static_assets(output_dir : String)
      static_dir = File.join(output_dir, "static")
      Dir.mkdir_p(static_dir)

      tailwind = find_tailwind
      if tailwind
        input_css = File.join(output_dir, "input.css")
        File.write(input_css, "@import \"tailwindcss\";\n")
        err_io = IO::Memory.new
        result = Process.run(tailwind,
          ["--input", "input.css", "--output", "static/app.css", "--minify"],
          chdir: output_dir, output: Process::Redirect::Close, error: err_io)
        if result.success?
          size = File.size(File.join(static_dir, "app.css"))
          puts "  static/app.css (#{size} bytes)"
        else
          puts "  tailwind: build failed"
        end
        File.delete(input_css) if File.exists?(input_css)
      end

      turbo_js = find_turbo_js
      if turbo_js
        File.copy(turbo_js, File.join(static_dir, "turbo.min.js"))
        size = File.size(File.join(static_dir, "turbo.min.js"))
        puts "  static/turbo.min.js (#{size} bytes)"
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
        return output.to_s.strip if result.success? && File.exists?(output.to_s.strip)
      rescue
      end
      nil
    end

    private def find_turbo_js : String?
      begin
        output = IO::Memory.new
        result = Process.run("ruby",
          ["-e", "puts Gem::Specification.find_by_name('turbo-rails').gem_dir + '/app/assets/javascripts/turbo.min.js'"],
          output: output, error: Process::Redirect::Close)
        return output.to_s.strip if result.success? && File.exists?(output.to_s.strip)
      rescue
      end
      nil
    end

    # ── Emit package.json ──

    private def emit_package_json(output_dir : String)
      File.write(File.join(output_dir, "package.json"), <<-JSON)
      {
        "name": "#{app.name}",
        "private": true,
        "type": "module",
        "dependencies": {
          "better-sqlite3": "^11.0.0",
          "ejs": "^3.1.0",
          "express": "^4.21.0",
          "ws": "^8.18.0"
        },
        "devDependencies": {
          "@types/better-sqlite3": "^7.6.0",
          "@types/ejs": "^3.1.0",
          "@types/express": "^5.0.0",
          "@types/ws": "^8.5.0",
          "@types/supertest": "^6.0.0",
          "supertest": "^7.0.0",
          "tsx": "^4.0.0",
          "typescript": "^5.0.0"
        }
      }
      JSON
      puts "  package.json"

      File.write(File.join(output_dir, "tsconfig.json"), <<-JSON)
      {
        "compilerOptions": {
          "target": "ES2022",
          "module": "ES2022",
          "moduleResolution": "bundler",
          "strict": true,
          "esModuleInterop": true,
          "skipLibCheck": true,
          "outDir": "dist"
        },
        "include": ["**/*.ts"],
        "exclude": ["node_modules"]
      }
      JSON
      puts "  tsconfig.json"
    end

    # ── Helpers ──

    private def extract_railcar_nodes(typed_ast : Crystal::ASTNode) : Array(Crystal::ASTNode)
      nodes = [] of Crystal::ASTNode
      case typed_ast
      when Crystal::Expressions
        typed_ast.expressions.each do |expr|
          case expr
          when Crystal::ModuleDef
            if expr.name.names.includes?("Railcar")
              case expr.body
              when Crystal::Expressions
                nodes.concat(expr.body.as(Crystal::Expressions).expressions)
              else
                nodes << expr.body
              end
            end
          end
        end
      end
      nodes
    end
  end
end
