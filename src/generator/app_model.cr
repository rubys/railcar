# Language-agnostic intermediate representation of a Rails application.
#
# Populated by extractors (Prism-based parsing of Rails source files),
# consumed by emitters (Crystal code generation, potentially other backends).

require "./schema_extractor"
require "./model_extractor"
require "./controller_extractor"
require "./route_extractor"
require "./fixture_loader"

module Railcar
  class AppModel
    getter name : String
    getter schemas : Array(TableSchema)
    getter models : Hash(String, ModelInfo)
    getter controllers : Array(ControllerInfo)
    getter routes : RouteSet
    getter fixtures : Array(FixtureTable)

    def initialize(@name, @schemas = [] of TableSchema,
                   @models = {} of String => ModelInfo,
                   @controllers = [] of ControllerInfo,
                   @routes = RouteSet.new,
                   @fixtures = [] of FixtureTable)
    end

    # Build an AppModel by extracting from a Rails application directory
    def self.extract(rails_dir : String) : AppModel
      name = File.basename(rails_dir)

      schemas = extract_schemas(rails_dir)
      models = extract_models(rails_dir)
      controllers = extract_controllers(rails_dir)
      routes = extract_routes(rails_dir)
      fixtures = extract_fixtures(rails_dir)

      AppModel.new(name, schemas, models, controllers, routes, fixtures)
    end

    private def self.extract_schemas(rails_dir : String) : Array(TableSchema)
      migrate_dir = File.join(rails_dir, "db/migrate")
      return [] of TableSchema unless Dir.exists?(migrate_dir)
      SchemaExtractor.extract_all(migrate_dir)
    end

    private def self.extract_models(rails_dir : String) : Hash(String, ModelInfo)
      models = {} of String => ModelInfo
      models_dir = File.join(rails_dir, "app/models")
      return models unless Dir.exists?(models_dir)

      Dir.glob(File.join(models_dir, "*.rb")).each do |path|
        model = ModelExtractor.extract_file(path)
        next unless model
        next if model.name == "ApplicationRecord"
        models[model.name] = model
      end
      models
    end

    private def self.extract_controllers(rails_dir : String) : Array(ControllerInfo)
      controllers = [] of ControllerInfo
      controllers_dir = File.join(rails_dir, "app/controllers")
      return controllers unless Dir.exists?(controllers_dir)

      Dir.glob(File.join(controllers_dir, "*_controller.rb")).each do |path|
        next if File.basename(path) == "application_controller.rb"
        info = ControllerExtractor.extract_file(path)
        controllers << info if info
      end
      controllers
    end

    private def self.extract_routes(rails_dir : String) : RouteSet
      routes_path = File.join(rails_dir, "config/routes.rb")
      return RouteSet.new unless File.exists?(routes_path)
      RouteExtractor.extract_file(routes_path)
    end

    private def self.extract_fixtures(rails_dir : String) : Array(FixtureTable)
      fixtures_dir = File.join(rails_dir, "test/fixtures")
      return [] of FixtureTable unless Dir.exists?(fixtures_dir)
      FixtureLoader.load_all(fixtures_dir)
    end
  end
end
