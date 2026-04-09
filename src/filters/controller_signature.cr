# Filter: Rewrite controller action signatures and inject Rails-equivalent behavior.
#
# This filter handles four related concerns that all operate on the same
# Def node and share the same context (controller name, nested parent,
# before_actions):
#
# 1. STRIP: Remove set_* and *_params private helper methods (inlined)
# 2. SIGNATURE: Add typed parameters (response, id, params, parent_id)
# 3. PREAMBLE: Flash consumption (for render actions) and before_action
#    inlining (model loading from id)
# 4. VIEW RENDER: Append layout + ECR.embed for display actions
#
# Also strips before_action, private, and broadcasts_to call nodes.
#
# Input:  def show
#           ...
#         end
#
# Output: def show(response : HTTP::Server::Response, id : Int64)
#           flash = FLASH_STORE.delete("default") || {notice: nil, alert: nil}
#           notice = flash[:notice]
#           article = Article.find(id)
#           ...
#           response.print(layout(article.title) { ... ECR.embed ... })
#         end

require "compiler/crystal/syntax"
require "../generator/inflector"

module Ruby2CR
  class ControllerSignature < Crystal::Transformer
    # Which actions need which params
    ID_ACTIONS     = {"show", "edit", "update", "destroy"}
    PARAMS_ACTIONS = {"create", "update"}
    RENDER_ACTIONS = {"index", "show", "new", "edit"}

    getter controller_name : String
    getter nested_parent : String?
    getter before_actions : Array(BeforeAction)
    getter model_names : Array(String)

    def initialize(@controller_name, @nested_parent, @before_actions, @model_names = [] of String)
    end

    def transform(node : Crystal::Def) : Crystal::ASTNode
      name = node.name

      # --- 1. STRIP: Remove inlined private helpers ---
      if name.starts_with?("set_") || name.ends_with?("_params")
        return Crystal::Nop.new
      end

      singular = Inflector.singularize(controller_name)
      model_class = Inflector.classify(singular)

      # --- 2. SIGNATURE: Build typed parameter list ---
      args = [Crystal::Arg.new("response", restriction: Crystal::Path.new(["HTTP", "Server", "Response"]))]
      if ID_ACTIONS.includes?(name)
        args << Crystal::Arg.new("id", restriction: Crystal::Path.new("Int64"))
      end
      if PARAMS_ACTIONS.includes?(name)
        args << Crystal::Arg.new("params", restriction: Crystal::Generic.new(
          Crystal::Path.new("Hash"),
          [Crystal::Path.new("String"), Crystal::Path.new("String")] of Crystal::ASTNode
        ))
      end
      if nested_parent
        parent_param = "#{nested_parent}_id"
        if ID_ACTIONS.includes?(name) || PARAMS_ACTIONS.includes?(name)
          args << Crystal::Arg.new(parent_param, restriction: Crystal::Path.new("Int64"))
        end
      end

      # --- 3. PREAMBLE: Flash consumption + before_action inlining ---
      preamble = [] of Crystal::ASTNode
      if RENDER_ACTIONS.includes?(name)
        preamble << Crystal::Assign.new(
          Crystal::Var.new("flash"),
          Crystal::Or.new(
            Crystal::Call.new(Crystal::Path.new("FLASH_STORE"), "delete",
              [Crystal::StringLiteral.new("default")] of Crystal::ASTNode),
            Crystal::NamedTupleLiteral.new([
              Crystal::NamedTupleLiteral::Entry.new("notice", Crystal::NilLiteral.new),
              Crystal::NamedTupleLiteral::Entry.new("alert", Crystal::NilLiteral.new),
            ])
          )
        )
        preamble << Crystal::Assign.new(
          Crystal::Var.new("notice"),
          Crystal::Call.new(Crystal::Var.new("flash"), "[]",
            [Crystal::SymbolLiteral.new("notice")] of Crystal::ASTNode)
        )
      end

      # Before action: set model from id
      needs_before = before_actions.any? { |ba| ba.only.nil? || ba.only.not_nil!.includes?(name) }
      if needs_before
        if parent = nested_parent
          parent_model = Inflector.classify(parent)
          preamble << Crystal::Assign.new(
            Crystal::Var.new(parent),
            Crystal::Call.new(Crystal::Path.new(parent_model), "find",
              [Crystal::Var.new("#{parent}_id")] of Crystal::ASTNode)
          )
        elsif ID_ACTIONS.includes?(name)
          preamble << Crystal::Assign.new(
            Crystal::Var.new(singular),
            Crystal::Call.new(Crystal::Path.new(model_class), "find",
              [Crystal::Var.new("id")] of Crystal::ASTNode)
          )
        end
      end

      # --- 4. VIEW RENDER: Append layout + ECR.embed for display actions ---
      view_render = if RENDER_ACTIONS.includes?(name)
                      build_view_render(name, singular)
                    else
                      nil
                    end

      # Combine: preamble + original body + view render
      body_nodes = preamble.dup
      case body = node.body
      when Crystal::Expressions
        body.expressions.each { |e| body_nodes << e }
      when Crystal::Nop
        # empty
      else
        body_nodes << body
      end
      body_nodes << view_render if view_render

      Crystal::Def.new(name, args, body: Crystal::Expressions.new(body_nodes))
    end

    # Strip before_action, private, broadcasts_to calls
    def transform(node : Crystal::Call) : Crystal::ASTNode
      case node.name
      when "before_action", "private", "broadcasts_to"
        Crystal::Nop.new
      else
        node.obj = node.obj.try(&.transform(self))
        node.args = node.args.map(&.transform(self).as(Crystal::ASTNode))
        node.named_args = node.named_args.try(&.map { |na|
          Crystal::NamedArgument.new(na.name, na.value.transform(self)).as(Crystal::NamedArgument)
        })
        node.block = node.block.try(&.transform(self).as(Crystal::Block))
        node
      end
    end

    private def build_view_render(action_name : String, singular : String) : Crystal::ASTNode
      title_expr = case action_name
                   when "index" then Crystal::StringLiteral.new(controller_name.capitalize)
                   when "show"  then Crystal::Call.new(Crystal::Var.new(singular), "title")
                   when "new"   then Crystal::StringLiteral.new("New #{singular}")
                   when "edit"  then Crystal::StringLiteral.new("Editing #{singular}")
                   else Crystal::StringLiteral.new(action_name.capitalize)
                   end

      ecr_path = "src/views/#{controller_name}/#{action_name}.ecr"

      ecr_embed = Crystal::Call.new(
        Crystal::Path.new("ECR"), "embed",
        [Crystal::StringLiteral.new(ecr_path), Crystal::Var.new("__str__")] of Crystal::ASTNode
      )

      string_build = Crystal::Call.new(
        Crystal::Path.new("String"), "build",
        block: Crystal::Block.new(
          args: [Crystal::Var.new("__str__")],
          body: ecr_embed
        )
      )

      layout_call = Crystal::Call.new(nil, "layout",
        [title_expr] of Crystal::ASTNode,
        block: Crystal::Block.new(body: string_build)
      )

      Crystal::Call.new(Crystal::Var.new("response"), "print",
        [layout_call] of Crystal::ASTNode)
    end
  end
end
