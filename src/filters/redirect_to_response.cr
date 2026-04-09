# Filter: Convert redirect_to into HTTP response operations.
#
# Input:  redirect_to(@article, notice: "Created.")
# Output: FLASH_STORE["default"] = {notice: "Created.", alert: nil}
#         response.status_code = 302
#         response.headers["Location"] = article_path(article)
#
# The model-to-path conversion (article → article_path(article))
# relies on InstanceVarToLocal having already run.

require "compiler/crystal/syntax"

module Railcar
  class RedirectToResponse < Crystal::Transformer
    def transform(node : Crystal::Call) : Crystal::ASTNode
      return transform_children(node) unless node.name == "redirect_to" && node.obj.nil?

      args = node.args
      named = node.named_args
      return transform_children(node) if args.empty?

      stmts = [] of Crystal::ASTNode

      # Extract notice/alert from named args
      notice = extract_named(named, "notice")
      alert = extract_named(named, "alert")

      if notice || alert
        notice_val = notice ? Crystal::StringLiteral.new(notice.not_nil!).as(Crystal::ASTNode) : Crystal::NilLiteral.new.as(Crystal::ASTNode)
        alert_val = alert ? Crystal::StringLiteral.new(alert.not_nil!).as(Crystal::ASTNode) : Crystal::NilLiteral.new.as(Crystal::ASTNode)

        flash_value = Crystal::NamedTupleLiteral.new([
          Crystal::NamedTupleLiteral::Entry.new("notice", notice_val),
          Crystal::NamedTupleLiteral::Entry.new("alert", alert_val),
        ])

        stmts << Crystal::Assign.new(
          Crystal::Call.new(Crystal::Path.new("FLASH_STORE"), "[]", [Crystal::StringLiteral.new("default")] of Crystal::ASTNode),
          flash_value
        )
      end

      # response.status_code = 302
      stmts << Crystal::Assign.new(
        Crystal::Call.new(Crystal::Var.new("response"), "status_code"),
        Crystal::NumberLiteral.new("302")
      )

      # response.headers["Location"] = path
      target = args[0]
      path_expr = model_to_path(target)
      stmts << Crystal::Assign.new(
        Crystal::Call.new(
          Crystal::Call.new(Crystal::Var.new("response"), "headers"),
          "[]",
          [Crystal::StringLiteral.new("Location")] of Crystal::ASTNode
        ),
        path_expr
      )

      Crystal::Expressions.new(stmts)
    end

    private def transform_children(node : Crystal::Call) : Crystal::ASTNode
      node.obj = node.obj.try(&.transform(self))
      node.args = node.args.map(&.transform(self).as(Crystal::ASTNode))
      node.named_args = node.named_args.try(&.map { |na|
        Crystal::NamedArgument.new(na.name, na.value.transform(self)).as(Crystal::NamedArgument)
      })
      node.block = node.block.try(&.transform(self).as(Crystal::Block))
      node
    end

    private def extract_named(named_args : Array(Crystal::NamedArgument)?, key : String) : String?
      return nil unless named_args
      named_args.each do |na|
        if na.name == key && na.value.is_a?(Crystal::StringLiteral)
          return na.value.as(Crystal::StringLiteral).value
        end
      end
      nil
    end

    private def model_to_path(node : Crystal::ASTNode) : Crystal::ASTNode
      case node
      when Crystal::Var
        name = node.name
        if name.ends_with?("_path")
          node
        else
          Crystal::Call.new(nil, "#{name}_path", [Crystal::Var.new(name)] of Crystal::ASTNode)
        end
      when Crystal::Call
        if node.obj.nil? && node.args.empty?
          name = node.name
          if name.ends_with?("_path")
            node
          else
            Crystal::Call.new(nil, "#{name}_path", [Crystal::Var.new(name)] of Crystal::ASTNode)
          end
        else
          node
        end
      else
        node
      end
    end
  end
end
