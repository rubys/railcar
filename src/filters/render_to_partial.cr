# Filter: Rewrite render calls to partial helper method calls.
#
# Input:  render @articles
# Output: articles.each { |article| render_article_partial(article) }
#
# Input:  render @article.comments
# Output: article.comments.each { |comment| render_comment_partial(comment) }
#
# Input:  render "form", article: @article
# Output: render_form_partial(article)

require "compiler/crystal/syntax"
require "../generator/inflector"

module Ruby2CR
  class RenderToPartial < Crystal::Transformer
    def transform(node : Crystal::Call) : Crystal::ASTNode
      if node.name == "render" && node.obj.nil? && !node.args.empty?
        result = convert_render(node)
        return result if result
      end
      node.obj = node.obj.try(&.transform(self))
      node.args = node.args.map(&.transform(self).as(Crystal::ASTNode))
      node.named_args = node.named_args.try(&.map { |na|
        Crystal::NamedArgument.new(na.name, na.value.transform(self)).as(Crystal::NamedArgument)
      })
      node.block = node.block.try(&.transform(self).as(Crystal::Block))
      node
    end

    private def convert_render(call : Crystal::Call) : Crystal::ASTNode?
      first_arg = call.args[0]

      case first_arg
      when Crystal::InstanceVar
        # render @articles → articles.each { |article| render_article_partial(article) }
        collection = first_arg.name.lchop("@")
        build_collection_loop(Crystal::Var.new(collection), collection)
      when Crystal::Var
        # render articles (after InstanceVarToLocal)
        build_collection_loop(first_arg, first_arg.name)
      when Crystal::Call
        if first_arg.obj.nil?
          # render articles → articles.each { ... }
          build_collection_loop(first_arg, first_arg.name)
        elsif first_arg.obj
          # render @article.comments → article.comments.each { ... }
          build_collection_loop(first_arg, first_arg.name)
        else
          nil
        end
      when Crystal::StringLiteral
        # render "form", article: @article → render_form_partial(article)
        partial_name = first_arg.value
        if named = call.named_args
          if !named.empty?
            val = named[0].value
            arg = val.is_a?(Crystal::InstanceVar) ? Crystal::Var.new(val.name.lchop("@")) : val
            return Crystal::Call.new(nil, "render_#{partial_name}_partial", [arg] of Crystal::ASTNode)
          end
        end
        Crystal::Call.new(nil, "render_#{partial_name}_partial")
      else
        nil
      end
    end

    private def build_collection_loop(collection : Crystal::ASTNode, name : String) : Crystal::ASTNode
      singular = Inflector.singularize(name)

      # If the collection is an association (e.g., article.comments),
      # pass the parent as an extra arg to the partial
      partial_args = [Crystal::Var.new(singular)] of Crystal::ASTNode
      if collection.is_a?(Crystal::Call) && collection.obj
        parent = collection.obj.not_nil!
        partial_args.unshift(parent.clone)
      end

      partial_call = Crystal::Call.new(nil, "render_#{singular}_partial", partial_args)

      Crystal::Call.new(collection, "each",
        block: Crystal::Block.new(
          args: [Crystal::Var.new(singular)],
          body: partial_call
        ))
    end
  end
end
