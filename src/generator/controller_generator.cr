# Generates Crystal controller methods from extracted Rails controller AST.
#
# Transforms Rails controller patterns to Crystal:
#   - @article = Article.find(params.expect(:id)) → article = Article.find(id)
#   - @article.save / @article.update(params) → article.save / article.update(hash)
#   - redirect_to @article → redirect(response, article_path(article))
#   - render :new → render template
#   - respond_to → HTML-only behavior
#   - params.expect(article: [:title, :body]) → extract from params hash

require "./crystal_expr"
require "./crystal_emitter"
require "./controller_extractor"

module Ruby2CR
  class ControllerGenerator
    include CrystalExpr

    # Actions that render a view template (vs redirect)
    RENDER_ACTIONS = {"index", "show", "new", "edit"}

    getter controller : String
    getter singular : String

    def initialize(@controller, @singular = CrystalEmitter.singularize(controller))
    end

    # Public class API delegates to instance
    def self.generate_action(action : ControllerAction, controller_name : String, render_view : Bool = false) : String
      new(controller_name).generate_action(action, render_view)
    end

    def generate_action(action : ControllerAction, render_view : Bool = false) : String
      io = IO::Memory.new

      io << "  def #{action.name}(response"
      io << ", id : Int64" if needs_id?(action.name)
      io << ", params : Hash(String, String)" if needs_params?(action.name)
      io << ")\n"

      # For view-rendering actions, consume flash
      if render_view && RENDER_ACTIONS.includes?(action.name)
        io << "    flash = FLASH_STORE.delete(\"default\") || {notice: nil, alert: nil}\n"
        io << "    notice = flash[:notice]\n"
      end

      if body = action.body
        emit_body(body, io, action.name, "    ")
      end

      # For view-rendering actions, add the template render
      if render_view && RENDER_ACTIONS.includes?(action.name)
        title = case action.name
                when "index" then CrystalEmitter.classify(controller)
                when "show"  then "#{singular}.title"
                when "new"   then "New #{CrystalEmitter.classify(singular)}"
                when "edit"  then "Edit #{CrystalEmitter.classify(singular)}"
                else action.name.capitalize
                end
        title_expr = action.name == "show" ? title : title.inspect
        io << "    response.print layout(#{title_expr}) {\n"
        io << "      String.build do |__str__|\n"
        io << "        ECR.embed(\"src/views/#{controller}/#{action.name}.ecr\", __str__)\n"
        io << "      end\n"
        io << "    }\n"
      end

      io << "  end\n"
      io.to_s
    end

    # Override CrystalExpr#convert_call for controller-specific patterns
    def convert_call(call : Prism::CallNode) : String
      receiver = call.receiver
      method = call.name
      args = call.arg_nodes

      case method
      when "find"
        recv = receiver ? expr(receiver) : singular
        arg = args.size == 1 ? expr(args[0]) : "id"
        arg = "id" if arg.includes?("params")
        "#{recv}.find(#{arg})"
      when "new"
        recv = receiver ? expr(receiver) : singular
        if args.empty?
          "#{recv}.new"
        elsif args[0].is_a?(Prism::CallNode) && args[0].as(Prism::CallNode).name.ends_with?("_params")
          "#{recv}.new(extract_model_params(params, \"#{singular}\"))"
        else
          "#{recv}.new(#{expr(args[0])})"
        end
      when "save", "save!"
        recv = receiver ? expr(receiver) : singular
        "#{recv}.save"
      when "update"
        recv = receiver ? expr(receiver) : singular
        if args.size == 1 && args[0].is_a?(Prism::CallNode) && args[0].as(Prism::CallNode).name.ends_with?("_params")
          "#{recv}.update(extract_model_params(params, \"#{singular}\"))"
        else
          "#{recv}.update(#{args.map { |a| expr(a) }.join(", ")})"
        end
      when "destroy", "destroy!"
        recv = receiver ? expr(receiver) : singular
        "#{recv}.destroy"
      when "build"
        recv = receiver ? expr(receiver) : "self"
        if args.size == 1 && args[0].is_a?(Prism::CallNode) && args[0].as(Prism::CallNode).name.ends_with?("_params")
          child_singular = CrystalEmitter.singularize(args[0].as(Prism::CallNode).name.rchop("_params"))
          "#{recv}.build(extract_model_params(params, \"#{child_singular}\"))"
        else
          "#{recv}.build(#{args.map { |a| expr(a) }.join(", ")})"
        end
      when "expect"
        if args.size == 1
          case args[0]
          when Prism::SymbolNode then args[0].as(Prism::SymbolNode).value
          else "params"
          end
        else
          "params"
        end
      when "includes", "order"
        recv = receiver ? expr(receiver) : singular
        "#{recv}.#{method}(#{args.map { |a| expr(a) }.join(", ")})"
      else
        generic_call(call)
      end
    end

    # --- Private helpers ---

    private def needs_id?(action_name : String) : Bool
      {"show", "edit", "update", "destroy"}.includes?(action_name)
    end

    private def needs_params?(action_name : String) : Bool
      {"create", "update"}.includes?(action_name)
    end

    private def emit_body(node : Prism::Node, io : IO, action_name : String, indent : String)
      case node
      when Prism::StatementsNode
        node.body.each { |child| emit_statement(child, io, action_name, indent) }
      else
        emit_statement(node, io, action_name, indent)
      end
    end

    private def emit_statement(node : Prism::Node, io : IO, action_name : String, indent : String)
      case node
      when Prism::InstanceVariableWriteNode
        io << indent << node.name.lchop("@") << " = " << expr(node.value) << "\n"
      when Prism::CallNode
        case node.name
        when "redirect_to" then emit_redirect(node, io, indent)
        when "respond_to"  then emit_respond_to(node, io, action_name, indent)
        when "render"      then emit_render(node, io, action_name, indent)
        else io << indent << expr(node) << "\n"
        end
      when Prism::IfNode
        io << indent << "if " << expr(node.condition) << "\n"
        emit_body(node.then_body.not_nil!, io, action_name, indent + "  ") if node.then_body
        if else_clause = node.else_clause
          io << indent << "else\n"
          case else_clause
          when Prism::ElseNode
            emit_body(else_clause.body.not_nil!, io, action_name, indent + "  ") if else_clause.body
          else
            emit_body(else_clause, io, action_name, indent + "  ")
          end
        end
        io << indent << "end\n"
      when Prism::LocalVariableWriteNode
        io << indent << node.name << " = " << expr(node.value) << "\n"
      end
    end

    private def emit_redirect(node : Prism::CallNode, io : IO, indent : String)
      args = node.arg_nodes
      return if args.empty?

      target = args[0]
      path = case target
             when Prism::InstanceVariableReadNode
               name = target.name.lchop("@")
               "#{name}_path(#{name})"
             when Prism::CallNode
               if target.receiver.nil? && target.arg_nodes.empty?
                 name = target.name
                 name.ends_with?("_path") ? name : "#{name}_path"
               else
                 expr(target)
               end
             else
               expr(target)
             end

      notice = extract_keyword_string(args, "notice")
      alert = extract_keyword_string(args, "alert")

      if notice
        io << indent << "FLASH_STORE[\"default\"] = {notice: \"" << notice << "\", alert: nil}\n"
      elsif alert
        io << indent << "FLASH_STORE[\"default\"] = {notice: nil, alert: \"" << alert << "\"}\n"
      end
      io << indent << "response.status_code = 302\n"
      io << indent << "response.headers[\"Location\"] = " << path << "\n"
    end

    private def emit_render(node : Prism::CallNode, io : IO, action_name : String, indent : String)
      args = node.arg_nodes
      template = case args[0]?
                 when Prism::SymbolNode then args[0].as(Prism::SymbolNode).value
                 when Prism::StringNode then args[0].as(Prism::StringNode).value
                 else action_name
                 end

      status = extract_keyword_string(args, "status")
      io << indent << "response.status_code = 422\n" if status == "unprocessable_entity"

      title = template.capitalize + " " + CrystalEmitter.classify(CrystalEmitter.singularize(controller))
      io << indent << "response.print layout(\"#{title}\") {\n"
      io << indent << "  String.build do |__str__|\n"
      io << indent << "    ECR.embed(\"src/views/#{controller}/#{template}.ecr\", __str__)\n"
      io << indent << "  end\n"
      io << indent << "}\n"
    end

    private def emit_respond_to(node : Prism::CallNode, io : IO, action_name : String, indent : String)
      block = node.block
      return unless block.is_a?(Prism::BlockNode)
      body = block.body
      return unless body
      emit_respond_to_body(body, io, action_name, indent)
    end

    private def emit_respond_to_body(node : Prism::Node, io : IO, action_name : String, indent : String)
      case node
      when Prism::StatementsNode
        node.body.each { |child| emit_respond_to_body(child, io, action_name, indent) }
      when Prism::CallNode
        if node.name == "html"
          if html_block = node.block
            if html_body = html_block.as?(Prism::BlockNode).try(&.body)
              emit_body(html_body, io, action_name, indent)
            end
          end
        end
      when Prism::IfNode
        io << indent << "if " << expr(node.condition) << "\n"
        emit_respond_to_body(node.then_body.not_nil!, io, action_name, indent + "  ") if node.then_body
        if else_clause = node.else_clause
          io << indent << "else\n"
          case else_clause
          when Prism::ElseNode
            emit_respond_to_body(else_clause.body.not_nil!, io, action_name, indent + "  ") if else_clause.body
          else
            emit_respond_to_body(else_clause, io, action_name, indent + "  ")
          end
        end
        io << indent << "end\n"
      end
    end
  end
end
