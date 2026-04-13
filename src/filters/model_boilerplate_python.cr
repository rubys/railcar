# Filter: Transform a Rails model class into macro-free Crystal for Python emission.
#
# Like ModelBoilerplate but produces explicit methods instead of macro calls.
# The output is plain Crystal that program.semantic can type and cr2py can emit.
#
# Input (translated from Rails via Prism):
#   class Article < ApplicationRecord
#     has_many :comments, dependent: :destroy
#     validates :title, presence: true
#   end
#
# Output:
#   class Article < ApplicationRecord
#     def self.table_name : String; "articles"; end
#     def title; attributes["title"]? || ""; end
#     def title=(value); attributes["title"] = value; end
#     def comments; CollectionProxy(Comment).new(self, "article_id"); end
#     def run_validations; ...; end
#     def destroy : Bool; comments.destroy_all; super; end
#   end

require "compiler/crystal/syntax"
require "../generator/inflector"
require "../generator/schema_extractor"
require "../generator/model_extractor"

module Railcar
  class ModelBoilerplatePython < Crystal::Transformer
    getter schema : TableSchema
    getter model_info : ModelInfo

    def initialize(@schema, @model_info)
    end

    def transform(node : Crystal::ClassDef) : Crystal::ASTNode
      class_body = [] of Crystal::ASTNode

      # table_name class method
      class_body << Crystal::Parser.parse(
        "def self.table_name : String\n  \"#{schema.name}\"\nend"
      )

      # Column getters and setters
      schema.columns.each do |col|
        next if col.name == "id"  # inherited from ApplicationRecord
        crystal_type = SchemaExtractor.crystal_type(col.type)
        default = case col.type.downcase
                  when "integer" then "0_i64"
                  when "boolean" then "false"
                  when "float", "real", "double" then "0.0"
                  else "\"\""
                  end
        class_body << Crystal::Parser.parse(
          "def #{col.name} : #{crystal_type}\n  (attributes[\"#{col.name}\"]? || #{default}).as(#{crystal_type})\nend"
        )
        class_body << Crystal::Parser.parse(
          "def #{col.name}=(value : #{crystal_type})\n  attributes[\"#{col.name}\"] = value\nend"
        )
      end

      # Association methods
      model_info.associations.each do |assoc|
        class_body << build_association_method(assoc)
      end

      # Copy custom methods from original class (not associations/validations)
      case body = node.body
      when Crystal::Expressions
        body.expressions.each do |expr|
          next if expr.is_a?(Crystal::Nop)
          next if is_rails_dsl_call?(expr)
          class_body << expr
        end
      when Crystal::Nop
        # empty
      else
        if body && !is_rails_dsl_call?(body)
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
          "def #{assoc.name}\n  MODEL_REGISTRY[\"#{target}\"].find(attributes[\"#{fk}\"]?.as(Int64))\nend"
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
          fk_val = attributes["#{fk}"]?
          if fk_val.nil?
            errors.add("#{a.name}", "must exist")
          else
            begin
              MODEL_REGISTRY["#{target}"].find(fk_val.as(Int64))
            rescue
              errors.add("#{a.name}", "must exist")
            end
          end
        CR
      end

      presence_validations.each do |v|
        stmts << <<-CR
          val = attributes["#{v.field}"]?
          if val.nil? || (val.is_a?(String) && val.as(String).empty?)
            errors.add("#{v.field}", "can't be blank")
          end
        CR
      end

      length_validations.each do |v|
        if min = v.options["minimum"]?
          stmts << <<-CR
            val = attributes["#{v.field}"]?
            if val.is_a?(String) && val.as(String).size < #{min}
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

    private def is_rails_dsl_call?(node : Crystal::ASTNode) : Bool
      return false unless node.is_a?(Crystal::Call)
      call = node.as(Crystal::Call)
      # Skip any class-level call (no receiver) that isn't a method definition
      # These are Rails DSL calls: has_many, validates, broadcasts_to, callbacks, etc.
      return false if call.obj  # has a receiver — it's a method call, keep it
      name = call.name
      {"has_many", "has_one", "belongs_to", "validates",
       "broadcasts_to", "broadcasts",
       "after_save", "after_destroy", "after_create", "after_update",
       "after_create_commit", "after_update_commit", "after_destroy_commit",
       "before_save", "before_destroy", "before_create", "before_update",
       "scope", "enum", "delegate", "accepts_nested_attributes_for"}.includes?(name)
    end
  end
end
