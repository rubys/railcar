# Extracts route definitions from config/routes.rb using Prism.
#
# Handles:
#   root "controller#action"
#   resources :name, only: [...]
#   nested resources (one level)

require "../prism/bindings"
require "../prism/deserializer"
require "../generator/crystal_emitter"  # for inflection

module Ruby2CR
  # A single route entry
  record Route,
    method : String,           # GET, POST, PATCH, DELETE
    path : String,             # "/articles/:id"
    controller : String,       # "articles"
    action : String,           # "show"
    name : String?             # route helper name, e.g. "article"

  # Extracted routes with helper info
  class RouteSet
    getter routes : Array(Route) = [] of Route
    property root_controller : String? = nil
    property root_action : String? = nil

    def add(route : Route)
      @routes << route
    end
  end

  class RouteExtractor
    RESOURCE_ACTIONS = {
      "index"   => {"GET", "", "index"},
      "new"     => {"GET", "/new", "new"},
      "create"  => {"POST", "", "create"},
      "show"    => {"GET", "/:id", "show"},
      "edit"    => {"GET", "/:id/edit", "edit"},
      "update"  => {"PATCH", "/:id", "update"},
      "destroy" => {"DELETE", "/:id", "destroy"},
    }

    def self.extract(source : String) : RouteSet
      ast = Prism.parse(source)
      route_set = RouteSet.new
      find_routes(ast, route_set)
      route_set
    end

    def self.extract_file(path : String) : RouteSet
      extract(File.read(path))
    end

    private def self.find_routes(node : Prism::Node, route_set : RouteSet, prefix : String = "", parent_singular : String? = nil)
      case node
      when Prism::CallNode
        case node.name
        when "root"
          parse_root(node, route_set)
        when "resources"
          parse_resources(node, route_set, prefix, parent_singular)
          return # don't recurse into children — we handle the block ourselves
        end
      end

      node.children.each do |child|
        find_routes(child, route_set, prefix, parent_singular)
      end
    end

    private def self.parse_root(call : Prism::CallNode, route_set : RouteSet)
      args = call.arg_nodes
      return if args.empty?

      target = case arg = args[0]
               when Prism::StringNode then arg.value
               else return
               end

      parts = target.split("#")
      return unless parts.size == 2
      route_set.root_controller = parts[0]
      route_set.root_action = parts[1]
    end

    private def self.parse_resources(call : Prism::CallNode, route_set : RouteSet, prefix : String, parent_singular : String?)
      args = call.arg_nodes
      return if args.empty?

      resource_name = case arg = args[0]
                      when Prism::SymbolNode then arg.value
                      else return
                      end

      singular = CrystalEmitter.singularize(resource_name)
      path = "#{prefix}/#{resource_name}"

      # Check for :only option
      only = extract_only(args)

      # Determine which actions to generate
      actions = only || RESOURCE_ACTIONS.keys

      # Generate routes for each action
      actions.each do |action|
        template = RESOURCE_ACTIONS[action]?
        next unless template
        http_method, suffix, action_name = template

        route_path = path + suffix

        # Replace :id with the appropriate param name for nested resources
        if parent_singular
          route_path = route_path.gsub(":id") do |_|
            # For nested, the parent's id is :parent_id, child's is :id
            ":id"
          end
        end

        helper_name = route_helper_name(action_name, singular, resource_name, prefix, parent_singular)

        route_set.add Route.new(
          method: http_method,
          path: route_path,
          controller: resource_name,
          action: action_name,
          name: helper_name
        )
      end

      # Process nested resources in the block
      if block = call.block
        if body = block.as?(Prism::BlockNode).try(&.body)
          # For nested routes, the parent path includes :parent_id
          nested_prefix = "#{path}/:#{singular}_id"
          find_routes(body, route_set, nested_prefix, singular)
        end
      end
    end

    private def self.extract_only(args : Array(Prism::Node)) : Array(String)?
      args.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)
        arg.elements.each do |el|
          next unless el.is_a?(Prism::AssocNode)
          key = el.key
          next unless key.is_a?(Prism::SymbolNode) && key.value == "only"
          val = el.value_node
          if val.is_a?(Prism::ArrayNode)
            return val.elements.compact_map { |e|
              e.is_a?(Prism::SymbolNode) ? e.value : nil
            }
          end
        end
      end
      nil
    end

    private def self.route_helper_name(action : String, singular : String, plural : String, prefix : String, parent_singular : String?) : String?
      if parent_singular
        # Nested routes: article_comments_path, article_comment_path
        case action
        when "index"   then "#{parent_singular}_#{plural}"
        when "create"  then "#{parent_singular}_#{plural}"
        when "new"     then "new_#{parent_singular}_#{singular}"
        when "show"    then "#{parent_singular}_#{singular}"
        when "edit"    then "edit_#{parent_singular}_#{singular}"
        when "update"  then "#{parent_singular}_#{singular}"
        when "destroy" then "#{parent_singular}_#{singular}"
        else nil
        end
      else
        case action
        when "index"   then plural
        when "create"  then plural
        when "new"     then "new_#{singular}"
        when "show"    then singular
        when "edit"    then "edit_#{singular}"
        when "update"  then singular
        when "destroy" then singular
        else nil
        end
      end
    end
  end

  # Generate Crystal route helpers and route matching code from a RouteSet
  class RouteGenerator
    def self.generate_helpers(route_set : RouteSet) : String
      io = IO::Memory.new
      io << "# Generated route helpers from config/routes.rb\n\n"
      io << "module Ruby2CR::RouteHelpers\n"

      # Collect unique helper names with their paths
      helpers = {} of String => {path: String, params: Array(String)}
      route_set.routes.each do |route|
        next unless route.name
        next if helpers.has_key?(route.name.not_nil!)

        # Extract param names from path
        params = route.path.scan(/:(\w+)/).map { |m| m[1] }
        helpers[route.name.not_nil!] = {path: route.path, params: params}
      end

      helpers.each do |name, info|
        if info[:params].empty?
          io << "  def #{name}_path : String\n"
          io << "    #{info[:path].inspect}\n"
          io << "  end\n\n"
        else
          # Generate method with typed parameters
          param_list = info[:params].map { |p| p }.join(", ")
          io << "  def #{name}_path(#{param_list}) : String\n"
          # Build interpolated path
          path_expr = info[:path]
          info[:params].each do |p|
            path_expr = path_expr.gsub(":#{p}", "\#{#{p}.is_a?(Ruby2CR::ApplicationRecord) ? #{p}.id : #{p}}")
          end
          io << "    #{path_expr.inspect.gsub("\\#", "#")}\n"
          io << "  end\n\n"
        end
      end

      io << "end\n"
      io.to_s
    end

    # Generate a complete router file with dispatch method
    def self.generate_router(route_set : RouteSet) : String
      io = IO::Memory.new
      io << "# Generated route matching\n\n"
      io << "require \"./controllers/*\"\n"
      io << "require \"./helpers/route_helpers\"\n"
      io << "require \"./helpers/view_helpers\"\n\n"
      io << "module Ruby2CR\n"
      io << "  class Router\n"
      io << "    include RouteHelpers\n"
      io << "    include ViewHelpers\n\n"

      # Controller instances
      controllers = Set(String).new
      route_set.routes.each { |r| controllers << r.controller }
      controllers.each do |ctrl|
        class_name = ctrl.split("_").map(&.capitalize).join + "Controller"
        io << "    getter #{ctrl}_controller = #{class_name}.new\n"
      end
      io << "\n"

      io << "    def dispatch(context : HTTP::Server::Context)\n"
      io << "      request = context.request\n"
      io << "      response = context.response\n"
      io << "      path = request.path\n"
      io << "      method = request.method\n\n"
      io << "      # Parse form body for POST\n"
      io << "      params = {} of String => String\n"
      io << "      if method == \"POST\" && request.body\n"
      io << "        body = request.body.not_nil!.gets_to_end\n"
      io << "        HTTP::Params.parse(body) { |key, value| params[key] = value }\n"
      io << "        if override = params[\"_method\"]?\n"
      io << "          method = override.upcase\n"
      io << "        end\n"
      io << "      end\n\n"

      io << "      case {method, path}\n"

      # Root route
      if route_set.root_controller
        io << "      when {\"GET\", \"/\"}\n"
        io << "        response.status_code = 302\n"
        io << "        response.headers[\"Location\"] = \"/#{route_set.root_controller}\"\n"
      end

      # Static routes (no params)
      route_set.routes.each do |route|
        next if route.path.includes?(":")
        io << "      when {\"#{route.method}\", \"#{route.path}\"}\n"
        args = ["response"]
        args << "params" if {"create"}.includes?(route.action)
        io << "        #{route.controller}_controller.#{route.action}(#{args.join(", ")})\n"
      end

      io << "      else\n"
      io << "        # Parameterized routes\n"

      param_routes = route_set.routes.select { |r| r.path.includes?(":") }
      param_routes = param_routes.sort_by { |r| -r.path.count("/") }

      emitted_patterns = Set(String).new
      first = true
      param_routes.each do |route|
        pattern = route.path.gsub(/:(\w+)/, "(\\\\d+)")
        regex = "^#{pattern}$"
        next if emitted_patterns.includes?(regex)
        emitted_patterns << regex

        matching = param_routes.select { |r| r.path.gsub(/:(\w+)/, "(\\\\d+)") == route.path.gsub(/:(\w+)/, "(\\\\d+)") }
        param_names = route.path.scan(/:(\w+)/).map { |m| m[1] }

        keyword = first ? "if" : "elsif"
        first = false

        io << "        #{keyword} match = path.match(%r{#{regex}})\n"
        param_names.each_with_index do |name, i|
          io << "          #{name} = match[#{i + 1}].to_i64\n"
        end
        io << "          case method\n"
        matching.each do |r|
          io << "          when \"#{r.method}\"\n"
          args = ["response"]
          args << "id" if {"show", "edit", "update", "destroy"}.includes?(r.action)
          args << "params" if {"create", "update"}.includes?(r.action)
          # Pass parent IDs for nested resources
          if r.path.includes?("_id")
            param_names.select { |n| n.ends_with?("_id") }.each do |p|
              args << p unless args.includes?(p)
            end
          end
          io << "            #{r.controller}_controller.#{r.action}(#{args.join(", ")})\n"
        end
        io << "          else\n"
        io << "            response.status_code = 404\n"
        io << "            response.print \"Not found\"\n"
        io << "          end\n"
      end

      io << "        else\n"
      io << "          response.status_code = 404\n"
      io << "          response.print \"Not found\"\n"
      io << "        end\n"
      io << "      end\n"
      io << "      response.headers[\"Content-Type\"] ||= \"text/html\"\n"
      io << "    end\n"
      io << "  end\n"
      io << "end\n"
      io.to_s
    end
  end
end
