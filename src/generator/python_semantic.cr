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

          # Build method body: before_action preambles + action body
          body_parts = [] of Crystal::ASTNode

          # Inline before_action bodies (only for public actions)
          info.before_actions.each do |ba|
            next if action.is_private
            next if ba.only && !ba.only.not_nil!.includes?(action.name)
            if method_body = private_methods[ba.method_name]?
              preamble = PrismTranslator.new.translate(method_body)
              preamble = preamble.transform(InstanceVarToLocal.new)
              preamble = preamble.transform(ParamsExpect.new)
              body_parts << preamble
            end
          end

          translated = PrismTranslator.new.translate(body)
          translated = translated.transform(InstanceVarToLocal.new)
          translated = translated.transform(ParamsExpect.new)
          translated = translated.transform(RespondToHTML.new)
          # Don't apply StrongParams — it introduces bare 'params' reference
          # that can't resolve in top-level methods. article_params/comment_params
          # are included as private methods in the stubs instead.
          body_parts << translated

          full_body = body_parts.size == 1 ? body_parts[0] : Crystal::Expressions.new(body_parts)

          # Unique method name (prefix public methods to avoid collisions,
          # keep private method names as-is so they're callable from action bodies)
          method_name = if action.is_private
                          action.name
                        else
                          "#{Inflector.underscore(info.name).chomp("_controller")}_#{action.name}"
                        end

          # Collect param names introduced by ParamsExpect (they become method args)
          param_names = Set(String).new
          body_parts.each do |part|
            collect_param_vars(part, param_names)
          end

          args = param_names.map { |n| Crystal::Arg.new(n, default_value: Crystal::NumberLiteral.new("0")) }
          method_def = Crystal::Def.new(method_name, args, body: full_body)
          action_nodes << method_def

          # Call site to trigger type inference (only for public methods)
          unless action.is_private
            call_sites << Crystal::Assign.new(
              Crystal::Var.new("__type_#{method_name}"),
              Crystal::Call.new(nil, method_name)
            )
          end
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
      report_typed_methods(action_nodes)
      true
    rescue ex
      # Retry, removing methods that fail type-checking.
      # Must re-parse stubs each time since semantic mutates AST in place.
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }
      stub_source = generate_stubs(schema_map)

      action_nodes = @action_nodes.not_nil!
      call_sites = @call_sites.not_nil!
      total = action_nodes.size
      skip_methods = Set(String).new

      # Extract the failing method from the first error
      if (msg = ex.message) && msg =~ /instantiating '(\w+)\(\)'/
        skip_methods << $1
      end

      5.times do
        fresh_stubs = Crystal::Parser.parse(stub_source)
        remaining = action_nodes.reject { |n| n.is_a?(Crystal::Def) && skip_methods.includes?(n.name) }
        remaining_calls = call_sites.reject { |n| n.is_a?(Crystal::Assign) && skip_methods.any? { |s| n.target.to_s == "__type_#{s}" } }

        nodes = [Crystal::Require.new("prelude"), fresh_stubs] of Crystal::ASTNode
        nodes.concat(remaining)
        nodes.concat(remaining_calls)

        @program = prog = Crystal::Program.new
        normalized = prog.normalize(Crystal::Expressions.new(nodes))
        @typed_ast = prog.semantic(normalized)

        typed = remaining.size
        if skip_methods.empty?
          puts "  semantic analysis: #{typed} methods typed"
        else
          puts "  semantic analysis: #{typed} of #{total} methods typed, skipped: #{skip_methods.join(", ")}"
        end
        return true
      rescue retry_ex
        if (retry_msg = retry_ex.message) && retry_msg =~ /instantiating '(\w+)\(\)'/
          skip_methods << $1
        else
          return false
        end
      end
      false
    end

    # Report which methods were typed by checking the typed AST
    private def report_typed_methods(action_nodes : Array(Crystal::ASTNode))
      return unless typed = @typed_ast
      return unless prog = @program

      typed_names = [] of String
      untyped_names = [] of String

      action_nodes.each do |node|
        next unless node.is_a?(Crystal::Def)
        name = node.name
        # Check if the call site assignment got a type
        if typed.is_a?(Crystal::Expressions)
          typed.expressions.each do |expr|
            if expr.is_a?(Crystal::Assign) && expr.target.to_s == "__type_#{name}"
              if expr.value.type?
                typed_names << name
              else
                untyped_names << name
              end
            end
          end
        end
      end

      total = typed_names.size + untyped_names.size
      if untyped_names.empty?
        puts "  semantic analysis: #{typed_names.size} methods typed"
      else
        puts "  semantic analysis: #{typed_names.size} of #{total} methods typed, skipped: #{untyped_names.join(", ")}"
      end
    end

    # Find variable names that come from ParamsExpect (used but not assigned)
    private def collect_param_vars(node : Crystal::ASTNode, names : Set(String))
      case node
      when Crystal::Expressions
        node.expressions.each { |e| collect_param_vars(e, names) }
      when Crystal::Assign
        # Track assigned variables
        collect_param_vars(node.value, names)
      when Crystal::Call
        if node.name == "find" && node.args.size == 1
          arg = node.args[0]
          if arg.is_a?(Crystal::Var) && !%w[self _buf].includes?(arg.name)
            names << arg.name
          end
        end
        collect_param_vars(node.obj.not_nil!, names) if node.obj
        node.args.each { |a| collect_param_vars(a, names) }
      when Crystal::If
        collect_param_vars(node.then, names)
        collect_param_vars(node.else, names) if node.else
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
