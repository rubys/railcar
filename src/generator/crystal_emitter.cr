# Generates Crystal model source files from extracted schema and model metadata.
#
# Takes TableSchema (from migrations) + ModelInfo (from model files) and
# produces Crystal source that uses the Ruby2CR runtime macros.

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
      io = IO::Memory.new

      io << "require \"../runtime/application_record\"\n"
      io << "require \"../runtime/relation\"\n"
      io << "require \"../runtime/collection_proxy\"\n"
      io << "\n"
      io << "module Ruby2CR\n"
      io << "  class #{model.name} < ApplicationRecord\n"
      io << "    model #{schema.name.inspect} do\n"

      # Columns (skip id, it's implicit)
      schema.columns.each do |col|
        crystal_type = SchemaExtractor.crystal_type(col.type)
        io << "      column #{col.name}, #{crystal_type}\n"
      end
      io << "\n" unless schema.columns.empty?

      # Associations
      model.associations.each do |assoc|
        target_class = classify(assoc.name)
        # For belongs_to, the target is the singular form
        # For has_many, the target is already the class name from singular
        case assoc.kind
        when :belongs_to
          fk = assoc.options["foreign_key"]? || "#{assoc.name}_id"
          io << "      belongs_to #{assoc.name}, #{target_class}, foreign_key: #{fk.inspect}\n"
        when :has_many
          target_class = classify(singularize(assoc.name))
          fk = assoc.options["foreign_key"]? || "#{singularize(schema.name)}_id"
          dep = assoc.options["dependent"]?
          if dep
            io << "      has_many #{assoc.name}, #{target_class}, foreign_key: #{fk.inspect}, dependent: :#{dep}\n"
          else
            io << "      has_many #{assoc.name}, #{target_class}, foreign_key: #{fk.inspect}\n"
          end
        when :has_one
          target_class = classify(assoc.name)
          fk = assoc.options["foreign_key"]? || "#{singularize(schema.name)}_id"
          io << "      has_one #{assoc.name}, #{target_class}, foreign_key: #{fk.inspect}\n"
        end
      end
      io << "\n" unless model.associations.empty?

      # Validations
      model.validations.each do |v|
        case v.kind
        when "presence"
          io << "      validates #{v.field}, presence: true\n"
        when "length"
          opts = v.options.map { |k, val| "#{k}: #{val}" }.join(", ")
          io << "      validates #{v.field}, length: {#{opts}}\n"
        when "format"
          io << "      validates #{v.field}, format: true\n"
        when "uniqueness"
          io << "      validates #{v.field}, uniqueness: true\n"
        when "numericality"
          io << "      validates #{v.field}, numericality: true\n"
        end
      end

      io << "    end\n"
      io << "\n"

      # Generate run_validations override
      presence_validations = model.validations.select { |v| v.kind == "presence" }
      length_validations = model.validations.select { |v| v.kind == "length" }
      belongs_to_assocs = model.associations.select { |a| a.kind == :belongs_to }
      has_any_validations = !presence_validations.empty? || !length_validations.empty? || !belongs_to_assocs.empty?

      if has_any_validations
        io << "    private def run_validations\n"
        belongs_to_assocs.each do |a|
          io << "      self.class.validate_belongs_to_#{a.name}(self)\n"
        end
        presence_validations.each do |v|
          io << "      self.class.validate_presence_#{v.field}(self)\n"
        end
        length_validations.each do |v|
          io << "      self.class.validate_length_#{v.field}(self)\n"
        end
        io << "    end\n"
        io << "\n"
      end

      # Generate dependent: :destroy override
      destroy_assocs = model.associations.select { |a| a.options["dependent"]? == "destroy" }
      unless destroy_assocs.empty?
        io << "    def destroy : Bool\n"
        destroy_assocs.each do |a|
          io << "      #{a.name}.destroy_all\n"
        end
        io << "      super\n"
        io << "    end\n"
      end

      io << "  end\n"
      io << "end\n"

      io.to_s
    end

    # Generate models for an entire Rails app
    def self.generate_all(migration_dir : String, models_dir : String) : Hash(String, String)
      schemas = SchemaExtractor.extract_all(migration_dir)
      results = {} of String => String

      # Build table_name → schema map
      schema_map = {} of String => TableSchema
      schemas.each { |s| schema_map[s.name] = s }

      # Parse each model file
      model_files = Dir.glob(File.join(models_dir, "*.rb")).sort
      model_files.each do |path|
        model = ModelExtractor.extract_file(path)
        next unless model
        next if model.name == "ApplicationRecord"

        # Find the matching schema
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
