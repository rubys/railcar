# Filter: Inject controller boilerplate into the class AST.
#
# Adds to the controller class:
#   - include RouteHelpers / ViewHelpers
#   - extract_model_params helper method
#   - layout helper method
#   - partial render helpers (from view file scan)
#   - Module wrapping (Ruby2CR)
#   - Require statements

require "compiler/crystal/syntax"
require "../generator/inflector"

module Ruby2CR
  class ControllerBoilerplate < Crystal::Transformer
    getter controller_name : String
    getter views_dir : String
    getter nested_parent : String?

    def initialize(@controller_name, @views_dir, @nested_parent = nil)
    end

    def transform(node : Crystal::ClassDef) : Crystal::ASTNode
      # Only transform the controller class
      return node unless node.name.names.last.ends_with?("Controller")

      body_nodes = [] of Crystal::ASTNode

      # Includes
      body_nodes << Crystal::Include.new(Crystal::Path.new(["RouteHelpers"]))
      body_nodes << Crystal::Include.new(Crystal::Path.new(["ViewHelpers"]))

      # extract_model_params helper
      body_nodes << build_extract_model_params

      # layout helper
      body_nodes << build_layout_helper

      # Partial helpers from view files
      body_nodes.concat(build_partial_helpers)

      # Existing class body
      case existing = node.body
      when Crystal::Expressions
        existing.expressions.each do |expr|
          next if expr.is_a?(Crystal::Nop)
          body_nodes << expr
        end
      when Crystal::Nop
        # empty
      else
        body_nodes << existing if existing
      end

      node.body = Crystal::Expressions.new(body_nodes)
      node
    end

    private def build_extract_model_params : Crystal::Def
      # private def extract_model_params(params, model) : Hash(String, DB::Any)
      #   hash = {} of String => DB::Any
      #   prefix = "#{model}["
      #   params.each { |k, v| hash[k[prefix.size..-2]] = v if k.starts_with?(prefix) && k.ends_with?("]") }
      #   hash
      # end
      body = Crystal::MacroLiteral.new(
        "hash = {} of String => DB::Any\n" \
        "    prefix = \"\#{model}[\"\n" \
        "    params.each do |k, v|\n" \
        "      if k.starts_with?(prefix) && k.ends_with?(\"]\")\n" \
        "        field = k[prefix.size..-2]\n" \
        "        hash[field] = v.as(DB::Any)\n" \
        "      end\n" \
        "    end\n" \
        "    hash"
      )

      def_node = Crystal::Def.new("extract_model_params",
        [
          Crystal::Arg.new("params", restriction: Crystal::Generic.new(
            Crystal::Path.new("Hash"),
            [Crystal::Path.new("String"), Crystal::Path.new("String")] of Crystal::ASTNode
          )),
          Crystal::Arg.new("model", restriction: Crystal::Path.new("String")),
        ],
        body: body,
        return_type: Crystal::Generic.new(
          Crystal::Path.new("Hash"),
          [Crystal::Path.new("String"), Crystal::Path.new(["DB", "Any"])] of Crystal::ASTNode
        )
      )
      def_node.visibility = Crystal::Visibility::Private
      def_node
    end

    private def build_layout_helper : Crystal::Def
      body = Crystal::MacroLiteral.new(
        "content = yield\n" \
        "    String.build do |__str__|\n" \
        "      ECR.embed(\"src/views/layouts/application.ecr\", __str__)\n" \
        "    end"
      )

      def_node = Crystal::Def.new("layout",
        [Crystal::Arg.new("title", restriction: Crystal::Path.new("String"))],
        body: body,
        return_type: Crystal::Path.new("String"),
        block_arity: 0
      )
      def_node.visibility = Crystal::Visibility::Private
      def_node
    end

    private def build_partial_helpers : Array(Crystal::ASTNode)
      helpers = [] of Crystal::ASTNode
      singular = Inflector.singularize(controller_name)
      model_class = Inflector.classify(singular)

      # Scan this controller's views for partials
      ctrl_views = File.join(views_dir, controller_name)
      if Dir.exists?(ctrl_views)
        Dir.glob(File.join(ctrl_views, "_*.html.erb")).each do |path|
          partial_name = File.basename(path, ".html.erb").lchop("_")
          helpers << build_partial_def(
            partial_name,
            controller_name,
            [{singular, model_class}]
          )
        end
      end

      # Scan other controllers' views for cross-controller partials
      if Dir.exists?(views_dir)
        Dir.each_child(views_dir) do |other_dir|
          next if other_dir == controller_name || other_dir == "layouts"
          other_path = File.join(views_dir, other_dir)
          next unless File.directory?(other_path)

          Dir.glob(File.join(other_path, "_*.html.erb")).each do |path|
            partial_name = File.basename(path, ".html.erb").lchop("_")
            other_singular = Inflector.singularize(other_dir)
            other_model = Inflector.classify(other_singular)

            # Include if this is a nested resource relationship
            if nested_parent && Inflector.pluralize(nested_parent.not_nil!) == other_dir
              # Skip — parent already has its own partials
            elsif controller_name == Inflector.pluralize(nested_parent || "")
              # This controller is the parent — include child partials
            else
              # Check by name: articles controller might render comment partials
              next unless other_dir_is_related?(other_dir)
            end

            helpers << build_partial_def(
              partial_name,
              other_dir,
              [{singular, model_class}, {other_singular, other_model}]
            )
          end
        end
      end

      helpers
    end

    private def build_partial_def(partial_name : String, view_dir : String, params : Array(Tuple(String, String))) : Crystal::Def
      ecr_path = "src/views/#{view_dir}/_#{partial_name}.ecr"

      body = Crystal::MacroLiteral.new(
        "String.build do |__str__|\n" \
        "      ECR.embed(\"#{ecr_path}\", __str__)\n" \
        "    end"
      )

      args = params.map { |name, type|
        Crystal::Arg.new(name, restriction: Crystal::Path.new(type))
      }

      def_node = Crystal::Def.new("render_#{partial_name}_partial", args,
        body: body,
        return_type: Crystal::Path.new("String")
      )
      def_node.visibility = Crystal::Visibility::Private
      def_node
    end

    private def other_dir_is_related?(other_dir : String) : Bool
      # Simple heuristic: related if nested parent matches
      if np = nested_parent
        Inflector.pluralize(np) == other_dir
      else
        false
      end
    end
  end
end
