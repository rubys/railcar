# GoGenerator — orchestrates Go generation from Rails app via Crystal AST.
#
# Pipeline:
#   1. Build Crystal AST: runtime source + model ASTs (via filter chain)
#   2. program.semantic() → types on all nodes
#   3. Emit models via Cr2Go emitter, tests via Prism AST walking
#
# Target: net/http + database/sql + modernc.org/sqlite + html/template.

require "./app_model"
require "./schema_extractor"
require "./inflector"
require "./source_parser"
require "./fixture_loader"
require "../semantic"
require "../filters/model_boilerplate_python"
require "../filters/broadcasts_to"
require "../filters/shared_controller_filters"
require "../filters/instance_var_to_local"
require "../filters/rails_helpers"
require "../filters/link_to_path_helper"
require "../filters/button_to_path_helper"
require "../filters/render_to_partial"
require "../filters/form_to_html"
require "../filters/turbo_stream_connect"
require "../emitter/go/cr2go"
require "./gotemplate_converter"

module Railcar
  class GoGenerator
    getter app : AppModel
    getter rails_dir : String

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      puts "Generating Go from #{rails_dir}..."
      Dir.mkdir_p(output_dir)

      app_name = app.name.downcase.gsub("-", "_")

      # Build model ASTs through shared filter chain
      model_asts = build_model_asts

      emit_go_mod(output_dir, app_name)
      emit_runtime(output_dir)
      emit_helpers(output_dir, app_name)
      emit_models(output_dir, app_name, model_asts)
      emit_views(output_dir, app_name)
      emit_controllers(output_dir, app_name)
      emit_app(output_dir, app_name)
      copy_static_assets(output_dir)
      emit_model_tests(output_dir, app_name)
      emit_controller_tests(output_dir, app_name)

      puts "Done! Output in #{output_dir}/"
      puts "  cd #{output_dir} && go mod tidy && go test ./..."
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

        # Same filter chain as Python/TypeScript
        ast = SourceParser.parse(source_path)
        ast = ast.transform(BroadcastsTo.new)
        ast = ast.transform(ModelBoilerplatePython.new(schema, model))

        asts[name] = ast
      end
      asts
    end

    # ── go.mod ──

    private def emit_go_mod(output_dir : String, app_name : String)
      File.write(File.join(output_dir, "go.mod"), <<-MOD)
      module #{app_name}

      go 1.21

      require modernc.org/sqlite v1.37.1
      MOD
      puts "  go.mod"
    end

    # ── Runtime ──

    private def emit_runtime(output_dir : String)
      runtime_src = File.join(File.dirname(__FILE__), "..", "runtime", "go", "railcar.go")
      Dir.mkdir_p(File.join(output_dir, "railcar"))
      File.copy(runtime_src, File.join(output_dir, "railcar", "railcar.go"))
      puts "  railcar/railcar.go"
    end

    # ── Models (AST-based) ──

    private def emit_models(output_dir : String, app_name : String, model_asts : Hash(String, Crystal::ASTNode))
      models_dir = File.join(output_dir, "models")
      Dir.mkdir_p(models_dir)

      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      emitter = Cr2Go::Emitter.new

      model_asts.each do |name, ast|
        next unless ast.is_a?(Crystal::ClassDef)
        table_name = Inflector.pluralize(Inflector.underscore(name))
        schema = schema_map[table_name]?
        next unless schema

        source = emitter.emit_model(ast.as(Crystal::ClassDef), name, schema, app_name)
        singular = Inflector.underscore(name)

        File.write(File.join(models_dir, "#{singular}.go"), source)
        puts "  models/#{singular}.go"
      end
    end

    # ── Helpers ──

    private def emit_helpers(output_dir : String, app_name : String)
      helpers_dir = File.join(output_dir, "helpers")
      Dir.mkdir_p(helpers_dir)

      io = IO::Memory.new
      io << "package helpers\n\n"
      io << "import (\n"
      io << "\t\"fmt\"\n"
      io << "\t\"html/template\"\n"
      io << "\t\"net/http\"\n"
      io << "\t\"net/url\"\n"
      io << "\t\"path/filepath\"\n"
      io << "\t\"strings\"\n"
      io << ")\n\n"

      io << "var Templates *template.Template\n\n"

      io << "func InitTemplates() {\n"
      io << "\tfuncMap := template.FuncMap{\n"
      io << "\t\t\"linkTo\":          LinkTo,\n"
      io << "\t\t\"buttonTo\":        ButtonTo,\n"
      io << "\t\t\"turboStreamFrom\": TurboStreamFrom,\n"
      io << "\t\t\"truncate\":        Truncate,\n"
      io << "\t\t\"domID\":           DomID,\n"
      io << "\t\t\"pluralize\":       Pluralize,\n"
      io << "\t\t\"formWithOpenTag\": FormWithOpenTag,\n"
      io << "\t\t\"formSubmitTag\":   FormSubmitTag,\n"

      # Route helper functions
      app.routes.helpers.each do |helper|
        func_name = helper.name.split("_").map(&.capitalize).join("")
        func_name = func_name[0].downcase + func_name[1..] + "Path"
        io << "\t\t#{func_name.inspect}: #{func_name.capitalize[0]}#{func_name[1..]}Func,\n"
      end

      io << "\t}\n"
      io << "\tt := template.New(\"\").Funcs(funcMap)\n"
      io << "\tglobs := []string{\"templates/*/*.gohtml\", \"templates/*.gohtml\", \"templates/*/*/*.gohtml\"}\n"
      io << "\tfor _, g := range globs {\n"
      io << "\t\tif files, _ := filepath.Glob(g); len(files) > 0 {\n"
      io << "\t\t\tvar err error\n"
      io << "\t\t\tt, err = t.ParseGlob(g)\n"
      io << "\t\t\tif err != nil { fmt.Println(\"Template parse error:\", err); }\n"
      io << "\t\t}\n"
      io << "\t}\n"
      io << "\tTemplates = t\n"
      io << "}\n\n"

      # Route helpers
      app.routes.helpers.each do |helper|
        func_name = helper.name.split("_").map(&.capitalize).join("") + "Path"
        if helper.params.empty?
          io << "func #{func_name}() string { return #{helper.path.inspect} }\n"
          io << "func #{func_name}Func() string { return #{helper.path.inspect} }\n\n"
        else
          param_names = helper.params.map_with_index do |p, i|
            p == "id" ? (i == 0 ? "model" : "child") : p.chomp("_id")
          end

          # Function version for controllers (takes struct)
          first_with_params = app.routes.helpers.find { |h| !h.params.empty? }
          io << "type HasID interface { ID() int64 }\n" if helper.params.size == 1 && first_with_params && helper == first_with_params
          io << "func #{func_name}(args ...HasID) string {\n"
          path_parts = helper.path.split("/")
          path_expr = path_parts.map_with_index do |part, i|
            if part.starts_with?(":")
              param_idx = helper.params.index(part.lchop(":"))
              param_idx ? "%d" : part
            else
              part
            end
          end.join("/")
          format_args = helper.params.map_with_index { |_, i| "args[#{i}].ID()" }.join(", ")
          io << "\treturn fmt.Sprintf(#{path_expr.inspect}, #{format_args})\n"
          io << "}\n\n"

          # FuncMap version (same)
          io << "func #{func_name}Func(args ...HasID) string { return #{func_name}(args...) }\n\n"
        end
      end

      # View helpers
      io << <<-GO
      func LinkTo(text, url string, args ...string) template.HTML {
        cls := ""
        if len(args) > 0 { cls = fmt.Sprintf(` class="%s"`, args[0]) }
        return template.HTML(fmt.Sprintf(`<a href="%s"%s>%s</a>`, url, cls, text))
      }

      func ButtonTo(text, url string, args ...string) template.HTML {
        method := "post"
        cls := ""
        confirm := ""
        for i, a := range args {
          switch i {
          case 0: method = a
          case 1: cls = fmt.Sprintf(` class="%s"`, a)
          case 2: confirm = fmt.Sprintf(` data-turbo-confirm="%s"`, a)
          }
        }
        return template.HTML(fmt.Sprintf(`<form method="post" action="%s"%s><input type="hidden" name="_method" value="%s"><button type="submit"%s>%s</button></form>`, url, confirm, method, cls, text))
      }

      func TurboStreamFrom(channel string) template.HTML {
        return template.HTML(fmt.Sprintf(`<turbo-cable-stream-source channel="Turbo::StreamsChannel" signed-stream-name="%s"></turbo-cable-stream-source>`, channel))
      }

      func Truncate(text string, args ...int) string {
        length := 30
        if len(args) > 0 { length = args[0] }
        if len(text) <= length { return text }
        if length <= 3 { return text[:length] }
        return text[:length-3] + "..."
      }

      type HasIDAndName interface {
        ID() int64
      }

      func DomID(obj HasIDAndName, args ...string) string {
        name := strings.ToLower(fmt.Sprintf("%T", obj))
        if i := strings.LastIndex(name, "."); i >= 0 { name = name[i+1:] }
        name = strings.TrimPrefix(name, "*")
        if len(args) > 0 { return fmt.Sprintf("%s_%s_%d", args[0], name, obj.ID()) }
        return fmt.Sprintf("%s_%d", name, obj.ID())
      }

      func Pluralize(count int, singular string) string {
        if count == 1 { return fmt.Sprintf("%d %s", count, singular) }
        return fmt.Sprintf("%d %ss", count, singular)
      }

      func FormWithOpenTag(obj HasIDAndName, args ...string) template.HTML {
        name := strings.ToLower(fmt.Sprintf("%T", obj))
        if i := strings.LastIndex(name, "."); i >= 0 { name = name[i+1:] }
        name = strings.TrimPrefix(name, "*")
        plural := name + "s"
        cls := ""
        if len(args) > 0 { cls = fmt.Sprintf(` class="%s"`, args[0]) }
        if obj.ID() > 0 {
          return template.HTML(fmt.Sprintf(`<form action="/%s/%d" method="post"%s><input type="hidden" name="_method" value="patch">`, plural, obj.ID(), cls))
        }
        return template.HTML(fmt.Sprintf(`<form action="/%s" method="post"%s>`, plural, cls))
      }

      func FormSubmitTag(obj HasIDAndName, args ...string) template.HTML {
        name := fmt.Sprintf("%T", obj)
        if i := strings.LastIndex(name, "."); i >= 0 { name = name[i+1:] }
        name = strings.TrimPrefix(name, "*")
        cls := ""
        if len(args) > 0 { cls = fmt.Sprintf(` class="%s"`, args[0]) }
        action := "Create"
        if obj.ID() > 0 { action = "Update" }
        return template.HTML(fmt.Sprintf(`<input type="submit" value="%s %s"%s>`, action, name, cls))
      }

      func RenderView(w http.ResponseWriter, tmpl string, data map[string]any) {
        RenderViewStatus(w, tmpl, data, 200)
      }

      func RenderViewStatus(w http.ResponseWriter, tmpl string, data map[string]any, status int) {
        // Render the content template
        var content strings.Builder
        name := "templates/" + tmpl + ".gohtml"
        if err := Templates.ExecuteTemplate(&content, name, data); err != nil {
          http.Error(w, err.Error(), 500)
          return
        }
        // Render layout
        layoutData := map[string]any{"Title": "Blog", "Content": template.HTML(content.String())}
        w.Header().Set("Content-Type", "text/html")
        w.WriteHeader(status)
        Templates.ExecuteTemplate(w, "templates/layouts/application.gohtml", layoutData)
      }

      func ExtractModelParams(form url.Values, model string) map[string]any {
        result := map[string]any{}
        prefix := model + "["
        for key, values := range form {
          if strings.HasPrefix(key, prefix) && strings.HasSuffix(key, "]") {
            field := key[len(prefix) : len(key)-1]
            result[field] = values[0]
          }
        }
        return result
      }

      var _ = filepath.Base
      GO

      File.write(File.join(helpers_dir, "helpers.go"), io.to_s)
      puts "  helpers/helpers.go"
    end

    # ── Views ──

    private def emit_views(output_dir : String, app_name : String)
      rails_views = File.join(rails_dir, "app/views")

      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        template_dir = File.join(rails_views, Inflector.pluralize(controller_name))
        next unless Dir.exists?(template_dir)

        views_dir = File.join(output_dir, "templates/#{Inflector.pluralize(controller_name)}")
        Dir.mkdir_p(views_dir)

        Dir.glob(File.join(template_dir, "*.html.erb")).sort.each do |erb_path|
          filename = File.basename(erb_path)
          basename = filename.sub(/\.html\.erb$/, "")
          tmpl_name = "#{basename}.gohtml"

          tmpl_source = GoTemplateConverter.convert_file(erb_path, basename, controller_name,
            view_filters: build_view_filters, known_fields: all_column_names)

          File.write(File.join(views_dir, tmpl_name), tmpl_source)
          puts "  templates/#{Inflector.pluralize(controller_name)}/#{tmpl_name}"
        end
      end

      # Layout template
      layout_dir = File.join(output_dir, "templates/layouts")
      Dir.mkdir_p(layout_dir)
      File.write(File.join(layout_dir, "application.gohtml"), generate_layout)
      puts "  templates/layouts/application.gohtml"
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

    private def all_column_names : Set(String)
      fields = Set(String).new
      app.schemas.each do |schema|
        schema.columns.each { |c| fields << c.name }
      end
      fields
    end

    private def generate_layout : String
      <<-GOHTML
      <!DOCTYPE html>
      <html>
      <head>
        <title>{{.Title}}</title>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="action-cable-url" content="/cable">
        <link rel="stylesheet" href="/static/app.css">
        <script type="module" src="/static/turbo.min.js"></script>
      </head>
      <body>
        <main class="container mx-auto mt-28 px-5 flex flex-col">
          {{.Content}}
        </main>
      </body>
      </html>
      GOHTML
    end

    # ── Controllers ──

    private def emit_controllers(output_dir : String, app_name : String)
      controllers_dir = File.join(output_dir, "controllers")
      Dir.mkdir_p(controllers_dir)

      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        singular = Inflector.singularize(controller_name)
        plural = Inflector.pluralize(controller_name)
        model_name = Inflector.classify(singular)
        nested_parent = app.routes.nested_parent_for(plural)

        io = IO::Memory.new
        io << "package controllers\n\n"
        io << "import (\n"
        io << "\t\"net/http\"\n"
        io << "\t\"strconv\"\n"
        io << "\t\"#{app_name}/models\"\n"
        io << "\t\"#{app_name}/helpers\"\n"
        io << ")\n\n"

        info.actions.each do |action|
          next if action.is_private
          emit_controller_action(action.name, io, model_name, singular, plural, nested_parent)
        end

        io << "var _ = strconv.Atoi\n"

        out_path = File.join(controllers_dir, "#{controller_name}.go")
        File.write(out_path, io.to_s)
        puts "  controllers/#{controller_name}.go"
      end
    end

    private def emit_controller_action(action_name : String, io : IO, model_name : String,
                                        singular : String, plural : String, nested_parent : String?)
      cap = singular.capitalize
      case action_name
      when "index"
        io << "func Index(w http.ResponseWriter, r *http.Request) {\n"
        io << "\t#{plural}, _ := models.All#{model_name}s(\"created_at DESC\")\n"
        io << "\thelpers.RenderView(w, \"#{plural}/index\", map[string]any{\"#{plural}\": #{plural}})\n"
        io << "}\n\n"
      when "show"
        io << "func Show#{cap}(w http.ResponseWriter, r *http.Request) {\n"
        io << "\tid, _ := strconv.ParseInt(r.PathValue(\"id\"), 10, 64)\n"
        io << "\t#{singular}, _ := models.Find#{model_name}(id)\n"
        io << "\thelpers.RenderView(w, \"#{plural}/show\", map[string]any{\"#{singular}\": #{singular}})\n"
        io << "}\n\n"
      when "new"
        io << "func New#{cap}(w http.ResponseWriter, r *http.Request) {\n"
        io << "\t#{singular} := models.New#{model_name}()\n"
        io << "\thelpers.RenderView(w, \"#{plural}/new\", map[string]any{\"#{singular}\": #{singular}})\n"
        io << "}\n\n"
      when "edit"
        io << "func Edit#{cap}(w http.ResponseWriter, r *http.Request) {\n"
        io << "\tid, _ := strconv.ParseInt(r.PathValue(\"id\"), 10, 64)\n"
        io << "\t#{singular}, _ := models.Find#{model_name}(id)\n"
        io << "\thelpers.RenderView(w, \"#{plural}/edit\", map[string]any{\"#{singular}\": #{singular}})\n"
        io << "}\n\n"
      when "create"
        if nested_parent
          parent_model = Inflector.classify(nested_parent)
          io << "func Create#{cap}(w http.ResponseWriter, r *http.Request) {\n"
          io << "\tr.ParseForm()\n"
          io << "\tparentId, _ := strconv.ParseInt(r.PathValue(\"#{nested_parent}_id\"), 10, 64)\n"
          io << "\t#{nested_parent}, _ := models.Find#{parent_model}(parentId)\n"
          io << "\tattrs := helpers.ExtractModelParams(r.Form, \"#{singular}\")\n"
          io << "\tattrs[\"#{nested_parent}_id\"] = #{nested_parent}.Id\n"
          io << "\t_, err := models.Create#{model_name}(attrs)\n"
          io << "\tif err != nil {\n"
          io << "\t\thttp.Redirect(w, r, helpers.#{parent_model}Path(#{nested_parent}), http.StatusFound)\n"
          io << "\t\treturn\n"
          io << "\t}\n"
          io << "\thttp.Redirect(w, r, helpers.#{parent_model}Path(#{nested_parent}), http.StatusFound)\n"
          io << "}\n\n"
        else
          io << "func Create#{cap}(w http.ResponseWriter, r *http.Request) {\n"
          io << "\tr.ParseForm()\n"
          io << "\tattrs := helpers.ExtractModelParams(r.Form, \"#{singular}\")\n"
          io << "\t#{singular}, err := models.Create#{model_name}(attrs)\n"
          io << "\tif err != nil {\n"
          io << "\t\thelpers.RenderViewStatus(w, \"#{plural}/new\", map[string]any{\"#{singular}\": #{singular}}, 422)\n"
          io << "\t\treturn\n"
          io << "\t}\n"
          io << "\thttp.Redirect(w, r, helpers.#{model_name}Path(#{singular}), http.StatusFound)\n"
          io << "}\n\n"
        end
      when "update"
        io << "func Update#{cap}(w http.ResponseWriter, r *http.Request) {\n"
        io << "\tr.ParseForm()\n"
        io << "\tid, _ := strconv.ParseInt(r.PathValue(\"id\"), 10, 64)\n"
        io << "\t#{singular}, _ := models.Find#{model_name}(id)\n"
        io << "\tattrs := helpers.ExtractModelParams(r.Form, \"#{singular}\")\n"
        io << "\terr := #{singular}.Update(attrs)\n"
        io << "\tif err != nil {\n"
        io << "\t\thelpers.RenderViewStatus(w, \"#{plural}/edit\", map[string]any{\"#{singular}\": #{singular}}, 422)\n"
        io << "\t\treturn\n"
        io << "\t}\n"
        io << "\thttp.Redirect(w, r, helpers.#{model_name}Path(#{singular}), http.StatusFound)\n"
        io << "}\n\n"
      when "destroy"
        if nested_parent
          parent_model = Inflector.classify(nested_parent)
          io << "func Destroy#{cap}(w http.ResponseWriter, r *http.Request) {\n"
          io << "\tparentId, _ := strconv.ParseInt(r.PathValue(\"#{nested_parent}_id\"), 10, 64)\n"
          io << "\t#{nested_parent}, _ := models.Find#{parent_model}(parentId)\n"
          io << "\tchildId, _ := strconv.ParseInt(r.PathValue(\"id\"), 10, 64)\n"
          io << "\t#{singular}, _ := models.Find#{model_name}(childId)\n"
          io << "\t#{singular}.Delete()\n"
          io << "\thttp.Redirect(w, r, helpers.#{parent_model}Path(#{nested_parent}), http.StatusFound)\n"
          io << "}\n\n"
        else
          io << "func Destroy#{cap}(w http.ResponseWriter, r *http.Request) {\n"
          io << "\tid, _ := strconv.ParseInt(r.PathValue(\"id\"), 10, 64)\n"
          io << "\t#{singular}, _ := models.Find#{model_name}(id)\n"
          io << "\t#{singular}.Delete()\n"
          io << "\thttp.Redirect(w, r, helpers.#{Inflector.classify(plural)}Path(), http.StatusFound)\n"
          io << "}\n\n"
        end
      end
    end

    # ── App entry point ──

    private def emit_app(output_dir : String, app_name : String)
      io = IO::Memory.new
      io << "package main\n\n"
      io << "import (\n"
      io << "\t\"database/sql\"\n"
      io << "\t\"fmt\"\n"
      io << "\t\"log\"\n"
      io << "\t\"net/http\"\n"
      io << "\t\"#{app_name}/controllers\"\n"
      io << "\t\"#{app_name}/helpers\"\n"
      io << "\t\"#{app_name}/models\"\n"
      io << "\t\"#{app_name}/railcar\"\n"
      io << "\t_ \"modernc.org/sqlite\"\n"
      io << ")\n\n"

      # DB init
      io << "func initDB() *sql.DB {\n"
      io << "\tdb, err := sql.Open(\"sqlite\", \"#{app_name}.db\")\n"
      io << "\tif err != nil { log.Fatal(err) }\n"
      io << "\tdb.Exec(\"PRAGMA foreign_keys = ON\")\n"
      app.schemas.each do |schema|
        all_cols = [{name: "id", type: "INTEGER"}]
        schema.columns.each { |c| all_cols << {name: c.name, type: c.type} }
        col_defs = all_cols.map do |c|
          parts = "#{c[:name]} #{c[:type]}"
          parts += " PRIMARY KEY AUTOINCREMENT" if c[:name] == "id"
          parts += " NOT NULL" unless c[:name] == "id"
          parts
        end
        io << "\tdb.Exec(`CREATE TABLE IF NOT EXISTS #{schema.name} (\n"
        io << "\t\t#{col_defs.join(",\n\t\t")}\n"
        io << "\t)`)\n"
      end
      io << "\trailcar.DB = db\n"
      io << "\treturn db\n"
      io << "}\n\n"

      # Seed data
      seeds_path = File.join(rails_dir, "db/seeds.rb")
      io << "func seedDB() {\n"
      io << "\tcount, _ := models.ArticleCount()\n"
      io << "\tif count > 0 { return }\n"
      if File.exists?(seeds_path)
        emit_seeds(io, seeds_path)
      end
      io << "}\n\n"

      # Main
      io << "func main() {\n"
      io << "\tdb := initDB()\n"
      io << "\tdefer db.Close()\n"
      io << "\tseedDB()\n"
      io << "\thelpers.InitTemplates()\n\n"

      # Routes
      io << "\tmux := http.NewServeMux()\n"
      io << "\tmux.Handle(\"/static/\", http.StripPrefix(\"/static/\", http.FileServer(http.Dir(\"static\"))))\n\n"

      # Routes from AppModel
      app.routes.routes.each do |route|
        singular = Inflector.singularize(route.controller)
        model_name = Inflector.classify(singular)
        handler = case route.action
                  when "index"   then "controllers.Index"
                  when "show"    then "controllers.Show#{singular.capitalize}"
                  when "new"     then "controllers.New#{singular.capitalize}"
                  when "edit"    then "controllers.Edit#{singular.capitalize}"
                  when "create"  then "controllers.Create#{singular.capitalize}"
                  when "update"  then "controllers.Update#{singular.capitalize}"
                  when "destroy" then "controllers.Destroy#{singular.capitalize}"
                  else next
                  end

        go_path = route.path.gsub(/:(\w+)/, "{\\1}")
        go_method = route.method.upcase

        io << "\tmux.HandleFunc(\"#{go_method} #{go_path}\", #{handler})\n"
      end

      # Root route
      if root_ctrl = app.routes.root_controller
        io << "\tmux.HandleFunc(\"GET /\", controllers.Index)\n"
      end

      # _method dispatch for POST
      io << "\n\t// Wrap mux with _method dispatch\n"
      io << "\thandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {\n"
      io << "\t\tif r.Method == \"POST\" {\n"
      io << "\t\t\tr.ParseForm()\n"
      io << "\t\t\tif method := r.FormValue(\"_method\"); method != \"\" {\n"
      io << "\t\t\t\tr.Method = method\n"
      io << "\t\t\t}\n"
      io << "\t\t}\n"
      io << "\t\tmux.ServeHTTP(w, r)\n"
      io << "\t})\n\n"

      io << "\tfmt.Println(\"#{app_name} running at http://localhost:3000\")\n"
      io << "\tlog.Fatal(http.ListenAndServe(\":3000\", handler))\n"
      io << "}\n\n"

      io << "var _ = models.NewArticle\n"

      File.write(File.join(output_dir, "main.go"), io.to_s)
      puts "  main.go"
    end

    private def emit_seeds(io : IO, seeds_path : String)
      source = File.read(seeds_path)
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

      joined.each_with_index do |stmt, idx|
        case stmt
        when /^(\w+)\s*=\s*(\w+)\.create!\(\s*(.+)\s*\)$/m
          var_name = $1
          model = $2
          # Convert Ruby hash syntax to Go map: title: "foo" → "title": "foo"
          # Only match keys at word boundaries before `: "` (not inside strings)
          attrs = $3.gsub(/\s+/, " ").gsub(/(?<=\A|,\s)(\w+):\s*/) { |m| "\"#{$1}\": " }
          used = joined[(idx + 1)..].any? { |s| s.includes?(var_name) }
          if used
            io << "\t#{var_name}, _ := models.Create#{model}(map[string]any{#{attrs}})\n"
          else
            io << "\tmodels.Create#{model}(map[string]any{#{attrs}})\n"
          end
        when /^(\w+)\.(\w+)\.create!\(\s*(.+)\s*\)$/m
          parent = $1
          assoc = $2
          attrs = $3.gsub(/\s+/, " ").gsub(/(?<=\A|,\s)(\w+):\s*/) { |m| "\"#{$1}\": " }
          singular = Inflector.singularize(assoc)
          model = Inflector.classify(singular)
          # Strip trailing digits from variable name to get model name (article1 → article)
          parent_model_name = parent.gsub(/\d+$/, "")
          fk = "#{parent_model_name}_id"
          io << "\tmodels.Create#{model}(map[string]any{#{attrs}, \"#{fk}\": #{parent}.Id})\n"
        end
      end
    end

    # ── Helpers package ──

    # Note: helpers will be generated as part of emit_app or as a separate package
    # For now, emit a helpers package with route helpers and view rendering

    private def emit_helpers_package(output_dir : String, app_name : String)
      # This would be called from generate — adding it to the emit chain
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

      models_dir = File.join(output_dir, "models")
      Dir.mkdir_p(models_dir)

      emit_test_helper(models_dir, app_name)

      Dir.glob(File.join(rails_test_dir, "*_test.rb")).sort.each do |path|
        basename = File.basename(path, "_test.rb")
        model_name = Inflector.classify(basename)

        ast = SourceParser.parse(path)
        emit_model_test_file(models_dir, app_name, model_name, basename, ast)
      end
    end

    private def emit_test_helper(models_dir : String, app_name : String)
      io = IO::Memory.new
      io << "package models\n\n"
      io << "import (\n"
      io << "\t\"database/sql\"\n"
      io << "\t\"testing\"\n"
      io << "\t\"#{app_name}/railcar\"\n"
      io << "\t_ \"modernc.org/sqlite\"\n"
      io << ")\n\n"

      io << "func setupTestDB(t *testing.T) *sql.DB {\n"
      io << "\tt.Helper()\n"
      io << "\tdb, err := sql.Open(\"sqlite\", \":memory:\")\n"
      io << "\tif err != nil { t.Fatal(err) }\n"
      io << "\tdb.Exec(\"PRAGMA foreign_keys = ON\")\n"

      app.schemas.each do |schema|
        all_cols = [{name: "id", type: "INTEGER"}]
        schema.columns.each { |c| all_cols << {name: c.name, type: c.type} }
        col_defs = all_cols.map do |c|
          parts = "#{c[:name]} #{c[:type]}"
          parts += " PRIMARY KEY AUTOINCREMENT" if c[:name] == "id"
          parts += " NOT NULL" unless c[:name] == "id"
          parts
        end
        io << "\tdb.Exec(`CREATE TABLE #{schema.name} (\n"
        io << "\t\t#{col_defs.join(",\n\t\t")}\n"
        io << "\t)`)\n"
      end

      io << "\trailcar.DB = db\n"
      io << "\treturn db\n"
      io << "}\n\n"

      # Fixtures struct and setup
      sorted_fixtures = FixtureLoader.sort_by_dependency(app.fixtures, app.models)

      io << "type fixtures struct {\n"
      sorted_fixtures.each do |table|
        singular = Inflector.singularize(table.name)
        model_name = Inflector.classify(singular)
        next unless app.models.has_key?(model_name)
        table.records.each do |record|
          io << "\t#{table.name}_#{record.label} *#{model_name}\n"
        end
      end
      io << "}\n\n"

      io << "func setupFixtures(t *testing.T) *fixtures {\n"
      io << "\tt.Helper()\n"
      io << "\tf := &fixtures{}\n"

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
              attrs << "\"#{field}_id\": f.#{ref_table}_#{value}.Id"
            else
              if value.match(/^\d+$/)
                attrs << "\"#{field}\": int64(#{value})"
              else
                attrs << "\"#{field}\": #{value.inspect}"
              end
            end
          end

          var_name = "#{table.name}_#{record.label}"
          io << "\tf.#{var_name}, _ = Create#{model_name}(map[string]any{#{attrs.join(", ")}})\n"
        end
      end

      io << "\treturn f\n"
      io << "}\n"

      File.write(File.join(models_dir, "test_helper_test.go"), io.to_s)
      puts "  models/test_helper_test.go"
    end

    private def emit_model_test_file(models_dir : String, app_name : String, model_name : String,
                                      basename : String, ast : Crystal::ASTNode)
      io = IO::Memory.new
      io << "package models\n\n"
      io << "import \"testing\"\n\n"

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
        go_name = "Test" + test_name.split(" ").map(&.capitalize).join("")

        io << "func #{go_name}(t *testing.T) {\n"
        io << "\tdb := setupTestDB(t)\n"
        io << "\tdefer db.Close()\n"
        io << "\tf := setupFixtures(t)\n"
        io << "\t_ = f\n\n"

        emit_go_test_body(call.block.not_nil!.body, io, model_name, basename)

        io << "}\n\n"
      end

      out_path = File.join(models_dir, "#{basename}_test.go")
      File.write(out_path, io.to_s)
      puts "  models/#{basename}_test.go"
    end

    private def emit_go_test_body(node : Crystal::ASTNode, io : IO, model_name : String, basename : String)
      singular = Inflector.underscore(model_name)
      plural = Inflector.pluralize(singular)

      exprs = case node
              when Crystal::Expressions then node.expressions
              else [node]
              end

      exprs.each do |expr|
        case expr
        when Crystal::Assign
          emit_go_test_assign(expr, io, model_name, singular, plural)
        when Crystal::Call
          emit_go_test_call(expr, io, model_name, singular, plural)
        end
      end
    end

    private def emit_go_test_assign(node : Crystal::Assign, io : IO, model_name : String,
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
        io << "\t#{var_name} := f.#{func}_#{label}\n"
      elsif value.is_a?(Crystal::Call) && value.name == "new" && value.obj
        obj_name = value.obj.not_nil!.to_s
        attrs = go_struct_attrs(value)
        io << "\t#{var_name} := &#{obj_name}{#{attrs}}\n"
      elsif value.is_a?(Crystal::Call) && value.name == "create" && value.obj.is_a?(Crystal::Call)
        parent_call = value.obj.as(Crystal::Call)
        if parent_call.obj
          parent_var = go_expr(parent_call.obj.not_nil!)
          child_model = Inflector.classify(Inflector.singularize(parent_call.name))
          parent_singular = Inflector.underscore(parent_var)
          fk = "#{parent_singular}_id"
          attrs = go_map_attrs(value)
          io << "\t#{var_name}, _ := Create#{child_model}(map[string]any{#{attrs}, #{fk.inspect}: #{parent_var}.Id})\n"
        end
      elsif value.is_a?(Crystal::Call) && value.name == "build" && value.obj.is_a?(Crystal::Call)
        parent_call = value.obj.as(Crystal::Call)
        if parent_call.obj
          parent_var = go_expr(parent_call.obj.not_nil!)
          child_model = Inflector.classify(Inflector.singularize(parent_call.name))
          parent_singular = Inflector.underscore(parent_var)
          fk = go_field_name("#{parent_singular}_id")
          attrs = go_struct_attrs(value)
          attrs_with_fk = attrs.empty? ? "#{fk}: #{parent_var}.Id" : "#{attrs}, #{fk}: #{parent_var}.Id"
          io << "\t#{var_name} := &#{child_model}{#{attrs_with_fk}}\n"
        end
      else
        io << "\t// TODO: #{node}\n"
      end
    end

    private def emit_go_test_call(node : Crystal::Call, io : IO, model_name : String,
                                   singular : String, plural : String)
      name = node.name
      args = node.args

      case name
      when "assert_not_nil"
        if args.size == 1
          io << "\tif #{go_expr(args[0])} == 0 { t.Error(\"expected non-zero ID\") }\n"
        end
      when "assert_equal"
        if args.size == 2
          expected = go_expr(args[0])
          actual = go_expr(args[1])
          io << "\tif #{actual} != #{expected} { t.Errorf(\"expected %v, got %v\", #{expected}, #{actual}) }\n"
        end
      when "assert_not"
        if args.size == 1 && args[0].is_a?(Crystal::Call) && args[0].as(Crystal::Call).name == "save"
          obj = args[0].as(Crystal::Call).obj
          obj_str = obj ? go_expr(obj) : singular
          io << "\tif err := #{obj_str}.Save(); err == nil { t.Error(\"expected save to fail\") }\n"
        end
      when "assert_difference"
        if args.size >= 1 && node.block
          count_expr = args[0].to_s.strip('"')
          model = count_expr.split(".").first
          diff = args.size > 1 ? args[1].to_s.to_i : 1
          io << "\tbeforeCount, _ := #{model}Count()\n"
          emit_go_test_body(node.block.not_nil!.body, io, model_name, singular)
          io << "\tafterCount, _ := #{model}Count()\n"
          io << "\tif afterCount - beforeCount != #{diff} { t.Errorf(\"expected count diff %d, got %d\", #{diff}, afterCount - beforeCount) }\n"
        end
      else
        if obj = node.obj
          obj_str = obj.to_s.lchop("@")
          if name == "destroy"
            io << "\t#{obj_str}.Delete()\n"
          end
        end
      end
    end

    # ── Controller tests ──

    private def emit_controller_tests(output_dir : String, app_name : String)
      rails_test_dir = File.join(rails_dir, "test/controllers")
      return unless Dir.exists?(rails_test_dir)

      controllers_dir = File.join(output_dir, "controllers")
      Dir.mkdir_p(controllers_dir)

      # Test setup helper
      emit_controller_test_helper(controllers_dir, app_name)

      Dir.glob(File.join(rails_test_dir, "*_test.rb")).sort.each do |path|
        basename = File.basename(path, "_test.rb")
        controller_name = basename.chomp("_controller")
        singular = Inflector.singularize(controller_name)
        model_name = Inflector.classify(singular)

        ast = SourceParser.parse(path)
        emit_controller_test_file(controllers_dir, app_name, model_name, controller_name, singular, ast)
      end
    end

    private def emit_controller_test_helper(controllers_dir : String, app_name : String)
      io = IO::Memory.new
      io << "package controllers\n\n"
      io << "import (\n"
      io << "\t\"database/sql\"\n"
      io << "\t\"net/http\"\n"
      io << "\t\"net/http/httptest\"\n"
      io << "\t\"net/url\"\n"
      io << "\t\"os\"\n"
      io << "\t\"strings\"\n"
      io << "\t\"testing\"\n"
      io << "\t\"#{app_name}/helpers\"\n"
      io << "\t\"#{app_name}/models\"\n"
      io << "\t\"#{app_name}/railcar\"\n"
      io << "\t_ \"modernc.org/sqlite\"\n"
      io << ")\n\n"

      io << "func setupControllerTest(t *testing.T) (*sql.DB, http.Handler) {\n"
      io << "\tt.Helper()\n"
      io << "\tdb, _ := sql.Open(\"sqlite\", \":memory:\")\n"
      io << "\tdb.Exec(\"PRAGMA foreign_keys = ON\")\n"

      app.schemas.each do |schema|
        all_cols = [{name: "id", type: "INTEGER"}]
        schema.columns.each { |c| all_cols << {name: c.name, type: c.type} }
        col_defs = all_cols.map do |c|
          parts = "#{c[:name]} #{c[:type]}"
          parts += " PRIMARY KEY AUTOINCREMENT" if c[:name] == "id"
          parts += " NOT NULL" unless c[:name] == "id"
          parts
        end
        io << "\tdb.Exec(`CREATE TABLE #{schema.name} (\n"
        io << "\t\t#{col_defs.join(",\n\t\t")}\n"
        io << "\t)`)\n"
      end

      io << "\trailcar.DB = db\n"
      io << "\tos.Chdir(\"..\")\n"
      io << "\thelpers.InitTemplates()\n\n"

      # Setup routes
      io << "\tmux := http.NewServeMux()\n"
      app.routes.routes.each do |route|
        singular = Inflector.singularize(route.controller)
        handler = case route.action
                  when "index"   then "Index"
                  when "show"    then "Show#{singular.capitalize}"
                  when "new"     then "New#{singular.capitalize}"
                  when "edit"    then "Edit#{singular.capitalize}"
                  when "create"  then "Create#{singular.capitalize}"
                  when "update"  then "Update#{singular.capitalize}"
                  when "destroy" then "Destroy#{singular.capitalize}"
                  else next
                  end
        go_path = route.path.gsub(/:(\w+)/, "{\\1}")
        io << "\tmux.HandleFunc(\"#{route.method.upcase} #{go_path}\", #{handler})\n"
      end
      if app.routes.root_controller
        io << "\tmux.HandleFunc(\"GET /\", Index)\n"
      end

      io << "\n\thandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {\n"
      io << "\t\tif r.Method == \"POST\" {\n"
      io << "\t\t\tr.ParseForm()\n"
      io << "\t\t\tif method := r.FormValue(\"_method\"); method != \"\" {\n"
      io << "\t\t\t\tr.Method = strings.ToUpper(method)\n"
      io << "\t\t\t}\n"
      io << "\t\t}\n"
      io << "\t\tmux.ServeHTTP(w, r)\n"
      io << "\t})\n\n"

      io << "\treturn db, handler\n"
      io << "}\n\n"

      # Fixtures
      sorted_fixtures = FixtureLoader.sort_by_dependency(app.fixtures, app.models)

      io << "type ctrlFixtures struct {\n"
      sorted_fixtures.each do |table|
        singular = Inflector.singularize(table.name)
        model_name = Inflector.classify(singular)
        next unless app.models.has_key?(model_name)
        table.records.each do |record|
          io << "\t#{table.name}_#{record.label} *models.#{model_name}\n"
        end
      end
      io << "}\n\n"

      io << "func setupCtrlFixtures(t *testing.T) *ctrlFixtures {\n"
      io << "\tt.Helper()\n"
      io << "\tf := &ctrlFixtures{}\n"
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
              attrs << "\"#{field}_id\": f.#{ref_table}_#{value}.Id"
            else
              if value.match(/^\d+$/)
                attrs << "\"#{field}\": int64(#{value})"
              else
                attrs << "\"#{field}\": #{value.inspect}"
              end
            end
          end
          io << "\tf.#{table.name}_#{record.label}, _ = models.Create#{model_name}(map[string]any{#{attrs.join(", ")}})\n"
        end
      end
      io << "\treturn f\n"
      io << "}\n\n"

      io << "func encodeParams(params map[string]map[string]string) string {\n"
      io << "\tvalues := url.Values{}\n"
      io << "\tfor outer, inner := range params {\n"
      io << "\t\tfor k, v := range inner {\n"
      io << "\t\t\tvalues.Set(outer+\"[\"+k+\"]\", v)\n"
      io << "\t\t}\n"
      io << "\t}\n"
      io << "\treturn values.Encode()\n"
      io << "}\n\n"

      io << "func doRequest(handler http.Handler, method, path string, body ...string) *httptest.ResponseRecorder {\n"
      io << "\tvar req *http.Request\n"
      io << "\tif len(body) > 0 {\n"
      io << "\t\treq = httptest.NewRequest(method, path, strings.NewReader(body[0]))\n"
      io << "\t\treq.Header.Set(\"Content-Type\", \"application/x-www-form-urlencoded\")\n"
      io << "\t} else {\n"
      io << "\t\treq = httptest.NewRequest(method, path, nil)\n"
      io << "\t}\n"
      io << "\tw := httptest.NewRecorder()\n"
      io << "\thandler.ServeHTTP(w, req)\n"
      io << "\treturn w\n"
      io << "}\n\n"

      io << "var _ = httptest.NewRequest\n"
      io << "var _ = strings.NewReader\n"

      File.write(File.join(controllers_dir, "test_helper_test.go"), io.to_s)
      puts "  controllers/test_helper_test.go"
    end

    private def emit_controller_test_file(controllers_dir : String, app_name : String,
                                           model_name : String, controller_name : String,
                                           singular : String, ast : Crystal::ASTNode)
      plural = Inflector.pluralize(singular)
      io = IO::Memory.new
      io << "package controllers\n\n"
      io << "import (\n"
      io << "\t\"fmt\"\n"
      io << "\t\"strings\"\n"
      io << "\t\"testing\"\n"
      io << "\t\"#{app_name}/helpers\"\n"
      io << "\t\"#{app_name}/models\"\n"
      io << ")\n\n"

      class_body = find_class_body(ast)
      return unless class_body

      exprs = case class_body
              when Crystal::Expressions then class_body.expressions
              else [class_body]
              end

      # Extract setup block
      setup_stmts = IO::Memory.new
      exprs.each do |expr|
        if expr.is_a?(Crystal::Call) && expr.as(Crystal::Call).name == "setup" && expr.as(Crystal::Call).block
          emit_go_test_body(expr.as(Crystal::Call).block.not_nil!.body, setup_stmts, model_name, singular)
        end
      end
      setup_code = setup_stmts.to_s

      exprs.each do |expr|
        next unless expr.is_a?(Crystal::Call)
        call = expr.as(Crystal::Call)
        next unless call.name == "test" && call.args.size == 1 && call.block
        test_name = call.args[0].to_s.strip('"')
        go_name = "Test" + test_name.split(" ").map(&.capitalize).join("")

        io << "func #{go_name}(t *testing.T) {\n"
        io << "\tdb, handler := setupControllerTest(t)\n"
        io << "\tdefer db.Close()\n"
        io << "\tf := setupCtrlFixtures(t)\n"
        io << "\t_ = f\n"
        io << "\t_ = handler\n\n"
        unless setup_code.empty?
          io << setup_code
          # Suppress unused variable errors for setup vars
          setup_code.scan(/\t(\w+) :=/) do |m|
            io << "\t_ = #{m[1]}\n"
          end
        end

        begin
          emit_controller_test_body(call.block.not_nil!.body, io, model_name, singular, plural)
        rescue ex
          STDERR.puts "  WARN: test #{test_name.inspect}: #{ex.message}"
          io << "\t// ERROR: #{ex.message}\n"
        end

        io << "}\n\n"
      end

      io << "var _ = fmt.Sprintf\n"
      io << "var _ = strings.Contains\n"
      io << "var _ = helpers.ArticlesPath\n"
      io << "var _ = models.ArticleCount\n"

      out_path = File.join(controllers_dir, "#{controller_name}_test.go")
      File.write(out_path, io.to_s)
      puts "  controllers/#{controller_name}_test.go"
    end

    private def emit_controller_test_body(node : Crystal::ASTNode, io : IO, model_name : String,
                                           singular : String, plural : String)
      exprs = case node
              when Crystal::Expressions then node.expressions
              else [node]
              end

      exprs.each do |expr|
        emit_controller_test_stmt(expr, io, model_name, singular, plural)
      end
    end

    private def emit_controller_test_stmt(node : Crystal::ASTNode, io : IO, model_name : String,
                                           singular : String, plural : String)
      case node
      when Crystal::Assign
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
          io << "\t#{var_name} := f.#{func}_#{label}\n"
        end

      when Crystal::Call
        name = node.name
        args = node.args

        case name
        when "get"
          path = go_url_expr(args[0], singular, plural)
          io << "\tresp := doRequest(handler, \"GET\", #{path})\n"
        when "post"
          path = go_url_expr(args[0], singular, plural)
          params = extract_go_params(node, singular)
          io << "\tresp := doRequest(handler, \"POST\", #{path}, #{params})\n"
        when "patch"
          path = go_url_expr(args[0], singular, plural)
          params = extract_go_params(node, singular)
          io << "\tresp := doRequest(handler, \"POST\", #{path}, #{params}+\"&_method=patch\")\n"
        when "delete"
          path = go_url_expr(args[0], singular, plural)
          io << "\tresp := doRequest(handler, \"POST\", #{path}, \"_method=delete\")\n"
        when "assert_response"
          status = args[0].to_s.strip(':')
          case status
          when "success" then io << "\tif resp.Code != 200 { t.Errorf(\"expected 200, got %d\", resp.Code) }\n"
          when "unprocessable_entity" then io << "\tif resp.Code != 422 { t.Errorf(\"expected 422, got %d\", resp.Code) }\n"
          end
        when "assert_redirected_to"
          io << "\tif resp.Code < 300 || resp.Code >= 400 { t.Errorf(\"expected redirect, got %d\", resp.Code) }\n"
        when "assert_select"
          if args.size >= 2 && args[1].is_a?(Crystal::StringLiteral)
            text = args[1].as(Crystal::StringLiteral).value
            io << "\tif !strings.Contains(resp.Body.String(), #{text.inspect}) { t.Error(\"expected body to contain #{text}\") }\n"
          elsif args.size >= 1
            selector = args[0].to_s.strip('"')
            if selector.starts_with?("#")
              id = selector.lchop("#").split(" ").first
              io << "\tif !strings.Contains(resp.Body.String(), `id=\"#{id}\"`) { t.Error(\"expected body to contain id=#{id}\") }\n"
            else
              io << "\tif !strings.Contains(resp.Body.String(), \"<#{selector}\") { t.Error(\"expected body to contain <#{selector}\") }\n"
            end
          end
        when "assert_equal"
          if args.size == 2
            expected = go_expr(args[0])
            actual = go_expr(args[1])
            io << "\tif #{actual} != #{expected} { t.Errorf(\"expected %v, got %v\", #{expected}, #{actual}) }\n"
          end
        when "assert_difference", "assert_no_difference"
          if args.size >= 1 && node.block
            count_expr = args[0].to_s.strip('"')
            model = count_expr.split(".").first
            diff = args.size > 1 ? args[1].to_s.to_i : (name == "assert_difference" ? 1 : 0)
            io << "\tbeforeCount, _ := models.#{model}Count()\n"
            emit_controller_test_body(node.block.not_nil!.body, io, model_name, singular, plural)
            io << "\tafterCount, _ := models.#{model}Count()\n"
            if name == "assert_difference"
              io << "\tif afterCount-beforeCount != #{diff} { t.Errorf(\"expected count diff %d, got %d\", #{diff}, afterCount-beforeCount) }\n"
            else
              io << "\tif afterCount != beforeCount { t.Errorf(\"expected count unchanged, was %d now %d\", beforeCount, afterCount) }\n"
            end
          end
        else
          if obj = node.obj
            obj_str = obj.to_s.lchop("@")
            if name == "reload"
              cls = Inflector.classify(obj_str)
              io << "\t#{obj_str}, _ = models.Find#{cls}(#{obj_str}.Id)\n"
            end
          end
        end
      end
    end

    private def go_url_expr(node : Crystal::ASTNode, singular : String, plural : String) : String
      case node
      when Crystal::Call
        url_name = node.name.chomp("_url")
        func_name = url_name.split("_").map(&.capitalize).join("") + "Path"
        if node.args.empty?
          "helpers.#{func_name}()"
        else
          args = node.args.map do |a|
            case a
            when Crystal::InstanceVar then a.name.lchop("@")
            when Crystal::Var then a.name
            else a.to_s.lchop("@")
            end
          end
          "helpers.#{func_name}(#{args.join(", ")})"
        end
      else
        node.to_s.inspect
      end
    end

    private def extract_go_params(node : Crystal::Call, singular : String) : String
      if named = node.named_args
        params_arg = named.find { |na| na.name == "params" }
        if params_arg
          return "encodeParams(#{go_hash_to_map(params_arg.value)})"
        end
      end
      "\"\""
    end

    private def go_hash_to_map(node : Crystal::ASTNode, depth : Int32 = 0) : String
      case node
      when Crystal::HashLiteral
        entries = node.entries.map do |entry|
          key = case entry.key
                when Crystal::SymbolLiteral then entry.key.as(Crystal::SymbolLiteral).value.inspect
                when Crystal::StringLiteral then entry.key.as(Crystal::StringLiteral).value.inspect
                else entry.key.to_s.inspect
                end
          value = go_hash_to_map(entry.value, depth + 1)
          "#{key}: #{value}"
        end
        if depth == 0
          "map[string]map[string]string{#{entries.join(", ")}}"
        else
          "map[string]string{#{entries.join(", ")}}"
        end
      when Crystal::NamedTupleLiteral
        entries = node.entries.map { |e| "#{e.key.inspect}: #{go_hash_to_map(e.value, depth + 1)}" }
        if depth == 0
          "map[string]map[string]string{#{entries.join(", ")}}"
        else
          "map[string]string{#{entries.join(", ")}}"
        end
      when Crystal::StringLiteral then node.value.inspect
      when Crystal::Call
        if obj = node.obj
          obj_str = case obj
                    when Crystal::InstanceVar then obj.as(Crystal::InstanceVar).name.lchop("@")
                    when Crystal::Var then obj.as(Crystal::Var).name
                    else obj.to_s
                    end
          "#{obj_str}.#{go_field_name(node.name)}"
        else
          node.name
        end
      else node.to_s.gsub("@", "")
      end
    end

    # ── Helpers ──

    private def find_class_body(ast : Crystal::ASTNode) : Crystal::ASTNode?
      case ast
      when Crystal::ClassDef then ast.body
      when Crystal::Expressions
        ast.expressions.each do |expr|
          result = find_class_body(expr)
          return result if result
        end
        nil
      else nil
      end
    end

    private def go_field_name(name : String) : String
      name.split("_").map(&.capitalize).join("")
    end

    private def go_expr(node : Crystal::ASTNode) : String
      case node
      when Crystal::StringLiteral then node.value.inspect
      when Crystal::NumberLiteral then "int64(#{node.value.to_s.gsub(/_i64|_i32/, "")})"
      when Crystal::InstanceVar then node.name.lchop("@")
      when Crystal::Var then node.name
      when Crystal::Path then node.names.join(".")
      when Crystal::Call
        obj = node.obj
        if obj
          # Model class method calls: Article.last → models.ArticleLast()
          if obj.is_a?(Crystal::Path) && {"last", "find", "count", "all"}.includes?(node.name)
            model = obj.as(Crystal::Path).names.last
            func = go_field_name(node.name)
            args = node.args.map { |a| go_expr(a) }
            result = "models.#{model}#{func}(#{args.join(", ")})"
            # Unwrap pointer for nil return: ArticleLast() returns (*Article, error)
            if node.name == "last"
              return "func() *models.#{model} { r, _ := #{result}; return r }()"
            end
            return result
          end
          obj_str = go_expr(obj)
          field = go_field_name(node.name)
          if node.args.empty? && !node.block
            "#{obj_str}.#{field}"
          elsif node.args.size == 1 && node.args[0].is_a?(Crystal::SymbolLiteral)
            label = node.args[0].as(Crystal::SymbolLiteral).value
            "f.#{node.name}_#{label}"
          else
            "#{obj_str}.#{field}"
          end
        else
          if node.args.size == 1 && node.args[0].is_a?(Crystal::SymbolLiteral)
            label = node.args[0].as(Crystal::SymbolLiteral).value
            "f.#{node.name}_#{label}"
          else
            node.name
          end
        end
      when Crystal::NilLiteral then "nil"
      else node.to_s.gsub("@", "")
      end
    end

    private def go_struct_attrs(call : Crystal::Call) : String
      if named = call.named_args
        return named.map { |na| "#{go_field_name(na.name)}: #{go_value(na.value)}" }.join(", ")
      end
      call.args.each do |arg|
        case arg
        when Crystal::NamedTupleLiteral
          return arg.entries.map { |e| "#{go_field_name(e.key)}: #{go_value(e.value)}" }.join(", ")
        when Crystal::HashLiteral
          return arg.entries.map do |e|
            key = case e.key
                  when Crystal::SymbolLiteral then e.key.as(Crystal::SymbolLiteral).value
                  when Crystal::StringLiteral then e.key.as(Crystal::StringLiteral).value
                  else e.key.to_s
                  end
            "#{go_field_name(key)}: #{go_value(e.value)}"
          end.join(", ")
        end
      end
      ""
    end

    private def go_map_attrs(call : Crystal::Call) : String
      if named = call.named_args
        return named.map { |na| "#{na.name.inspect}: #{go_value(na.value)}" }.join(", ")
      end
      call.args.each do |arg|
        case arg
        when Crystal::NamedTupleLiteral
          return arg.entries.map { |e| "#{e.key.inspect}: #{go_value(e.value)}" }.join(", ")
        when Crystal::HashLiteral
          return arg.entries.map do |e|
            key = case e.key
                  when Crystal::SymbolLiteral then e.key.as(Crystal::SymbolLiteral).value
                  when Crystal::StringLiteral then e.key.as(Crystal::StringLiteral).value
                  else e.key.to_s
                  end
            "#{key.inspect}: #{go_value(e.value)}"
          end.join(", ")
        end
      end
      ""
    end

    private def go_value(node : Crystal::ASTNode) : String
      case node
      when Crystal::StringLiteral then node.value.inspect
      when Crystal::NumberLiteral then "int64(#{node.value.to_s.gsub(/_i64|_i32/, "")})"
      when Crystal::BoolLiteral then node.value.to_s
      when Crystal::NilLiteral then "nil"
      else node.to_s
      end
    end
  end
end
