# Filter: Convert redirect_to calls to Python/aiohttp raise statements.
#
# Input:  redirect_to(article, notice: "Created.")
# Output: raise web.HTTPFound(article_path(article))
#
# Input:  redirect_to(articles_path(), notice: "Destroyed.", status: "see_other")
# Output: raise web.HTTPSeeOther(articles_path())
#
# Flash notices are currently dropped (Python app doesn't implement flash yet).
# The model-to-path conversion (article → article_path(article)) handles
# the common Rails pattern of passing a model to redirect_to.

require "compiler/crystal/syntax"
require "../generator/inflector"

module Railcar
  class PythonRedirect < Crystal::Transformer
    def transform(node : Crystal::Call) : Crystal::ASTNode
      return node unless node.name == "redirect_to" && node.obj.nil?
      return node if node.args.empty?

      target = node.args[0]
      named = node.named_args

      # Determine status
      status = extract_named_string(named, "status")
      exception_class = if status == "see_other"
                          "web.HTTPSeeOther"
                        else
                          "web.HTTPFound"
                        end

      # Convert target to path
      path = model_to_path(target)

      # raise web.HTTPFound(path)
      raise_call = Crystal::Call.new(nil, exception_class, [path] of Crystal::ASTNode)
      Crystal::Call.new(nil, "raise", [raise_call] of Crystal::ASTNode)
    end

    private def model_to_path(target : Crystal::ASTNode) : Crystal::ASTNode
      case target
      when Crystal::Var
        name = target.name
        # article → article_path(article)
        Crystal::Call.new(nil, "#{name}_path", [target] of Crystal::ASTNode)
      when Crystal::Call
        # Already a path helper call like articles_path()
        target
      else
        target
      end
    end

    private def extract_named_string(named : Array(Crystal::NamedArgument)?, key : String) : String?
      return nil unless named
      named.each do |na|
        if na.name == key
          case v = na.value
          when Crystal::SymbolLiteral then return v.value
          when Crystal::StringLiteral then return v.value
          end
        end
      end
      nil
    end
  end
end
