# Filter: Transform a Rails model class into macro-free Crystal for Python emission.
#
# Produces declarative COLUMNS/property declarations that program.semantic can type.
# The Python runtime uses COLUMNS + setattr for direct attribute access.
#
# Input (translated from Rails via Prism):
#   class Article < ApplicationRecord
#     has_many :comments, dependent: :destroy
#     validates :title, presence: true
#   end
#
# Output:
#   class Article < ApplicationRecord
#     COLUMNS = ["title", "body", "created_at", "updated_at"]
#     property title : String = ""
#     property body : String = ""
#     def self.table_name : String; "articles"; end
#     def comments; CollectionProxy.new(self, "article_id", "Comment"); end
#     def run_validations; ...; end
#     def destroy : Bool; comments.destroy_all; super; end
#   end

require "compiler/crystal/syntax"
require "../generator/inflector"
require "../generator/schema_extractor"
require "../generator/model_extractor"
require "./rails_dsl"

module Railcar
  class ModelBoilerplatePython < Crystal::Transformer
    getter schema : TableSchema
    getter model_info : ModelInfo

    def initialize(@schema, @model_info)
    end

    def transform(node : Crystal::ClassDef) : Crystal::ASTNode
      class_body = [] of Crystal::ASTNode

      # TABLE and table_name — TABLE is used by Python runtime, table_name for Crystal compat
      class_body << Crystal::Parser.parse("TABLE = \"#{schema.name}\"")
      class_body << Crystal::Parser.parse(
        "def self.table_name : String\n  \"#{schema.name}\"\nend"
      )

      # COLUMNS constant — used by Python runtime for direct attribute access
      col_names = schema.columns.reject { |c| c.name == "id" }.map { |c| "\"#{c.name}\"" }
      class_body << Crystal::Parser.parse(
        "COLUMNS = [#{col_names.join(", ")}] of String"
      )

      # Instance variable declarations — for program.semantic type checking only.
      # The emitter emits these as comments (TypeDeclaration → "# name: type").
      # The Python runtime uses COLUMNS + setattr for direct attribute access.
      schema.columns.each do |col|
        next if col.name == "id"
        # Use String for datetime columns (Python stores as ISO string)
        crystal_type = case col.type.downcase
                       when "datetime", "date", "time" then "String"
                       else SchemaExtractor.crystal_type(col.type)
                       end
        default = case col.type.downcase
                  when "integer" then "0_i64"
                  when "boolean" then "false"
                  when "float", "real", "double" then "0.0"
                  else "\"\""
                  end
        class_body << Crystal::Parser.parse("@#{col.name} : #{crystal_type} = #{default}")
      end

      # Association methods
      model_info.associations.each do |assoc|
        class_body << build_association_method(assoc)
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

      # run_validations override
      if validations_def = build_run_validations
        class_body << validations_def
      end

      # dependent: :destroy override
      if destroy_def = build_destroy_override
        class_body << destroy_def
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
        Crystal::Parser.parse(
          "def #{assoc.name} : CollectionProxy\n  CollectionProxy.new(self, \"#{fk}\", \"#{target}\")\nend"
        )
      when :belongs_to
        target = Inflector.classify(assoc.name)
        fk = assoc.options["foreign_key"]? || "#{assoc.name}_id"
        Crystal::Parser.parse(
          "def #{assoc.name} : ApplicationRecord\n  MODEL_REGISTRY[\"#{target}\"].find(@#{fk}.as(Int64))\nend"
        )
      else
        Crystal::Nop.new
      end
    end

    private def build_run_validations : Crystal::Def?
      presence_validations = model_info.validations.select { |v| v.kind == "presence" }
      length_validations = model_info.validations.select { |v| v.kind == "length" }
      belongs_to_assocs = model_info.associations.select { |a| a.kind == :belongs_to }

      return nil if presence_validations.empty? && length_validations.empty? && belongs_to_assocs.empty?

      stmts = [] of String

      belongs_to_assocs.each do |a|
        target = Inflector.classify(a.name)
        fk = a.options["foreign_key"]? || "#{a.name}_id"
        stmts << <<-CR
          if @#{fk}.nil?
            errors.add("#{a.name}", "must exist")
          else
            begin
              MODEL_REGISTRY["#{target}"].find(@#{fk}.as(Int64))
            rescue
              errors.add("#{a.name}", "must exist")
            end
          end
        CR
      end

      presence_validations.each do |v|
        stmts << <<-CR
          if @#{v.field}.nil? || (@#{v.field}.is_a?(String) && @#{v.field}.as(String).empty?)
            errors.add("#{v.field}", "can't be blank")
          end
        CR
      end

      length_validations.each do |v|
        if min = v.options["minimum"]?
          stmts << <<-CR
            if @#{v.field}.is_a?(String) && @#{v.field}.as(String).size < #{min}
              errors.add("#{v.field}", "is too short (minimum is #{min} characters)")
            end
          CR
        end
      end

      Crystal::Parser.parse("def run_validations\n#{stmts.join("\n")}\nend").as(Crystal::Def)
    end

    private def build_destroy_override : Crystal::Def?
      destroy_assocs = model_info.associations.select { |a| a.options["dependent"]? == "destroy" }
      return nil if destroy_assocs.empty?

      stmts = destroy_assocs.map { |a| "#{a.name}.destroy_all" }
      stmts << "super"

      Crystal::Parser.parse("def destroy : Bool\n#{stmts.join("\n")}\nend").as(Crystal::Def)
    end

    private def is_callback?(node : Crystal::ASTNode) : Bool
      return false unless node.is_a?(Crystal::Call)
      Railcar::RAILS_MODEL_CALLBACKS.includes?(node.as(Crystal::Call).name)
    end
  end
end
