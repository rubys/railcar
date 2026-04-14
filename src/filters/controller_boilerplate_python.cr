# Filter: Transform Rails controller class into async Python handler functions.
#
# Transforms Rails patterns to Python/aiohttp equivalents:
#   redirect_to(model) → raise web.HTTPFound(model_path(model))
#   render(:template, status: :unprocessable_entity) → return web.Response(text=render_template(...), status=422)
#   params → request form data parsing
#   before_action inlining

require "compiler/crystal/syntax"
require "../generator/inflector"

module Railcar
  class ControllerBoilerplatePython < Crystal::Transformer
    getter controller_name : String
    getter model_name : String
    getter nested_parent : String?
    getter extracted_before_actions : Array(BeforeAction)

    def initialize(@controller_name, @model_name, @nested_parent = nil,
                   @extracted_before_actions = [] of BeforeAction)
    end

    def transform(node : Crystal::ClassDef) : Crystal::ASTNode
      body = node.body
      exprs = case body
              when Crystal::Expressions then body.expressions
              else [body]
              end

      # Build before_actions lookup from extracted ControllerInfo
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

      # Collect private methods from AST (needed for inlining)
      private_methods = {} of String => Crystal::Def
      in_private = false

      exprs.each do |expr|
        case expr
        when Crystal::Call
          if expr.name == "private" && expr.args.empty?
            in_private = true
          end
        when Crystal::Def
          if in_private
            private_methods[expr.name] = expr
          end
        when Crystal::VisibilityModifier
          in_private = true
          if expr.exp.is_a?(Crystal::Def)
            private_methods[expr.exp.as(Crystal::Def).name] = expr.exp.as(Crystal::Def)
          end
        end
      end

      # Transform public actions (skip private methods and Call nodes)
      actions = [] of Crystal::ASTNode
      in_private = false  # reset for second pass
      exprs.each do |expr|
        case expr
        when Crystal::Call
          if expr.as(Crystal::Call).name == "private"
            in_private = true
          end
          next  # skip before_action and other declarations
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

      stmts = [] of Crystal::ASTNode

      # For create/update/destroy: parse form data
      if %w[create update destroy].includes?(action_name)
        # if data is None: data = parse_form(request.read)
        stmts << Crystal::If.new(
          Crystal::Call.new(Crystal::Var.new("data"), "nil?"),
          Crystal::Assign.new(
            Crystal::Var.new("data"),
            Crystal::Call.new(nil, "parse_form",
              [Crystal::Call.new(Crystal::Var.new("request"), "read")] of Crystal::ASTNode)
          )
        )
      end

      # Inline before_action callbacks (specific + wildcard)
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
        # empty action — just render the template
        stmts << render_template(action_name, singular)
      else
        transform_action_stmt(defn.body, stmts, action_name, singular, plural)
      end

      # If action doesn't end with a redirect or return, add template render
      unless ends_with_redirect_or_render?(stmts)
        stmts << render_template(action_name, singular)
      end

      # Build function
      args = [Crystal::Arg.new("request")]
      if %w[create update destroy].includes?(action_name)
        data_arg = Crystal::Arg.new("data")
        data_arg.default_value = Crystal::NilLiteral.new
        args << data_arg
      end

      func_name = action_name == "new" ? "new" : action_name
      new_def = Crystal::Def.new(func_name, args,
        Crystal::Expressions.new(stmts),
        return_type: Crystal::Path.new("web.Response"))
      new_def
    end

    private def inline_method_body(defn : Crystal::Def, stmts : Array(Crystal::ASTNode), singular : String)
      case defn.body
      when Crystal::Expressions
        defn.body.as(Crystal::Expressions).expressions.each do |e|
          next if e.is_a?(Crystal::Nop)
          # Transform set_article: Article.find(id) → Article.find(int(request.match_info['id']))
          stmts << transform_before_action_stmt(e, singular)
        end
      when Crystal::Nop
        # skip
      else
        stmts << transform_before_action_stmt(defn.body, singular)
      end
    end

    private def transform_before_action_stmt(node : Crystal::ASTNode, singular : String) : Crystal::ASTNode
      # article = Article.find(article_id) → article = Model.find(int(request.match_info['article_id']))
      if node.is_a?(Crystal::Assign)
        value = node.value
        if value.is_a?(Crystal::Call) && value.name == "find" && value.obj
          # Determine model class and URL parameter name from the find call
          model = value.obj.not_nil!
          param_name = if value.args.size > 0 && value.args[0].is_a?(Crystal::Var)
                         value.args[0].as(Crystal::Var).name
                       else
                         "id"
                       end
          var_name = node.target.to_s
          return Crystal::Assign.new(
            Crystal::Var.new(var_name),
            Crystal::Call.new(model, "find",
              [Crystal::Call.new(nil, "int",
                [Crystal::Call.new(
                  Crystal::Call.new(Crystal::Var.new("request"), "match_info"),
                  "[]",
                  [Crystal::StringLiteral.new(param_name)] of Crystal::ASTNode
                )] of Crystal::ASTNode
              )] of Crystal::ASTNode
            )
          )
        end
      end
      node
    end

    private def transform_action_stmt(node : Crystal::ASTNode, stmts : Array(Crystal::ASTNode),
                                       action_name : String, singular : String, plural : String)
      case node
      when Crystal::Call
        name = node.name

        if name == "update" && node.obj
          # article.update(params) → update attributes and save
          stmts << Crystal::Call.new(node.obj.not_nil!, "update",
            [Crystal::Call.new(nil, "extract_model_params",
              [Crystal::Var.new("data"),
               Crystal::StringLiteral.new(singular)] of Crystal::ASTNode
            )] of Crystal::ASTNode)
          return
        elsif name == "redirect_to"
          stmts << transform_redirect(node, singular, plural)
        elsif name == "render"
          stmts << transform_render(node, action_name, singular)
        elsif name == "destroy!" || name == "destroy"
          if obj = node.obj
            stmts << Crystal::Call.new(obj, "destroy")
          end
        else
          stmts << node
        end

      when Crystal::If
        # Transform condition — handle article.update(params) → article.update(data)
        cond = node.cond
        if cond.is_a?(Crystal::Call) && cond.name == "update" && cond.obj
          cond = Crystal::Call.new(cond.obj, "update",
            [Crystal::Call.new(nil, "extract_model_params",
              [Crystal::Var.new("data"),
               Crystal::StringLiteral.new(singular)] of Crystal::ASTNode
            )] of Crystal::ASTNode)
        end

        # Transform both branches
        then_stmts = [] of Crystal::ASTNode
        else_stmts = [] of Crystal::ASTNode

        case node.then
        when Crystal::Expressions
          node.then.as(Crystal::Expressions).expressions.each do |e|
            transform_action_stmt(e, then_stmts, action_name, singular, plural)
          end
        when Crystal::Nop
          # skip
        else
          transform_action_stmt(node.then, then_stmts, action_name, singular, plural)
        end

        case node.else
        when Crystal::Expressions
          node.else.as(Crystal::Expressions).expressions.each do |e|
            transform_action_stmt(e, else_stmts, action_name, singular, plural)
          end
        when Crystal::Nop
          # skip
        else
          transform_action_stmt(node.else, else_stmts, action_name, singular, plural)
        end

        new_if = Crystal::If.new(cond,
          Crystal::Expressions.new(then_stmts),
          Crystal::Expressions.new(else_stmts))
        stmts << new_if

      when Crystal::Assign
        # Transform value side
        if node.value.is_a?(Crystal::Call)
          call = node.value.as(Crystal::Call)
          if call.name == "new" && call.obj.to_s == @model_name
            if call.args.size > 0
              # Article.new(extract_model_params(params, "article"))
              # → article = Article(extract_model_params(data, "article"))
              stmts << Crystal::Assign.new(
                Crystal::Var.new(singular),
                Crystal::Call.new(Crystal::Path.new(@model_name), "new",
                  [Crystal::Call.new(nil, "extract_model_params",
                    [Crystal::Var.new("data"),
                     Crystal::StringLiteral.new(singular)] of Crystal::ASTNode
                  )] of Crystal::ASTNode)
              )
            else
              # Article.new → Article()
              stmts << Crystal::Assign.new(
                Crystal::Var.new(singular),
                Crystal::Call.new(Crystal::Path.new(@model_name), "new")
              )
            end
          elsif call.name == "build" && call.args.size > 0
            # article.comments.build(extract_model_params(params, "comment"))
            # → replace params with data
            new_args = call.args.map do |arg|
              replace_params_with_data(arg)
            end
            stmts << Crystal::Assign.new(node.target,
              Crystal::Call.new(call.obj, "build", new_args))
          elsif call.name == "find" && call.obj && !call.obj.is_a?(Crystal::Path)
            # article.comments.find(id) → Model.find(int(request.match_info['id']))
            new_args = call.args.map do |arg|
              if arg.is_a?(Crystal::Var)
                Crystal::Call.new(nil, "int",
                  [Crystal::Call.new(
                    Crystal::Call.new(Crystal::Var.new("request"), "match_info"),
                    "[]",
                    [Crystal::StringLiteral.new(arg.as(Crystal::Var).name)] of Crystal::ASTNode
                  )] of Crystal::ASTNode)
              else
                arg
              end
            end
            stmts << Crystal::Assign.new(node.target,
              Crystal::Call.new(call.obj, "find", new_args))
          elsif call.name == "includes" || call.name == "order"
            # Article.includes(:comments).order(...) → Article.all()
            stmts << Crystal::Assign.new(node.target, Crystal::Call.new(Crystal::Path.new(@model_name), "all"))
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
                      Crystal::Call.new(nil, "#{plural}_path")
                    elsif target_str == singular || target_str.includes?("@")
                      Crystal::Call.new(nil, "#{singular}_path", [Crystal::Var.new(singular)] of Crystal::ASTNode)
                    elsif target.is_a?(Crystal::Var) || target.is_a?(Crystal::Call)
                      # Variable reference (e.g., article in comments controller) → model_path(model)
                      Crystal::Call.new(nil, "#{target_str}_path", [Crystal::Var.new(target_str)] of Crystal::ASTNode)
                    else
                      target
                    end

        Crystal::Call.new(nil, "raise",
          [Crystal::Call.new(Crystal::Path.new(["web", "HTTPFound"]), "new",
            [path_call] of Crystal::ASTNode)] of Crystal::ASTNode)
      else
        Crystal::Call.new(nil, "raise",
          [Crystal::Call.new(Crystal::Path.new(["web", "HTTPFound"]), "new",
            [Crystal::StringLiteral.new("/#{plural}")] of Crystal::ASTNode)] of Crystal::ASTNode)
      end
    end

    private def transform_render(node : Crystal::Call, action_name : String, singular : String) : Crystal::ASTNode
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
                     when "ok"                   then 200
                     else 200
                     end
          end
        end
      end

      build_response(template, singular, status)
    end

    private def render_template(action_name : String, singular : String) : Crystal::ASTNode
      build_response(action_name, singular, 200)
    end

    private def build_response(template : String, singular : String, status : Int32) : Crystal::ASTNode
      # index uses plural (articles), other actions use singular (article)
      var_name = template == "index" ? Inflector.pluralize(singular) : singular
      render_call = Crystal::Call.new(nil, "render_#{template}",
        named_args: [Crystal::NamedArgument.new(var_name, Crystal::Var.new(var_name))])
      layout_call = Crystal::Call.new(nil, "layout", [render_call] of Crystal::ASTNode)

      response_args = [
        Crystal::NamedArgument.new("text", layout_call),
        Crystal::NamedArgument.new("content_type", Crystal::StringLiteral.new("text/html")),
      ]
      if status != 200
        response_args << Crystal::NamedArgument.new("status", Crystal::NumberLiteral.new(status.to_s))
      end

      Crystal::Return.new(
        Crystal::Call.new(Crystal::Path.new(["web", "Response"]), "new",
          named_args: response_args)
      )
    end

    private def replace_params_with_data(node : Crystal::ASTNode) : Crystal::ASTNode
      if node.is_a?(Crystal::Call) && node.name == "extract_model_params"
        new_args = node.args.map do |arg|
          if arg.is_a?(Crystal::Var) && arg.name == "params"
            Crystal::Var.new("data").as(Crystal::ASTNode)
          else
            arg
          end
        end
        Crystal::Call.new(nil, "extract_model_params", new_args)
      else
        node
      end
    end

    private def ends_with_redirect_or_render?(stmts : Array(Crystal::ASTNode)) : Bool
      return false if stmts.empty?
      last = stmts.last
      return true if last.is_a?(Crystal::Return)
      str = last.to_s
      return true if str.includes?("HTTPFound") || str.includes?("Response")
      return true if last.is_a?(Crystal::If)
      false
    end
  end
end
