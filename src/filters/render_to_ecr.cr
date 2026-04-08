# Filter: Convert render calls to ECR template embedding.
#
# Input:  render :new, status: :unprocessable_entity
# Output: response.status_code = 422
#         response.print(layout("New Article") {
#           String.build do |__str__|
#             ECR.embed("src/views/articles/new.ecr", __str__)
#           end
#         })
#
# Requires knowing the controller name for the view path.

require "compiler/crystal/syntax"
require "../generator/inflector"

module Ruby2CR
  class RenderToECR < Crystal::Transformer
    getter controller : String

    def initialize(@controller)
    end

    def transform(node : Crystal::Call) : Crystal::ASTNode
      if node.name == "render" && node.obj.nil?
        return convert_render(node)
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

    private def convert_render(node : Crystal::Call) : Crystal::ASTNode
      args = node.args
      named = node.named_args

      # Determine template name
      template = case args[0]?
                 when Crystal::SymbolLiteral then args[0].as(Crystal::SymbolLiteral).value
                 when Crystal::StringLiteral then args[0].as(Crystal::StringLiteral).value
                 else return node
                 end

      stmts = [] of Crystal::ASTNode

      # Check for status: :unprocessable_entity
      status = extract_named_symbol(named, "status")
      if status == "unprocessable_entity"
        stmts << Crystal::Assign.new(
          Crystal::Call.new(Crystal::Var.new("response"), "status_code"),
          Crystal::NumberLiteral.new("422")
        )
      end

      # Build: response.print(layout("Title") { String.build do |__str__| ECR.embed(...) end })
      singular = Inflector.singularize(controller)
      title = "#{template.capitalize} #{Inflector.classify(singular)}"

      ecr_path = "src/views/#{controller}/#{template}.ecr"

      # ECR.embed(path, __str__)
      ecr_embed = Crystal::Call.new(
        Crystal::Path.new("ECR"),
        "embed",
        [Crystal::StringLiteral.new(ecr_path), Crystal::Var.new("__str__")] of Crystal::ASTNode
      )

      # String.build do |__str__| ECR.embed(...) end
      string_build = Crystal::Call.new(
        Crystal::Path.new("String"),
        "build",
        block: Crystal::Block.new(
          args: [Crystal::Var.new("__str__")],
          body: ecr_embed
        )
      )

      # layout("Title") { string_build }
      layout_call = Crystal::Call.new(nil, "layout",
        [Crystal::StringLiteral.new(title)] of Crystal::ASTNode,
        block: Crystal::Block.new(body: string_build)
      )

      # response.print(layout_call)
      stmts << Crystal::Call.new(
        Crystal::Var.new("response"),
        "print",
        [layout_call] of Crystal::ASTNode
      )

      if stmts.size == 1
        stmts[0]
      else
        Crystal::Expressions.new(stmts)
      end
    end

    private def extract_named_symbol(named_args : Array(Crystal::NamedArgument)?, key : String) : String?
      return nil unless named_args
      named_args.each do |na|
        if na.name == key && na.value.is_a?(Crystal::SymbolLiteral)
          return na.value.as(Crystal::SymbolLiteral).value
        end
      end
      nil
    end
  end
end
