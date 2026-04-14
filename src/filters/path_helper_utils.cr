# Shared utilities for converting model references to path helper calls.
#
# Used by LinkToPathHelper and ButtonToPathHelper to avoid duplicating
# the model_to_path logic that rewrites @article → article_path(article).

require "compiler/crystal/syntax"

module Railcar
  module PathHelperUtils
    # Convert a model reference (instance var, local var, or bare call)
    # to its corresponding *_path helper call.
    private def model_to_path(node : Crystal::ASTNode) : Crystal::ASTNode
      case node
      when Crystal::InstanceVar
        name = node.name.lchop("@")
        Crystal::Call.new(nil, "#{name}_path", [Crystal::Var.new(name)] of Crystal::ASTNode)
      when Crystal::Var
        name = node.name
        return node if name.ends_with?("_path")
        Crystal::Call.new(nil, "#{name}_path", [node] of Crystal::ASTNode)
      when Crystal::Call
        if node.obj.nil? && node.args.empty?
          name = node.name
          return node if name.ends_with?("_path")
          Crystal::Call.new(nil, "#{name}_path", [node] of Crystal::ASTNode)
        else
          node
        end
      else
        node
      end
    end

    # Extract a resource name from a node for building nested path helpers.
    # e.g. comment.article → "article", @article → "article"
    private def extract_resource_name(node : Crystal::ASTNode) : String
      case node
      when Crystal::InstanceVar then node.name.lchop("@")
      when Crystal::Var then node.name
      when Crystal::Call then node.name
      else node.to_s
      end
    end
  end
end
