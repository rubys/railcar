# Filter: Transform Rails controller class into Elixir Plug handler functions.
#
# Transforms Rails patterns to Plug/Elixir equivalents:
#   redirect_to(model) → conn |> put_resp_header("location", path) |> send_resp(302, "")
#   render(:template, status: :unprocessable_entity) → Helpers.render_view(conn, ..., 422)
#   if article.save → case Model.create(params) do {:ok, ...} → ... end
#   Article.find(id) → Blog.Article.find(String.to_integer(conn.path_params["id"]))
#   before_action inlining

require "compiler/crystal/syntax"
require "../generator/inflector"

module Railcar
  class ControllerBoilerplateElixir < Crystal::Transformer
    getter controller_name : String
    getter model_name : String
    getter app_module : String
    getter nested_parent : String?
    getter extracted_before_actions : Array(BeforeAction)

    def initialize(@controller_name, @model_name, @app_module,
                   @nested_parent = nil,
                   @extracted_before_actions = [] of BeforeAction)
    end

    def transform(node : Crystal::ClassDef) : Crystal::ASTNode
      body = node.body
      exprs = case body
              when Crystal::Expressions then body.expressions
              else [body]
              end

      # Build before_actions lookup
      before_actions = {} of String => Array(String)
      @extracted_before_actions.each do |ba|
        if only = ba.only
          only.each do |action|
            before_actions[action] ||= [] of String
            before_actions[action] << ba.method_name
          end
        else
          before_actions["*"] ||= [] of String
          before_actions["*"] << ba.method_name
        end
      end

      # Collect private methods
      private_methods = {} of String => Crystal::Def
      in_private = false
      exprs.each do |expr|
        case expr
        when Crystal::Call
          in_private = true if expr.name == "private"
        when Crystal::Def
          private_methods[expr.name] = expr if in_private
        when Crystal::VisibilityModifier
          in_private = true
          if expr.exp.is_a?(Crystal::Def)
            private_methods[expr.exp.as(Crystal::Def).name] = expr.exp.as(Crystal::Def)
          end
        end
      end

      # Transform public actions
      actions = [] of Crystal::ASTNode
      in_private = false
      exprs.each do |expr|
        case expr
        when Crystal::Call
          in_private = true if expr.as(Crystal::Call).name == "private"
          next
        when Crystal::VisibilityModifier
          in_private = true
          next
        when Crystal::Def
          next if in_private
          next if private_methods.has_key?(expr.name)
          actions << transform_action(expr, before_actions, private_methods)
        end
      end

      Crystal::Expressions.new(actions)
    end

    def transform(node : Crystal::ASTNode) : Crystal::ASTNode
      super
    end

    private def transform_action(defn : Crystal::Def,
                                  before_actions : Hash(String, Array(String)),
                                  private_methods : Hash(String, Crystal::Def)) : Crystal::ASTNode
      action_name = defn.name
      singular = Inflector.singularize(@controller_name)
      plural = Inflector.pluralize(@controller_name)
      full_model = "#{app_module}.#{model_name}"

      stmts = [] of Crystal::ASTNode

      # Inline before_action callbacks
      all_callbacks = [] of String
      if cbs = before_actions["*"]?
        all_callbacks.concat(cbs)
      end
      if cbs = before_actions[action_name]?
        all_callbacks.concat(cbs)
      end
      all_callbacks.each do |cb_name|
        if cb_def = private_methods[cb_name]?
          inline_method_body(cb_def, stmts, singular)
        end
      end

      # Transform action body
      case defn.body
      when Crystal::Expressions
        defn.body.as(Crystal::Expressions).expressions.each do |e|
          next if e.is_a?(Crystal::Nop)
          transform_action_stmt(e, stmts, action_name, singular, plural)
        end
      when Crystal::Nop
        # empty action — render template
        stmts << render_view(action_name, singular, plural)
      else
        transform_action_stmt(defn.body, stmts, action_name, singular, plural)
      end

      # Add implicit render if action doesn't end with redirect/render
      unless ends_with_redirect_or_render?(stmts)
        stmts << render_view(action_name, singular, plural)
      end

      # Build function with conn parameter
      Crystal::Def.new(action_name, [Crystal::Arg.new("conn")],
        Crystal::Expressions.new(stmts))
    end

    private def inline_method_body(defn : Crystal::Def, stmts : Array(Crystal::ASTNode), singular : String)
      case defn.body
      when Crystal::Expressions
        defn.body.as(Crystal::Expressions).expressions.each do |e|
          next if e.is_a?(Crystal::Nop)
          stmts << transform_before_action_stmt(e, singular)
        end
      when Crystal::Nop
        # skip
      else
        stmts << transform_before_action_stmt(defn.body, singular)
      end
    end

    private def transform_before_action_stmt(node : Crystal::ASTNode, singular : String) : Crystal::ASTNode
      if node.is_a?(Crystal::Assign)
        value = node.value
        if value.is_a?(Crystal::Call) && value.name == "find" && value.obj
          model = value.obj.not_nil!
          model_str = model.to_s
          param_name = if value.args.size > 0 && value.args[0].is_a?(Crystal::Var)
                         value.args[0].as(Crystal::Var).name
                       else
                         "id"
                       end
          var_name = node.target.to_s
          # article = Blog.Article.find(String.to_integer(conn.path_params["id"]))
          return Crystal::Assign.new(
            Crystal::Var.new(var_name),
            Crystal::Call.new(
              Crystal::Path.new(qualify_model(model_str).split(".")),
              "find",
              [build_param_coerce(param_name)] of Crystal::ASTNode
            )
          )
        end
      end
      node
    end

    private def transform_action_stmt(node : Crystal::ASTNode, stmts : Array(Crystal::ASTNode),
                                       action_name : String, singular : String, plural : String)
      full_model = "#{app_module}.#{model_name}"

      case node
      when Crystal::Call
        name = node.name
        if name == "redirect_to"
          stmts << transform_redirect(node, singular, plural)
        elsif name == "render"
          stmts << transform_render(node, action_name, singular, plural)
        elsif name == "destroy!" || name == "destroy"
          if obj = node.obj
            obj_name = emit_target(obj)
            # Blog.Model.delete(obj)
            stmts << Crystal::Call.new(
              Crystal::Path.new(full_model.split(".")),
              "delete",
              [Crystal::Var.new(obj_name)] of Crystal::ASTNode
            )
          end
        elsif name == "update" && node.obj
          # article.update(params) — transformed into case result
          obj_name = emit_target(node.obj.not_nil!)
          stmts << Crystal::Call.new(
            Crystal::Path.new(full_model.split(".")),
            "update",
            [Crystal::Var.new(obj_name),
             Crystal::Call.new(nil, "extract_model_params",
              [Crystal::Call.new(Crystal::Var.new("conn"), "body_params"),
               Crystal::StringLiteral.new(singular)] of Crystal::ASTNode
             )] of Crystal::ASTNode
          )
        else
          stmts << node
        end

      when Crystal::If
        transform_if(node, stmts, action_name, singular, plural)

      when Crystal::Assign
        transform_assign(node, stmts, action_name, singular, plural)

      else
        stmts << node
      end
    end

    private def transform_if(node : Crystal::If, stmts : Array(Crystal::ASTNode),
                              action_name : String, singular : String, plural : String)
      full_model = "#{app_module}.#{model_name}"
      cond = node.cond

      # if article.save → case Blog.Article.create(params) do
      if cond.is_a?(Crystal::Call)
        call = cond.as(Crystal::Call)
        if call.name == "save" && call.obj
          # Params were already assigned by transform_assign (new or build)
          new_cond = Crystal::Call.new(
            Crystal::Path.new(full_model.split(".")),
            "create",
            [Crystal::Var.new("params")] of Crystal::ASTNode
          )
          then_stmts = transform_branch(node.then, action_name, singular, plural)
          else_stmts = transform_branch(node.else, action_name, singular, plural)

          stmts << Crystal::If.new(new_cond,
            Crystal::Expressions.new(then_stmts),
            Crystal::Expressions.new(else_stmts))
          return
        elsif call.name == "update" && call.obj
          obj_name = emit_target(call.obj.not_nil!)
          # Add params assignment before the case
          stmts << Crystal::Assign.new(
            Crystal::Var.new("params"),
            Crystal::Call.new(nil, "extract_model_params",
              [Crystal::Call.new(Crystal::Var.new("conn"), "body_params"),
               Crystal::StringLiteral.new(singular)] of Crystal::ASTNode
            )
          )
          new_cond = Crystal::Call.new(
            Crystal::Path.new(full_model.split(".")),
            "update",
            [Crystal::Var.new(obj_name),
             Crystal::Var.new("params")] of Crystal::ASTNode
          )
          then_stmts = transform_branch(node.then, action_name, singular, plural)
          else_stmts = transform_branch(node.else, action_name, singular, plural)

          stmts << Crystal::If.new(new_cond,
            Crystal::Expressions.new(then_stmts),
            Crystal::Expressions.new(else_stmts))
          return
        end
      end

      # Generic if
      then_stmts = transform_branch(node.then, action_name, singular, plural)
      else_stmts = transform_branch(node.else, action_name, singular, plural)
      stmts << Crystal::If.new(node.cond,
        Crystal::Expressions.new(then_stmts),
        Crystal::Expressions.new(else_stmts))
    end

    private def transform_branch(node : Crystal::ASTNode, action_name : String,
                                  singular : String, plural : String) : Array(Crystal::ASTNode)
      branch_stmts = [] of Crystal::ASTNode
      case node
      when Crystal::Expressions
        node.expressions.each do |e|
          next if e.is_a?(Crystal::Nop)
          transform_action_stmt(e, branch_stmts, action_name, singular, plural)
        end
      when Crystal::Nop
        # empty
      else
        transform_action_stmt(node, branch_stmts, action_name, singular, plural)
      end
      branch_stmts
    end

    private def transform_assign(node : Crystal::Assign, stmts : Array(Crystal::ASTNode),
                                  action_name : String, singular : String, plural : String)
      full_model = "#{app_module}.#{model_name}"

      if node.value.is_a?(Crystal::Call)
        call = node.value.as(Crystal::Call)
        case call.name
        when "new"
          if call.obj.to_s == model_name
            if call.args.size > 0
              # Article.new(extract_model_params(params, "article"))
              # → params = extract_model_params(conn.body_params, "article")
              # The subsequent `if article.save` will use params via create
              stmts << Crystal::Assign.new(
                Crystal::Var.new("params"),
                rewrite_extract_model_params(call.args[0], singular)
              )
            else
              # Article.new → %Blog.Article{}
              stmts << Crystal::Assign.new(
                Crystal::Var.new(singular),
                Crystal::Call.new(Crystal::Path.new(full_model.split(".")), "empty_struct")
              )
            end
          else
            stmts << node
          end
        when "build"
          # article.comments.build(extract_model_params(params, "comment"))
          # → params = extract_model_params(conn.body_params, "comment")
          # → params = Map.put(params, :parent_id, parent.id)
          if call.obj && call.args.size > 0 && nested_parent
            parent = nested_parent.not_nil!
            stmts << Crystal::Assign.new(
              Crystal::Var.new("params"),
              rewrite_extract_model_params(call.args[0], singular)
            )
            # Add foreign key from parent
            stmts << Crystal::Assign.new(
              Crystal::Var.new("params"),
              Crystal::Call.new(Crystal::Path.new(["Map"]), "put",
                [Crystal::Var.new("params"),
                 Crystal::SymbolLiteral.new("#{parent}_id"),
                 Crystal::Call.new(Crystal::Var.new(parent), "id"),
                ] of Crystal::ASTNode)
            )
          else
            stmts << node
          end
        when "includes", "order"
          # Article.includes(:comments).order(created_at: :desc)
          # → Blog.Article.all("created_at DESC")
          order_arg = extract_order_arg(call)
          all_args = order_arg ? [Crystal::StringLiteral.new(order_arg)] of Crystal::ASTNode : [] of Crystal::ASTNode
          stmts << Crystal::Assign.new(node.target,
            Crystal::Call.new(Crystal::Path.new(full_model.split(".")), "all", all_args))
        when "find"
          if call.obj && !call.obj.is_a?(Crystal::Path)
            # association.find(id) — e.g., article.comments.find(id)
            # Resolve to: Blog.Comment.find(String.to_integer(conn.path_params["id"]))
            child_model = resolve_association_model(call.obj.not_nil!)
            new_args = call.args.map do |arg|
              if arg.is_a?(Crystal::Var)
                build_param_coerce(arg.as(Crystal::Var).name).as(Crystal::ASTNode)
              else
                arg
              end
            end
            stmts << Crystal::Assign.new(node.target,
              Crystal::Call.new(
                Crystal::Path.new(child_model.split(".")),
                "find", new_args))
          else
            stmts << node
          end
        else
          stmts << node
        end
      else
        stmts << node
      end
    end

    private def transform_redirect(node : Crystal::Call, singular : String, plural : String) : Crystal::ASTNode
      args = node.args
      if args.size > 0
        target = args[0]
        target_str = target.to_s

        path_call = if target_str == "#{plural}_path" || target_str == "#{plural}_path()"
                      Crystal::Call.new(Crystal::Path.new(["Helpers"]), "#{plural}_path")
                    elsif target_str == singular
                      Crystal::Call.new(Crystal::Path.new(["Helpers"]), "#{singular}_path",
                        [Crystal::Var.new(singular)] of Crystal::ASTNode)
                    elsif target.is_a?(Crystal::Var)
                      # Variable reference (e.g., article in comments controller)
                      Crystal::Call.new(Crystal::Path.new(["Helpers"]), "#{target_str}_path",
                        [Crystal::Var.new(target_str)] of Crystal::ASTNode)
                    else
                      Crystal::StringLiteral.new("/#{plural}")
                    end

        # conn |> put_resp_header("location", path) |> send_resp(302, "")
        build_redirect_pipe(path_call)
      else
        build_redirect_pipe(Crystal::StringLiteral.new("/#{plural}"))
      end
    end

    private def build_redirect_pipe(path : Crystal::ASTNode) : Crystal::ASTNode
      # We encode this as a special Call that the emitter renders as a pipe chain
      # Using a synthetic "redirect_pipe" call that Cr2Ex recognizes
      Crystal::Call.new(nil, "__redirect_pipe__",
        [path] of Crystal::ASTNode)
    end

    private def transform_render(node : Crystal::Call, action_name : String,
                                  singular : String, plural : String) : Crystal::ASTNode
      template = if node.args.size > 0
                   node.args[0].to_s.strip(':').strip('"')
                 else
                   action_name
                 end

      status = 200
      if named = node.named_args
        named.each do |na|
          if na.name == "status"
            val = na.value.to_s.strip(':').strip('"')
            status = case val
                     when "unprocessable_entity" then 422
                     when "created"              then 201
                     else 200
                     end
          end
        end
      end

      build_render_view(template, singular, plural, status)
    end

    private def build_render_view(template : String, singular : String, plural : String, status : Int32) : Crystal::ASTNode
      template_path = "#{plural}/#{template}"
      var_name = template == "index" ? plural : singular

      args = [
        Crystal::Var.new("conn"),
        Crystal::StringLiteral.new(template_path),
        Crystal::Var.new(var_name), # placeholder — emitter formats as keyword list
      ] of Crystal::ASTNode

      if status != 200
        args << Crystal::NumberLiteral.new(status.to_s)
      end

      Crystal::Call.new(Crystal::Path.new(["Helpers"]), "render_view", args)
    end

    private def render_view(action_name : String, singular : String, plural : String) : Crystal::ASTNode
      build_render_view(action_name, singular, plural, 200)
    end

    # ── Helpers ──

    private def qualify_model(name : String) : String
      if name == model_name || name == "#{model_name}"
        "#{app_module}.#{model_name}"
      else
        "#{app_module}.#{name}"
      end
    end

    private def build_param_coerce(param_name : String) : Crystal::ASTNode
      # String.to_integer(conn.path_params["param_name"])
      Crystal::Call.new(
        Crystal::Path.new(["String"]),
        "to_integer",
        [Crystal::Call.new(
          Crystal::Call.new(Crystal::Var.new("conn"), "path_params"),
          "[]",
          [Crystal::StringLiteral.new(param_name)] of Crystal::ASTNode
        )] of Crystal::ASTNode
      )
    end

    private def emit_target(node : Crystal::ASTNode) : String
      case node
      when Crystal::Var then node.name
      when Crystal::InstanceVar then node.name.lchop("@")
      when Crystal::Call then node.name
      else node.to_s
      end
    end

    private def extract_order_arg(call : Crystal::Call) : String?
      node = call
      while node.is_a?(Crystal::Call)
        if node.name == "order"
          if named = node.named_args
            if na = named.first?
              dir = na.value.to_s.strip(':').strip('"').upcase
              return "#{na.name} #{dir}"
            end
          end
          if !node.args.empty?
            return node.args[0].to_s.strip(':').strip('"')
          end
        end
        node = node.obj
      end
      nil
    end

    # Rewrite extract_model_params(params, "model") → extract_model_params(conn.body_params, "model")
    private def rewrite_extract_model_params(node : Crystal::ASTNode, singular : String) : Crystal::ASTNode
      if node.is_a?(Crystal::Call) && node.name == "extract_model_params"
        Crystal::Call.new(nil, "extract_model_params",
          [Crystal::Call.new(Crystal::Var.new("conn"), "body_params"),
           Crystal::StringLiteral.new(singular)] of Crystal::ASTNode)
      else
        # Fallback: wrap in extract_model_params
        Crystal::Call.new(nil, "extract_model_params",
          [Crystal::Call.new(Crystal::Var.new("conn"), "body_params"),
           Crystal::StringLiteral.new(singular)] of Crystal::ASTNode)
      end
    end

    # Resolve association call chain to qualified model name
    # e.g., article.comments → Blog.Comment
    private def resolve_association_model(obj : Crystal::ASTNode) : String
      # Walk the call chain to find the association name
      assoc_name = case obj
                   when Crystal::Call
                     obj.as(Crystal::Call).name
                   else
                     obj.to_s
                   end
      child_class = Inflector.classify(Inflector.singularize(assoc_name))
      "#{app_module}.#{child_class}"
    end

    private def ends_with_redirect_or_render?(stmts : Array(Crystal::ASTNode)) : Bool
      return false if stmts.empty?
      last = stmts.last
      str = last.to_s
      return true if str.includes?("__redirect_pipe__") || str.includes?("render_view")
      return true if last.is_a?(Crystal::If)
      false
    end
  end
end
