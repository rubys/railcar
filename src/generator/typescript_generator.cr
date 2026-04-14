# TypeScriptGenerator — generates TypeScript from Rails app via Crystal AST.
#
# Pipeline:
#   1. Build Crystal AST: runtime source + model ASTs (via filter chain)
#   2. program.semantic() → types on all nodes
#   3. Extract model nodes, emit TypeScript via Cr2Ts
#
# Currently handles: models only (controllers, views, tests coming later)

require "./app_model"
require "./schema_extractor"
require "./inflector"
require "./source_parser"
require "../semantic"
require "../filters/model_boilerplate_python"
require "../filters/broadcasts_to"
require "../emitter/typescript/cr2ts"
require "./fixture_loader"

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

      # Emit
      emit_runtime(output_dir)
      emit_helpers(output_dir)
      emit_models(typed_ast, output_dir)
      emit_broadcast_callbacks(output_dir)
      emit_views(output_dir)
      emit_controllers(output_dir)
      emit_app(output_dir)
      copy_static_assets(output_dir)
      emit_tests(output_dir)
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

        # Parse Rails model → Crystal AST → filter chain
        # Reuse ModelBoilerplatePython — it produces macro-free Crystal that works
        # for any target language. The key output: TABLE, COLUMNS, property decls,
        # association methods, run_validations, destroy override.
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
        runtime_source.lines.each do |line|
          next if line.strip.starts_with?("require ")
          io << line << "\n"
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

    # ── Emit models ──

    private def emit_models(typed_ast : Crystal::ASTNode, output_dir : String)
      models_dir = File.join(output_dir, "models")
      Dir.mkdir_p(models_dir)

      emitter = Cr2Ts::Emitter.new

      # Extract Railcar module nodes from typed AST
      nodes = extract_railcar_nodes(typed_ast)

      skip = %w[ValidationErrors ApplicationRecord CollectionProxy]
      nodes.each do |node|
        next unless node.is_a?(Crystal::ClassDef)
        class_name = node.name.names.last
        next if skip.includes?(class_name)

        ts_source = emitter.emit_model(node, class_name)

        # Add imports
        imports = String.build do |io|
          io << "import { ApplicationRecord, CollectionProxy, MODEL_REGISTRY } from \"../runtime/base.js\";\n\n"
        end

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
        when Crystal::StringLiteral
          a.value.inspect
        when Crystal::StringInterpolation
          parts = a.expressions.map do |part|
            case part
            when Crystal::StringLiteral then part.value
            when Crystal::Call
              "${record.#{part.name}}"
            else "${#{part}}"
            end
          end
          "`#{parts.join}`"
        else
          a.to_s.inspect
        end
      end

      "#{method}(#{args.join(", ")})"
    end

    # ── Emit helpers ──

    private def emit_helpers(output_dir : String)
      io = IO::Memory.new
      io << "// View and route helpers for railcar-generated TypeScript apps.\n\n"

      # Route helpers from route data model
      io << "// Route helpers\n"
      app.routes.helpers.each do |helper|
        if helper.params.empty?
          io << "export function #{helper.name}Path(): string {\n"
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
          io << "export function #{helper.name}Path(#{param_list}): string {\n"
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
      io << <<-TS
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

      export function parseForm(body: string): Record<string, string[]> {
        const result: Record<string, string[]> = {};
        for (const pair of body.split("&")) {
          const [key, value] = pair.split("=").map(decodeURIComponent);
          if (!result[key]) result[key] = [];
          result[key].push(value ?? "");
        }
        return result;
      }

      export function formValue(data: Record<string, string[]>, key: string): string {
        return data[key]?.[0] ?? "";
      }

      export function extractModelParams(data: Record<string, string[]>, model: string): Record<string, string> {
        const result: Record<string, string> = {};
        const prefix = `${model}[`;
        for (const [key, values] of Object.entries(data)) {
          if (key.startsWith(prefix) && key.endsWith("]")) {
            const field = key.slice(prefix.length, -1);
            result[field] = values[0];
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
      TS

      File.write(File.join(output_dir, "helpers.ts"), io.to_s)
      puts "  helpers.ts"
    end

    # ── Emit views ──

    private def emit_views(output_dir : String)
      views_dir = File.join(output_dir, "views")
      Dir.mkdir_p(views_dir)

      rails_views = File.join(rails_dir, "app/views")

      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        template_dir = File.join(rails_views, Inflector.pluralize(controller_name))
        next unless Dir.exists?(template_dir)

        model_name = Inflector.classify(Inflector.singularize(controller_name))
        singular = Inflector.singularize(controller_name)

        io = IO::Memory.new
        io << "import * as helpers from \"../helpers.js\";\n"

        # Import models
        io << "import { #{model_name} } from \"../models/#{Inflector.underscore(model_name)}.js\";\n"
        app.models.each_key do |name|
          next if name == model_name
          # Check if any template references this model
          has_ref = Dir.glob(File.join(template_dir, "*.html.erb")).any? do |path|
            File.read(path).includes?(name) || File.read(path).includes?(Inflector.underscore(name))
          end
          io << "import { #{name} } from \"../models/#{Inflector.underscore(name)}.js\";\n" if has_ref
        end

        # Import other view modules for cross-references
        app.controllers.each do |other_info|
          other_name = Inflector.underscore(other_info.name).chomp("_controller")
          next if other_name == controller_name
          other_plural = Inflector.pluralize(other_name)
          has_ref = Dir.glob(File.join(template_dir, "*.html.erb")).any? do |path|
            File.read(path).includes?("render_#{Inflector.singularize(other_name)}_partial") ||
            File.read(path).includes?("render #{other_name}") ||
            File.read(path).includes?("render @#{other_plural}") ||
            File.read(path).includes?("render @article.#{other_plural}")
          end
          if has_ref
            io << "import * as #{other_name}Views from \"./#{other_plural}.js\";\n"
          end
        end
        io << "\n"

        # Process each template
        Dir.glob(File.join(template_dir, "*.html.erb")).sort.each do |erb_path|
          basename = File.basename(erb_path, ".html.erb")
          emit_view_function(erb_path, basename, controller_name, singular, model_name, io)
        end

        out_path = File.join(views_dir, "#{Inflector.pluralize(controller_name)}.ts")
        File.write(out_path, io.to_s)
        puts "  views/#{Inflector.pluralize(controller_name)}.ts"
      end
    end

    private def emit_view_function(erb_path : String, basename : String, controller_name : String,
                                    singular : String, model_name : String, io : IO)
      erb_source = File.read(erb_path)
      is_partial = basename.starts_with?("_")
      func_name = is_partial ? "render#{Inflector.classify(basename.lstrip('_'))}Partial" : "render#{Inflector.classify(basename)}"

      if is_partial
        io << "export function #{func_name}(...args: unknown[]): string {\n"
        io << "  const #{singular} = args[args.length - 1] as any;\n"
      else
        param_name = basename == "index" ? Inflector.pluralize(singular) : singular
        io << "export function #{func_name}(#{param_name}: any, notice?: string | null): string {\n"
      end

      io << "  let _buf = \"\";\n"

      # Convert ERB to template literal string building
      convert_erb_to_ts(erb_source, io, singular, model_name, controller_name)

      io << "  return _buf;\n"
      io << "}\n\n"
    end

    private def convert_erb_to_ts(source : String, io : IO, singular : String, model_name : String, controller_name : String)
      plural = Inflector.pluralize(singular)
      pos = 0
      while pos < source.size
        tag_start = source.index("<%", pos)
        if tag_start.nil?
          emit_text_chunk(source[pos..], io)
          break
        end

        emit_text_chunk(source[pos...tag_start], io) if tag_start > pos

        tag_end = source.index("%>", tag_start)
        break unless tag_end

        raw = source[(tag_start + 2)...tag_end]
        stripped = raw.strip

        if stripped.starts_with?('#')
          # Comment — skip
        elsif stripped.starts_with?('=')
          expr = stripped[1..].strip
          emit_ts_expression(expr, io, singular, model_name, controller_name)
        else
          emit_ts_code(stripped, io, singular, model_name, controller_name)
        end

        pos = tag_end + 2
      end
    end

    private def emit_text_chunk(text : String, io : IO)
      return if text.empty?
      # Escape backticks and ${} in template literals
      escaped = text.gsub("\\", "\\\\\\\\").gsub("`", "\\`").gsub("${", "\\${")
      io << "  _buf += `#{escaped}`;\n" unless escaped.strip.empty? && !escaped.includes?("\n")
    end

    private def emit_ts_expression(expr : String, io : IO, singular : String, model_name : String, controller_name : String)
      plural = Inflector.pluralize(singular)

      # Skip Rails asset helpers
      return if expr == "csrf_meta_tags" || expr == "csp_meta_tag"
      return if expr.starts_with?("stylesheet_link_tag") || expr == "javascript_importmap_tags"
      return if expr.starts_with?("yield :head")

      case expr
      when /^turbo_stream_from\s+"([^"]+)"/
        io << "  _buf += helpers.turboStreamFrom(#{$1.inspect});\n"
      when /^turbo_stream_from\s+"([^"]*)\#\{(@?\w+)\.(\w+)\}([^"]*)"/
        var = $2.lstrip('@')
        io << "  _buf += helpers.turboStreamFrom(`#{$1}\\${#{var}.#{$3}}#{$4}`);\n"
      when /^link_to\s+"([^"]+)",\s*(\w+_path(?:\([^)]*\))?)/
        path = convert_path_helper($2)
        rest = expr.match(/,\s*class:\s*"([^"]+)"/)
        cls = rest ? ", { class: #{rest[1].inspect} }" : ""
        io << "  _buf += helpers.linkTo(#{$1.inspect}, #{path}#{cls});\n"
      when /^link_to\s+(\w+)\.(\w+),\s*(\w+)/
        io << "  _buf += helpers.linkTo(#{$1}.#{$2}, helpers.#{convert_path_helper($3)});\n"
      when /^button_to\s+/
        emit_button_to(expr, io, singular)
      when /^form_with/
        emit_form_with(expr, io, singular)
      when /^form\.label\s+:(\w+)/
        field = $1
        rest = expr.match(/class:\s*"([^"]+)"/)
        cls = rest ? " class=\\\"#{rest[1]}\\\"" : ""
        io << "  _buf += `<label for=\\\"#{singular}_#{field}\\\"#{cls}>#{field.capitalize}</label>`;\n"
      when /^form\.text_field\s+:(\w+)/
        field = $1
        rest = expr.match(/class:\s*"([^"]+)"/)
        cls = rest ? " class=\\\"#{rest[1]}\\\"" : ""
        io << "  _buf += `<input type=\\\"text\\\" name=\\\"#{singular}[#{field}]\\\" id=\\\"#{singular}_#{field}\\\" value=\\\"\\${#{singular}.#{field}}\\\"#{cls}>`;\n"
      when /^form\.text_area\s+:(\w+)/
        field = $1
        rows_match = expr.match(/rows:\s*(\d+)/)
        rows = rows_match ? " rows=\\\"#{rows_match[1]}\\\"" : ""
        rest = expr.match(/class:\s*"([^"]+)"/)
        cls = rest ? " class=\\\"#{rest[1]}\\\"" : ""
        io << "  _buf += `<textarea name=\\\"#{singular}[#{field}]\\\" id=\\\"#{singular}_#{field}\\\"#{rows}#{cls}>\\n\\${#{singular}.#{field}}</textarea>`;\n"
      when /^form\.submit\s+"([^"]+)"/
        rest = expr.match(/class:\s*"([^"]+)"/)
        cls = rest ? " class=\\\"#{rest[1]}\\\"" : ""
        io << "  _buf += `<button type=\\\"submit\\\"#{cls}>#{$1}</button>`;\n"
      when /^form\.submit$/
        io << "  _buf += helpers.formSubmitTag(#{singular}, {});\n"
      when /^render\s+@?(\w+)\.(\w+)/
        # render @article.comments → loop with partial
        var = $1
        assoc = $2
        partial_singular = Inflector.singularize(assoc)
        partial_func = "render#{Inflector.classify(partial_singular)}Partial"
        # Check if partial is in another view module
        other_controller = Inflector.pluralize(partial_singular)
        if other_controller != Inflector.pluralize(singular)
          io << "  for (const #{partial_singular} of (#{var} as any).#{assoc}()) {\n"
          io << "    _buf += #{other_controller}Views.#{partial_func}(#{var}, #{partial_singular});\n"
          io << "  }\n"
        else
          io << "  for (const #{partial_singular} of #{var}) {\n"
          io << "    _buf += #{partial_func}(#{partial_singular});\n"
          io << "  }\n"
        end
      when /^render\s+@(\w+)/
        # render @articles → loop with partial
        var = $1
        partial_singular = Inflector.singularize(var)
        partial_func = "render#{Inflector.classify(partial_singular)}Partial"
        io << "  for (const #{partial_singular} of #{var}) {\n"
        io << "    _buf += #{partial_func}(#{partial_singular});\n"
        io << "  }\n"
      when /^render\s+"([^"]+)"/
        # render "form" → render_form_partial
        partial_func = "render#{Inflector.classify($1)}Partial"
        io << "  _buf += #{partial_func}(#{singular});\n"
      when /^pluralize\((.+)\)$/
        io << "  _buf += helpers.pluralize(#{convert_ruby_expr($1, singular)});\n"
      when /^truncate\((.+)\)$/
        io << "  _buf += helpers.truncate(#{convert_ruby_expr($1, singular)});\n"
      when /^dom_id\((.+)\)$/
        io << "  _buf += helpers.domId(#{convert_ruby_expr($1, singular)});\n"
      when /^content_for\s+:title,\s*"([^"]+)"/
        io << "  const title = #{$1.inspect};\n"
      when /^notice$/
        io << "  _buf += String(notice ?? \"\");\n"
      when /^error\.full_message/
        io << "  _buf += String(error.fullMessage());\n"
      else
        # Generic expression — try to convert
        converted = convert_ruby_expr(expr, singular)
        io << "  _buf += String(#{converted});\n"
      end
    end

    private def emit_ts_code(code : String, io : IO, singular : String, model_name : String, controller_name : String)
      plural = Inflector.pluralize(singular)
      case code
      when /^if\s+notice(\.present\?)?$/
        io << "  if (notice) {\n"
      when /^if\s+@?(\w+)\.any\?$/
        io << "  if (#{$1}.length > 0) {\n"
      when /^if\s+@?(\w+)\.errors(\.any\?)?$/
        io << "  if (#{$1}.errors.any()) {\n"
      when /^if\s+@?(\w+)/
        io << "  if (#{$1}) {\n"
      when /^else$/
        io << "  } else {\n"
      when /^end$/
        io << "  }\n"
      when /^(\w+)\.errors\.each\s+do\s+\|(\w+)\|$/
        io << "  for (const #{$2} of #{$1}.errors) {\n"
      when /^@?(\w+)\.(\w+)\.each\s+do\s+\|(\w+)\|$/
        io << "  for (const #{$3} of (#{$1} as any).#{$2}()) {\n"
      when /^@?(\w+)\.each\s+do\s+\|(\w+)\|$/
        io << "  for (const #{$2} of #{$1}) {\n"
      when /^content_for\s+:title,\s*"([^"]+)"/
        io << "  const title = #{$1.inspect};\n"
      when /^content_for/
        # skip other content_for
      else
        io << "  // TODO: #{code}\n"
      end
    end

    private def emit_button_to(expr : String, io : IO, singular : String)
      # Parse button_to arguments
      if expr =~ /button_to\s+"([^"]+)",\s*(.+)/
        text = $1
        rest = $2
        # Extract path
        path = if rest =~ /^(\[.+?\])/
                 convert_array_path($1, singular)
               elsif rest =~ /^(@?\w+(?:_path)?(?:\([^)]*\))?)/
                 convert_path_helper($1)
               else
                 "\"#\""
               end
        # Extract options
        method = rest.match(/method:\s*:(\w+)/)
        cls = rest.match(/class:\s*"([^"]+)"/)
        form_class = rest.match(/form_class:\s*"([^"]+)"/)
        confirm = rest.match(/turbo_confirm:\s*"([^"]+)"/)

        opts = [] of String
        opts << "method: #{method[1].inspect}" if method
        opts << "class: #{cls[1].inspect}" if cls
        opts << "form_class: #{form_class[1].inspect}" if form_class
        if confirm
          opts << "data: { turbo_confirm: #{confirm[1].inspect} }"
        end
        io << "  _buf += helpers.buttonTo(#{text.inspect}, #{path}, { #{opts.join(", ")} });\n"
      end
    end

    private def emit_form_with(expr : String, io : IO, singular : String)
      # form_with model: [@article, Comment.new] or form_with model: @article
      cls_match = expr.match(/class:\s*"([^"]+)"/)
      cls = cls_match ? " class=\\\"#{cls_match[1]}\\\"" : ""

      if expr.includes?("[@") || expr.includes?("[#{singular}")
        # Nested form: form_with model: [@article, Comment.new]
        io << "  _buf += helpers.formWithOpenTag(#{singular}, { #{cls_match ? "class: #{cls_match[1].inspect}" : ""} });\n"
      else
        io << "  _buf += helpers.formWithOpenTag(#{singular}#{cls_match ? ", { class: #{cls_match[1].inspect} }" : ""});\n"
      end
    end

    private def convert_path_helper(expr : String) : String
      # articles_path → helpers.articlesPath()
      # article_path(@article) → helpers.articlePath(article)
      if expr =~ /^(\w+)_path\(([^)]*)\)$/
        name = $1
        args = $2.gsub("@", "")
        ts_name = name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
        "helpers.#{ts_name}Path(#{args})"
      elsif expr =~ /^(\w+)_path$/
        name = $1
        ts_name = name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
        "helpers.#{ts_name}Path()"
      else
        expr
      end
    end

    private def convert_array_path(expr : String, singular : String) : String
      # [comment.article, comment] → helpers.articleCommentPath(comment.article(), comment)
      if expr =~ /\[(\w+)\.(\w+),\s*(\w+)\]/
        parent_method = $2
        child = $3
        ts_name = "#{parent_method}#{Inflector.classify(child)}"
        "helpers.#{ts_name}Path(#{$1}.#{parent_method}(), #{child})"
      else
        "\"#\""
      end
    end

    private def convert_ruby_expr(expr : String, singular : String) : String
      result = expr
        .gsub("@", "")
        .gsub(/(\w+)\.size/, "\\1.length")
        .gsub(/(\w+)\.count/, "\\1.length")
        .gsub(".comments.size", ".comments().size()")
        .gsub(".comments", ".comments()")
        .gsub("_path(", "Path(")
        .gsub("_path", "Path()")
      # Prefix path helpers with helpers.
      result = result.gsub(/\b(\w+Path\()/, "helpers.\\1")
      result
    end

    # ── Emit controllers ──

    private def emit_controllers(output_dir : String)
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

        io = IO::Memory.new
        io << "import type { Request, Response } from \"express\";\n"
        io << "import { #{model_name} } from \"../models/#{Inflector.underscore(model_name)}.js\";\n"
        if nested_parent
          parent_model = Inflector.classify(nested_parent)
          io << "import { #{parent_model} } from \"../models/#{nested_parent}.js\";\n"
        end
        io << "import * as helpers from \"../helpers.js\";\n"
        io << "import * as views from \"../views/#{plural}.js\";\n"
        io << "\n"

        # Generate controller actions
        info.actions.each do |action|
          next if action.is_private
          emit_controller_action(action.name, controller_name, model_name, singular, nested_parent, io)
        end

        out_path = File.join(controllers_dir, "#{controller_name}.ts")
        File.write(out_path, io.to_s)
        puts "  controllers/#{controller_name}.ts"
      end
    end

    private def emit_controller_action(action_name : String, controller_name : String,
                                        model_name : String, singular : String,
                                        nested_parent : String?, io : IO)
      plural = Inflector.pluralize(singular)

      case action_name
      when "index"
        io << "export function index(req: Request, res: Response): void {\n"
        io << "  const #{plural} = #{model_name}.all(\"created_at DESC\");\n"
        io << "  res.send(helpers.layout(views.renderIndex(#{plural})));\n"
        io << "}\n\n"
      when "show"
        io << "export function show(req: Request, res: Response): void {\n"
        if nested_parent
          io << "  const #{nested_parent} = #{Inflector.classify(nested_parent)}.find(Number(req.params.#{nested_parent}_id));\n"
        end
        io << "  const #{singular} = #{model_name}.find(Number(req.params.id));\n"
        io << "  res.send(helpers.layout(views.renderShow(#{singular})));\n"
        io << "}\n\n"
      when "new"
        io << "export function newAction(req: Request, res: Response): void {\n"
        io << "  const #{singular} = new #{model_name}();\n"
        io << "  res.send(helpers.layout(views.renderNew(#{singular})));\n"
        io << "}\n\n"
      when "edit"
        io << "export function edit(req: Request, res: Response): void {\n"
        io << "  const #{singular} = #{model_name}.find(Number(req.params.id));\n"
        io << "  res.send(helpers.layout(views.renderEdit(#{singular})));\n"
        io << "}\n\n"
      when "create"
        if nested_parent
          parent_model = Inflector.classify(nested_parent)
          io << "export function create(req: Request, res: Response, data?: Record<string, string[]>): void {\n"
          io << "  if (!data) data = helpers.parseForm(req.body);\n"
          io << "  const #{nested_parent} = #{parent_model}.find(Number(req.params.#{nested_parent}_id));\n"
          io << "  const #{singular} = (#{nested_parent} as any).#{plural}().build(helpers.extractModelParams(data, #{singular.inspect}));\n"
          io << "  if (#{singular}.save()) {\n"
          io << "    res.redirect(helpers.#{Inflector.underscore(nested_parent).gsub(/_([a-z])/) { |_, m| m[1].upcase }}Path(#{nested_parent}));\n"
          io << "  } else {\n"
          io << "    res.redirect(helpers.#{Inflector.underscore(nested_parent).gsub(/_([a-z])/) { |_, m| m[1].upcase }}Path(#{nested_parent}));\n"
          io << "  }\n"
          io << "}\n\n"
        else
          io << "export function create(req: Request, res: Response, data?: Record<string, string[]>): void {\n"
          io << "  if (!data) data = helpers.parseForm(req.body);\n"
          io << "  const #{singular} = new #{model_name}(helpers.extractModelParams(data, #{singular.inspect}));\n"
          io << "  if (#{singular}.save()) {\n"
          io << "    res.redirect(helpers.#{singular.gsub(/_([a-z])/) { |_, m| m[1].upcase }}Path(#{singular}));\n"
          io << "  } else {\n"
          io << "    res.status(422).send(helpers.layout(views.renderNew(#{singular})));\n"
          io << "  }\n"
          io << "}\n\n"
        end
      when "update"
        io << "export function update(req: Request, res: Response, data?: Record<string, string[]>): void {\n"
        io << "  if (!data) data = helpers.parseForm(req.body);\n"
        io << "  const #{singular} = #{model_name}.find(Number(req.params.id));\n"
        io << "  if (#{singular}.update(helpers.extractModelParams(data, #{singular.inspect}))) {\n"
        io << "    res.redirect(helpers.#{singular.gsub(/_([a-z])/) { |_, m| m[1].upcase }}Path(#{singular}));\n"
        io << "  } else {\n"
        io << "    res.status(422).send(helpers.layout(views.renderEdit(#{singular})));\n"
        io << "  }\n"
        io << "}\n\n"
      when "destroy"
        if nested_parent
          parent_model = Inflector.classify(nested_parent)
          io << "export function destroy(req: Request, res: Response, data?: Record<string, string[]>): void {\n"
          io << "  if (!data) data = helpers.parseForm(req.body);\n"
          io << "  const #{nested_parent} = #{parent_model}.find(Number(req.params.#{nested_parent}_id));\n"
          io << "  const #{singular} = (#{nested_parent} as any).#{plural}().find(Number(req.params.id));\n"
          io << "  #{singular}.destroy();\n"
          io << "  res.redirect(helpers.#{Inflector.underscore(nested_parent).gsub(/_([a-z])/) { |_, m| m[1].upcase }}Path(#{nested_parent}));\n"
          io << "}\n\n"
        else
          io << "export function destroy(req: Request, res: Response, data?: Record<string, string[]>): void {\n"
          io << "  if (!data) data = helpers.parseForm(req.body);\n"
          io << "  const #{singular} = #{model_name}.find(Number(req.params.id));\n"
          io << "  #{singular}.destroy();\n"
          io << "  res.redirect(helpers.#{plural.gsub(/_([a-z])/) { |_, m| m[1].upcase }}Path());\n"
          io << "}\n\n"
        end
      end
    end

    # ── Emit app entry point ──

    private def emit_app(output_dir : String)
      io = IO::Memory.new
      io << "import express from \"express\";\n"
      io << "import Database from \"better-sqlite3\";\n"
      io << "import path from \"path\";\n"
      io << "import { fileURLToPath } from \"url\";\n"
      io << "import { ApplicationRecord } from \"./runtime/base.js\";\n"
      io << "import * as helpers from \"./helpers.js\";\n"

      # Controller imports
      controller_names = [] of String
      app.controllers.each do |info|
        name = Inflector.underscore(info.name).chomp("_controller")
        controller_names << name
        io << "import * as #{name}Controller from \"./controllers/#{name}.js\";\n"
      end

      # Model imports for seeding and broadcast partials
      app.models.each_key do |name|
        io << "import { #{name} } from \"./models/#{Inflector.underscore(name)}.js\";\n"
      end
      io << "\n"

      io << "const __dirname = path.dirname(fileURLToPath(import.meta.url));\n\n"

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

      # Seed data
      seeds_path = File.join(rails_dir, "db/seeds.rb")
      io << "function seedDb(): void {\n"
      if File.exists?(seeds_path)
        emit_seeds(io, seeds_path)
      end
      io << "}\n\n"

      # Wire broadcast partials
      app.models.each_key do |name|
        singular = Inflector.underscore(name)
        plural = Inflector.pluralize(singular)
        io << "import { render#{Inflector.classify(singular)}Partial } from \"./views/#{plural}.js\";\n"
      end
      io << "\n"

      # Create app
      io << "function createApp(): express.Application {\n"
      app.models.each_key do |name|
        singular = Inflector.underscore(name)
        io << "  #{name}.renderPartial = render#{Inflector.classify(singular)}Partial;\n"
      end
      io << "  const app = express();\n"
      io << "  app.use(express.urlencoded({ extended: true }));\n"
      io << "  app.use(\"/static\", express.static(path.join(__dirname, \"static\")));\n\n"

      # Routes — using route data
      routes_by_path = {} of String => Hash(String, {String, String})
      app.routes.routes.each do |route|
        controller = Inflector.singularize(route.controller)
        path = route.path.gsub(/:(\w+)/, ":$1")  # Already Express format
        routes_by_path[path] ||= {} of String => {String, String}
        routes_by_path[path][route.method.upcase] = {route.controller, route.action}
      end

      routes_by_path.each do |route_path, methods|
        express_path = route_path.gsub(/:(\w+)/, ":$1")

        if get = methods["GET"]?
          controller = Inflector.singularize(get[0])
          action = get[1] == "new" ? "newAction" : get[1]
          io << "  app.get(\"#{express_path}\", #{controller}Controller.#{action});\n"
        end

        has_dispatch = methods.has_key?("PATCH") || methods.has_key?("PUT") || methods.has_key?("DELETE")
        if post = methods["POST"]?
          controller = Inflector.singularize(post[0])
          if has_dispatch
            # POST with _method dispatch
            io << "  app.post(\"#{express_path}\", (req, res) => {\n"
            io << "    const data = helpers.parseForm(req.body?.toString() ?? \"\");\n"
            io << "    const method = (data._method?.[0] ?? \"POST\").toUpperCase();\n"
            if del = methods["DELETE"]?
              del_ctrl = Inflector.singularize(del[0])
              io << "    if (method === \"DELETE\") return #{del_ctrl}Controller.destroy(req, res, data);\n"
            end
            if patch = (methods["PATCH"]? || methods["PUT"]?)
              patch_ctrl = Inflector.singularize(patch[0])
              io << "    if (method === \"PATCH\" || method === \"PUT\") return #{patch_ctrl}Controller.update(req, res, data);\n"
            end
            io << "    #{controller}Controller.#{post[1]}(req, res, data);\n"
            io << "  });\n"
          else
            io << "  app.post(\"#{express_path}\", #{controller}Controller.#{post[1]});\n"
          end
        elsif has_dispatch
          # Only PATCH/DELETE, no POST
          io << "  app.post(\"#{express_path}\", (req, res) => {\n"
          io << "    const data = helpers.parseForm(req.body?.toString() ?? \"\");\n"
          io << "    const method = (data._method?.[0] ?? \"POST\").toUpperCase();\n"
          if del = methods["DELETE"]?
            del_ctrl = Inflector.singularize(del[0])
            io << "    if (method === \"DELETE\") return #{del_ctrl}Controller.destroy(req, res, data);\n"
          end
          if patch = (methods["PATCH"]? || methods["PUT"]?)
            patch_ctrl = Inflector.singularize(patch[0])
            io << "    if (method === \"PATCH\" || method === \"PUT\") return #{patch_ctrl}Controller.update(req, res, data);\n"
          end
          io << "    res.status(404).send(\"Not found\");\n"
          io << "  });\n"
        end
      end

      # Root route
      if root_ctrl = app.routes.root_controller
        root_action = app.routes.root_action || "index"
        ctrl = Inflector.singularize(root_ctrl)
        io << "  app.get(\"/\", #{ctrl}Controller.#{root_action});\n"
      end

      io << "\n  return app;\n"
      io << "}\n\n"

      # Main
      io << "initDb();\n"
      io << "seedDb();\n"
      io << "const app = createApp();\n"
      io << "app.listen(3000, () => {\n"
      io << "  console.log(\"Blog running at http://localhost:3000\");\n"
      io << "});\n"

      File.write(File.join(output_dir, "app.ts"), io.to_s)
      puts "  app.ts"
    end

    private def emit_seeds(io : IO, seeds_path : String)
      source = File.read(seeds_path)
      source.lines.each do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.starts_with?("#") || stripped.starts_with?("return") || stripped.starts_with?("puts")

        case stripped
        when /^(\w+)\s*=\s*(\w+)\.create!\((.+)\)$/
          attrs = convert_ruby_hash($3)
          io << "  const #{$1} = #{$2}.create({ #{attrs} });\n"
        when /^(\w+)\.(\w+)\.create!\((.+)\)$/
          attrs = convert_ruby_hash($3)
          ts_assoc = $2.gsub(/_([a-z])/) { |_, m| m[1].upcase }
          io << "  (#{$1} as any).#{ts_assoc}().create({ #{attrs} });\n"
        else
          # skip unrecognized lines
        end
      end
    end

    # ── Copy static assets ──

    private def copy_static_assets(output_dir : String)
      static_dir = File.join(output_dir, "static")
      Dir.mkdir_p(static_dir)

      # Tailwind CSS
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

      # Turbo JS
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
        if result.success?
          bin = output.to_s.strip
          return bin if File.exists?(bin)
        end
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
        if result.success?
          path = output.to_s.strip
          return path if File.exists?(path)
        end
      rescue
      end
      nil
    end

    # ── Emit tests ──

    private def emit_tests(output_dir : String)
      tests_dir = File.join(output_dir, "tests")
      Dir.mkdir_p(tests_dir)

      emit_test_setup(tests_dir)
      emit_model_tests(tests_dir)
    end

    private def emit_test_setup(tests_dir : String)
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      io = IO::Memory.new
      io << "import Database from \"better-sqlite3\";\n"
      io << "import { ApplicationRecord } from \"../runtime/base.js\";\n"

      # Import all models
      app.models.each_key do |name|
        io << "import { #{name} } from \"../models/#{Inflector.underscore(name)}.js\";\n"
      end
      io << "\n"

      # Setup function: create in-memory DB + tables
      io << "export function setupDb(): Database.Database {\n"
      io << "  const db = new Database(\":memory:\");\n"
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
        io << "  db.exec(`CREATE TABLE #{schema.name} (\n"
        io << "    #{col_defs.join(",\n    ")}\n"
        io << "  )`);\n"
      end

      io << "  ApplicationRecord.db = db;\n"
      io << "  return db;\n"
      io << "}\n\n"

      # Fixture creation
      sorted_fixtures = FixtureLoader.sort_by_dependency(app.fixtures, app.models)

      io << "export function setupFixtures(): void {\n"
      sorted_fixtures.each do |table|
        singular = Inflector.singularize(table.name)
        model_name = Inflector.classify(singular)
        next unless app.models.has_key?(model_name)

        table.records.each do |record|
          # Resolve fixture references (e.g., article: one → article_id: articles_one.id)
          attrs = [] of String
          record.fields.each do |field, value|
            # Check if this field is a fixture reference
            model_info = app.models[model_name]?
            assoc = model_info.try(&.associations.find { |a| a.name == field })
            if assoc && assoc.kind == :belongs_to
              # Reference to another fixture: article: one → article_id: articles_one.id
              ref_table = Inflector.pluralize(field)
              attrs << "#{field}_id: #{ref_table}_#{value}.id!"
            else
              # Regular value
              if value.match(/^\d+$/)
                attrs << "#{field}: #{value}"
              else
                attrs << "#{field}: #{value.inspect}"
              end
            end
          end
          var_name = "#{table.name}_#{record.label}"
          io << "  #{var_name} = #{model_name}.create({ #{attrs.join(", ")} });\n"
        end
      end
      io << "}\n\n"

      # Export fixture variables
      sorted_fixtures.each do |table|
        table.records.each do |record|
          var_name = "#{table.name}_#{record.label}"
          io << "export let #{var_name}: ApplicationRecord;\n"
        end
      end
      io << "\n"

      # Fixture accessor functions (like Python's articles("one"))
      app.models.each_key do |name|
        table_name = Inflector.pluralize(Inflector.underscore(name))
        fixture_table = app.fixtures.find { |t| t.name == table_name }
        next unless fixture_table

        io << "export function #{table_name}(name: string): ApplicationRecord {\n"
        fixture_table.records.each_with_index do |record, i|
          keyword = i == 0 ? "if" : "} else if"
          io << "  #{keyword} (name === #{record.label.inspect}) {\n"
          io << "    return #{name}.find(#{table_name}_#{record.label}.id!);\n"
        end
        io << "  }\n"
        io << "  throw new Error(`Unknown fixture: ${name}`);\n"
        io << "}\n\n"
      end

      File.write(File.join(tests_dir, "setup.ts"), io.to_s)
      puts "  tests/setup.ts"
    end

    private def emit_model_tests(tests_dir : String)
      test_dir = File.join(rails_dir, "test/models")
      return unless Dir.exists?(test_dir)

      Dir.glob(File.join(test_dir, "*_test.rb")).sort.each do |path|
        basename = File.basename(path, "_test.rb")
        model_name = Inflector.classify(basename)

        ts_source = convert_model_test(path, model_name, basename)
        next if ts_source.empty?

        out_path = File.join(tests_dir, "#{basename}.test.ts")
        File.write(out_path, ts_source)
        puts "  tests/#{basename}.test.ts"
      end
    end

    private def convert_model_test(path : String, model_name : String, basename : String) : String
      source = File.read(path)
      table_name = Inflector.pluralize(basename)

      io = IO::Memory.new
      io << "import { describe, it, beforeEach, afterEach } from \"node:test\";\n"
      io << "import assert from \"node:assert/strict\";\n"
      # Detect all fixture accessor functions referenced in the test
      fixture_funcs = Set(String).new
      fixture_funcs << table_name  # always include own fixtures
      app.fixtures.each do |ft|
        if source.includes?("#{ft.name}(:")
          fixture_funcs << ft.name
        end
      end
      io << "import { setupDb, setupFixtures, #{fixture_funcs.join(", ")} } from \"./setup.js\";\n"

      # Import models used in this test
      io << "import { #{model_name} } from \"../models/#{basename}.js\";\n"
      # Also import related models if referenced
      app.models.each_key do |name|
        next if name == model_name
        if source.includes?(name)
          io << "import { #{name} } from \"../models/#{Inflector.underscore(name)}.js\";\n"
        end
      end
      io << "import type Database from \"better-sqlite3\";\n"
      io << "\n"

      io << "let db: Database.Database;\n\n"
      io << "beforeEach(() => {\n"
      io << "  db = setupDb();\n"
      io << "  setupFixtures();\n"
      io << "});\n\n"
      io << "afterEach(() => {\n"
      io << "  db.close();\n"
      io << "});\n\n"

      # Parse test blocks from Ruby source
      io << "describe(\"#{model_name}\", () => {\n"

      # Extract test blocks using simple regex
      source.scan(/test\s+"([^"]+)"\s+do\n(.*?)end/m).each do |match|
        test_name = match[1]
        test_body = match[2]
        ts_body = convert_test_body(test_body, model_name, basename)
        io << "  it(#{test_name.inspect}, () => {\n"
        io << ts_body
        io << "  });\n\n"
      end

      io << "});\n"
      io.to_s
    end

    private def convert_test_body(body : String, model_name : String, basename : String) : String
      table_name = Inflector.pluralize(basename)
      lines = body.strip.lines
      io = IO::Memory.new

      lines.each do |line|
        stripped = line.strip
        next if stripped.empty?

        case stripped
        when /^(\w+)\s*=\s*(\w+)\(:(\w+)\)$/
          # article = articles(:one) → fixture accessor
          var = $1
          func = $2
          label = $3
          io << "    const #{var} = #{func}(#{label.inspect});\n"

        when /^assert_not_nil\s+(\w+)\.(\w+)$/
          io << "    assert.notStrictEqual(#{$1}.#{$2}, null);\n"

        when /^assert_equal\s+"([^"]+)",\s*(\w+)\.(\w+)$/
          io << "    assert.strictEqual((#{$2} as any).#{$3}, #{$1.inspect});\n"

        when /^assert_equal\s+(\w+)\(:(\w+)\)\.(\w+),\s*(\w+)\.(\w+)$/
          # assert_equal articles(:one).id, comment.article_id
          io << "    assert.strictEqual((#{$4} as any).#{$5}, #{$1}(#{$2.inspect}).#{$3});\n"

        when /^(\w+)\s*=\s*(\w+)\.new\((.+)\)$/
          # article = Article.new(title: "", body: "...")
          attrs = convert_ruby_hash($3)
          io << "    const #{$1} = new #{$2}({ #{attrs} });\n"

        when /^assert_not\s+(\w+)\.(\w+)$/
          ts_method = ts_method_name($2)
          io << "    assert.strictEqual(#{$1}.#{ts_method}(), false);\n"

        when /^assert_equal\s+(\w+)\.(\w+),\s*(\w+)\.(\w+)$/
          # assert_equal article.id, comment.article_id
          io << "    assert.strictEqual((#{$3} as any).#{$4}, (#{$1} as any).#{$2});\n"

        when /^(\w+)\s*=\s*(\w+)\.(\w+)\.create\((.+)\)$/
          # comment = article.comments.create(...)
          attrs = convert_ruby_hash($4)
          ts_assoc = ts_method_name($3)
          io << "    const #{$1} = (#{$2} as any).#{ts_assoc}().create({ #{attrs} });\n"

        when /^(\w+)\s*=\s*(\w+)\.(\w+)\.build\((.+)\)$/
          attrs = convert_ruby_hash($4)
          ts_assoc = ts_method_name($3)
          io << "    const #{$1} = (#{$2} as any).#{ts_assoc}().build({ #{attrs} });\n"

        when /^assert_difference\("(\w+)\.count",\s*(-?\d+)\)\s+do$/
          model = $1
          diff = $2
          io << "    const _before = #{model}.count();\n"

        when /^(\w+)\.destroy$/
          io << "    #{$1}.destroy();\n"

        when /^end$/
          # Check if we're closing an assert_difference block
          if io.to_s.includes?("_before = ")
            # Find the last assert_difference to get the expected diff and model
            # We already emitted _before, just need the assertion
          end

        else
          io << "    // TODO: #{stripped}\n"
        end
      end

      # Handle assert_difference pattern: check if _before was set
      result = io.to_s
      if result.includes?("_before = ")
        # Find the model from the _before line
        if result =~ /const _before = (\w+)\.count\(\);/
          model = $1
          # Add assertion after the last line before closing
          result = result.rstrip
          result += "\n    assert.strictEqual(#{model}.count() - _before, "
          # Find the diff value - scan the original body
          if body =~ /assert_difference\("\w+\.count",\s*(-?\d+)\)/
            result += "#{$1}"
          else
            result += "-1"
          end
          result += ");\n"
        end
      end

      result
    end

    private def convert_ruby_hash(ruby : String) : String
      # Convert "title: \"foo\", body: \"bar\"" → "title: \"foo\", body: \"bar\""
      # Convert "commenter: \"Alice\"" → "commenter: \"Alice\""
      # Already mostly valid TS/JS syntax, just need to handle symbol keys
      ruby.gsub(/(\w+):\s*/, "\\1: ").gsub(/article_id:\s*(\d+)/, "article_id: \\1")
    end

    private def ts_method_name(name : String) : String
      case name
      when "save" then "save"
      when "destroy" then "destroy"
      when "comments" then "comments"
      when "valid?" then "valid"
      else name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
      end
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
          "express": "^4.21.0"
        },
        "devDependencies": {
          "@types/better-sqlite3": "^7.6.0",
          "@types/express": "^5.0.0",
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
