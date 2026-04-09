# Generates Crystal fixture loading code from Rails YAML fixtures.
#
# Parses fixture YAML files, resolves associations (e.g. `article: one`),
# and generates setup code that creates records in dependency order.

require "yaml"
require "./schema_extractor"
require "./model_extractor"
require "./crystal_emitter"

module Railcar
  record FixtureRecord, label : String, fields : Hash(String, String)

  record FixtureTable, name : String, records : Array(FixtureRecord)

  class FixtureLoader
    # Parse all fixture YAML files from a directory
    def self.load_all(fixtures_dir : String) : Array(FixtureTable)
      tables = [] of FixtureTable
      return tables unless Dir.exists?(fixtures_dir)

      Dir.glob(File.join(fixtures_dir, "*.yml")).sort.each do |path|
        table = load_file(path)
        tables << table if table && !table.records.empty?
      end

      tables
    end

    def self.load_file(path : String) : FixtureTable?
      table_name = File.basename(path, ".yml")
      content = File.read(path)
      yaml = YAML.parse(content)
      return nil unless yaml.as_h?

      records = [] of FixtureRecord
      yaml.as_h.each do |label, fields|
        next unless fields.as_h?
        field_hash = {} of String => String
        fields.as_h.each do |k, v|
          field_hash[k.as_s] = v.as_s? || v.as_i?.try(&.to_s) || v.as_f?.try(&.to_s) || v.to_s
        end
        records << FixtureRecord.new(label.as_s, field_hash)
      end

      FixtureTable.new(table_name, records)
    end

    # Sort tables by dependency order (tables with FK references come after their targets)
    def self.sort_by_dependency(tables : Array(FixtureTable), models : Hash(String, ModelInfo)) : Array(FixtureTable)
      # Build dependency graph from associations
      deps = {} of String => Array(String)
      tables.each do |table|
        singular = CrystalEmitter.singularize(table.name)
        model_name = CrystalEmitter.classify(singular)
        model = models[model_name]?

        table_deps = [] of String
        if model
          model.associations.each do |assoc|
            if assoc.kind == :belongs_to
              target_table = CrystalEmitter.pluralize(assoc.name)
              table_deps << target_table
            end
          end
        end
        deps[table.name] = table_deps
      end

      # Topological sort
      sorted = [] of FixtureTable
      visited = Set(String).new
      table_map = {} of String => FixtureTable
      tables.each { |t| table_map[t.name] = t }

      tables.each do |table|
        topo_visit(table.name, deps, visited, sorted, table_map)
      end

      sorted
    end

    private def self.topo_visit(name : String, deps : Hash(String, Array(String)), visited : Set(String), sorted : Array(FixtureTable), table_map : Hash(String, FixtureTable))
      return if visited.includes?(name)
      visited << name

      deps[name]?.try &.each do |dep|
        topo_visit(dep, deps, visited, sorted, table_map)
      end

      sorted << table_map[name] if table_map.has_key?(name)
    end

    # Generate Crystal spec helper code for fixture loading
    def self.generate_fixture_helper(tables : Array(FixtureTable), models : Hash(String, ModelInfo)) : String
      sorted = sort_by_dependency(tables, models)

      io = IO::Memory.new
      io << "# Generated fixture helpers\n\n"

      # Fixture record storage
      sorted.each do |table|
        singular = CrystalEmitter.singularize(table.name)
        model_class = CrystalEmitter.classify(singular)
        io << "FIXTURE_#{table.name.upcase} = {} of String => Railcar::#{model_class}\n"
      end
      io << "\n"

      # Setup method
      io << "def setup_fixtures(db : DB::Database)\n"

      sorted.each do |table|
        singular = CrystalEmitter.singularize(table.name)
        model_class = CrystalEmitter.classify(singular)

        table.records.each do |record|
          io << "  FIXTURE_#{table.name.upcase}[\"#{record.label}\"] = Railcar::#{model_class}.create!(\n"
          record.fields.each_with_index do |(field, value), i|
            comma = i < record.fields.size - 1 ? "," : ""
            # Check if this field is a belongs_to reference
            if is_association_ref?(field, table.name, models)
              ref_table = CrystalEmitter.pluralize(field)
              io << "    #{field}_id: FIXTURE_#{ref_table.upcase}[\"#{value}\"].id.not_nil!#{comma}\n"
            else
              io << "    #{field}: #{value.inspect}#{comma}\n"
            end
          end
          io << "  )\n"
        end
      end

      io << "end\n\n"

      # Accessor methods: articles(:one) → FIXTURE_ARTICLES["one"]
      sorted.each do |table|
        singular = CrystalEmitter.singularize(table.name)
        model_class = CrystalEmitter.classify(singular)
        io << "def #{table.name}(label : String) : Railcar::#{model_class}\n"
        io << "  FIXTURE_#{table.name.upcase}[label]\n"
        io << "end\n\n"
        # Also support symbol-like access: articles(:one)
        io << "def #{table.name}(label : Symbol) : Railcar::#{model_class}\n"
        io << "  FIXTURE_#{table.name.upcase}[label.to_s]\n"
        io << "end\n\n"
      end

      io.to_s
    end

    private def self.is_association_ref?(field : String, table_name : String, models : Hash(String, ModelInfo)) : Bool
      singular = CrystalEmitter.singularize(table_name)
      model_name = CrystalEmitter.classify(singular)
      model = models[model_name]?
      return false unless model

      model.associations.any? { |a| a.kind == :belongs_to && a.name == field }
    end
  end
end
