# Runs Crystal's semantic analysis on the full generated Crystal program.
#
# Reuses the Crystal generator's filter chain to produce valid Crystal AST,
# then runs program.semantic() to get types on every node.
#
# This is the same code path that produces compilable Crystal output —
# if Crystal compiles, semantic analysis will type every node.

require "../semantic"
require "./source_parser"
require "./prism_translator"
require "./inflector"
require "./schema_extractor"
require "../filters/shared_controller_filters"
require "../filters/redirect_to_response"
require "../filters/render_to_ecr"
require "../filters/controller_signature"
require "../filters/controller_boilerplate"
require "../filters/model_namespace"
require "../filters/strip_turbo_stream"
require "../filters/strip_callbacks"
require "../filters/broadcasts_to"
require "../filters/model_boilerplate"

module Railcar
  class SemanticAnalyzer
    getter app : AppModel
    getter rails_dir : String
    getter program : Crystal::Program?
    getter typed_ast : Crystal::ASTNode?

    def initialize(@app, @rails_dir)
    end

    def analyze : Bool
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }
      model_names = app.models.keys.to_a

      # Build model stubs (Crystal-compatible, with typed properties)
      stubs = build_model_stubs(schema_map)

      # Build controller ASTs using the full Crystal filter chain
      controller_asts = [] of Crystal::ASTNode
      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        ast = build_controller_ast(info, controller_name, model_names)
        next unless ast
        # Wrap in Railcar module (same as Crystal generator)
        controller_asts << Crystal::ModuleDef.new(Crystal::Path.new("Railcar"), body: ast)
      end

      # Build call sites to trigger type inference on all public methods
      call_sites = [] of Crystal::ASTNode
      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        singular = Inflector.singularize(controller_name)
        nested_parent = app.routes.nested_parent_for(controller_name)

        info.actions.reject(&.is_private).each do |action|
          next unless action.body
          # Build args matching ControllerSignature's method signature
          args = build_call_args(action.name, info.before_actions)
          call_sites << Crystal::Assign.new(
            Crystal::Var.new("__type_#{controller_name}_#{action.name}"),
            Crystal::Call.new(
              Crystal::Call.new(Crystal::Path.new(["Railcar", info.name]), "new"),
              action.name,
              args
            )
          )
        end
      end

      # Combine: prelude + db stub + http + ecr + stubs + controllers + call sites
      # Require nodes need a location for relative require resolution
      location = Crystal::Location.new("src/app.cr", 1, 1)
      nodes = [
        Crystal::Require.new("prelude").at(location),
        Crystal::Require.new("http/server").at(location),
        Crystal::Require.new("ecr").at(location),
      ] of Crystal::ASTNode
      nodes << stubs
      nodes.concat(controller_asts)
      nodes.concat(call_sites)

      @program = prog = Crystal::Program.new
      # Assign a compiler so stdlib codegen stubs are available
      compiler = Crystal::Compiler.new
      compiler.no_codegen = true
      prog.compiler = compiler

      # Try with all controllers first; if that fails, retry with just models
      normalized = prog.normalize(Crystal::Expressions.new(nodes))
      begin
        @typed_ast = prog.semantic(normalized)
      rescue
        # Retry without controllers — models may still type successfully
        STDERR.puts "  retrying without controllers..."
        model_nodes = [
          Crystal::Require.new("prelude").at(location),
          Crystal::Require.new("http/server").at(location),
          Crystal::Require.new("ecr").at(location),
        ] of Crystal::ASTNode
        model_nodes << stubs
        prog2 = Crystal::Program.new
        prog2.compiler = compiler
        normalized2 = prog2.normalize(Crystal::Expressions.new(model_nodes))
        @typed_ast = prog2.semantic(normalized2)
        @program = prog2
      end

      # Count typed methods
      typed_count = 0
      call_sites.each do |cs|
        if cs.is_a?(Crystal::Assign) && cs.value.type?
          typed_count += 1
        end
      end
      puts "  semantic analysis: #{typed_count} of #{call_sites.size} methods typed"
      true
    rescue ex
      full_msg = ex.message || ""
      STDERR.puts "  semantic analysis failed: #{full_msg}"
      STDERR.puts "  exception class: #{ex.class}"
      if ex.responds_to?(:to_s)
        STDERR.puts "  full: #{ex.to_s.lines.first(15).join("\n    ")}"
      end
      false
    end

    # Build controller AST using the full Crystal filter chain
    private def build_controller_ast(info : ControllerInfo, controller_name : String,
                                      model_names : Array(String)) : Crystal::ASTNode?
      source_path = File.join(rails_dir, "app/controllers/#{controller_name}_controller.rb")
      return nil unless File.exists?(source_path)

      nested_parent = app.routes.nested_parent_for(controller_name)
      views_dir = File.join(rails_dir, "app/views")

      ast = SourceParser.parse(source_path)

      # Same filter chain as AppGenerator.generate_controller_file
      ast = SharedControllerFilters.apply(ast)
      ast = ast.transform(RedirectToResponse.new)
      ast = ast.transform(RenderToECR.new(controller_name))
      ast = ast.transform(ControllerSignature.new(controller_name, nested_parent, info.before_actions, model_names))
      ast = ast.transform(ControllerBoilerplate.new(controller_name, views_dir, nested_parent))
      ast = ast.transform(ModelNamespace.new(model_names))

      ast
    end

    # Build typed model stubs that match the Crystal runtime
    private def build_model_stubs(schema_map : Hash(String, TableSchema)) : Crystal::ASTNode
      stub_source = String.build do |io|
        # Runtime stubs
        io << "module Railcar\n"

        # FLASH_STORE
        io << "  FLASH_STORE = {} of String => {notice: String?, alert: String?}\n"

        # Route helpers module
        io << "  module RouteHelpers\n"
        app.models.each_key do |name|
          singular = Inflector.underscore(name)
          plural = Inflector.pluralize(singular)
          io << "    def #{singular}_path(model) : String\n      \"\"\n    end\n"
          io << "    def #{plural}_path : String\n      \"\"\n    end\n"
          io << "    def edit_#{singular}_path(model) : String\n      \"\"\n    end\n"
          io << "    def new_#{singular}_path : String\n      \"\"\n    end\n"
        end
        # Nested helpers
        app.models.each do |name, model|
          model.associations.each do |assoc|
            next unless assoc.kind == :has_many
            parent = Inflector.underscore(name)
            child_plural = assoc.name
            child_singular = Inflector.singularize(child_plural)
            io << "    def #{parent}_#{child_plural}_path(model) : String\n      \"\"\n    end\n"
            io << "    def #{parent}_#{child_singular}_path(model, child) : String\n      \"\"\n    end\n"
          end
        end
        io << "  end\n\n"

        # View helpers module
        io << "  module ViewHelpers\n"
        io << "    def link_to(*args, **kwargs) : String\n      \"\"\n    end\n"
        io << "    def button_to(*args, **kwargs) : String\n      \"\"\n    end\n"
        io << "    def label_tag(*args, **kwargs) : String\n      \"\"\n    end\n"
        io << "    def text_field_tag(*args, **kwargs) : String\n      \"\"\n    end\n"
        io << "    def text_area_tag(*args, **kwargs) : String\n      \"\"\n    end\n"
        io << "    def submit_tag(*args, **kwargs) : String\n      \"\"\n    end\n"
        io << "    def turbo_cable_stream_tag(*args) : String\n      \"\"\n    end\n"
        io << "    def dom_id(*args) : String\n      \"\"\n    end\n"
        io << "    def pluralize(*args) : String\n      \"\"\n    end\n"
        io << "    def truncate(*args, **kwargs) : String\n      \"\"\n    end\n"
        io << "  end\n\n"

        # extract_model_params (from StrongParams)
        io << "  def self.extract_model_params(params : Hash(String, String), model : String) : Hash(String, DB::Any)\n"
        io << "    {} of String => DB::Any\n"
        io << "  end\n\n"

        # Forward declare models
        app.models.each_key { |name| io << "  class #{name}\n  end\n" }
        io << "\n"

        # Model definitions
        app.models.each do |name, model|
          table_name = Inflector.pluralize(Inflector.underscore(name))
          schema = schema_map[table_name]?

          io << "  class #{name}\n"
          io << "    property id : Int64 = 0\n"
          io << "    getter? persisted : Bool = false\n"

          if schema
            schema.columns.each do |col|
              next if col.name == "id"
              ct = SchemaExtractor.crystal_type(col.type)
              default = ct == "String" ? "\"\"" : ct == "Time" ? "Time.utc" : "0"
              io << "    property #{col.name} : #{ct} = #{default}\n"
            end
          end

          io << "    class Relation\n"
          io << "      include Enumerable(#{name})\n"
          io << "      def each(& : #{name} ->) : Nil\n      end\n"
          io << "      def order(**a) : Relation\n        self\n      end\n"
          io << "      def includes(*a) : Relation\n        self\n      end\n"
          io << "      def limit(n) : Relation\n        self\n      end\n"
          io << "    end\n"

          model.associations.each do |assoc|
            case assoc.kind
            when :has_many
              target = Inflector.classify(Inflector.singularize(assoc.name))
              io << "    def #{assoc.name} : Array(#{target})\n      [] of #{target}\n    end\n"
            when :belongs_to
              target = Inflector.classify(assoc.name)
              io << "    def #{assoc.name} : #{target}\n      #{target}.new\n    end\n"
            end
          end

          io << "    def self.find(id) : #{name}\n      #{name}.new\n    end\n"
          io << "    def self.includes(*a) : Relation\n      Relation.new\n    end\n"
          io << "    def self.order(**a) : Relation\n      Relation.new\n    end\n"
          io << "    def self.all : Relation\n      Relation.new\n    end\n"
          io << "    def self.new(params : Hash(String, DB::Any)) : #{name}\n      #{name}.new\n    end\n"
          io << "    def save : Bool\n      true\n    end\n"
          io << "    def update(params : Hash(String, DB::Any)) : Bool\n      true\n    end\n"
          io << "    def destroy : #{name}\n      self\n    end\n"
          io << "    def destroy! : #{name}\n      self\n    end\n"
          io << "    def errors : Array(String)\n      [] of String\n    end\n"
          io << "  end\n\n"
        end

        io << "end\n"

        # DB::Any type alias (needed by extract_model_params)
        io << "module DB\n  alias Any = String | Int64 | Float64 | Bool | Nil\nend\n"

        # HTTP types loaded via Crystal::Require node above

        # ECR stub
        io << "module ECR\n"
        io << "  macro embed(filename, io)\n"
        io << "  end\n"
        io << "end\n"
      end

      Crystal::Parser.parse(stub_source)
    end

    # Build call arguments matching ControllerSignature's method signatures
    private def build_call_args(action_name : String, before_actions : Array(BeforeAction)) : Array(Crystal::ASTNode)
      args = [Crystal::Call.new(Crystal::Path.new(["HTTP", "Server", "Response"]), "new",
        [Crystal::Call.new(Crystal::Path.new(["IO", "Memory"]), "new")] of Crystal::ASTNode
      )] of Crystal::ASTNode

      # ID parameter for show/edit/update/destroy
      needs_id = %w[show edit update destroy].includes?(action_name)
      if needs_id
        args << Crystal::NumberLiteral.new("1", :i64)
      end

      # Params for create/update
      needs_params = %w[create update].includes?(action_name)
      if needs_params
        args << Crystal::HashLiteral.new([] of Crystal::HashLiteral::Entry,
          of: Crystal::HashLiteral::Entry.new(Crystal::Path.new("String"), Crystal::Path.new("String")))
      end

      # Nested resource parent ID (e.g., article_id for comments)
      if before_actions.any? { |ba| ba.method_name.includes?("set_") || ba.method_name.includes?("find_") }
        args << Crystal::NumberLiteral.new("1", :i64)
      end

      args
    end

  end
end
