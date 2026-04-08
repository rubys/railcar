# Filter: Convert strong params calls to extract_model_params.
#
# Rails controllers define private methods like:
#   def article_params
#     params.expect(article: [:title, :body])
#   end
#
# And call them as: Article.new(article_params)
#
# This filter converts the call site:
#   Model.new(article_params) → Model.new(extract_model_params(params, "article"))
#   article.update(article_params) → article.update(extract_model_params(params, "article"))
#   article.comments.build(comment_params) → article.comments.build(extract_model_params(params, "comment"))

require "compiler/crystal/syntax"

module Ruby2CR
  class StrongParams < Crystal::Transformer
    def transform(node : Crystal::Call) : Crystal::ASTNode
      case node.name
      when "new", "update", "build"
        if node.args.size == 1 && is_params_call?(node.args[0])
          model_name = extract_model_name(node.args[0])
          if model_name
            node.args = [
              Crystal::Call.new(nil, "extract_model_params", [
                Crystal::Var.new("params"),
                Crystal::StringLiteral.new(model_name),
              ] of Crystal::ASTNode),
            ] of Crystal::ASTNode
          end
        end
      end

      # Transform children
      node.obj = node.obj.try(&.transform(self))
      node.args = node.args.map(&.transform(self).as(Crystal::ASTNode))
      node.named_args = node.named_args.try(&.map { |na|
        Crystal::NamedArgument.new(na.name, na.value.transform(self)).as(Crystal::NamedArgument)
      })
      node.block = node.block.try(&.transform(self).as(Crystal::Block))
      node
    end

    private def is_params_call?(node : Crystal::ASTNode) : Bool
      case node
      when Crystal::Call
        node.name.ends_with?("_params") && node.obj.nil? && node.args.empty?
      else
        false
      end
    end

    private def extract_model_name(node : Crystal::ASTNode) : String?
      if node.is_a?(Crystal::Call) && node.name.ends_with?("_params")
        node.name.chomp("_params")
      else
        nil
      end
    end
  end
end
