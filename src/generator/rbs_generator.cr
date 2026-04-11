# Generates RBS type signature files from extracted Rails metadata.
#
# Uses Crystal's semantic analysis to infer method return types:
# 1. Generates Crystal stub classes from schema/model metadata
# 2. Translates Ruby method bodies to Crystal AST via PrismTranslator
# 3. Runs Crystal's type inference on the combined AST
# 4. Maps inferred Crystal types back to RBS type signatures

require "./app_model"
require "./schema_extractor"
require "./prism_translator"
require "./source_parser"
require "../semantic"
require "../filters/respond_to_html"
require "../filters/strip_turbo_stream"
require "../filters/strip_callbacks"

module Railcar
  class RbsGenerator
    getter app : AppModel
    getter rails_dir : String

    def initialize(@app, @rails_dir = "")
    end

    def generate(output_dir : String)
      mkdir(output_dir)

      generate_models(output_dir)
      generate_controllers(output_dir)

      puts "RBS files written to #{output_dir}/"
    end

    private def generate_models(output_dir : String)
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      app.models.each do |name, model|
        table_name = Inflector.pluralize(Inflector.underscore(name))
        schema = schema_map[table_name]?
        next unless schema

        rbs = String.build do |io|
          io << "class #{name} < ApplicationRecord\n"

          # Column attributes
          schema.columns.each do |col|
            next if col.name == "id"
            rbs_type = rails_type_to_rbs(col.type)
            io << "  attr_accessor #{col.name}: #{rbs_type}\n"
          end

          io << "\n" unless schema.columns.empty?

          # Associations
          model.associations.each do |assoc|
            case assoc.kind
            when :has_many
              target = Inflector.classify(Inflector.singularize(assoc.name))
              io << "  def #{assoc.name}: ActiveRecord::Associations::CollectionProxy[#{target}]\n"
            when :belongs_to
              target = Inflector.classify(assoc.name)
              io << "  def #{assoc.name}: #{target}\n"
              io << "  def #{assoc.name}_id: Integer?\n"
            when :has_one
              target = Inflector.classify(assoc.name)
              io << "  def #{assoc.name}: #{target}?\n"
            end
          end

          io << "end\n"
        end

        File.write(File.join(output_dir, "#{Inflector.underscore(name)}.rbs"), rbs)
        puts "  #{Inflector.underscore(name)}.rbs"
      end
    end

    private def generate_controllers(output_dir : String)
      # Infer return types for all controller methods via semantic analysis
      inferred_types = infer_controller_types

      app.controllers.each do |info|
        ct = inferred_types[info.name]? || ControllerTypes.new

        rbs = String.build do |io|
          io << "class #{info.name} < #{info.superclass}\n"

          # Instance variable type declarations
          unless ct.ivars.empty?
            ct.ivars.each do |name, type|
              io << "  #{name}: #{type}\n"
            end
            io << "\n"
          end

          info.actions.each do |action|
            next if action.is_private
            ret = ct.methods[action.name]? || "void"
            io << "  def #{action.name}: #{ret}\n"
          end

          # Private methods
          has_private = info.actions.any?(&.is_private)
          if has_private
            io << "\n  private\n\n"
            info.actions.each do |action|
              next unless action.is_private
              ret = ct.methods[action.name]? || "void"
              io << "  def #{action.name}: #{ret}\n"
            end
          end

          io << "end\n"
        end

        basename = Inflector.underscore(info.name)
        File.write(File.join(output_dir, "#{basename}.rbs"), rbs)
        puts "  #{basename}.rbs"
      end
    end

    # Run Crystal's semantic analysis to infer controller types.
    # Returns Hash: controller_name => ControllerTypes (methods + ivars)
    private def infer_controller_types : Hash(String, ControllerTypes)
      result = {} of String => ControllerTypes

      # Build schema map for stub generation
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      # Generate Crystal stub source for models
      stub_source = generate_model_stubs(schema_map)

      # For each controller, translate method bodies and run semantic analysis
      app.controllers.each do |info|
        ct = infer_methods_for_controller(info, stub_source)
        result[info.name] = ct unless ct.methods.empty? && ct.ivars.empty?
      end

      result
    rescue
      result || {} of String => ControllerTypes
    end

    # Generate Crystal stub classes from schema/model metadata.
    # These stubs provide typed signatures so Crystal can infer
    # return types in controller method bodies.
    private def generate_model_stubs(schema_map : Hash(String, TableSchema)) : String
      String.build do |io|
        # Stub for controller base
        io << "class ApplicationController\n"
        io << "  macro before_action(*args, **kwargs)\n"
        io << "  end\n"
        io << "  macro private\n"
        io << "  end\n"
        io << "  def redirect_to(*args, **kwargs)\n"
        io << "  end\n"
        io << "  def render(*args, **kwargs)\n"
        io << "  end\n"
        io << "  def head(*args)\n"
        io << "  end\n"
        io << "end\n\n"

        # Route helpers
        app.routes.routes.each do |route|
          io << "def #{route.controller}_path(*args) : String\n"
          io << "  \"\"\n"
          io << "end\n"
        end
        # Singular path helpers from model names
        app.models.each_key do |name|
          singular = Inflector.underscore(name)
          plural = Inflector.pluralize(singular)
          io << "def #{singular}_path(*args) : String\n"
          io << "  \"\"\n"
          io << "end\n"
          io << "def #{plural}_path(*args) : String\n"
          io << "  \"\"\n"
          io << "end\n"
        end
        io << "\n"

        # Stub for params
        io << "class ActionController::Parameters\n"
        io << "  def expect(**args) : ActionController::Parameters\n"
        io << "    ActionController::Parameters.new\n"
        io << "  end\n"
        io << "  def expect(arg) : ActionController::Parameters\n"
        io << "    ActionController::Parameters.new\n"
        io << "  end\n"
        io << "end\n\n"

        io << "def params : ActionController::Parameters\n"
        io << "  ActionController::Parameters.new\n"
        io << "end\n\n"

        app.models.each do |name, model|
          table_name = Inflector.pluralize(Inflector.underscore(name))
          schema = schema_map[table_name]?

          io << "class #{name}\n"

          # Properties from schema
          if schema
            schema.columns.each do |col|
              next if col.name == "id"
              crystal_type = SchemaExtractor.crystal_type(col.type)
              io << "  property #{col.name} : #{crystal_type} = #{default_for(crystal_type)}\n"
            end
          end

          # Relation stub for chainable queries
          io << "  class Relation\n"
          io << "    include Enumerable(#{name})\n"
          io << "    def each(& : #{name} ->) : Nil\n"
          io << "    end\n"
          io << "    def order(**args) : Relation\n"
          io << "      self\n"
          io << "    end\n"
          io << "    def where(**args) : Relation\n"
          io << "      self\n"
          io << "    end\n"
          io << "    def includes(*args) : Relation\n"
          io << "      self\n"
          io << "    end\n"
          io << "    def limit(n) : Relation\n"
          io << "      self\n"
          io << "    end\n"
          io << "  end\n\n"

          # Class methods
          io << "  def self.find(id) : #{name}\n"
          io << "    #{name}.new\n"
          io << "  end\n"
          io << "  def self.where(**conditions) : Relation\n"
          io << "    Relation.new\n"
          io << "  end\n"
          io << "  def self.includes(*args) : Relation\n"
          io << "    Relation.new\n"
          io << "  end\n"
          io << "  def self.order(**args) : Relation\n"
          io << "    Relation.new\n"
          io << "  end\n"
          io << "  def self.all : Relation\n"
          io << "    Relation.new\n"
          io << "  end\n"
          io << "  def self.new(params) : #{name}\n"
          io << "    #{name}.new\n"
          io << "  end\n"

          # Association methods
          model.associations.each do |assoc|
            case assoc.kind
            when :has_many
              target = Inflector.classify(Inflector.singularize(assoc.name))
              io << "  def #{assoc.name} : Array(#{target})\n"
              io << "    [] of #{target}\n"
              io << "  end\n"
            when :belongs_to
              target = Inflector.classify(assoc.name)
              io << "  def #{assoc.name} : #{target}\n"
              io << "    #{target}.new\n"
              io << "  end\n"
            when :has_one
              target = Inflector.classify(assoc.name)
              io << "  def #{assoc.name} : #{target}?\n"
              io << "    nil\n"
              io << "  end\n"
            end
          end

          # Instance methods used in controllers
          io << "  def save : Bool\n"
          io << "    true\n"
          io << "  end\n"
          io << "  def update(params) : Bool\n"
          io << "    true\n"
          io << "  end\n"
          io << "  def destroy! : #{name}\n"
          io << "    self\n"
          io << "  end\n"

          io << "end\n\n"
        end
      end
    end

    # Translate a controller's Ruby method bodies via Prism,
    # combine with model stubs, run semantic analysis per method,
    # and return inferred return types.
    class ControllerTypes
      property methods : Hash(String, String)
      property ivars : Hash(String, String)

      def initialize(@methods = {} of String => String, @ivars = {} of String => String)
      end
    end

    private def infer_methods_for_controller(
      info : ControllerInfo,
      stub_source : String
    ) : ControllerTypes
      # First try all methods together to get ivar types
      ivar_types = infer_all_methods(info, stub_source)
      result = ControllerTypes.new(ivars: ivar_types || {} of String => String)

      # Then infer return types per method (more resilient to failures)
      info.actions.each do |action|
        body = action.body
        next unless body

        inferred = infer_single_method(info.name, action.name, body, stub_source)
        if inferred
          result.methods[action.name] = inferred
        end
      end

      result
    end

    # Run all methods together to accumulate ivar types on the class.
    # Parses the full controller file and applies the filter chain
    # (same filters AppGenerator uses) to produce valid Crystal.
    private def infer_all_methods(
      info : ControllerInfo,
      stub_source : String
    )
      return {} of String => String if rails_dir.empty?

      # Find and parse the controller source file
      controller_name = Inflector.underscore(info.name).chomp("_controller")
      source_path = File.join(rails_dir, "app/controllers/#{controller_name}_controller.rb")
      return {} of String => String unless File.exists?(source_path)

      ast = SourceParser.parse(source_path)

      # Apply minimal filter chain to make the code valid Crystal.
      # Skip InstanceVarToLocal — we want ivars preserved for type extraction.
      ast = ast.transform(RespondToHTML.new)
      ast = ast.transform(StripTurboStream.new)
      ast = ast.transform(StripCallbacks.new)

      stub_ast = Crystal::Parser.parse(stub_source)

      # Only call private methods (set_article, article_params, etc.)
      # which set ivars. Skip public actions which have complex
      # bodies (respond_to, redirect_to) that may fail type checking.
      private_methods = info.actions.select { |a| a.is_private && a.body }
      call_sites = private_methods.map do |action|
        Crystal::Call.new(
          Crystal::Call.new(Crystal::Path.new(info.name), "new"),
          action.name
        ).as(Crystal::ASTNode)
      end

      program = Crystal::Program.new
      full_ast = Crystal::Expressions.new([
        Crystal::Require.new("prelude"),
        stub_ast,
        ast,
      ] of Crystal::ASTNode + call_sites)

      normalized = program.normalize(full_ast)
      program.semantic(normalized)

      extract_ivar_types(program, info.name)
    rescue
      {} of String => String
    end

    # Run semantic analysis on a single controller method.
    # Returns the inferred RBS type string, or nil on failure.
    private def infer_single_method(
      controller_name : String,
      method_name : String,
      body : Prism::Node,
      stub_source : String
    ) : String?
      # Parse fresh stubs for each method — semantic analysis mutates
      # AST nodes in place, so they can't be reused across Programs.
      stub_ast = Crystal::Parser.parse(stub_source)
      translated_body = PrismTranslator.new.translate(body)
      translated_body = strip_ivars(translated_body)

      method_def = Crystal::Def.new(method_name, body: translated_body)
      class_def = Crystal::ClassDef.new(
        Crystal::Path.new(controller_name),
        body: method_def
      )

      call_site = Crystal::Assign.new(
        Crystal::Var.new("__rbs_result"),
        Crystal::Call.new(
          Crystal::Call.new(Crystal::Path.new(controller_name), "new"),
          method_name
        )
      )

      program = Crystal::Program.new
      full_ast = Crystal::Expressions.new([
        Crystal::Require.new("prelude"),
        stub_ast,
        class_def,
        call_site,
      ] of Crystal::ASTNode)

      normalized = program.normalize(full_ast)
      typed = program.semantic(normalized)

      # Find the call-site assignment and read its type
      if typed.is_a?(Crystal::Expressions)
        typed.expressions.each do |expr|
          if expr.is_a?(Crystal::Assign) && expr.target.to_s == "__rbs_result"
            if type = expr.value.type?
              return crystal_type_to_rbs(type.to_s)
            end
          end
        end
      end

      nil
    rescue
      nil
    end

    # Extract instance variable types from a controller type
    # after semantic analysis has been run.
    private def extract_ivar_types(
      program : Crystal::Program,
      controller_name : String
    )
      ivar_types = {} of String => String
      controller_type = program.types[controller_name]?

      if controller_type
        controller_type.instance_vars.each do |name, ivar|
          if type = ivar.type?
            rbs_type = crystal_type_to_rbs(type.to_s)
            ivar_types[name] = rbs_type unless rbs_type == "untyped"
          end
        end
      end

      ivar_types
    end

    private def strip_ivars(node : Crystal::ASTNode) : Crystal::ASTNode
      case node
      when Crystal::InstanceVar
        Crystal::Var.new(node.name.lchop("@"))
      when Crystal::Assign
        target = node.target
        value = strip_ivars(node.value)
        if target.is_a?(Crystal::InstanceVar)
          Crystal::Assign.new(Crystal::Var.new(target.name.lchop("@")), value)
        else
          Crystal::Assign.new(target, value)
        end
      when Crystal::Expressions
        Crystal::Expressions.new(node.expressions.map { |e| strip_ivars(e) })
      when Crystal::If
        Crystal::If.new(
          strip_ivars(node.cond),
          strip_ivars(node.then),
          node.else.try { |e| strip_ivars(e) }
        )
      when Crystal::Call
        obj = node.obj.try { |o| strip_ivars(o) }
        args = node.args.map { |a| strip_ivars(a) }
        call = Crystal::Call.new(obj, node.name, args)
        call.block = node.block
        call
      else
        node
      end
    end

    # Map Crystal inferred types to RBS type notation
    private def crystal_type_to_rbs(crystal_type : String) : String
      # Handle nullable types: (Foo | Nil) → Foo?
      if crystal_type.starts_with?("(") && crystal_type.ends_with?(")")
        inner = crystal_type[1..-2]  # strip parens
        parts = inner.split(" | ")
        non_nil = parts.reject { |p| p == "Nil" }
        if non_nil.size == 1 && parts.size > non_nil.size
          return crystal_type_to_rbs(non_nil[0]) + "?"
        elsif non_nil.size > 1
          return non_nil.map { |p| crystal_type_to_rbs(p) }.join(" | ")
        end
      end

      case crystal_type
      when "Nil"             then "void"
      when "Bool"            then "bool"
      when "Int32", "Int64"  then "Integer"
      when "Float32", "Float64" then "Float"
      when "String"          then "String"
      when "Time"            then "Time"
      when /^Array\((.+)\)$/
        inner = crystal_type_to_rbs($1)
        "ActiveRecord::Relation[#{inner}]"
      when "ActionController::Parameters"
        "ActionController::Parameters"
      else
        # Model names and their inner types pass through
        if app.models.has_key?(crystal_type)
          crystal_type
        elsif crystal_type.ends_with?("::Relation")
          model = crystal_type.chomp("::Relation")
          if app.models.has_key?(model)
            "ActiveRecord::Relation[#{model}]"
          else
            "untyped"
          end
        else
          "untyped"
        end
      end
    end

    private def rails_type_to_rbs(rails_type : String) : String
      case rails_type
      when "string", "text"          then "String"
      when "integer", "references"   then "Integer"
      when "float", "decimal"        then "Float"
      when "boolean"                 then "bool"
      when "datetime", "date", "time" then "Time"
      when "json", "jsonb"           then "untyped"
      when "uuid"                    then "String"
      when "binary"                  then "String"
      else                                "untyped"
      end
    end

    private def default_for(crystal_type : String) : String
      case crystal_type
      when "String" then "\"\""
      when "Int64"  then "0_i64"
      when "Float64" then "0.0"
      when "Bool"   then "false"
      when "Time"   then "Time.utc"
      else          "\"\""
      end
    end

    private def mkdir(path : String)
      Dir.mkdir_p(path) unless Dir.exists?(path)
    end
  end
end
