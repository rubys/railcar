# Filter: Transform a Rails model class into the Ruby2CR macro DSL.
#
# Takes the translated Crystal AST of a model and:
#   - Wraps declarations in a `model "table_name" do ... end` block
#   - Adds column declarations from the schema
#   - Generates run_validations override (including belongs_to validators)
#   - Generates dependent: :destroy override
#   - Adds require statements and Ruby2CR module wrapper

require "compiler/crystal/syntax"
require "../generator/inflector"
require "../generator/schema_extractor"
require "../generator/model_extractor"

module Ruby2CR
  class ModelBoilerplate < Crystal::Transformer
    getter schema : TableSchema
    getter model_info : ModelInfo

    def initialize(@schema, @model_info)
    end

    def transform(node : Crystal::ClassDef) : Crystal::ASTNode
      class_body = [] of Crystal::ASTNode

      # Build model("table_name") { columns + existing declarations } block
      class_body << build_model_block(node)

      # run_validations override
      validations_def = build_run_validations
      class_body << validations_def if validations_def

      # dependent: :destroy override
      destroy_def = build_destroy_override
      class_body << destroy_def if destroy_def

      Crystal::ClassDef.new(
        node.name,
        body: Crystal::Expressions.new(class_body),
        superclass: Crystal::Path.new("ApplicationRecord")
      )
    end

    private def build_model_block(node : Crystal::ClassDef) : Crystal::Call
      block_stmts = [] of Crystal::ASTNode

      # Add column declarations from schema
      schema.columns.each do |col|
        crystal_type = SchemaExtractor.crystal_type(col.type)
        block_stmts << Crystal::Call.new(nil, "column", [
          Crystal::Call.new(nil, col.name),
          Crystal::Path.new(crystal_type),
        ] of Crystal::ASTNode)
      end

      # Copy existing class body (has_many, belongs_to, validates, etc.)
      case body = node.body
      when Crystal::Expressions
        body.expressions.each do |expr|
          next if expr.is_a?(Crystal::Nop)
          block_stmts << expr
        end
      when Crystal::Nop
        # empty
      else
        block_stmts << body if body
      end

      block = Crystal::Block.new(body: Crystal::Expressions.new(block_stmts))
      Crystal::Call.new(nil, "model", [
        Crystal::StringLiteral.new(schema.name),
      ] of Crystal::ASTNode, block: block)
    end

    private def build_run_validations : Crystal::Def?
      presence_validations = model_info.validations.select { |v| v.kind == "presence" }
      length_validations = model_info.validations.select { |v| v.kind == "length" }
      belongs_to_assocs = model_info.associations.select { |a| a.kind == :belongs_to }

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
      def_node.visibility = Crystal::Visibility::Private
      def_node
    end

    private def build_destroy_override : Crystal::Def?
      destroy_assocs = model_info.associations.select { |a| a.options["dependent"]? == "destroy" }
      return nil if destroy_assocs.empty?

      calls = [] of Crystal::ASTNode
      destroy_assocs.each do |a|
        calls << Crystal::Call.new(
          Crystal::Call.new(nil, a.name),
          "destroy_all"
        )
      end
      calls << Crystal::Call.new(nil, "super")

      def_node = Crystal::Def.new("destroy",
        body: Crystal::Expressions.new(calls),
        return_type: Crystal::Path.new("Bool")
      )
      def_node
    end
  end
end
