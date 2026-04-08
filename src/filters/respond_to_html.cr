# Filter: Extract HTML behavior from respond_to blocks.
#
# Rails controllers use respond_to for content negotiation:
#   respond_to do |format|
#     format.html { redirect_to @article }
#     format.json { render json: @article }
#   end
#
# This filter extracts the format.html block body and replaces
# the entire respond_to with just that. JSON/other formats are dropped.
#
# Input:  respond_to do |format|
#           format.html { redirect_to @article }
#           format.json { render json: @article }
#         end
# Output: redirect_to @article

require "compiler/crystal/syntax"

module Ruby2CR
  class RespondToHTML < Crystal::Transformer
    def transform(node : Crystal::Call) : Crystal::ASTNode
      if node.name == "respond_to" && node.obj.nil? && node.block
        block = node.block.not_nil!
        html_body = extract_html_body(block.body)
        if html_body
          # Return the HTML block body, transforming its children
          return html_body.transform(self)
        end
      end

      # Transform children for non-respond_to calls
      node.obj = node.obj.try(&.transform(self))
      node.args = node.args.map(&.transform(self).as(Crystal::ASTNode))
      node.named_args = node.named_args.try(&.map { |na|
        Crystal::NamedArgument.new(na.name, na.value.transform(self)).as(Crystal::NamedArgument)
      })
      node.block = node.block.try(&.transform(self).as(Crystal::Block))
      node
    end

    # Walk the respond_to block body and extract format.html bodies.
    # Preserves if/else structure when format calls are in branches.
    private def extract_html_body(node : Crystal::ASTNode) : Crystal::ASTNode?
      case node
      when Crystal::Expressions
        # Check if any child is a format.html call
        html_bodies = node.expressions.compact_map { |expr| extract_html_body(expr) }
        if html_bodies.size == 1
          return html_bodies[0]
        elsif html_bodies.size > 1
          return Crystal::Expressions.new(html_bodies)
        end
      when Crystal::Call
        if node.name == "html" && node.block
          return node.block.not_nil!.body
        end
      when Crystal::If
        # Preserve if/else structure, extracting html from each branch
        then_html = extract_html_body(node.then)
        else_html = node.else ? extract_html_body(node.else.not_nil!) : nil
        if then_html || else_html
          return Crystal::If.new(
            node.cond,
            then_html || Crystal::Nop.new,
            else_html
          )
        end
      end
      nil
    end

    # Override for If nodes that contain respond_to in branches
    def transform(node : Crystal::If) : Crystal::ASTNode
      # Transform the condition
      node.cond = node.cond.transform(self)

      # Transform then/else — respond_to inside branches gets unwrapped
      node.then = node.then.transform(self)
      node.else = node.else.try(&.transform(self))
      node
    end
  end
end
