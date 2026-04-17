# RustGenerator — orchestrates Rust generation from Rails app via Crystal AST.
#
# Pipeline:
#   1. Build Crystal AST: runtime source + model ASTs (via filter chain)
#   2. Emit models via Cr2Rs emitter
#
# Target: axum + rusqlite + tokio.

require "./app_model"
require "./schema_extractor"
require "./inflector"
require "./source_parser"
require "./fixture_loader"
require "../semantic"
require "../filters/model_boilerplate_python"
require "../filters/broadcasts_to"
require "../filters/instance_var_to_local"
require "../filters/rails_helpers"
require "../filters/link_to_path_helper"
require "../filters/button_to_path_helper"
require "../filters/render_to_partial"
require "../filters/form_to_html"
require "../filters/turbo_stream_connect"
require "../filters/view_cleanup"
require "../emitter/rust/cr2rs"
require "../filters/method_map"
require "./go_view_emitter"
require "./rust_view_emitter"
require "./type_resolver"
require "./view_semantic_analyzer"
require "./erb_compiler"
require "ast-builder"

module Railcar
  class RustGenerator
    include CrystalAST::Builder

    getter app : AppModel
    getter rails_dir : String
    getter broadcast_asts : Hash(String, Crystal::ASTNode) = {} of String => Crystal::ASTNode

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      puts "Generating Rust from #{rails_dir}..."
      Dir.mkdir_p(output_dir)

      app_name = app.name.downcase.gsub("-", "_")

      model_asts = build_model_asts

      emit_cargo_toml(output_dir, app_name)
      emit_runtime(output_dir)
      emit_models(output_dir, app_name, model_asts)
      emit_helpers(output_dir, app_name)
      emit_views(output_dir, app_name)
      emit_controllers(output_dir, app_name)
      emit_main(output_dir, app_name)
      copy_static_assets(output_dir)
      emit_model_tests(output_dir, app_name)
      emit_controller_tests(output_dir, app_name)

      puts "Done! Output in #{output_dir}/"
      puts "  cd #{output_dir} && cargo test"
    end

    # ── Build model ASTs from Rails source ──

    private def build_model_asts : Hash(String, Crystal::ASTNode)
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      asts = {} of String => Crystal::ASTNode
      app.models.each do |name, model|
        source_path = File.join(rails_dir, "app/models/#{Inflector.underscore(name)}.rb")
        next unless File.exists?(source_path)

        schema = schema_map[Inflector.pluralize(Inflector.underscore(name))]?
        next unless schema

        ast = SourceParser.parse(source_path)
        ast = ast.transform(BroadcastsTo.new)
        @broadcast_asts[name] = ast.clone
        ast = ast.transform(ModelBoilerplatePython.new(schema, model))

        asts[name] = ast
      end
      asts
    end

    # ── Cargo.toml ──

    private def emit_cargo_toml(output_dir : String, app_name : String)
      File.write(File.join(output_dir, "Cargo.toml"), <<-TOML)
      [package]
      name = "#{app_name}"
      version = "0.1.0"
      edition = "2021"

      [dependencies]
      axum = { version = "0.8", features = ["ws"] }
      chrono = "0.4"
      futures-util = "0.3"
      lazy_static = "1.5"
      rusqlite = { version = "0.32", features = ["bundled"] }
      serde = { version = "1", features = ["derive"] }
      serde_json = "1"
      tokio = { version = "1", features = ["full"] }
      tower-http = { version = "0.6", features = ["fs"] }

      [dev-dependencies]
      axum-test = "18"
      tokio = { version = "1", features = ["full"] }
      TOML
      puts "  Cargo.toml"
    end

    # ── Runtime ──

    private def emit_runtime(output_dir : String)
      src_dir = File.join(output_dir, "src")
      Dir.mkdir_p(src_dir)

      runtime_src = File.join(File.dirname(__FILE__), "..", "runtime", "rust", "railcar.rs")
      File.copy(runtime_src, File.join(src_dir, "railcar.rs"))
      puts "  src/railcar.rs"
    end

    # ── Models ──

    private def emit_models(output_dir : String, app_name : String, model_asts : Hash(String, Crystal::ASTNode))
      src_dir = File.join(output_dir, "src")
      Dir.mkdir_p(src_dir)

      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      emitter = Cr2Rs::Emitter.new

      # Collect model names for mod declarations
      model_names = [] of String

      model_asts.each do |name, ast|
        next unless ast.is_a?(Crystal::ClassDef)
        table_name = Inflector.pluralize(Inflector.underscore(name))
        schema = schema_map[table_name]?
        next unless schema

        broadcast_ast = broadcast_asts[name]?
        source = emitter.emit_model(ast.as(Crystal::ClassDef), name, schema, app_name, broadcast_ast)
        singular = Inflector.underscore(name)

        File.write(File.join(src_dir, "#{singular}.rs"), source)
        puts "  src/#{singular}.rs"
        model_names << singular
      end

      # Generate lib.rs with mod declarations
      io = IO::Memory.new
      io << "pub mod railcar;\n"
      io << "pub mod helpers;\n"
      io << "pub mod views;\n"
      io << "pub mod controllers;\n"
      model_names.each do |name|
        io << "pub mod #{name};\n"
      end
      File.write(File.join(src_dir, "lib.rs"), io.to_s)
      puts "  src/lib.rs"
    end

    # ── Helpers ──

    private def emit_helpers(output_dir : String, app_name : String)
      io = IO::Memory.new
      io << "use std::fmt;\n\n"

      # Route helpers
      app.routes.helpers.each do |helper|
        func_name = helper.name + "_path"
        if helper.params.empty?
          io << "pub fn #{func_name}() -> String { #{helper.path.inspect}.to_string() }\n\n"
        else
          param_decl = helper.params.map_with_index { |_, i| "id#{i}: i64" }.join(", ")
          path_fmt = helper.path.gsub(/:(\w+)/) { "{}" }
          format_args = helper.params.map_with_index { |_, i| "id#{i}" }.join(", ")
          io << "pub fn #{func_name}(#{param_decl}) -> String { format!(\"#{path_fmt}\", #{format_args}) }\n\n"
        end
      end

      # View helpers
      io << <<-RUST
      pub fn link_to(text: &str, url: &str, class: &str) -> String {
          if class.is_empty() {
              format!("<a href=\\"{}\\">{}</a>", url, text)
          } else {
              format!("<a href=\\"{}\\" class=\\"{}\\">{}</a>", url, class, text)
          }
      }

      pub fn button_to(text: &str, url: &str, method: &str, form_class: &str, class: &str, confirm: &str) -> String {
          let form_cls = if form_class.is_empty() { String::new() } else { format!(" class=\\"{}\\"", form_class) };
          let btn_cls = if class.is_empty() { String::new() } else { format!(" class=\\"{}\\"", class) };
          let conf = if confirm.is_empty() { String::new() } else { format!(" data-turbo-confirm=\\"{}\\"", confirm) };
          format!("<form method=\\"post\\" action=\\"{}\\"{}{conf}><input type=\\"hidden\\" name=\\"_method\\" value=\\"{}\\"><button type=\\"submit\\"{}>{}</button></form>", url, form_cls, method, btn_cls, text)
      }

      pub fn turbo_stream_from(channel: &str) -> String {
          let json = format!("\\"{}\\"", channel);
          let signed = base64_encode(json.as_bytes());
          format!("<turbo-cable-stream-source channel=\\"Turbo::StreamsChannel\\" signed-stream-name=\\"{}\\"></turbo-cable-stream-source>", signed)
      }

      fn base64_encode(data: &[u8]) -> String {
          const CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
          let mut result = Vec::new();
          for chunk in data.chunks(3) {
              let b0 = chunk[0] as usize;
              let b1 = if chunk.len() > 1 { chunk[1] as usize } else { 0 };
              let b2 = if chunk.len() > 2 { chunk[2] as usize } else { 0 };
              result.push(CHARS[b0 >> 2]);
              result.push(CHARS[(b0 & 3) << 4 | b1 >> 4]);
              result.push(if chunk.len() > 1 { CHARS[(b1 & 0xf) << 2 | b2 >> 6] } else { b'=' });
              result.push(if chunk.len() > 2 { CHARS[b2 & 0x3f] } else { b'=' });
          }
          String::from_utf8(result).unwrap_or_default()
      }

      pub fn truncate(text: &str, length: usize) -> String {
          if text.len() <= length { return text.to_string(); }
          if length <= 3 { return text[..length].to_string(); }
          format!("{}...", &text[..length - 3])
      }

      pub fn dom_id<T: fmt::Debug>(obj: &T, id: i64, prefix: &str) -> String {
          let type_name = format!("{:?}", obj);
          let name = type_name.split('{').next().unwrap_or("item").trim().to_lowercase();
          if prefix.is_empty() {
              format!("{}_{}", name, id)
          } else {
              format!("{}_{}_{}", prefix, name, id)
          }
      }

      pub fn pluralize(count: usize, singular: &str) -> String {
          if count == 1 { format!("{} {}", count, singular) }
          else { format!("{} {}s", count, singular) }
      }

      pub fn form_with_open_tag(model_name: &str, id: i64, class: &str) -> String {
          let plural = format!("{}s", model_name);
          let cls = if class.is_empty() { String::new() } else { format!(" class=\\"{}\\"", class) };
          if id > 0 {
              format!("<form action=\\"/{}/{}\\" method=\\"post\\"{}><input type=\\"hidden\\" name=\\"_method\\" value=\\"patch\\">", plural, id, cls)
          } else {
              format!("<form action=\\"/{}\\" method=\\"post\\"{}>"  , plural, cls)
          }
      }

      pub fn form_submit_tag(model_name: &str, id: i64, class: &str) -> String {
          let cls = if class.is_empty() { String::new() } else { format!(" class=\\"{}\\"", class) };
          let action = if id > 0 { "Update" } else { "Create" };
          let cap_name = format!("{}{}", &model_name[..1].to_uppercase(), &model_name[1..]);
          format!("<input type=\\"submit\\" value=\\"{} {}\\"{}>", action, cap_name, cls)
      }

      pub fn extract_model_params(form: &std::collections::HashMap<String, String>, model: &str) -> std::collections::HashMap<String, String> {
          let prefix = format!("{}[", model);
          let mut result = std::collections::HashMap::new();
          for (key, value) in form {
              if key.starts_with(&prefix) && key.ends_with(']') {
                  let field = &key[prefix.len()..key.len() - 1];
                  result.insert(field.to_string(), value.clone());
              }
          }
          result
      }

      pub fn render_page(content: &str) -> String {
          render_page_status(content, 200)
      }

      pub fn render_page_status(content: &str, _status: u16) -> String {
          format!("<!DOCTYPE html>\\n<html>\\n<head>\\n  <title>Blog</title>\\n  <meta name=\\"viewport\\" content=\\"width=device-width,initial-scale=1\\">\\n  <link rel=\\"stylesheet\\" href=\\"/static/app.css\\">\\n  <script type=\\"module\\" src=\\"/static/turbo.min.js\\"></script>\\n</head>\\n<body>\\n  <main class=\\"container mx-auto mt-28 px-5 flex flex-col\\">\\n    {}\\n  </main>\\n</body>\\n</html>", content)
      }
      RUST

      File.write(File.join(output_dir, "src", "helpers.rs"), io.to_s)
      puts "  src/helpers.rs"
    end

    # ── Views ──

    private def emit_views(output_dir : String, app_name : String)
      rails_views = File.join(rails_dir, "app/views")
      io = IO::Memory.new
      io << "use crate::helpers;\n"
      io << "use crate::railcar::Model;\n"
      app.models.each_key do |name|
        singular = Inflector.underscore(name)
        io << "use crate::#{singular}::*;\n"
      end
      io << "\n"

      all_partial_names = collect_partial_names(rails_views)

      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        singular = Inflector.singularize(controller_name)
        plural = Inflector.pluralize(controller_name)
        model_name = Inflector.classify(singular)
        template_dir = File.join(rails_views, plural)
        next unless Dir.exists?(template_dir)

        Dir.glob(File.join(template_dir, "*.html.erb")).sort.each do |erb_path|
          basename = File.basename(erb_path, ".html.erb")
          next if basename.ends_with?(".json")

          is_partial = basename.starts_with?("_")
          func_name = if is_partial
                        "render_#{basename.lchop("_")}_partial"
                      else
                        "render_#{basename}"
                      end

          begin
            erb_source = File.read(erb_path)
            ruby_code = ErbCompiler.new(erb_source).src
            ast = SourceParser.parse_source(ruby_code, "template.rb")

            build_view_filters.each { |f| ast = ast.transform(f) }
            ast = ast.transform(ViewCleanup.new)
            var_names = [singular, plural, "_buf", "notice", "flash", "form"]
            model_info = app.models[Inflector.classify(singular)]?
            if model_info
              model_info.associations.each do |assoc|
                var_names << assoc.name if assoc.kind == :belongs_to
              end
            end
            ast = ViewCleanup.calls_to_vars(ast, var_names)

            body = ast
            while body.is_a?(Crystal::Def) && body.as(Crystal::Def).name == "render"
              body = body.as(Crystal::Def).body
            end
            if body.is_a?(Crystal::Expressions)
              body.as(Crystal::Expressions).expressions.each do |expr|
                if expr.is_a?(Crystal::Def) && expr.as(Crystal::Def).name == "render"
                  body = expr.as(Crystal::Def).body
                  break
                end
              end
            end

            # Emit Rust function signature + build parallel typed args for
            # the semantic analyzer.
            typed_args = [] of Crystal::Arg
            if is_partial
              partial_name = basename.lchop("_")
              partial_model_name = Inflector.classify(partial_name)
              pmodel_info = app.models[partial_model_name]?
              parent_assoc = pmodel_info.try(&.associations.find { |a| a.kind == :belongs_to })
              if partial_name == "form"
                io << "pub fn #{func_name}(#{singular}: &#{model_name}) -> String {\n"
                typed_args << arg(singular, restriction: path(model_name))
              elsif parent_assoc
                parent_name = parent_assoc.name
                parent_model = Inflector.classify(parent_name)
                io << "pub fn #{func_name}(_#{parent_name}: &#{parent_model}, #{partial_name}: &#{partial_model_name}) -> String {\n"
                typed_args << arg(parent_name, restriction: path(parent_model))
                typed_args << arg(partial_name, restriction: path(partial_model_name))
              else
                io << "pub fn #{func_name}(#{partial_name}: &#{partial_model_name}) -> String {\n"
                typed_args << arg(partial_name, restriction: path(partial_model_name))
              end
            else
              param = basename == "index" ? plural : singular
              param_type = basename == "index" ? "&[#{model_name}]" : "&#{model_name}"
              io << "pub fn #{func_name}(#{param}: #{param_type}) -> String {\n"
              if basename == "index"
                array_rest = Crystal::Parser.parse("x : Array(#{model_name})")
                  .as(Crystal::TypeDeclaration).declared_type
                typed_args << arg(param, restriction: array_rest)
              else
                typed_args << arg(param, restriction: path(model_name))
              end
              typed_args << arg("notice", default_value: str(""), restriction: path("String"))
            end

            typed_body = attempt_semantic(basename, body, typed_args, all_partial_names)
            body_to_emit = typed_body || body

            resolver = TypeResolver.new(app)
            emitter = RustViewEmitter.new(app, singular, resolver)
            emitter.emit_body(body_to_emit, io)

            io << "}\n\n"
          rescue ex
            STDERR.puts "  WARN: #{func_name}: #{ex.message}"
            io << "pub fn #{func_name}(_: &str) -> String { \"<!-- #{basename} -->\".to_string() }\n\n"
          end
        end
      end

      File.write(File.join(output_dir, "src", "views.rs"), io.to_s)
      puts "  src/views.rs"
    end

    private def build_view_filters : Array(Crystal::Transformer)
      [
        InstanceVarToLocal.new,
        TurboStreamConnect.new,
        RailsHelpers.new,
        LinkToPathHelper.new,
        ButtonToPathHelper.new,
        RenderToPartial.new,
        FormToHTML.new,
      ] of Crystal::Transformer
    end

    # Scan for partial basenames across all view dirs so the semantic
    # analyzer can stub render_<x>_partial calls.
    private def collect_partial_names(rails_views : String) : Array(String)
      names = Set(String).new
      Dir.glob(File.join(rails_views, "**/_*.html.erb")).each do |p|
        names << File.basename(p, ".html.erb").lchop("_")
      end
      names.to_a
    end

    # Run a view body through semantic analysis, return typed body on
    # success or nil on failure (caller falls back to untyped body).
    private def attempt_semantic(basename : String, body : Crystal::ASTNode,
                                  typed_args : Array(Crystal::Arg),
                                  partial_names : Array(String)) : Crystal::ASTNode?
      view_def = def_("render", typed_args, body, return_type: path("String"))
      analyzer = ViewSemanticAnalyzer.new(app)
      analyzer.partial_names = partial_names
      analyzer.add_view(basename, view_def)
      return nil unless analyzer.analyze
      analyzer.typed_body_for(basename)
    end

    # ── Controllers ──

    private def emit_controllers(output_dir : String, app_name : String)
      io = IO::Memory.new
      io << "use axum::extract::{Form, Path};\n"
      io << "use axum::response::{Html, IntoResponse, Redirect, Response};\n"
      io << "use axum::http::StatusCode;\n"
      io << "use std::collections::HashMap;\n"
      io << "use crate::helpers;\n"
      io << "use crate::views;\n"
      app.models.each_key do |name|
        singular = Inflector.underscore(name)
        io << "use crate::#{singular};\n"
      end
      io << "\n"

      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        singular = Inflector.singularize(controller_name)
        plural = Inflector.pluralize(controller_name)
        model_name = Inflector.classify(singular)
        nested_parent = app.routes.nested_parent_for(plural)

        info.actions.each do |action|
          next if action.is_private
          emit_rust_controller_action(action.name, io, model_name, singular, plural, nested_parent)
        end
      end

      # Generate _method dispatch functions for paths with both PATCH and DELETE
      dispatched = Set(String).new
      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        singular = Inflector.singularize(controller_name)
        mod = Inflector.underscore(Inflector.classify(singular))
        has_update = info.actions.any? { |a| a.name == "update" }
        has_destroy = info.actions.any? { |a| a.name == "destroy" }
        next unless has_update && has_destroy
        next if dispatched.includes?(singular)
        dispatched << singular

        io << "pub async fn method_dispatch_#{singular}(Path(id): Path<i64>, Form(form): Form<HashMap<String, String>>) -> Response {\n"
        io << "    match form.get(\"_method\").map(|s| s.as_str()) {\n"
        io << "        Some(\"delete\") => destroy_#{singular}(Path(id)).await,\n"
        io << "        _ => update_#{singular}(Path(id), Form(form)).await,\n"
        io << "    }\n"
        io << "}\n\n"
      end

      File.write(File.join(output_dir, "src", "controllers.rs"), io.to_s)
      puts "  src/controllers.rs"
    end

    private def emit_rust_controller_action(action_name : String, io : IO, model_name : String,
                                             singular : String, plural : String, nested_parent : String?)
      case action_name
      when "index"
        mod = Inflector.underscore(model_name)
        io << "pub async fn index() -> impl IntoResponse {\n"
        io << "    match #{mod}::all_#{singular}s(\"created_at DESC\") {\n"
        io << "        Ok(#{plural}) => Html(helpers::render_page(&views::render_index(&#{plural}))),\n"
        io << "        Err(e) => Html(format!(\"Error: {}\", e)),\n"
        io << "    }\n"
        io << "}\n\n"
      when "show"
        mod = Inflector.underscore(model_name)
        io << "pub async fn show_#{singular}(Path(id): Path<i64>) -> Response {\n"
        io << "    match #{mod}::find_#{singular}(id) {\n"
        io << "        Ok(#{singular}) => Html(helpers::render_page(&views::render_show(&#{singular}))).into_response(),\n"
        io << "        Err(_) => StatusCode::NOT_FOUND.into_response(),\n"
        io << "    }\n"
        io << "}\n\n"
      when "new"
        mod = Inflector.underscore(model_name)
        io << "pub async fn new_#{singular}() -> impl IntoResponse {\n"
        io << "    let #{singular} = #{mod}::#{model_name}::new();\n"
        io << "    Html(helpers::render_page(&views::render_new(&#{singular})))\n"
        io << "}\n\n"
      when "edit"
        mod = Inflector.underscore(model_name)
        io << "pub async fn edit_#{singular}(Path(id): Path<i64>) -> Response {\n"
        io << "    match #{mod}::find_#{singular}(id) {\n"
        io << "        Ok(#{singular}) => Html(helpers::render_page(&views::render_edit(&#{singular}))).into_response(),\n"
        io << "        Err(_) => StatusCode::NOT_FOUND.into_response(),\n"
        io << "    }\n"
        io << "}\n\n"
      when "create"
        mod = Inflector.underscore(model_name)
        if nested_parent
          parent_model = Inflector.classify(nested_parent)
          parent_mod = Inflector.underscore(parent_model)
          io << "pub async fn create_#{singular}(Path(parent_id): Path<i64>, Form(form): Form<HashMap<String, String>>) -> Response {\n"
          io << "    if let Ok(#{nested_parent}) = #{parent_mod}::find_#{nested_parent}(parent_id) {\n"
          io << "        let mut attrs = helpers::extract_model_params(&form, \"#{singular}\");\n"
          io << "        attrs.insert(\"#{nested_parent}_id\".to_string(), format!(\"{}\", #{nested_parent}.id));\n"
          io << "        let _ = #{mod}::create_#{singular}(&attrs);\n"
          io << "        Redirect::to(&helpers::#{nested_parent}_path(#{nested_parent}.id)).into_response()\n"
          io << "    } else {\n"
          io << "        StatusCode::NOT_FOUND.into_response()\n"
          io << "    }\n"
          io << "}\n\n"
        else
          io << "pub async fn create_#{singular}(Form(form): Form<HashMap<String, String>>) -> Response {\n"
          io << "    let attrs = helpers::extract_model_params(&form, \"#{singular}\");\n"
          io << "    let mut #{singular} = #{mod}::#{model_name}::new();\n"
          schema_map = {} of String => TableSchema
          app.schemas.each { |s| schema_map[s.name] = s }
          table = Inflector.pluralize(singular)
          if schema = schema_map[table]?
            schema.columns.each do |col|
              next if {"id", "created_at", "updated_at"}.includes?(col.name)
              if col.type.downcase == "integer" || col.type.downcase == "references"
                io << "    if let Some(v) = attrs.get(\"#{col.name}\") { #{singular}.#{col.name} = v.parse().unwrap_or(0); }\n"
              else
                io << "    if let Some(v) = attrs.get(\"#{col.name}\") { #{singular}.#{col.name} = v.clone(); }\n"
              end
            end
          end
          io << "    match #{singular}.save() {\n"
          io << "        Ok(_) => Redirect::to(&helpers::#{singular}_path(#{singular}.id)).into_response(),\n"
          io << "        Err(_) => {\n"
          io << "            (StatusCode::UNPROCESSABLE_ENTITY, Html(helpers::render_page(&views::render_new(&#{singular})))).into_response()\n"
          io << "        }\n"
          io << "    }\n"
          io << "}\n\n"
        end
      when "update"
        mod = Inflector.underscore(model_name)
        io << "pub async fn update_#{singular}(Path(id): Path<i64>, Form(form): Form<HashMap<String, String>>) -> Response {\n"
        io << "    match #{mod}::find_#{singular}(id) {\n"
        io << "        Ok(mut #{singular}) => {\n"
        io << "            let attrs = helpers::extract_model_params(&form, \"#{singular}\");\n"
        io << "            match #{singular}.update(&attrs) {\n"
        io << "                Ok(_) => Redirect::to(&helpers::#{singular}_path(#{singular}.id)).into_response(),\n"
        io << "                Err(_) => (StatusCode::UNPROCESSABLE_ENTITY, Html(helpers::render_page(&views::render_edit(&#{singular})))).into_response(),\n"
        io << "            }\n"
        io << "        }\n"
        io << "        Err(_) => StatusCode::NOT_FOUND.into_response(),\n"
        io << "    }\n"
        io << "}\n\n"
      when "destroy"
        mod = Inflector.underscore(model_name)
        if nested_parent
          parent_model = Inflector.classify(nested_parent)
          parent_mod = Inflector.underscore(parent_model)
          io << "pub async fn destroy_#{singular}(Path((parent_id, id)): Path<(i64, i64)>) -> Response {\n"
          io << "    if let (Ok(#{nested_parent}), Ok(#{singular})) = (#{parent_mod}::find_#{nested_parent}(parent_id), #{mod}::find_#{singular}(id)) {\n"
          io << "        let _ = #{singular}.delete();\n"
          io << "        Redirect::to(&helpers::#{nested_parent}_path(#{nested_parent}.id)).into_response()\n"
          io << "    } else {\n"
          io << "        StatusCode::NOT_FOUND.into_response()\n"
          io << "    }\n"
          io << "}\n\n"
        else
          io << "pub async fn destroy_#{singular}(Path(id): Path<i64>) -> Response {\n"
          io << "    match #{mod}::find_#{singular}(id) {\n"
          io << "        Ok(#{singular}) => {\n"
          io << "            let _ = #{singular}.delete();\n"
          io << "            Redirect::to(&helpers::#{plural}_path()).into_response()\n"
          io << "        }\n"
          io << "        Err(_) => StatusCode::NOT_FOUND.into_response(),\n"
          io << "    }\n"
          io << "}\n\n"
        end
      end
    end

    # ── create_*_str helper (accepts HashMap<String, String>) ──
    # The emitter generates create_* taking HashMap<String, String>
    # which is what we use here. No need for additional helper.

    # ── Main entry point ──

    private def emit_main(output_dir : String, app_name : String)
      io = IO::Memory.new
      io << "use axum::{routing::{get, post, delete}, Router};\n"
      io << "use rusqlite::Connection;\n"
      io << "use tower_http::services::ServeDir;\n"
      io << "use #{app_name}::railcar;\n"
      io << "use #{app_name}::controllers;\n"
      io << "use #{app_name}::views;\n"
      app.models.each_key do |name|
        singular = Inflector.underscore(name)
        io << "use #{app_name}::#{singular};\n"
      end
      io << "use std::collections::HashMap;\n\n"

      # DB init
      io << "fn init_db() {\n"
      io << "    let conn = Connection::open(\"#{app_name}.db\").expect(\"Failed to open database\");\n"
      io << "    conn.execute_batch(\"PRAGMA foreign_keys = ON;\").unwrap();\n"
      app.schemas.each do |schema|
        all_cols = [{name: "id", type: "INTEGER"}]
        schema.columns.each { |c| all_cols << {name: c.name, type: c.type} }
        col_defs = all_cols.map do |c|
          parts = "#{c[:name]} #{c[:type]}"
          parts += " PRIMARY KEY AUTOINCREMENT" if c[:name] == "id"
          parts += " NOT NULL" unless c[:name] == "id"
          parts
        end
        io << "    conn.execute_batch(\"CREATE TABLE IF NOT EXISTS #{schema.name} (\n"
        io << "        #{col_defs.join(",\n        ")}\n"
        io << "    );\").unwrap();\n"
      end
      io << "    *railcar::DB.lock().unwrap() = Some(conn);\n"
      io << "}\n\n"

      # Seed
      io << "fn seed_db() {\n"
      io << "    if article::article_count().unwrap_or(0) > 0 { return; }\n"
      seeds_path = File.join(rails_dir, "db/seeds.rb")
      if File.exists?(seeds_path)
        emit_rust_seeds(io, seeds_path)
      end
      io << "}\n\n"

      # Main
      io << "#[tokio::main]\n"
      io << "async fn main() {\n"
      io << "    init_db();\n"
      io << "    seed_db();\n\n"

      # Register partial renderers
      app.models.each do |name, model|
        singular = Inflector.underscore(name)
        plural = Inflector.pluralize(singular)
        partial_path = File.join(rails_dir, "app/views/#{plural}/_#{singular}.html.erb")
        if File.exists?(partial_path)
          parent_assoc = model.associations.find { |a| a.kind == :belongs_to }
          if parent_assoc
            parent_name = parent_assoc.name
            parent_mod = Inflector.underscore(Inflector.classify(parent_name))
            io << "    railcar::register_partial(\"#{name}\", |id| {\n"
            io << "        if let Ok(rec) = #{singular}::find_#{singular}(id) {\n"
            io << "            if let Ok(parent) = rec.#{parent_name}() {\n"
            io << "                return views::render_#{singular}_partial(&parent, &rec);\n"
            io << "            }\n"
            io << "        }\n"
            io << "        String::new()\n"
            io << "    });\n"
          else
            io << "    railcar::register_partial(\"#{name}\", |id| {\n"
            io << "        if let Ok(rec) = #{singular}::find_#{singular}(id) {\n"
            io << "            return views::render_#{singular}_partial(&rec);\n"
            io << "        }\n"
            io << "        String::new()\n"
            io << "    });\n"
          end
        end
      end
      io << "\n"

      # Routes — group by path to combine methods and avoid Axum overlap errors
      io << "    let app = Router::new()\n"
      routes_by_path = {} of String => Array({method: String, handler: String})
      app.routes.routes.each do |route|
        singular = Inflector.singularize(route.controller)
        handler = case route.action
                  when "index"   then "controllers::index"
                  when "show"    then "controllers::show_#{singular}"
                  when "new"     then "controllers::new_#{singular}"
                  when "edit"    then "controllers::edit_#{singular}"
                  when "create"  then "controllers::create_#{singular}"
                  when "update"  then "controllers::update_#{singular}"
                  when "destroy" then "controllers::destroy_#{singular}"
                  else next
                  end
        axum_path = route.path.gsub(/:(\w+)/) { |m| "{#{$1}}" }
        routes_by_path[axum_path] ||= [] of {method: String, handler: String}
        routes_by_path[axum_path] << {method: route.method.downcase, handler: handler}
      end

      routes_by_path.each do |path, methods|
        parts = [] of String
        has_patch_or_delete = false
        methods.each do |m|
          parts << "#{m[:method]}(#{m[:handler]})"
          has_patch_or_delete = true if {"patch", "delete"}.includes?(m[:method])
        end
        # Add POST dispatch for PATCH/DELETE (HTML forms can only POST)
        if has_patch_or_delete
          # Use a dispatcher that checks _method form field
          update_handler = methods.find { |m| m[:method] == "patch" }
          delete_handler = methods.find { |m| m[:method] == "delete" }
          if update_handler && delete_handler
            parts << "post(controllers::method_dispatch_#{Inflector.singularize(path.split("/")[1]? || "item")})"
          elsif update_handler
            parts << "post(#{update_handler[:handler]})"
          elsif delete_handler
            parts << "post(#{delete_handler[:handler]})"
          end
        end
        io << "        .route(\"#{path}\", #{parts.join(".")})\n"
      end
      if app.routes.root_controller
        io << "        .route(\"/\", get(controllers::index))\n"
      end
      io << "        .route(\"/cable\", get(railcar::cable_handler))\n"
      io << "        .nest_service(\"/static\", ServeDir::new(\"static\"));\n\n"

      io << "    println!(\"#{app_name} running at http://localhost:3000\");\n"
      io << "    let listener = tokio::net::TcpListener::bind(\"0.0.0.0:3000\").await.unwrap();\n"
      io << "    axum::serve(listener, app).await.unwrap();\n"
      io << "}\n"

      File.write(File.join(output_dir, "src", "main.rs"), io.to_s)
      puts "  src/main.rs"
    end

    private def emit_rust_seeds(io : IO, seeds_path : String)
      source = File.read(seeds_path)
      # Simple line-by-line seed parsing (same approach as Go)
      current = ""
      depth = 0
      joined = [] of String
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

      joined.each_with_index do |stmt, idx|
        case stmt
        when /^(\w+)\s*=\s*(\w+)\.create!\(\s*(.+)\s*\)$/m
          var_name = $1
          model = $2
          singular = Inflector.underscore(model)
          attrs = parse_seed_attrs($3)
          used = joined[(idx + 1)..].any? { |s| s.includes?(var_name) }
          if used
            io << "    let #{var_name} = #{singular}::create_#{singular}(&HashMap::from([#{attrs}])).unwrap();\n"
          else
            io << "    let _ = #{singular}::create_#{singular}(&HashMap::from([#{attrs}]));\n"
          end
        when /^(\w+)\.(\w+)\.create!\(\s*(.+)\s*\)$/m
          parent = $1
          assoc = $2
          singular_assoc = Inflector.singularize(assoc)
          model = Inflector.classify(singular_assoc)
          singular_model = Inflector.underscore(model)
          parent_model_name = parent.gsub(/\d+$/, "")
          fk = "#{parent_model_name}_id"
          attrs = parse_seed_attrs($3)
          io << "    let _ = #{singular_model}::create_#{singular_model}(&HashMap::from([#{attrs}, (\"#{fk}\".to_string(), format!(\"{}\", #{parent}.id))]));\n"
        end
      end
    end

    private def parse_seed_attrs(raw : String) : String
      raw.gsub(/\s+/, " ").scan(/(?<=\A|,\s)(\w+):\s*("(?:[^"\\]|\\.)*")/).map do |m|
        "(\"#{m[1]}\".to_string(), #{m[2]}.to_string())"
      end.join(", ")
    end

    # ── Static assets ──

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

    # ── Model tests ──

    private def emit_model_tests(output_dir : String, app_name : String)
      rails_test_dir = File.join(rails_dir, "test/models")
      return unless Dir.exists?(rails_test_dir)

      tests_dir = File.join(output_dir, "tests")
      Dir.mkdir_p(tests_dir)

      io = IO::Memory.new
      io << "use #{app_name}::railcar;\n"
      io << "use #{app_name}::article::*;\n"
      io << "use #{app_name}::comment::*;\n"
      io << "use rusqlite::Connection;\n"
      io << "use std::collections::HashMap;\n\n"

      # Setup helper
      io << "fn setup_db() {\n"
      io << "    let conn = Connection::open_in_memory().unwrap();\n"
      io << "    conn.execute_batch(\"PRAGMA foreign_keys = ON;\").unwrap();\n"
      app.schemas.each do |schema|
        all_cols = [{name: "id", type: "INTEGER"}]
        schema.columns.each { |c| all_cols << {name: c.name, type: c.type} }
        col_defs = all_cols.map do |c|
          parts = "#{c[:name]} #{c[:type]}"
          parts += " PRIMARY KEY AUTOINCREMENT" if c[:name] == "id"
          parts += " NOT NULL" unless c[:name] == "id"
          parts
        end
        io << "    conn.execute_batch(\"CREATE TABLE #{schema.name} (\n"
        io << "        #{col_defs.join(",\n        ")}\n"
        io << "    );\").unwrap();\n"
      end
      io << "    *railcar::DB.lock().unwrap() = Some(conn);\n"
      io << "}\n\n"

      # Fixtures struct
      io << "struct Fixtures {\n"
      sorted_fixtures = FixtureLoader.sort_by_dependency(app.fixtures, app.models)
      sorted_fixtures.each do |table|
        singular = Inflector.singularize(table.name)
        model_name = Inflector.classify(singular)
        next unless app.models.has_key?(model_name)
        table.records.each do |record|
          io << "    #{table.name}_#{record.label}: #{model_name},\n"
        end
      end
      io << "}\n\n"

      io << "fn setup_fixtures() -> Fixtures {\n"
      sorted_fixtures.each do |table|
        singular = Inflector.singularize(table.name)
        model_name = Inflector.classify(singular)
        next unless app.models.has_key?(model_name)

        table.records.each do |record|
          attrs = [] of String
          record.fields.each do |field, value|
            model_info = app.models[model_name]?
            assoc = model_info.try(&.associations.find { |a| a.name == field })
            if assoc && assoc.kind == :belongs_to
              ref_table = Inflector.pluralize(field)
              attrs << "(\"#{field}_id\".to_string(), format!(\"{}\", #{ref_table}_#{value}.id))"
            else
              attrs << "(\"#{field}\".to_string(), \"#{value}\".to_string())"
            end
          end

          var_name = "#{table.name}_#{record.label}"
          io << "    let #{var_name} = create_#{singular}(&HashMap::from([#{attrs.join(", ")}])).unwrap();\n"
        end
      end
      io << "    Fixtures {\n"
      sorted_fixtures.each do |table|
        singular = Inflector.singularize(table.name)
        model_name = Inflector.classify(singular)
        next unless app.models.has_key?(model_name)
        table.records.each do |record|
          io << "        #{table.name}_#{record.label},\n"
        end
      end
      io << "    }\n"
      io << "}\n\n"

      # Generate test functions from Rails test files
      Dir.glob(File.join(rails_test_dir, "*_test.rb")).sort.each do |path|
        basename = File.basename(path, "_test.rb")
        model_name = Inflector.classify(basename)
        ast = SourceParser.parse(path)
        emit_rust_test_functions(io, model_name, basename, ast)
      end

      File.write(File.join(tests_dir, "model_tests.rs"), io.to_s)
      puts "  tests/model_tests.rs"
    end

    private def emit_rust_test_functions(io : IO, model_name : String, basename : String,
                                          ast : Crystal::ASTNode)
      class_body = find_class_body(ast)
      return unless class_body

      exprs = case class_body
              when Crystal::Expressions then class_body.expressions
              else [class_body]
              end

      exprs.each do |expr|
        next unless expr.is_a?(Crystal::Call)
        call = expr.as(Crystal::Call)
        next unless call.name == "test" && call.args.size == 1 && call.block
        test_name = call.args[0].to_s.strip('"')
        rust_name = "test_" + test_name.downcase.gsub(" ", "_").gsub(/[^a-z0-9_]/, "")

        io << "#[test]\n"
        io << "fn #{rust_name}() {\n"
        io << "    setup_db();\n"
        io << "    let f = setup_fixtures();\n"
        io << "    let _ = &f;\n\n"

        emit_rust_test_body(call.block.not_nil!.body, io, model_name, basename)

        io << "}\n\n"
      end
    end

    private def emit_rust_test_body(node : Crystal::ASTNode, io : IO, model_name : String, basename : String)
      singular = Inflector.underscore(model_name)
      plural = Inflector.pluralize(singular)

      exprs = case node
              when Crystal::Expressions then node.expressions
              else [node]
              end

      exprs.each do |expr|
        case expr
        when Crystal::Assign
          emit_rust_test_assign(expr, io, model_name, singular, plural)
        when Crystal::Call
          emit_rust_test_call(expr, io, model_name, singular, plural)
        end
      end
    end

    private def emit_rust_test_assign(node : Crystal::Assign, io : IO, model_name : String,
                                       singular : String, plural : String)
      target = node.target
      value = node.value
      var_name = case target
                 when Crystal::InstanceVar then target.name.lchop("@")
                 when Crystal::Var then target.name
                 else target.to_s
                 end

      if value.is_a?(Crystal::Call) && value.args.size == 1 && value.args[0].is_a?(Crystal::SymbolLiteral)
        func = value.name
        label = value.args[0].as(Crystal::SymbolLiteral).value
        io << "    let #{var_name} = &f.#{func}_#{label};\n"
      elsif value.is_a?(Crystal::Call) && value.name == "new" && value.obj
        obj_name = value.obj.not_nil!.to_s
        attrs = rust_struct_attrs(value)
        io << "    let mut #{var_name} = #{obj_name} { #{attrs}, ..#{obj_name}::new() };\n"
      elsif value.is_a?(Crystal::Call) && value.name == "create" && value.obj.is_a?(Crystal::Call)
        parent_call = value.obj.as(Crystal::Call)
        if parent_call.obj
          parent_var = rust_expr(parent_call.obj.not_nil!)
          child_model = Inflector.classify(Inflector.singularize(parent_call.name))
          child_singular = Inflector.underscore(child_model)
          parent_singular = Inflector.underscore(parent_var)
          fk = "#{parent_singular}_id"
          attrs = rust_map_attrs(value)
          io << "    let #{var_name} = create_#{child_singular}(&HashMap::from([#{attrs}, (\"#{fk}\".to_string(), format!(\"{}\", #{parent_var}.id))])).unwrap();\n"
        end
      elsif value.is_a?(Crystal::Call) && value.name == "build" && value.obj.is_a?(Crystal::Call)
        parent_call = value.obj.as(Crystal::Call)
        if parent_call.obj
          parent_var = rust_expr(parent_call.obj.not_nil!)
          child_model = Inflector.classify(Inflector.singularize(parent_call.name))
          attrs = rust_struct_attrs(value)
          io << "    let mut #{var_name} = #{child_model} { #{attrs}, article_id: #{parent_var}.id, ..#{child_model}::new() };\n"
        end
      else
        io << "    // TODO: #{node}\n"
      end
    end

    private def emit_rust_test_call(node : Crystal::Call, io : IO, model_name : String,
                                     singular : String, plural : String)
      name = node.name
      args = node.args

      case name
      when "assert_not_nil"
        if args.size == 1
          io << "    assert!(#{rust_expr(args[0])} != 0, \"expected non-zero ID\");\n"
        end
      when "assert_equal"
        if args.size == 2
          expected = rust_expr(args[0])
          actual = rust_expr(args[1])
          io << "    assert_eq!(#{actual}, #{expected});\n"
        end
      when "assert_not"
        if args.size == 1 && args[0].is_a?(Crystal::Call) && args[0].as(Crystal::Call).name == "save"
          obj = args[0].as(Crystal::Call).obj
          obj_str = obj ? rust_expr(obj) : singular
          io << "    assert!(#{obj_str}.save().is_err(), \"expected save to fail\");\n"
        end
      when "assert_difference"
        if args.size >= 1 && node.block
          count_expr = args[0].to_s.strip('"')
          model = count_expr.split(".").first
          model_singular = Inflector.underscore(model)
          diff = args.size > 1 ? args[1].to_s.to_i : 1
          io << "    let before_count = #{model_singular}_count().unwrap();\n"
          emit_rust_test_body(node.block.not_nil!.body, io, model_name, singular)
          io << "    let after_count = #{model_singular}_count().unwrap();\n"
          if diff >= 0
            io << "    assert_eq!(after_count - before_count, #{diff}, \"expected count diff #{diff}\");\n"
          else
            io << "    assert_eq!(before_count - after_count, #{-diff}, \"expected count diff #{diff}\");\n"
          end
        end
      else
        if obj = node.obj
          obj_str = rust_expr(obj)
          if name == "destroy"
            io << "    #{obj_str}.destroy().unwrap();\n"
          end
        end
      end
    end

    private def rust_expr(node : Crystal::ASTNode) : String
      case node
      when Crystal::Var then node.name
      when Crystal::InstanceVar then node.name.lchop("@")
      when Crystal::Call
        # Fixture reference: articles(:one) → f.articles_one
        if !node.obj && node.args.size == 1 && node.args[0].is_a?(Crystal::SymbolLiteral)
          label = node.args[0].as(Crystal::SymbolLiteral).value
          return "f.#{node.name}_#{label}"
        end
        if node.obj
          obj_str = rust_expr(node.obj.not_nil!)
          "#{obj_str}.#{node.name}"
        else
          node.name
        end
      when Crystal::StringLiteral then "\"#{node.value}\""
      when Crystal::NumberLiteral then node.value.to_s.gsub(/_i64|_i32/, "")
      when Crystal::SymbolLiteral then "\"#{node.value}\""
      else node.to_s
      end
    end

    private def rust_struct_attrs(call : Crystal::Call) : String
      if named = call.named_args
        named.map do |na|
          value = case na.value
                  when Crystal::StringLiteral then "\"#{na.value.as(Crystal::StringLiteral).value}\".to_string()"
                  when Crystal::NumberLiteral then na.value.to_s.gsub(/_i64|_i32/, "")
                  else "\"#{na.value}\".to_string()"
                  end
          "#{na.name}: #{value}"
        end.join(", ")
      else
        ""
      end
    end

    private def rust_map_attrs(call : Crystal::Call) : String
      if named = call.named_args
        named.map do |na|
          value = case na.value
                  when Crystal::StringLiteral then "\"#{na.value.as(Crystal::StringLiteral).value}\".to_string()"
                  when Crystal::NumberLiteral then na.value.to_s + ".to_string()"
                  else "\"#{na.value}\".to_string()"
                  end
          "(\"#{na.name}\".to_string(), #{value})"
        end.join(", ")
      else
        ""
      end
    end

    private def find_class_body(ast : Crystal::ASTNode) : Crystal::ASTNode?
      case ast
      when Crystal::ClassDef
        return ast.body
      when Crystal::Expressions
        ast.expressions.each do |expr|
          result = find_class_body(expr)
          return result if result
        end
      end
      nil
    end

    # ── Controller tests ──

    private def emit_controller_tests(output_dir : String, app_name : String)
      rails_test_dir = File.join(rails_dir, "test/controllers")
      return unless Dir.exists?(rails_test_dir)

      tests_dir = File.join(output_dir, "tests")
      Dir.mkdir_p(tests_dir)

      io = IO::Memory.new
      io << "use axum::{routing::{get, post, delete}, Router};\n"
      io << "use axum_test::TestServer;\n"
      io << "use rusqlite::Connection;\n"
      io << "use std::collections::HashMap;\n"
      io << "use #{app_name}::railcar;\n"
      io << "use #{app_name}::controllers;\n"
      app.models.each_key do |name|
        singular = Inflector.underscore(name)
        io << "use #{app_name}::#{singular}::*;\n"
      end
      io << "use #{app_name}::helpers;\n\n"

      # Setup helper
      io << "fn setup_test() -> TestServer {\n"
      io << "    let conn = Connection::open_in_memory().unwrap();\n"
      io << "    conn.execute_batch(\"PRAGMA foreign_keys = ON;\").unwrap();\n"
      app.schemas.each do |schema|
        all_cols = [{name: "id", type: "INTEGER"}]
        schema.columns.each { |c| all_cols << {name: c.name, type: c.type} }
        col_defs = all_cols.map do |c|
          parts = "#{c[:name]} #{c[:type]}"
          parts += " PRIMARY KEY AUTOINCREMENT" if c[:name] == "id"
          parts += " NOT NULL" unless c[:name] == "id"
          parts
        end
        io << "    conn.execute_batch(\"CREATE TABLE #{schema.name} (\n"
        io << "        #{col_defs.join(",\n        ")}\n"
        io << "    );\").unwrap();\n"
      end
      io << "    *railcar::DB.lock().unwrap() = Some(conn);\n\n"

      # Build router
      io << "    let app = Router::new()\n"
      test_routes_by_path = {} of String => Array({method: String, handler: String})
      app.routes.routes.each do |route|
        singular = Inflector.singularize(route.controller)
        handler = case route.action
                  when "index"   then "controllers::index"
                  when "show"    then "controllers::show_#{singular}"
                  when "new"     then "controllers::new_#{singular}"
                  when "edit"    then "controllers::edit_#{singular}"
                  when "create"  then "controllers::create_#{singular}"
                  when "update"  then "controllers::update_#{singular}"
                  when "destroy" then "controllers::destroy_#{singular}"
                  else next
                  end
        axum_path = route.path.gsub(/:(\w+)/) { |m| "{#{$1}}" }
        test_routes_by_path[axum_path] ||= [] of {method: String, handler: String}
        test_routes_by_path[axum_path] << {method: route.method.downcase, handler: handler}
      end
      test_routes_by_path.each do |path, methods|
        parts = methods.map { |m| "#{m[:method]}(#{m[:handler]})" }
        has_pd = methods.any? { |m| {"patch", "delete"}.includes?(m[:method]) }
        if has_pd
          update_h = methods.find { |m| m[:method] == "patch" }
          delete_h = methods.find { |m| m[:method] == "delete" }
          if update_h && delete_h
            resource = Inflector.singularize(path.split("/")[1]? || "item")
            parts << "post(controllers::method_dispatch_#{resource})"
          elsif update_h
            parts << "post(#{update_h[:handler]})"
          elsif delete_h
            parts << "post(#{delete_h[:handler]})"
          end
        end
        io << "        .route(\"#{path}\", #{parts.join(".")})\n"
      end
      if app.routes.root_controller
        io << "        .route(\"/\", get(controllers::index))\n"
      end
      io << "        ;\n\n"

      io << "    TestServer::new(app).unwrap()\n"
      io << "}\n\n"

      # Fixtures
      io << "struct CtrlFixtures {\n"
      sorted_fixtures = FixtureLoader.sort_by_dependency(app.fixtures, app.models)
      sorted_fixtures.each do |table|
        singular = Inflector.singularize(table.name)
        model_name = Inflector.classify(singular)
        next unless app.models.has_key?(model_name)
        table.records.each do |record|
          io << "    #{table.name}_#{record.label}: #{model_name},\n"
        end
      end
      io << "}\n\n"

      io << "fn setup_ctrl_fixtures() -> CtrlFixtures {\n"
      sorted_fixtures.each do |table|
        singular = Inflector.singularize(table.name)
        model_name = Inflector.classify(singular)
        next unless app.models.has_key?(model_name)
        table.records.each do |record|
          attrs = [] of String
          record.fields.each do |field, value|
            model_info = app.models[model_name]?
            assoc = model_info.try(&.associations.find { |a| a.name == field })
            if assoc && assoc.kind == :belongs_to
              ref_table = Inflector.pluralize(field)
              attrs << "(\"#{field}_id\".to_string(), format!(\"{}\", #{ref_table}_#{value}.id))"
            else
              attrs << "(\"#{field}\".to_string(), \"#{value}\".to_string())"
            end
          end
          io << "    let #{table.name}_#{record.label} = create_#{singular}(&HashMap::from([#{attrs.join(", ")}])).unwrap();\n"
        end
      end
      io << "    CtrlFixtures {\n"
      sorted_fixtures.each do |table|
        singular = Inflector.singularize(table.name)
        model_name = Inflector.classify(singular)
        next unless app.models.has_key?(model_name)
        table.records.each do |record|
          io << "        #{table.name}_#{record.label},\n"
        end
      end
      io << "    }\n"
      io << "}\n\n"

      # Helper for form encoding
      io << "fn encode_params(model: &str, params: &[(&str, &str)]) -> String {\n"
      io << "    params.iter().map(|(k, v)| format!(\"{}[{}]={}\", model, k, v)).collect::<Vec<_>>().join(\"&\")\n"
      io << "}\n\n"

      # Generate test functions
      Dir.glob(File.join(rails_test_dir, "*_test.rb")).sort.each do |path|
        basename = File.basename(path, "_test.rb")
        controller_name = basename.chomp("_controller")
        singular = Inflector.singularize(controller_name)
        plural = Inflector.pluralize(controller_name)
        model_name = Inflector.classify(singular)

        ast = SourceParser.parse(path)
        emit_rust_controller_test_functions(io, model_name, singular, plural, ast)
      end

      File.write(File.join(tests_dir, "controller_tests.rs"), io.to_s)
      puts "  tests/controller_tests.rs"
    end

    private def emit_rust_controller_test_functions(io : IO, model_name : String, singular : String,
                                                     plural : String, ast : Crystal::ASTNode)
      class_body = find_class_body(ast)
      return unless class_body

      exprs = case class_body
              when Crystal::Expressions then class_body.expressions
              else [class_body]
              end

      # Extract setup block assignments
      setup_code = IO::Memory.new
      exprs.each do |expr|
        if expr.is_a?(Crystal::Call) && expr.as(Crystal::Call).name == "setup" && expr.as(Crystal::Call).block
          emit_rust_ctrl_test_body(expr.as(Crystal::Call).block.not_nil!.body, setup_code, model_name, singular, plural)
        end
      end
      setup_str = setup_code.to_s

      exprs.each do |expr|
        next unless expr.is_a?(Crystal::Call)
        call = expr.as(Crystal::Call)
        next unless call.name == "test" && call.args.size == 1 && call.block
        test_name = call.args[0].to_s.strip('"')
        rust_name = "test_" + test_name.downcase.gsub(" ", "_").gsub(/[^a-z0-9_]/, "")

        io << "#[tokio::test]\n"
        io << "async fn #{rust_name}() {\n"
        io << "    let server = setup_test();\n"
        io << "    let f = setup_ctrl_fixtures();\n"
        io << "    let _ = &f;\n\n"
        io << setup_str unless setup_str.empty?

        emit_rust_ctrl_test_body(call.block.not_nil!.body, io, model_name, singular, plural)

        io << "}\n\n"
      end
    end

    private def emit_rust_ctrl_test_body(node : Crystal::ASTNode, io : IO, model_name : String,
                                          singular : String, plural : String)
      exprs = case node
              when Crystal::Expressions then node.expressions
              else [node]
              end

      exprs.each do |expr|
        case expr
        when Crystal::Assign
          emit_rust_ctrl_test_assign(expr, io, model_name, singular, plural)
        when Crystal::Call
          emit_rust_ctrl_test_call(expr, io, model_name, singular, plural)
        end
      end
    end

    private def emit_rust_ctrl_test_assign(node : Crystal::Assign, io : IO, model_name : String,
                                            singular : String, plural : String)
      target = node.target
      value = node.value
      var_name = case target
                 when Crystal::InstanceVar then target.name.lchop("@")
                 when Crystal::Var then target.name
                 else target.to_s
                 end

      if value.is_a?(Crystal::Call) && value.args.size == 1 && value.args[0].is_a?(Crystal::SymbolLiteral)
        func = value.name
        label = value.args[0].as(Crystal::SymbolLiteral).value
        io << "    let #{var_name} = &f.#{func}_#{label};\n"
      end
    end

    private def emit_rust_ctrl_test_call(node : Crystal::Call, io : IO, model_name : String,
                                          singular : String, plural : String)
      name = node.name
      args = node.args

      case name
      when "get"
        url = rust_url_expr(args[0], singular, plural)
        io << "    let resp = server.get(&#{url}).await;\n"
      when "post"
        url = rust_url_expr(args[0], singular, plural)
        params_node = args[1]? || node.named_args.try(&.find { |na| na.name == "params" }).try(&.value)
        if params_node
          params = rust_form_params(params_node, singular)
          io << "    let resp = server.post(&#{url}).form(&#{params}).await;\n"
        else
          io << "    let resp = server.post(&#{url}).await;\n"
        end
      when "patch"
        url = rust_url_expr(args[0], singular, plural)
        params_node = args[1]? || node.named_args.try(&.find { |na| na.name == "params" }).try(&.value)
        if params_node
          params = rust_form_params(params_node, singular)
          io << "    let resp = server.patch(&#{url}).form(&#{params}).await;\n"
        else
          io << "    let resp = server.patch(&#{url}).await;\n"
        end
      when "delete"
        url = rust_url_expr(args[0], singular, plural)
        io << "    let resp = server.delete(&#{url}).await;\n"
      when "assert_response"
        status = args[0].to_s.strip(':')
        case status
        when "success"
          io << "    resp.assert_status_ok();\n"
        when "unprocessable_entity"
          io << "    assert_eq!(resp.status_code(), 422);\n"
        end
      when "assert_redirected_to"
        io << "    assert!(resp.status_code().is_redirection());\n"
      when "assert_select"
        if args.size >= 2 && args[1].is_a?(Crystal::StringLiteral)
          text = args[1].as(Crystal::StringLiteral).value
          io << "    assert!(resp.text().contains(\"#{text}\"), \"expected body to contain \\\"#{text}\\\"\");\n"
        elsif args.size >= 1
          selector = args[0].to_s.strip('"')
          if selector.starts_with?("#")
            id = selector.lchop("#").split(" ").first
            io << "    assert!(resp.text().contains(\"id=\\\"#{id}\\\"\"), \"expected body to contain id=#{id}\");\n"
          else
            io << "    assert!(resp.text().contains(\"<#{selector}\"), \"expected body to contain <#{selector}\");\n"
          end
        end
      when "assert_equal"
        if args.size == 2
          expected = rust_ctrl_test_expr(args[0], singular, plural)
          actual = rust_ctrl_test_expr(args[1], singular, plural)
          io << "    assert_eq!(#{actual}, #{expected});\n"
        end
      when "assert_difference", "assert_no_difference"
        if args.size >= 1 && node.block
          count_expr = args[0].to_s.strip('"')
          model = count_expr.split(".").first
          model_singular = Inflector.underscore(model)
          diff = args.size > 1 ? args[1].to_s.to_i : (name == "assert_difference" ? 1 : 0)
          io << "    let before_count = #{model_singular}_count().unwrap();\n"
          emit_rust_ctrl_test_body(node.block.not_nil!.body, io, model_name, singular, plural)
          io << "    let after_count = #{model_singular}_count().unwrap();\n"
          if name == "assert_difference"
            if diff >= 0
              io << "    assert_eq!(after_count - before_count, #{diff});\n"
            else
              io << "    assert_eq!(before_count - after_count, #{-diff});\n"
            end
          else
            io << "    assert_eq!(after_count, before_count);\n"
          end
        end
      else
        if obj = node.obj
          obj_str = rust_expr(obj)
          if name == "reload"
            cls = Inflector.classify(obj_str)
            singular_name = Inflector.underscore(cls)
            io << "    let #{obj_str} = find_#{singular_name}(#{obj_str}.id).unwrap();\n"
          end
        end
      end
    end

    private def rust_ctrl_test_expr(node : Crystal::ASTNode, singular : String, plural : String) : String
      case node
      when Crystal::Call
        obj = node.obj
        name = node.name
        # Model.last → model_last().unwrap()
        if obj.is_a?(Crystal::Call) && obj.as(Crystal::Call).name == "last" && obj.as(Crystal::Call).obj.is_a?(Crystal::Path)
          model_path = obj.as(Crystal::Call).obj.as(Crystal::Path).names.last
          model_singular = Inflector.underscore(model_path)
          return "#{model_singular}_last().unwrap().#{name}"
        end
        # Model.last → model_last().unwrap()
        if name == "last" && obj.is_a?(Crystal::Path)
          model_singular = Inflector.underscore(obj.as(Crystal::Path).names.last)
          return "#{model_singular}_last().unwrap()"
        end
        # Chained field access
        if obj
          return "#{rust_ctrl_test_expr(obj, singular, plural)}.#{name}"
        end
      end
      rust_expr(node)
    end

    private def rust_url_expr(node : Crystal::ASTNode, singular : String, plural : String) : String
      case node
      when Crystal::Call
        name = node.name
        # Strip _url suffix if present, convert to _path
        if name.ends_with?("_url")
          name = name.chomp("_url") + "_path"
        end
        # Already ends with _path — use directly
        if name.ends_with?("_path")
          args = node.args.map { |a| rust_expr(a) }
          if args.empty?
            return "helpers::#{name}()"
          else
            return "helpers::#{name}(#{args.map { |a| "#{a}.id" }.join(", ")})"
          end
        end
        # Bare URL-like calls: articles_url → helpers::articles_path()
        return "helpers::#{name.chomp("_url")}_path()"
      when Crystal::StringLiteral
        return "\"#{node.value}\".to_string()"
      else
        return "\"/\".to_string()"
      end
    end

    private def rust_form_params(node : Crystal::ASTNode, singular : String) : String
      # Extract { model: { field: value, ... } } hash → HashMap for .form()
      if node.is_a?(Crystal::HashLiteral)
        entries = node.as(Crystal::HashLiteral).entries
        if entries.size == 1
          model_key = entries[0].key.to_s.strip('"').strip(':')
          inner = entries[0].value
          if inner.is_a?(Crystal::HashLiteral)
            params = inner.as(Crystal::HashLiteral).entries.map do |e|
              key = e.key.to_s.strip('"').strip(':')
              value = case e.value
                      when Crystal::StringLiteral then e.value.as(Crystal::StringLiteral).value
                      when Crystal::NumberLiteral then e.value.to_s
                      else e.value.to_s
                      end
              "(\"#{model_key}[#{key}]\".to_string(), \"#{value}\".to_string())"
            end
            return "HashMap::from([#{params.join(", ")}])"
          end
        end
      end
      "HashMap::<String, String>::new()"
    end
  end
end
