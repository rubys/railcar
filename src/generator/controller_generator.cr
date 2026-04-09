# Generates Crystal controller methods from extracted Rails controller AST.
#
# Builds Crystal AST trees from Prism AST, serialized via to_s + Crystal.format.

require "compiler/crystal/syntax"
require "./crystal_expr"
require "./crystal_emitter"
require "./controller_extractor"

module Railcar
  class ControllerGenerator
    include CrystalExpr

    RENDER_ACTIONS = {"index", "show", "new", "edit"}

    getter controller : String
    getter singular : String

    def initialize(@controller, @singular = CrystalEmitter.singularize(controller))
    end

    def self.generate_action(action : ControllerAction, controller_name : String, render_view : Bool = false) : String
      new(controller_name).generate_action(action, render_view)
    end

    def generate_action(action : ControllerAction, render_view : Bool = false) : String
      args = [Crystal::Arg.new("response")] of Crystal::Arg
      if needs_id?(action.name)
        args << Crystal::Arg.new("id", restriction: Crystal::Path.new("Int64"))
      end
      if needs_params?(action.name)
        args << Crystal::Arg.new("params", restriction: Crystal::Generic.new(
          Crystal::Path.new("Hash"),
          [Crystal::Path.new("String"), Crystal::Path.new("String")] of Crystal::ASTNode
        ))
      end

      body_nodes = [] of Crystal::ASTNode

      if render_view && RENDER_ACTIONS.includes?(action.name)
        body_nodes << build_flash_consumption
      end

      if body = action.body
        body_nodes.concat(build_body(body, action.name))
      end

      if render_view && RENDER_ACTIONS.includes?(action.name)
        body_nodes << build_view_render(action.name)
      end

      def_node = Crystal::Def.new(action.name, args,
        body: Crystal::Expressions.new(body_nodes))
      def_node.to_s + "\n"
    end

    # --- CrystalExpr overrides ---

    def convert_call(call : Prism::CallNode) : String
      map_call(call).to_s
    end

    def map_call(call : Prism::CallNode) : Crystal::ASTNode
      receiver = call.receiver
      method = call.name
      args = call.arg_nodes

      case method
      when "find"
        recv = receiver ? map_node(receiver) : Crystal::Var.new(singular)
        arg = if args.size == 1
                mapped = map_node(args[0])
                mapped.to_s.includes?("params") ? Crystal::Var.new("id") : mapped
              else
                Crystal::Var.new("id")
              end
        Crystal::Call.new(recv, "find", [arg] of Crystal::ASTNode)
      when "new"
        recv = receiver ? map_node(receiver) : Crystal::Var.new(singular)
        if args.empty?
          Crystal::Call.new(recv, "new")
        elsif args[0].is_a?(Prism::CallNode) && args[0].as(Prism::CallNode).name.ends_with?("_params")
          Crystal::Call.new(recv, "new", [extract_model_params_call] of Crystal::ASTNode)
        else
          Crystal::Call.new(recv, "new", [map_node(args[0])] of Crystal::ASTNode)
        end
      when "save", "save!"
        recv = receiver ? map_node(receiver) : Crystal::Var.new(singular)
        Crystal::Call.new(recv, "save")
      when "update"
        recv = receiver ? map_node(receiver) : Crystal::Var.new(singular)
        if args.size == 1 && args[0].is_a?(Prism::CallNode) && args[0].as(Prism::CallNode).name.ends_with?("_params")
          Crystal::Call.new(recv, "update", [extract_model_params_call] of Crystal::ASTNode)
        else
          Crystal::Call.new(recv, "update", args.map { |a| map_node(a) })
        end
      when "destroy", "destroy!"
        recv = receiver ? map_node(receiver) : Crystal::Var.new(singular)
        Crystal::Call.new(recv, "destroy")
      when "build"
        recv = receiver ? map_node(receiver) : Crystal::Var.new("self")
        if args.size == 1 && args[0].is_a?(Prism::CallNode) && args[0].as(Prism::CallNode).name.ends_with?("_params")
          child_singular = CrystalEmitter.singularize(args[0].as(Prism::CallNode).name.rchop("_params"))
          Crystal::Call.new(recv, "build", [
            Crystal::Call.new(nil, "extract_model_params", [
              Crystal::Var.new("params"), Crystal::StringLiteral.new(child_singular),
            ] of Crystal::ASTNode),
          ] of Crystal::ASTNode)
        else
          Crystal::Call.new(recv, "build", args.map { |a| map_node(a) })
        end
      when "expect"
        if args.size == 1 && args[0].is_a?(Prism::SymbolNode)
          Crystal::Var.new(args[0].as(Prism::SymbolNode).value)
        else
          Crystal::Var.new("params")
        end
      when "includes", "order"
        recv = receiver ? map_node(receiver) : Crystal::Var.new(singular)
        Crystal::Call.new(recv, method, args.map { |a| map_node(a) })
      else
        generic_call_node(call)
      end
    end

    # --- AST body builders ---

    private def build_body(node : Prism::Node, action_name : String) : Array(Crystal::ASTNode)
      case node
      when Prism::StatementsNode
        node.body.flat_map { |child| build_statement(child, action_name) }
      else
        build_statement(node, action_name)
      end
    end

    private def build_statement(node : Prism::Node, action_name : String) : Array(Crystal::ASTNode)
      case node
      when Prism::InstanceVariableWriteNode
        [Crystal::Assign.new(
          Crystal::Var.new(node.name.lchop("@")),
          map_node(node.value)
        ).as(Crystal::ASTNode)]
      when Prism::LocalVariableWriteNode
        [Crystal::Assign.new(
          Crystal::Var.new(node.name),
          map_node(node.value)
        ).as(Crystal::ASTNode)]
      when Prism::CallNode
        case node.name
        when "redirect_to" then build_redirect(node)
        when "respond_to"  then build_respond_to(node, action_name)
        when "render"      then build_render(node, action_name)
        else [map_call(node).as(Crystal::ASTNode)]
        end
      when Prism::IfNode
        [build_if(node, action_name).as(Crystal::ASTNode)]
      else
        [] of Crystal::ASTNode
      end
    end

    private def build_if(node : Prism::IfNode, action_name : String) : Crystal::If
      cond = map_node(node.condition)
      then_body = node.then_body ? Crystal::Expressions.new(build_body(node.then_body.not_nil!, action_name)) : Crystal::Nop.new
      else_body = if ec = node.else_clause
                    case ec
                    when Prism::ElseNode
                      ec.body ? Crystal::Expressions.new(build_body(ec.body.not_nil!, action_name)) : nil
                    else
                      Crystal::Expressions.new(build_body(ec, action_name))
                    end
                  else
                    nil
                  end
      Crystal::If.new(cond, then_body, else_body)
    end

    # --- Redirect ---

    private def build_redirect(node : Prism::CallNode) : Array(Crystal::ASTNode)
      args = node.arg_nodes
      return [] of Crystal::ASTNode if args.empty?

      stmts = [] of Crystal::ASTNode
      target = args[0]
      path_expr = case target
                  when Prism::InstanceVariableReadNode
                    name = target.name.lchop("@")
                    Crystal::Call.new(nil, "#{name}_path", [Crystal::Var.new(name)] of Crystal::ASTNode)
                  when Prism::CallNode
                    if target.receiver.nil? && target.arg_nodes.empty?
                      name = target.name
                      Crystal::Call.new(nil, name.ends_with?("_path") ? name : "#{name}_path")
                    else
                      map_node(target)
                    end
                  else
                    map_node(target)
                  end

      notice = extract_keyword_string(args, "notice")
      alert = extract_keyword_string(args, "alert")

      if notice
        stmts << build_flash_assign(notice: notice)
      elsif alert
        stmts << build_flash_assign(alert: alert)
      end

      stmts << Crystal::Assign.new(
        Crystal::Call.new(Crystal::Var.new("response"), "status_code"),
        Crystal::NumberLiteral.new("302")
      )
      stmts << Crystal::Call.new(
        Crystal::Call.new(Crystal::Var.new("response"), "headers"),
        "[]=",
        [Crystal::StringLiteral.new("Location"), path_expr] of Crystal::ASTNode
      )
      stmts
    end

    private def build_flash_assign(notice : String? = nil, alert : String? = nil) : Crystal::ASTNode
      Crystal::Call.new(
        Crystal::Call.new(nil, "FLASH_STORE"),
        "[]=",
        [
          Crystal::StringLiteral.new("default"),
          Crystal::NamedTupleLiteral.new([
            Crystal::NamedTupleLiteral::Entry.new("notice", notice ? Crystal::StringLiteral.new(notice) : Crystal::NilLiteral.new),
            Crystal::NamedTupleLiteral::Entry.new("alert", alert ? Crystal::StringLiteral.new(alert) : Crystal::NilLiteral.new),
          ]),
        ] of Crystal::ASTNode
      )
    end

    # --- Render ---

    private def build_render(node : Prism::CallNode, action_name : String) : Array(Crystal::ASTNode)
      args = node.arg_nodes
      stmts = [] of Crystal::ASTNode

      template = case args[0]?
                 when Prism::SymbolNode then args[0].as(Prism::SymbolNode).value
                 when Prism::StringNode then args[0].as(Prism::StringNode).value
                 else action_name
                 end

      status = extract_keyword_string(args, "status")
      if status == "unprocessable_entity"
        stmts << Crystal::Assign.new(
          Crystal::Call.new(Crystal::Var.new("response"), "status_code"),
          Crystal::NumberLiteral.new("422")
        )
      end

      title = template.capitalize + " " + CrystalEmitter.classify(CrystalEmitter.singularize(controller))
      stmts << build_layout_call(title, template)
      stmts
    end

    # --- Respond to ---

    private def build_respond_to(node : Prism::CallNode, action_name : String) : Array(Crystal::ASTNode)
      block = node.block
      return [] of Crystal::ASTNode unless block.is_a?(Prism::BlockNode)
      body = block.body
      return [] of Crystal::ASTNode unless body
      build_respond_to_body(body, action_name)
    end

    private def build_respond_to_body(node : Prism::Node, action_name : String) : Array(Crystal::ASTNode)
      case node
      when Prism::StatementsNode
        node.body.flat_map { |child| build_respond_to_body(child, action_name) }
      when Prism::CallNode
        if node.name == "html" && (html_block = node.block)
          if html_body = html_block.as?(Prism::BlockNode).try(&.body)
            return build_body(html_body, action_name)
          end
        end
        [] of Crystal::ASTNode
      when Prism::IfNode
        cond = map_node(node.condition)
        then_body = node.then_body ? Crystal::Expressions.new(build_respond_to_body(node.then_body.not_nil!, action_name)) : Crystal::Nop.new
        else_body = if ec = node.else_clause
                      case ec
                      when Prism::ElseNode
                        ec.body ? Crystal::Expressions.new(build_respond_to_body(ec.body.not_nil!, action_name)) : nil
                      else
                        Crystal::Expressions.new(build_respond_to_body(ec, action_name))
                      end
                    else
                      nil
                    end
        [Crystal::If.new(cond, then_body, else_body).as(Crystal::ASTNode)]
      else
        [] of Crystal::ASTNode
      end
    end

    # --- Shared helpers ---

    private def needs_id?(name : String) : Bool
      {"show", "edit", "update", "destroy"}.includes?(name)
    end

    private def needs_params?(name : String) : Bool
      {"create", "update"}.includes?(name)
    end

    private def extract_model_params_call : Crystal::Call
      Crystal::Call.new(nil, "extract_model_params", [
        Crystal::Var.new("params"), Crystal::StringLiteral.new(singular),
      ] of Crystal::ASTNode)
    end

    private def build_flash_consumption : Crystal::ASTNode
      delete_call = Crystal::Call.new(
        Crystal::Call.new(nil, "FLASH_STORE"), "delete",
        [Crystal::StringLiteral.new("default")] of Crystal::ASTNode
      )
      default_tuple = Crystal::NamedTupleLiteral.new([
        Crystal::NamedTupleLiteral::Entry.new("notice", Crystal::NilLiteral.new),
        Crystal::NamedTupleLiteral::Entry.new("alert", Crystal::NilLiteral.new),
      ])
      flash_assign = Crystal::Assign.new(
        Crystal::Var.new("flash"),
        Crystal::Or.new(delete_call, default_tuple)
      )
      notice_assign = Crystal::Assign.new(
        Crystal::Var.new("notice"),
        Crystal::Call.new(Crystal::Var.new("flash"), "[]", [Crystal::SymbolLiteral.new("notice")] of Crystal::ASTNode)
      )
      Crystal::Expressions.new([flash_assign, notice_assign] of Crystal::ASTNode)
    end

    private def build_view_render(action_name : String) : Crystal::ASTNode
      title = case action_name
              when "index" then CrystalEmitter.classify(controller)
              when "show"  then "#{singular}.title"
              when "new"   then "New #{CrystalEmitter.classify(singular)}"
              when "edit"  then "Edit #{CrystalEmitter.classify(singular)}"
              else action_name.capitalize
              end
      build_layout_call(title, action_name)
    end

    private def build_layout_call(title : String, template : String) : Crystal::ASTNode
      ecr_call = Crystal::Call.new(Crystal::Path.new("ECR"), "embed", [
        Crystal::StringLiteral.new("src/views/#{controller}/#{template}.ecr"),
        Crystal::Var.new("__str__"),
      ] of Crystal::ASTNode)

      string_build = Crystal::Call.new(Crystal::Path.new("String"), "build",
        block: Crystal::Block.new(
          args: [Crystal::Var.new("__str__")],
          body: ecr_call
        ))

      layout_call = Crystal::Call.new(nil, "layout",
        [Crystal::StringLiteral.new(title)] of Crystal::ASTNode,
        block: Crystal::Block.new(body: string_build))

      Crystal::Call.new(Crystal::Var.new("response"), "print", [layout_call] of Crystal::ASTNode)
    end
  end
end
