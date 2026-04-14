# Filter: Transform Rails controller class into async Python handler functions.
#
# Input (Crystal AST from Prism, after shared filters):
#   class ArticlesController < ApplicationController
#     before_action(:set_article, only: [:show, :edit, :update, :destroy])
#     def index; articles = Article.all; end
#     def create; article = Article.new(extract_model_params(params, "article")); ...
#     private
#     def set_article; article = Article.find(id); end
#   end
#
# Output (Crystal AST that emits as async Python functions):
#   def index(request); articles = Article.all; end
#   def create(request); ...; end

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

      # Collect before_action callbacks
      before_actions = {} of String => Array(String)
      private_methods = {} of String => Crystal::Def
      actions = [] of Crystal::ASTNode
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
          else
            actions << transform_action(expr, before_actions, private_methods)
          end
        when Crystal::VisibilityModifier
          in_private = true
          if expr.exp.is_a?(Crystal::Def)
            private_methods[expr.exp.as(Crystal::Def).name] = expr.exp.as(Crystal::Def)
          end
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

      only.each do |action|
        result[action] ||= [] of String
        result[action] << method_name
      end
    end

    private def transform_action(defn : Crystal::Def,
                                  before_actions : Hash(String, Array(String)),
                                  private_methods : Hash(String, Crystal::Def)) : Crystal::ASTNode
      action_name = defn.name
      stmts = [] of Crystal::ASTNode

      # Inline before_action callbacks
      if callbacks = before_actions[action_name]?
        callbacks.each do |cb_name|
          if cb_def = private_methods[cb_name]?
            case cb_def.body
            when Crystal::Expressions
              cb_def.body.as(Crystal::Expressions).expressions.each do |e|
                stmts << e unless e.is_a?(Crystal::Nop)
              end
            when Crystal::Nop
              # skip
            else
              stmts << cb_def.body
            end
          end
        end
      end

      # Add action body
      case defn.body
      when Crystal::Expressions
        defn.body.as(Crystal::Expressions).expressions.each do |e|
          stmts << e unless e.is_a?(Crystal::Nop)
        end
      when Crystal::Nop
        # empty action
      else
        stmts << defn.body
      end

      # Add request parameter
      args = [Crystal::Arg.new("request")]

      # For create/update/destroy, add data parameter
      if %w[create update destroy].includes?(action_name)
        data_arg = Crystal::Arg.new("data")
        data_arg.default_value = Crystal::NilLiteral.new
        args << data_arg
      end

      new_def = Crystal::Def.new(action_name, args,
        Crystal::Expressions.new(stmts))
      new_def
    end
  end
end
