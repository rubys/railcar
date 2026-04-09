# Generates RBS type signature files from extracted Rails metadata.
#
# Uses the same extractors as the Crystal code generator, but outputs
# .rbs files instead of .cr files.

require "./app_model"
require "./schema_extractor"

module Ruby2CR
  class RbsGenerator
    getter app : AppModel

    def initialize(@app)
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
      app.controllers.each do |info|
        rbs = String.build do |io|
          io << "class #{info.name} < #{info.superclass}\n"

          info.actions.each do |action|
            next if action.is_private
            io << "  def #{action.name}: void\n"
          end

          # Private methods
          has_private = info.actions.any?(&.is_private)
          if has_private
            io << "\n  private\n\n"
            info.actions.each do |action|
              next unless action.is_private
              io << "  def #{action.name}: void\n"
            end
          end

          io << "end\n"
        end

        basename = Inflector.underscore(info.name)
        File.write(File.join(output_dir, "#{basename}.rbs"), rbs)
        puts "  #{basename}.rbs"
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

    private def mkdir(path : String)
      Dir.mkdir_p(path) unless Dir.exists?(path)
    end
  end
end
