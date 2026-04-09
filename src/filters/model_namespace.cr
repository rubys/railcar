# Filter: Add Railcar:: namespace to model constants.
#
# Rails autoloads model classes by name. In the generated Crystal app,
# models live in the Railcar module. This filter converts bare model
# references to namespaced ones.
#
# Input:  Article.find(id)
# Output: Railcar::Article.find(id)
#
# Only transforms known model names to avoid false positives.

require "compiler/crystal/syntax"

module Railcar
  class ModelNamespace < Crystal::Transformer
    getter model_names : Set(String)

    def initialize(@model_names)
    end

    def initialize(names : Array(String))
      @model_names = names.to_set
    end

    def transform(node : Crystal::Path) : Crystal::ASTNode
      if node.names.size == 1 && model_names.includes?(node.names[0])
        Crystal::Path.new(["Railcar", node.names[0]])
      else
        node
      end
    end
  end
end
