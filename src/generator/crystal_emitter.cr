# Generates Crystal model source files from extracted schema and model metadata.
#
# Takes TableSchema (from migrations) + ModelInfo (from model files) and
# produces Crystal source that uses the Ruby2CR runtime macros.
#
# Uses Crystal's own AST for code generation, ensuring output is valid Crystal.

require "compiler/crystal/syntax"
require "./schema_extractor"
require "./model_extractor"
require "./inflector"

module Ruby2CR
  class CrystalEmitter
    # Delegate to Inflector for backward compatibility
    def self.classify(word : String) : String
      Inflector.classify(word)
    end

    def self.singularize(word : String) : String
      Inflector.singularize(word)
    end

    def self.pluralize(word : String) : String
      Inflector.pluralize(word)
    end

    # Generate a complete Crystal model file
    def self.generate(schema : TableSchema, model : ModelInfo) : String
      requires = [
        Crystal::Require.new("../runtime/application_record"),
        Crystal::Require.new("../runtime/relation"),
        Crystal::Require.new("../runtime/collection_proxy"),
      ] of Crystal::ASTNode

      class_def = build_class(schema, model)
      mod_def = Crystal::ModuleDef.new(
        Crystal::Path.new("Ruby2CR"),
        body: class_def
      )

      nodes = requires + [mod_def] of Crystal::ASTNode
      Crystal::Expressions.new(nodes).to_s + "\n"
    end

    private def self.build_class(schema : TableSchema, model : ModelInfo) : Crystal::ClassDef
      body_nodes = [] of Crystal::ASTNode

      # model "table_name" do ... end
      body_nodes << build_model_block(schema, model)

      # run_validations override
      validations_def = build_validations(model)
      body_nodes << validations_def if validations_def

      # dependent: :destroy override
      destroy_def = build_destroy(model)
      body_nodes << destroy_def if destroy_def

      Crystal::ClassDef.new(
        Crystal::Path.new(model.name),
        body: Crystal::Expressions.new(body_nodes),
        superclass: Crystal::Path.new("ApplicationRecord")
      )
    end

    private def self.build_model_block(schema : TableSchema, model : ModelInfo) : Crystal::Call
      block_stmts = [] of Crystal::ASTNode

      # Columns
      schema.columns.each do |col|
        crystal_type = SchemaExtractor.crystal_type(col.type)
        block_stmts << Crystal::Call.new(nil, "column", [
          Crystal::Call.new(nil, col.name),
          Crystal::Path.new(crystal_type),
        ] of Crystal::ASTNode)
      end

      # Associations
      model.associations.each do |assoc|
        block_stmts << build_association(assoc, schema)
      end

      # Validations
      model.validations.each do |v|
        block_stmts << build_validation(v)
      end

      block = Crystal::Block.new(body: Crystal::Expressions.new(block_stmts))
      Crystal::Call.new(nil, "model", [
        Crystal::StringLiteral.new(schema.name),
      ] of Crystal::ASTNode, block: block)
    end

    private def self.build_association(assoc : Association, schema : TableSchema) : Crystal::Call
      case assoc.kind
      when :belongs_to
        target_class = classify(assoc.name)
        fk = assoc.options["foreign_key"]? || "#{assoc.name}_id"
        Crystal::Call.new(nil, "belongs_to", [
          Crystal::Call.new(nil, assoc.name),
          Crystal::Path.new(target_class),
        ] of Crystal::ASTNode, named_args: [
          Crystal::NamedArgument.new("foreign_key", Crystal::StringLiteral.new(fk)),
        ])
      when :has_many
        target_class = classify(singularize(assoc.name))
        fk = assoc.options["foreign_key"]? || "#{singularize(schema.name)}_id"
        named_args = [
          Crystal::NamedArgument.new("foreign_key", Crystal::StringLiteral.new(fk)),
        ]
        if dep = assoc.options["dependent"]?
          named_args << Crystal::NamedArgument.new("dependent", Crystal::SymbolLiteral.new(dep))
        end
        Crystal::Call.new(nil, "has_many", [
          Crystal::Call.new(nil, assoc.name),
          Crystal::Path.new(target_class),
        ] of Crystal::ASTNode, named_args: named_args)
      when :has_one
        target_class = classify(assoc.name)
        fk = assoc.options["foreign_key"]? || "#{singularize(schema.name)}_id"
        Crystal::Call.new(nil, "has_one", [
          Crystal::Call.new(nil, assoc.name),
          Crystal::Path.new(target_class),
        ] of Crystal::ASTNode, named_args: [
          Crystal::NamedArgument.new("foreign_key", Crystal::StringLiteral.new(fk)),
        ])
      else
        # Shouldn't happen, but satisfy Crystal type checker
        Crystal::Call.new(nil, "# unknown association #{assoc.kind}")
      end
    end

    private def self.build_validation(v : Validation) : Crystal::Call
      named_args = case v.kind
                   when "presence"
                     [Crystal::NamedArgument.new("presence", Crystal::BoolLiteral.new(true))]
                   when "length"
                     hash_entries = v.options.map do |k, val|
                       Crystal::NamedArgument.new(k, Crystal::NumberLiteral.new(val))
                     end
                     # length: {minimum: 10} — use a NamedTupleLiteral
                     entries = v.options.map do |k, val|
                       Crystal::NamedTupleLiteral::Entry.new(k, Crystal::NumberLiteral.new(val))
                     end
                     [Crystal::NamedArgument.new("length", Crystal::NamedTupleLiteral.new(entries))]
                   when "format"
                     [Crystal::NamedArgument.new("format", Crystal::BoolLiteral.new(true))]
                   when "uniqueness"
                     [Crystal::NamedArgument.new("uniqueness", Crystal::BoolLiteral.new(true))]
                   when "numericality"
                     [Crystal::NamedArgument.new("numericality", Crystal::BoolLiteral.new(true))]
                   else
                     [] of Crystal::NamedArgument
                   end

      Crystal::Call.new(nil, "validates", [
        Crystal::Call.new(nil, v.field),
      ] of Crystal::ASTNode, named_args: named_args)
    end

    private def self.build_validations(model : ModelInfo) : Crystal::ASTNode?
      presence_validations = model.validations.select { |v| v.kind == "presence" }
      length_validations = model.validations.select { |v| v.kind == "length" }
      belongs_to_assocs = model.associations.select { |a| a.kind == :belongs_to }

      return nil if presence_validations.empty? && length_validations.empty? && belongs_to_assocs.empty?

      calls = [] of Crystal::ASTNode
      belongs_to_assocs.each do |a|
        calls << Crystal::Call.new(
          Crystal::Call.new(Crystal::Var.new("self"), "class"),
          "validate_belongs_to_#{a.name}",
          [Crystal::Var.new("self")] of Crystal::ASTNode
        )
      end
      presence_validations.each do |v|
        calls << Crystal::Call.new(
          Crystal::Call.new(Crystal::Var.new("self"), "class"),
          "validate_presence_#{v.field}",
          [Crystal::Var.new("self")] of Crystal::ASTNode
        )
      end
      length_validations.each do |v|
        calls << Crystal::Call.new(
          Crystal::Call.new(Crystal::Var.new("self"), "class"),
          "validate_length_#{v.field}",
          [Crystal::Var.new("self")] of Crystal::ASTNode
        )
      end

      def_node = Crystal::Def.new("run_validations", body: Crystal::Expressions.new(calls))
      Crystal::VisibilityModifier.new(Crystal::Visibility::Private, def_node)
    end

    private def self.build_destroy(model : ModelInfo) : Crystal::Def?
      destroy_assocs = model.associations.select { |a| a.options["dependent"]? == "destroy" }
      return nil if destroy_assocs.empty?

      calls = destroy_assocs.map do |a|
        Crystal::Call.new(Crystal::Call.new(nil, a.name), "destroy_all").as(Crystal::ASTNode)
      end
      calls << Crystal::Call.new(nil, "super").as(Crystal::ASTNode)

      Crystal::Def.new("destroy",
        body: Crystal::Expressions.new(calls),
        return_type: Crystal::Path.new("Bool")
      )
    end

    # Generate models for an entire Rails app
    def self.generate_all(migration_dir : String, models_dir : String) : Hash(String, String)
      schemas = SchemaExtractor.extract_all(migration_dir)
      results = {} of String => String

      schema_map = {} of String => TableSchema
      schemas.each { |s| schema_map[s.name] = s }

      model_files = Dir.glob(File.join(models_dir, "*.rb")).sort
      model_files.each do |path|
        model = ModelExtractor.extract_file(path)
        next unless model
        next if model.name == "ApplicationRecord"

        table_name = pluralize(model.name.gsub(/([A-Z])/) { |m| "_#{m.downcase}" }.lstrip('_'))
        schema = schema_map[table_name]?
        next unless schema

        filename = File.basename(path, ".rb") + ".cr"
        results[filename] = generate(schema, model)
      end

      results
    end
  end
end
