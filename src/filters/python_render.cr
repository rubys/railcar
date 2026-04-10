# Filter: Convert Rails render calls to Python template rendering.
#
# Input:  render(:new, status: :unprocessable_entity)
# Output: return web.Response(text=render("articles/new.html", article=article),
#           content_type="text/html", status=422)
#
# The controller name is used to build the template path.
# Status symbols are converted to numeric codes.

require "compiler/crystal/syntax"

module Railcar
  class PythonRender < Crystal::Transformer
    getter controller : String
    getter model_name : String

    STATUS_CODES = {
      "ok"                     => "200",
      "created"                => "201",
      "no_content"             => "204",
      "moved_permanently"      => "301",
      "found"                  => "302",
      "see_other"              => "303",
      "not_found"              => "404",
      "unprocessable_entity"   => "422",
      "internal_server_error"  => "500",
    }

    def initialize(@controller : String, @model_name : String)
    end

    def transform(node : Crystal::Call) : Crystal::ASTNode
      return node unless node.name == "render" && node.obj.nil?
      return node if node.args.empty?

      template_arg = node.args[0]
      named = node.named_args

      # Extract template name
      template_name = case template_arg
                      when Crystal::SymbolLiteral then template_arg.value
                      when Crystal::StringLiteral then template_arg.value
                      else                             return node
                      end

      # Extract status
      status_code = "200"
      if named
        named.each do |na|
          if na.name == "status"
            case v = na.value
            when Crystal::SymbolLiteral
              status_code = STATUS_CODES[v.value]? || "200"
            when Crystal::StringLiteral
              status_code = STATUS_CODES[v.value]? || v.value
            when Crystal::NumberLiteral
              status_code = v.value
            end
          end
        end
      end

      # Build: render("controller/template.html", model=model)
      template_path = Crystal::StringLiteral.new("#{controller}/#{template_name}.html")
      render_args = [template_path] of Crystal::ASTNode
      render_named = [
        Crystal::NamedArgument.new(model_name, Crystal::Var.new(model_name)),
      ]
      render_call = Crystal::Call.new(nil, "render", render_args, named_args: render_named)

      # Build: web.Response(text=..., content_type="text/html", status=N)
      response_named = [
        Crystal::NamedArgument.new("text", render_call),
        Crystal::NamedArgument.new("content_type", Crystal::StringLiteral.new("text/html")),
      ]

      if status_code != "200"
        response_named << Crystal::NamedArgument.new("status", Crystal::NumberLiteral.new(status_code))
      end

      response_call = Crystal::Call.new(
        Crystal::Var.new("web"), "Response",
        named_args: response_named
      )

      # return web.Response(...)
      Crystal::Return.new(response_call)
    end
  end
end
