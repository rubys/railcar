# Filter: Transform a Rails model class into the Railcar macro DSL.
#
# Takes the translated Crystal AST of a model and:
#   - Wraps declarations in a `model "table_name" do ... end` block
#   - Adds column declarations from the schema
#   - Generates run_validations override (including belongs_to validators)
#   - Generates dependent: :destroy override
#   - Adds require statements and Railcar module wrapper

require "compiler/crystal/syntax"
require "../generator/inflector"
require "../generator/schema_extractor"
require "../generator/model_extractor"

module Railcar
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

      # Broadcast support: include helpers and render_broadcast_partial
      class_body << Crystal::Include.new(Crystal::Path.new("RouteHelpers"))
      class_body << Crystal::Include.new(Crystal::Path.new("ViewHelpers"))
      class_body << build_render_broadcast_partial

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

      # Add associations from metadata (not from translated AST, which has wrong format)
      model_info.associations.each do |assoc|
        block_stmts << build_association(assoc)
      end

      # Copy non-association, non-validation body expressions (callbacks, etc.)
      case body = node.body
      when Crystal::Expressions
        body.expressions.each do |expr|
          next if expr.is_a?(Crystal::Nop)
          next if is_association_call?(expr)
          next if is_validates_call?(expr)
          block_stmts << expr
        end
      when Crystal::Nop
        # empty
      else
        block_stmts << body if body && !is_association_call?(body) && !is_validates_call?(body)
      end

      # Add validations from metadata
      model_info.validations.each do |v|
        block_stmts << build_validation(v)
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

    private def build_render_broadcast_partial : Crystal::Def
      singular = Inflector.singularize(schema.name)
      ecr_path = "src/views/#{schema.name}/_#{singular}.ecr"

      # article = self
      self_assign = Crystal::Assign.new(
        Crystal::Var.new(singular),
        Crystal::Var.new("self")
      )

      # ECR.embed(path, __str__)
      ecr_call = Crystal::Call.new(
        Crystal::Path.new("ECR"), "embed",
        [Crystal::StringLiteral.new(ecr_path), Crystal::Var.new("__str__")] of Crystal::ASTNode
      )

      # String.build do |__str__| ECR.embed(...) end
      string_build = Crystal::Call.new(
        Crystal::Path.new("String"), "build",
        block: Crystal::Block.new(
          args: [Crystal::Var.new("__str__")],
          body: ecr_call
        )
      )

      body = Crystal::Expressions.new([self_assign, string_build] of Crystal::ASTNode)

      Crystal::Def.new("render_broadcast_partial",
        body: body,
        return_type: Crystal::Path.new("String")
      )
    end

    private def is_association_call?(node : Crystal::ASTNode) : Bool
      node.is_a?(Crystal::Call) && {"has_many", "has_one", "belongs_to"}.includes?(node.as(Crystal::Call).name)
    end

    private def is_validates_call?(node : Crystal::ASTNode) : Bool
      node.is_a?(Crystal::Call) && node.as(Crystal::Call).name == "validates"
    end

    private def build_association(assoc : Association) : Crystal::Call
      singular_table = Inflector.singularize(schema.name)
      case assoc.kind
      when :belongs_to
        target_class = Inflector.classify(assoc.name)
        fk = assoc.options["foreign_key"]? || "#{assoc.name}_id"
        Crystal::Call.new(nil, "belongs_to", [
          Crystal::Call.new(nil, assoc.name),
          Crystal::Path.new(target_class),
        ] of Crystal::ASTNode, named_args: [
          Crystal::NamedArgument.new("foreign_key", Crystal::StringLiteral.new(fk)),
        ])
      when :has_many
        target_class = Inflector.classify(Inflector.singularize(assoc.name))
        fk = assoc.options["foreign_key"]? || "#{singular_table}_id"
        named = [Crystal::NamedArgument.new("foreign_key", Crystal::StringLiteral.new(fk))]
        if dep = assoc.options["dependent"]?
          named << Crystal::NamedArgument.new("dependent", Crystal::SymbolLiteral.new(dep))
        end
        Crystal::Call.new(nil, "has_many", [
          Crystal::Call.new(nil, assoc.name),
          Crystal::Path.new(target_class),
        ] of Crystal::ASTNode, named_args: named)
      when :has_one
        target_class = Inflector.classify(assoc.name)
        fk = assoc.options["foreign_key"]? || "#{singular_table}_id"
        Crystal::Call.new(nil, "has_one", [
          Crystal::Call.new(nil, assoc.name),
          Crystal::Path.new(target_class),
        ] of Crystal::ASTNode, named_args: [
          Crystal::NamedArgument.new("foreign_key", Crystal::StringLiteral.new(fk)),
        ])
      else
        Crystal::Call.new(nil, "# unknown association #{assoc.kind}")
      end
    end

    private def build_validation(v : Validation) : Crystal::Call
      named_args = case v.kind
                   when "presence"
                     [Crystal::NamedArgument.new("presence", Crystal::BoolLiteral.new(true))]
                   when "length"
                     entries = v.options.map do |k, val|
                       Crystal::NamedTupleLiteral::Entry.new(k, Crystal::NumberLiteral.new(val))
                     end
                     [Crystal::NamedArgument.new("length", Crystal::NamedTupleLiteral.new(entries))]
                   else
                     [Crystal::NamedArgument.new(v.kind, Crystal::BoolLiteral.new(true))]
                   end
      Crystal::Call.new(nil, "validates", [Crystal::Call.new(nil, v.field)] of Crystal::ASTNode, named_args: named_args)
    end
  end
end
