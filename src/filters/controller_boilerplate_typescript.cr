# Filter: Transform Rails controller class into Express route handler functions.
#
# Transforms Rails patterns to Express/TypeScript equivalents:
#   redirect_to(model) → res.redirect(modelPath(model))
#   render(:template, status: :unprocessable_entity) → res.status(422).send(layout(renderTemplate(...)))
#   params → parseForm(req.body)
#   before_action inlining

require "compiler/crystal/syntax"
require "../generator/inflector"

module Railcar
  class ControllerBoilerplateTypeScript < Crystal::Transformer
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

      stmts = [] of Crystal::ASTNode

      # For create/update/destroy: parse form data
      if %w[create update destroy].includes?(action_name)
        stmts << Crystal::If.new(
          Crystal::Call.new(Crystal::Var.new("data"), "nil?"),
          Crystal::Assign.new(
            Crystal::Var.new("data"),
            Crystal::Call.new(nil, "parseForm",
              [Crystal::Call.new(Crystal::Var.new("req"), "body")] of Crystal::ASTNode)
          )
        )
      end

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
        stmts << render_template(action_name, singular)
      else
        transform_action_stmt(defn.body, stmts, action_name, singular, plural)
      end

      # Add implicit render if needed
      unless ends_with_redirect_or_render?(stmts)
        stmts << render_template(action_name, singular)
      end

      # Build function: (req: Request, res: Response, data?: ...) => void
      args = [Crystal::Arg.new("req"), Crystal::Arg.new("res")]
      if %w[create update destroy].includes?(action_name)
        data_arg = Crystal::Arg.new("data")
        data_arg.default_value = Crystal::NilLiteral.new
        args << data_arg
      end

      func_name = action_name == "new" ? "newAction" : action_name
      Crystal::Def.new(func_name, args,
        Crystal::Expressions.new(stmts),
        return_type: Crystal::Path.new("void"))
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
          param_name = if value.args.size > 0 && value.args[0].is_a?(Crystal::Var)
                         value.args[0].as(Crystal::Var).name
                       else
                         "id"
                       end
          var_name = node.target.to_s
          return Crystal::Assign.new(
            Crystal::Var.new(var_name),
            Crystal::Call.new(model, "find",
              [Crystal::Call.new(nil, "Number",
                [Crystal::Call.new(
                  Crystal::Call.new(Crystal::Var.new("req"), "params"),
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
          stmts << Crystal::Call.new(node.obj.not_nil!, "update",
            [Crystal::Call.new(nil, "extractModelParams",
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
        cond = node.cond
        if cond.is_a?(Crystal::Call) && cond.name == "update" && cond.obj
          cond = Crystal::Call.new(cond.obj, "update",
            [Crystal::Call.new(nil, "extractModelParams",
              [Crystal::Var.new("data"),
               Crystal::StringLiteral.new(singular)] of Crystal::ASTNode
            )] of Crystal::ASTNode)
        end

        then_stmts = [] of Crystal::ASTNode
        else_stmts = [] of Crystal::ASTNode

        case node.then
        when Crystal::Expressions
          node.then.as(Crystal::Expressions).expressions.each { |e| transform_action_stmt(e, then_stmts, action_name, singular, plural) }
        when Crystal::Nop then nil
        else transform_action_stmt(node.then, then_stmts, action_name, singular, plural)
        end

        case node.else
        when Crystal::Expressions
          node.else.as(Crystal::Expressions).expressions.each { |e| transform_action_stmt(e, else_stmts, action_name, singular, plural) }
        when Crystal::Nop then nil
        else transform_action_stmt(node.else, else_stmts, action_name, singular, plural)
        end

        stmts << Crystal::If.new(cond,
          Crystal::Expressions.new(then_stmts),
          Crystal::Expressions.new(else_stmts))

      when Crystal::Assign
        if node.value.is_a?(Crystal::Call)
          call = node.value.as(Crystal::Call)
          if call.name == "new" && call.obj.to_s == @model_name
            if call.args.size > 0
              stmts << Crystal::Assign.new(
                Crystal::Var.new(singular),
                Crystal::Call.new(Crystal::Path.new(@model_name), "new",
                  [Crystal::Call.new(nil, "extractModelParams",
                    [Crystal::Var.new("data"),
                     Crystal::StringLiteral.new(singular)] of Crystal::ASTNode
                  )] of Crystal::ASTNode))
            else
              stmts << Crystal::Assign.new(
                Crystal::Var.new(singular),
                Crystal::Call.new(Crystal::Path.new(@model_name), "new"))
            end
          elsif call.name == "build" && call.args.size > 0
            new_args = call.args.map { |arg| replace_params_with_data(arg) }
            stmts << Crystal::Assign.new(node.target,
              Crystal::Call.new(call.obj, "build", new_args))
          elsif call.name == "find" && call.obj && !call.obj.is_a?(Crystal::Path)
            new_args = call.args.map do |arg|
              if arg.is_a?(Crystal::Var)
                Crystal::Call.new(nil, "Number",
                  [Crystal::Call.new(
                    Crystal::Call.new(Crystal::Var.new("req"), "params"),
                    "[]",
                    [Crystal::StringLiteral.new(arg.as(Crystal::Var).name)] of Crystal::ASTNode
                  )] of Crystal::ASTNode).as(Crystal::ASTNode)
              else
                arg
              end
            end
            stmts << Crystal::Assign.new(node.target,
              Crystal::Call.new(call.obj, "find", new_args))
          elsif call.name == "includes" || call.name == "order"
            order_arg = extract_order_arg(call)
            all_call = Crystal::Call.new(Crystal::Path.new(@model_name), "all",
              order_arg ? [Crystal::StringLiteral.new(order_arg)] of Crystal::ASTNode : [] of Crystal::ASTNode)
            stmts << Crystal::Assign.new(node.target, all_call)
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

        # Build path helper call
        path_name = if target_str == "#{plural}_path" || target_str == "#{plural}_path()"
                      "#{plural}Path"
                    elsif target_str == singular || target_str.includes?("@")
                      "#{singular}Path"
                    elsif target.is_a?(Crystal::Var) || target.is_a?(Crystal::Call)
                      "#{target_str}Path"
                    else
                      nil
                    end

        if path_name
          path_args = if path_name == "#{plural}Path"
                        [] of Crystal::ASTNode
                      else
                        [Crystal::Var.new(target_str == singular ? singular : target_str)] of Crystal::ASTNode
                      end
          path_call = Crystal::Call.new(nil, path_name, path_args)
          Crystal::Call.new(Crystal::Var.new("res"), "redirect", [path_call] of Crystal::ASTNode)
        else
          Crystal::Call.new(Crystal::Var.new("res"), "redirect",
            [Crystal::StringLiteral.new("/#{plural}")] of Crystal::ASTNode)
        end
      else
        Crystal::Call.new(Crystal::Var.new("res"), "redirect",
          [Crystal::StringLiteral.new("/#{plural}")] of Crystal::ASTNode)
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
      var_name = template == "index" ? Inflector.pluralize(singular) : singular
      # Capitalize template name for function: renderIndex, renderShow, etc.
      func_name = "render#{template.capitalize}"
      render_call = Crystal::Call.new(nil, func_name,
        [Crystal::Var.new(var_name)] of Crystal::ASTNode)
      layout_call = Crystal::Call.new(nil, "layout", [render_call] of Crystal::ASTNode)

      if status != 200
        # res.status(422).send(layout(renderNew(article)))
        status_call = Crystal::Call.new(Crystal::Var.new("res"), "status",
          [Crystal::NumberLiteral.new(status.to_s)] of Crystal::ASTNode)
        Crystal::Call.new(status_call, "send", [layout_call] of Crystal::ASTNode)
      else
        # res.send(layout(renderIndex(articles)))
        Crystal::Call.new(Crystal::Var.new("res"), "send", [layout_call] of Crystal::ASTNode)
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

    private def replace_params_with_data(node : Crystal::ASTNode) : Crystal::ASTNode
      if node.is_a?(Crystal::Call) && node.name == "extract_model_params"
        new_args = node.args.map do |arg|
          if arg.is_a?(Crystal::Var) && arg.name == "params"
            Crystal::Var.new("data").as(Crystal::ASTNode)
          else
            arg
          end
        end
        Crystal::Call.new(nil, "extractModelParams", new_args)
      else
        node
      end
    end

    private def ends_with_redirect_or_render?(stmts : Array(Crystal::ASTNode)) : Bool
      return false if stmts.empty?
      last = stmts.last
      return true if last.is_a?(Crystal::Return)
      str = last.to_s
      return true if str.includes?("redirect") || str.includes?("send") || str.includes?("status")
      return true if last.is_a?(Crystal::If)
      false
    end
  end
end
