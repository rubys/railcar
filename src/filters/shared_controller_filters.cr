# Shared Rails controller filter chain applied by all target generators.
#
# These four filters normalize Rails controller AST into a target-neutral
# form before language-specific filters run. Order matters:
#
# 1. InstanceVarToLocal — @article → article (downstream filters see locals)
# 2. ParamsExpect        — params.expect(:id) → id (simplifies param refs)
# 3. RespondToHTML       — unwrap respond_to { format.html { ... } } blocks
# 4. StrongParams        — article_params → extract_model_params(params, "article")

require "./instance_var_to_local"
require "./params_expect"
require "./respond_to_html"
require "./strong_params"

module Railcar
  module SharedControllerFilters
    # Apply the shared Rails normalization chain to a controller AST.
    def self.apply(ast : Crystal::ASTNode) : Crystal::ASTNode
      ast = ast.transform(InstanceVarToLocal.new)
      ast = ast.transform(ParamsExpect.new)
      ast = ast.transform(RespondToHTML.new)
      ast = ast.transform(StrongParams.new)
      ast
    end
  end
end
