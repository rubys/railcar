# Runs Crystal's semantic analysis on the full program once,
# producing a typed AST that all Python generators can use.
#
# Pipeline:
#   1. Generate model stubs with typed signatures
#   2. Parse all controller source via Prism
#   3. Apply shared filters (InstanceVarToLocal, RespondToHTML, etc.)
#   4. Combine: prelude + stubs + all_controllers
#   5. program.semantic() → typed AST
#
# After this runs, every Crystal::ASTNode has .type? populated.
# The Python emitter and filters can read types for:
#   - Property vs method dispatch
#   - Type hints (str, int, Article, list[Comment])
#   - Precise method transforms (.map → comprehension, .size → len)

require "../semantic"
require "./source_parser"
require "./prism_translator"
require "./inflector"
require "../filters/instance_var_to_local"
require "../filters/params_expect"
require "../filters/respond_to_html"
require "../filters/strong_params"
require "../filters/strip_turbo_stream"
require "../filters/strip_callbacks"

module Railcar
  class PythonSemantic
    getter app : AppModel
    getter rails_dir : String
    getter program : Crystal::Program?
    getter typed_ast : Crystal::ASTNode?

    @stub_ast : Crystal::ASTNode?
    @action_nodes : Array(Crystal::ASTNode)?
    @call_sites : Array(Crystal::ASTNode)?

    def initialize(@app, @rails_dir)
    end

    # Run semantic analysis on the full program. Returns true on success.
    def analyze : Bool
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      # Build stubs
      stub_source = generate_stubs(schema_map)
      @stub_ast = stub_ast = Crystal::Parser.parse(stub_source)

      # Parse each action as a standalone method (not inside a class).
      # This avoids Crystal's instance variable nil-union issue where
      # @article set in set_article is (Article | Nil) in other methods.
      # Each action body becomes a top-level method with local variables.
      @action_nodes = action_nodes = [] of Crystal::ASTNode
      @call_sites = call_sites = [] of Crystal::ASTNode

      app.controllers.each do |info|
        # Build a map of private methods for before_action inlining
        private_methods = {} of String => Prism::Node
        info.actions.select(&.is_private).each do |a|
          private_methods[a.name] = a.body.not_nil! if a.body
        end

        info.actions.each do |action|
          body = action.body
          next unless body
          next if action.is_private

          # Build method body: before_action preambles + action body
          body_parts = [] of Crystal::ASTNode

          # Inline before_action bodies
          info.before_actions.each do |ba|
            next if ba.only && !ba.only.not_nil!.includes?(action.name)
            if method_body = private_methods[ba.method_name]?
              preamble = PrismTranslator.new.translate(method_body)
              preamble = preamble.transform(InstanceVarToLocal.new)
              body_parts << preamble
            end
          end

          translated = PrismTranslator.new.translate(body)
          translated = translated.transform(InstanceVarToLocal.new)
          translated = translated.transform(ParamsExpect.new)
          translated = translated.transform(RespondToHTML.new)
          translated = translated.transform(StrongParams.new)
          body_parts << translated

          full_body = body_parts.size == 1 ? body_parts[0] : Crystal::Expressions.new(body_parts)

          # Unique method name to avoid collisions
          method_name = "#{Inflector.underscore(info.name).chomp("_controller")}_#{action.name}"

          method_def = Crystal::Def.new(method_name, body: full_body)
          action_nodes << method_def

          # Call site to trigger type inference
          call_sites << Crystal::Assign.new(
            Crystal::Var.new("__type_#{method_name}"),
            Crystal::Call.new(nil, method_name)
          )
        end
      end

      # Combine everything
      nodes = [Crystal::Require.new("prelude"), stub_ast] of Crystal::ASTNode
      nodes.concat(action_nodes)
      nodes.concat(call_sites)

      full_ast = Crystal::Expressions.new(nodes)

      @program = prog = Crystal::Program.new
      normalized = prog.normalize(full_ast)
      @typed_ast = prog.semantic(normalized)
      puts "  semantic analysis: #{action_nodes.size} methods typed"
      true
    rescue
      # If full analysis fails, retry without failing methods
      retry_without_failures(@stub_ast.not_nil!, @action_nodes.not_nil!, @call_sites.not_nil!)
    end

    # Retry semantic analysis, progressively removing methods that fail
    private def retry_without_failures(stub_ast : Crystal::ASTNode,
                                        action_nodes : Array(Crystal::ASTNode),
                                        call_sites : Array(Crystal::ASTNode)) : Bool
      total = action_nodes.size
      remaining_actions = action_nodes.dup
      remaining_calls = call_sites.dup
      skipped = [] of String

      3.times do  # max retries
        nodes = [Crystal::Require.new("prelude"), stub_ast] of Crystal::ASTNode
        nodes.concat(remaining_actions)
        nodes.concat(remaining_calls)

        @program = prog = Crystal::Program.new
        normalized = prog.normalize(Crystal::Expressions.new(nodes))
        @typed_ast = prog.semantic(normalized)
        return true
      rescue ex
        msg = ex.message || ""
        # Extract the failing method name from "instantiating 'method_name()'"
        if msg =~ /instantiating '(\w+)\(\)'/
          failing = $1
          skipped << failing
          remaining_actions.reject! do |n|
            n.is_a?(Crystal::Def) && n.name == failing
          end
          remaining_calls.reject! do |n|
            n.is_a?(Crystal::Assign) && n.target.to_s == "__type_#{failing}"
          end
        else
          return false
        end
      end
      false
    ensure
      if (ra = remaining_actions)
        typed_count = ra.size
        if typed_count > 0
          skip_list = skipped.try(&.join(", ")) || ""
          skip_msg = skip_list.empty? ? "" : ", skipped: #{skip_list}"
          puts "  semantic analysis: #{typed_count} of #{total} methods typed#{skip_msg}"
        end
      end
    end

    private def generate_stubs(schema_map : Hash(String, TableSchema)) : String
      String.build do |io|
        # Controller base
        io << "class ApplicationController\n"
        io << "  macro before_action(*args, **kwargs)\n  end\n"
        io << "  macro private\n  end\n"
        io << "  def redirect_to(*args, **kwargs)\n  end\n"
        io << "  def render(*args, **kwargs)\n  end\n"
        io << "  def head(*args)\n  end\n"
        io << "end\n\n"

        # Params
        io << "class ActionController::Parameters\n"
        io << "  def expect(**args) : ActionController::Parameters\n    self\n  end\n"
        io << "  def expect(arg) : Int64\n    0_i64\n  end\n"
        io << "end\n"
        io << "def params : ActionController::Parameters\n  ActionController::Parameters.new\nend\n\n"

        # Path helpers
        app.models.each_key do |name|
          singular = Inflector.underscore(name)
          plural = Inflector.pluralize(singular)
          io << "def #{singular}_path(*args) : String\n  \"\"\nend\n"
          io << "def #{plural}_path(*args) : String\n  \"\"\nend\n"
          io << "def edit_#{singular}_path(*args) : String\n  \"\"\nend\n"
          io << "def new_#{singular}_path(*args) : String\n  \"\"\nend\n"
        end

        # Nested path helpers
        app.models.each do |name, model|
          model.associations.each do |assoc|
            next unless assoc.kind == :has_many
            parent = Inflector.underscore(name)
            child_plural = assoc.name
            child_singular = Inflector.singularize(child_plural)
            io << "def #{parent}_#{child_plural}_path(*args) : String\n  \"\"\nend\n"
            io << "def #{parent}_#{child_singular}_path(*args) : String\n  \"\"\nend\n"
          end
        end
        io << "\n"

        # extract_model_params stub (from StrongParams filter)
        io << "def extract_model_params(params, model : String) : Hash(String, String)\n"
        io << "  {} of String => String\n"
        io << "end\n\n"

        # Forward declare models
        app.models.each_key { |name| io << "class #{name}\nend\n" }
        io << "\n"

        # Model definitions
        app.models.each do |name, model|
          table_name = Inflector.pluralize(Inflector.underscore(name))
          schema = schema_map[table_name]?

          io << "class #{name}\n"
          io << "  property id : Int64 = 0\n"
          if schema
            schema.columns.each do |col|
              next if col.name == "id"
              ct = SchemaExtractor.crystal_type(col.type)
              default = ct == "String" ? "\"\"" : ct == "Time" ? "Time.utc" : "0"
              io << "  property #{col.name} : #{ct} = #{default}\n"
            end
          end

          # Relation
          io << "  class Relation\n"
          io << "    include Enumerable(#{name})\n"
          io << "    def each(& : #{name} ->) : Nil\n    end\n"
          io << "    def order(**a) : Relation\n      self\n    end\n"
          io << "    def includes(*a) : Relation\n      self\n    end\n"
          io << "  end\n"

          # Associations
          model.associations.each do |assoc|
            case assoc.kind
            when :has_many
              target = Inflector.classify(Inflector.singularize(assoc.name))
              io << "  def #{assoc.name} : Array(#{target})\n    [] of #{target}\n  end\n"
            when :belongs_to
              target = Inflector.classify(assoc.name)
              io << "  def #{assoc.name} : #{target}\n    #{target}.new\n  end\n"
            end
          end

          # Class methods
          io << "  def self.find(id) : #{name}\n    #{name}.new\n  end\n"
          io << "  def self.includes(*a) : Relation\n    Relation.new\n  end\n"
          io << "  def self.order(**a) : Relation\n    Relation.new\n  end\n"
          io << "  def self.all : Relation\n    Relation.new\n  end\n"
          io << "  def self.new(p) : #{name}\n    #{name}.new\n  end\n"
          io << "  def save : Bool\n    true\n  end\n"
          io << "  def update(p) : Bool\n    true\n  end\n"
          io << "  def destroy! : #{name}\n    self\n  end\n"
          io << "  def errors : Array(String)\n    [] of String\n  end\n"
          io << "end\n\n"
        end
      end
    end
  end
end
