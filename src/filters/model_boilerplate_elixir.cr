# Filter: Transform a Rails model class into Elixir-shaped Crystal AST.
#
# Produces a Crystal::ClassDef whose body contains Crystal::Def nodes
# representing Elixir module functions (each with "record" as first param).
# The Cr2Ex emitter walks this AST and emits Elixir syntax.
#
# Input (translated from Rails via Prism):
#   class Article < ApplicationRecord
#     has_many :comments, dependent: :destroy
#     validates :title, presence: true
#   end
#
# Output (Crystal AST shaped for Elixir emission):
#   class Article < ApplicationRecord
#     def comments(record); ...; end        # → def comments(record) do
#     def run_validations(record); ...; end  # → def run_validations(record) do
#     def delete(record); ...; super; end    # → def delete(record) do
#   end

require "compiler/crystal/syntax"
require "../generator/inflector"
require "../generator/schema_extractor"
require "../generator/model_extractor"
require "./rails_dsl"

module Railcar
  class ModelBoilerplateElixir < Crystal::Transformer
    getter schema : TableSchema
    getter model_info : ModelInfo
    getter app_module : String

    def initialize(@schema, @model_info, @app_module)
    end

    def transform(node : Crystal::ClassDef) : Crystal::ASTNode
      class_body = [] of Crystal::ASTNode

      # Association methods
      model_info.associations.each do |assoc|
        class_body << build_association_method(assoc)
      end

      # Validations
      if validations_def = build_run_validations
        class_body << validations_def
      end

      # Destroy override for dependent: :destroy
      if destroy_def = build_destroy_override
        class_body << destroy_def
      end

      # Copy custom methods (skip DSL calls and callbacks)
      case body = node.body
      when Crystal::Expressions
        body.expressions.each do |expr|
          next if expr.is_a?(Crystal::Nop)
          next if Railcar.rails_model_dsl?(expr)
          next if is_callback?(expr)
          class_body << expr
        end
      when Crystal::Nop
        # empty
      else
        if body && !Railcar.rails_model_dsl?(body) && !is_callback?(body)
          class_body << body
        end
      end

      Crystal::ClassDef.new(
        node.name,
        body: Crystal::Expressions.new(class_body),
        superclass: Crystal::Path.new("ApplicationRecord")
      )
    end

    def transform(node : Crystal::ASTNode) : Crystal::ASTNode
      super
    end

    private def build_association_method(assoc : Association) : Crystal::ASTNode
      singular_table = Inflector.singularize(schema.name)
      case assoc.kind
      when :has_many
        target = Inflector.classify(Inflector.singularize(assoc.name))
        fk = assoc.options["foreign_key"]? || "#{singular_table}_id"
        # Build: Blog.Target.where(%{fk: record.id})
        where_call = Crystal::Call.new(
          Crystal::Path.new([app_module, target]),
          "where",
          [Crystal::HashLiteral.new([
            Crystal::HashLiteral::Entry.new(
              Crystal::SymbolLiteral.new(fk),
              Crystal::Call.new(Crystal::Var.new("record"), "id")
            ),
          ])] of Crystal::ASTNode
        )
        build_def(assoc.name, where_call)
      when :belongs_to
        target = Inflector.classify(assoc.name)
        fk = assoc.options["foreign_key"]? || "#{assoc.name}_id"
        # Build: Blog.Target.find(record.fk)
        find_call = Crystal::Call.new(
          Crystal::Path.new([app_module, target]),
          "find",
          [Crystal::Call.new(Crystal::Var.new("record"), fk)] of Crystal::ASTNode
        )
        build_def(assoc.name, find_call)
      else
        Crystal::Nop.new
      end
    end

    private def build_run_validations : Crystal::Def?
      presence_validations = model_info.validations.select { |v| v.kind == "presence" }
      length_validations = model_info.validations.select { |v| v.kind == "length" }
      belongs_to_assocs = model_info.associations.select { |a| a.kind == :belongs_to }

      return nil if presence_validations.empty? && length_validations.empty? && belongs_to_assocs.empty?

      stmts = [] of Crystal::ASTNode

      belongs_to_assocs.each do |a|
        target = Inflector.classify(a.name)
        stmts << build_validation_call("validate_belongs_to", a.name, target: "#{app_module}.#{target}")
      end

      presence_validations.each do |v|
        stmts << build_validation_call("validate_presence", v.field)
      end

      length_validations.each do |v|
        stmts << build_validation_call("validate_length", v.field, options: v.options)
      end

      record_arg = Crystal::Arg.new("record")
      Crystal::Def.new("run_validations", [record_arg],
        Crystal::Expressions.new(stmts))
    end

    # Build a validation call as a Crystal AST node.
    # The emitter recognizes these by method name pattern and emits
    # Elixir-style: errors = errors ++ Railcar.Validation.validate_*(record, :field, ...)
    private def build_validation_call(kind : String, field : String,
                                       target : String? = nil,
                                       options : Hash(String, String)? = nil) : Crystal::Call
      args = [
        Crystal::Var.new("record"),
        Crystal::SymbolLiteral.new(field),
      ] of Crystal::ASTNode

      if target
        args << Crystal::Path.new(target.split("."))
      end

      named_args = nil
      if options
        named_args = options.map do |k, v|
          Crystal::NamedArgument.new(k, Crystal::NumberLiteral.new(v))
        end
      end

      Crystal::Call.new(
        Crystal::Path.new(["Railcar", "Validation"]),
        kind,
        args,
        named_args: named_args
      )
    end

    private def build_destroy_override : Crystal::Def?
      destroy_assocs = model_info.associations.select { |a| a.options["dependent"]? == "destroy" }
      return nil if destroy_assocs.empty?

      stmts = [] of Crystal::ASTNode
      destroy_assocs.each do |a|
        # comments(record) — call association method
        stmts << Crystal::Call.new(nil, a.name, [Crystal::Var.new("record")] of Crystal::ASTNode)
      end
      stmts << Crystal::Call.new(nil, "super", [Crystal::Var.new("record")] of Crystal::ASTNode)

      record_arg = Crystal::Arg.new("record")
      Crystal::Def.new("delete", [record_arg],
        Crystal::Expressions.new(stmts))
    end

    private def build_def(name : String, body : Crystal::ASTNode) : Crystal::Def
      record_arg = Crystal::Arg.new("record")
      Crystal::Def.new(name, [record_arg], body)
    end

    private def is_callback?(node : Crystal::ASTNode) : Bool
      return false unless node.is_a?(Crystal::Call)
      Railcar::RAILS_MODEL_CALLBACKS.includes?(node.as(Crystal::Call).name)
    end
  end
end
