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

    def initialize(@controller_name, @model_name, @nested_parent = nil)
    end

    def transform(node : Crystal::ClassDef) : Crystal::ASTNode
      body = node.body
      exprs = case body
              when Crystal::Expressions then body.expressions
              else [body]
              end

      # Collect before_action callbacks and private methods
      before_actions = {} of String => Array(String)
      private_methods = {} of String => Crystal::Def
      in_private = false

      exprs.each do |expr|
        case expr
        when Crystal::Call
          if expr.name == "before_action"
            parse_before_action(expr, before_actions)
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

      # Transform public actions
      actions = [] of Crystal::ASTNode
      in_private = false
      exprs.each do |expr|
        case expr
        when Crystal::Call
          next  # skip before_action declarations
        when Crystal::VisibilityModifier
          in_private = true
          next
        when Crystal::Def
          next if in_private
          actions << transform_action(expr, before_actions, private_methods)
        end
      end

      Crystal::Expressions.new(actions)
    end

    def transform(node : Crystal::ASTNode) : Crystal::ASTNode
      super
    end

    private def parse_before_action(call : Crystal::Call, result : Hash(String, Array(String)))
      return unless call.args.size > 0
      method_name = call.args[0].to_s.strip(':').strip('"')

      only = [] of String
      if named = call.named_args
        named.each do |na|
          if na.name == "only" && na.value.is_a?(Crystal::ArrayLiteral)
            na.value.as(Crystal::ArrayLiteral).elements.each do |el|
              only << el.to_s.strip(':').strip('"')
            end
          end
        end
      end

      if only.empty?
        # Applies to all actions — we'll handle this by marking all known actions
      else
        only.each do |action|
          result[action] ||= [] of String
          result[action] << method_name
        end
      end
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
        stmts << Crystal::Parser.parse("if data.nil?\n  data = parse_form(request.read)\nend")
      end

      # Inline before_action callbacks
      if callbacks = before_actions[action_name]?
        callbacks.each do |cb_name|
          if cb_def = private_methods[cb_name]?
            inline_method_body(cb_def, stmts, singular)
          end
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
      # article = Article.find(id) → article = Article.find(int(request.match_info['id']))
      if node.is_a?(Crystal::Assign)
        value = node.value
        if value.is_a?(Crystal::Call) && value.name == "find"
          return Crystal::Parser.parse(
            "#{singular} = #{@model_name}.find(int(request.match_info[\"id\"]))"
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

        if name == "redirect_to"
          stmts << transform_redirect(node, singular, plural)
        elsif name == "render"
          stmts << transform_render(node, action_name, singular)
        elsif name == "destroy!" || name == "destroy"
          # article.destroy! → article.destroy()
          if obj = node.obj
            stmts << Crystal::Parser.parse("#{obj}.destroy")
          end
        else
          stmts << node
        end

      when Crystal::If
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

        new_if = Crystal::If.new(node.cond,
          Crystal::Expressions.new(then_stmts),
          Crystal::Expressions.new(else_stmts))
        stmts << new_if

      when Crystal::Assign
        # Transform value side
        if node.value.is_a?(Crystal::Call)
          call = node.value.as(Crystal::Call)
          if call.name == "new" && call.obj.to_s == @model_name
            # Article.new(extract_model_params(params, "article"))
            # → Article(extract_model_params(data, "article"))
            stmts << Crystal::Parser.parse(
              "#{singular} = #{@model_name}.new(extract_model_params(data, \"#{singular}\"))"
            )
          elsif call.name == "includes" || call.name == "order"
            # Article.includes(:comments).order(...) → Article.all()
            stmts << Crystal::Parser.parse("#{node.target} = #{@model_name}.all")
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

        path = if target_str == "#{plural}_path" || target_str == "#{plural}_path()"
                 "#{plural}_path()"
               elsif target_str == singular || target_str.includes?("@")
                 "#{singular}_path(#{singular})"
               else
                 target_str
               end

        Crystal::Parser.parse("raise web.HTTPFound(#{path})")
      else
        Crystal::Parser.parse("raise web.HTTPFound(\"/#{plural}\")")
      end
    end

    private def transform_render(node : Crystal::Call, action_name : String, singular : String) : Crystal::ASTNode
      template = if node.args.size > 0
                   node.args[0].to_s.strip(':').strip('"')
                 else
                   action_name
                 end

      status = "200"
      if named = node.named_args
        named.each do |na|
          if na.name == "status"
            val = na.value.to_s.strip(':').strip('"')
            status = case val
                     when "unprocessable_entity" then "422"
                     when "created"              then "201"
                     when "ok"                   then "200"
                     else val
                     end
          end
        end
      end

      Crystal::Parser.parse(
        "return web.Response(text: layout(render_#{template}(#{singular}: #{singular})), content_type: \"text/html\", status: #{status})"
      )
    end

    private def render_template(action_name : String, singular : String) : Crystal::ASTNode
      Crystal::Parser.parse(
        "return web.Response(text: layout(render_#{action_name}(#{singular}: #{singular})), content_type: \"text/html\")"
      )
    end

    private def ends_with_redirect_or_render?(stmts : Array(Crystal::ASTNode)) : Bool
      return false if stmts.empty?
      last = stmts.last
      return true if last.to_s.includes?("web.HTTPFound") || last.to_s.includes?("web.Response")
      if last.is_a?(Crystal::If)
        # Both branches should end with redirect/render
        return true  # Assume if/else in action body is redirect/render pattern
      end
      false
    end
  end
end
