# Generates Crystal controller methods from extracted Rails controller AST.
#
# Transforms Rails controller patterns to Crystal:
#   - @article = Article.find(params.expect(:id)) → article = Article.find(id)
#   - @article.save / @article.update(params) → article.save / article.update(hash)
#   - redirect_to @article → redirect(response, article_path(article))
#   - render :new → render template
#   - respond_to → HTML-only behavior
#   - params.expect(article: [:title, :body]) → extract from params hash

require "./controller_extractor"
require "./crystal_emitter"

module Ruby2CR
  class ControllerGenerator
    # Actions that render a view template (vs redirect)
    RENDER_ACTIONS = {"index", "show", "new", "edit"}

    # Generate Crystal method source for a controller action
    def self.generate_action(action : ControllerAction, controller_name : String, render_view : Bool = false) : String
      io = IO::Memory.new
      singular = CrystalEmitter.singularize(controller_name)

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
        emit_body(body, io, controller_name, singular, action.name, "    ")
      end

      # For view-rendering actions, add the template render
      if render_view && RENDER_ACTIONS.includes?(action.name)
        title = case action.name
                when "index" then CrystalEmitter.classify(controller_name)
                when "show"  then "#{singular}.title"
                when "new"   then "New #{CrystalEmitter.classify(singular)}"
                when "edit"  then "Edit #{CrystalEmitter.classify(singular)}"
                else action.name.capitalize
                end
        title_expr = action.name == "show" ? title : title.inspect
        io << "    response.print layout(#{title_expr}) {\n"
        io << "      String.build do |__str__|\n"
        io << "        ECR.embed(\"src/views/#{controller_name}/#{action.name}.ecr\", __str__)\n"
        io << "      end\n"
        io << "    }\n"
      end

      io << "  end\n"
      io.to_s
    end

    # Generate a private helper method
    def self.generate_private_method(action : ControllerAction, controller_name : String) : String?
      return nil unless action.body
      singular = CrystalEmitter.singularize(controller_name)

      case action.name
      when /^set_/
        # before_action setter — we inline these, don't generate separate methods
        nil
      when /_params$/
        # Strong params — we handle these inline
        nil
      else
        nil
      end
    end

    private def self.needs_id?(action_name : String) : Bool
      {"show", "edit", "update", "destroy"}.includes?(action_name)
    end

    private def self.needs_params?(action_name : String) : Bool
      {"create", "update"}.includes?(action_name)
    end

    private def self.emit_body(node : Prism::Node, io : IO, controller : String, singular : String, action_name : String, indent : String)
      case node
      when Prism::StatementsNode
        node.body.each do |child|
          emit_statement(child, io, controller, singular, action_name, indent)
        end
      else
        emit_statement(node, io, controller, singular, action_name, indent)
      end
    end

    private def self.emit_statement(node : Prism::Node, io : IO, controller : String, singular : String, action_name : String, indent : String)
      case node
      when Prism::InstanceVariableWriteNode
        var = node.name.lchop("@")
        value_str = expr_to_crystal(node.value, controller, singular)
        io << indent << var << " = " << value_str << "\n"

      when Prism::CallNode
        case node.name
        when "redirect_to"
          emit_redirect(node, io, controller, singular, indent)
        when "respond_to"
          emit_respond_to(node, io, controller, singular, action_name, indent)
        when "render"
          emit_render(node, io, controller, singular, action_name, indent)
        else
          io << indent << expr_to_crystal(node, controller, singular) << "\n"
        end

      when Prism::IfNode
        io << indent << "if " << expr_to_crystal(node.condition, controller, singular) << "\n"
        emit_body(node.then_body.not_nil!, io, controller, singular, action_name, indent + "  ") if node.then_body
        if else_clause = node.else_clause
          io << indent << "else\n"
          case else_clause
          when Prism::ElseNode
            emit_body(else_clause.body.not_nil!, io, controller, singular, action_name, indent + "  ") if else_clause.body
          else
            emit_body(else_clause, io, controller, singular, action_name, indent + "  ")
          end
        end
        io << indent << "end\n"

      when Prism::LocalVariableWriteNode
        var = node.name
        value_str = expr_to_crystal(node.value, controller, singular)
        io << indent << var << " = " << value_str << "\n"

      else
        # Skip unknown statements
      end
    end

    private def self.emit_redirect(node : Prism::CallNode, io : IO, controller : String, singular : String, indent : String)
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
                 expr_to_crystal(target, controller, singular)
               end
             else
               expr_to_crystal(target, controller, singular)
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

    private def self.emit_render(node : Prism::CallNode, io : IO, controller : String, singular : String, action_name : String, indent : String)
      args = node.arg_nodes
      # render :new → render the "new" template
      # render :edit → render the "edit" template
      template = case args[0]?
                 when Prism::SymbolNode then args[0].as(Prism::SymbolNode).value
                 when Prism::StringNode then args[0].as(Prism::StringNode).value
                 else action_name
                 end

      # Check for status: :unprocessable_entity
      status = extract_keyword_string(args, "status")
      if status == "unprocessable_entity"
        io << indent << "response.status_code = 422\n"
      end

      # Capitalize for title
      title = template.capitalize + " " + CrystalEmitter.classify(CrystalEmitter.singularize(controller))
      io << indent << "response.print layout(\"#{title}\") {\n"
      io << indent << "  String.build do |__str__|\n"
      io << indent << "    ECR.embed(\"src/views/#{controller}/#{template}.ecr\", __str__)\n"
      io << indent << "  end\n"
      io << indent << "}\n"
    end

    private def self.emit_respond_to(node : Prism::CallNode, io : IO, controller : String, singular : String, action_name : String, indent : String)
      block = node.block
      return unless block.is_a?(Prism::BlockNode)
      body = block.body
      return unless body

      # Walk the respond_to block body, extracting HTML-only behavior
      emit_respond_to_body(body, io, controller, singular, action_name, indent)
    end

    private def self.emit_respond_to_body(node : Prism::Node, io : IO, controller : String, singular : String, action_name : String, indent : String)
      case node
      when Prism::StatementsNode
        node.body.each do |child|
          emit_respond_to_body(child, io, controller, singular, action_name, indent)
        end
      when Prism::CallNode
        if node.name == "html"
          # format.html { ... } — extract the block body
          if html_block = node.block
            if html_body = html_block.as?(Prism::BlockNode).try(&.body)
              emit_body(html_body, io, controller, singular, action_name, indent)
            end
          end
        end
      when Prism::IfNode
        io << indent << "if " << expr_to_crystal(node.condition, controller, singular) << "\n"
        emit_respond_to_body(node.then_body.not_nil!, io, controller, singular, action_name, indent + "  ") if node.then_body
        if else_clause = node.else_clause
          io << indent << "else\n"
          case else_clause
          when Prism::ElseNode
            emit_respond_to_body(else_clause.body.not_nil!, io, controller, singular, action_name, indent + "  ") if else_clause.body
          else
            emit_respond_to_body(else_clause, io, controller, singular, action_name, indent + "  ")
          end
        end
        io << indent << "end\n"
      end
    end

    # Convert a Prism node to a Crystal expression
    private def self.expr_to_crystal(node : Prism::Node, controller : String, singular : String) : String
      case node
      when Prism::CallNode
        convert_call(node, controller, singular)
      when Prism::InstanceVariableReadNode
        node.name.lchop("@")
      when Prism::InstanceVariableWriteNode
        "#{node.name.lchop("@")} = #{expr_to_crystal(node.value, controller, singular)}"
      when Prism::LocalVariableReadNode
        node.name
      when Prism::StringNode
        node.value.inspect
      when Prism::SymbolNode
        ":#{node.value}"
      when Prism::IntegerNode
        node.value.to_s
      when Prism::TrueNode
        "true"
      when Prism::FalseNode
        "false"
      when Prism::NilNode
        "nil"
      when Prism::ConstantReadNode
        "Ruby2CR::#{node.name}"
      when Prism::ArrayNode
        "[#{node.elements.map { |e| expr_to_crystal(e, controller, singular) }.join(", ")}]"
      when Prism::HashNode, Prism::KeywordHashNode
        elements = case node
                   when Prism::HashNode then node.elements
                   when Prism::KeywordHashNode then node.elements
                   else [] of Prism::Node
                   end
        pairs = elements.map do |el|
          if el.is_a?(Prism::AssocNode)
            key = el.key
            val = el.value_node
            if key.is_a?(Prism::SymbolNode)
              "#{key.value}: #{expr_to_crystal(val, controller, singular)}"
            else
              "#{expr_to_crystal(key, controller, singular)} => #{expr_to_crystal(val, controller, singular)}"
            end
          else
            ""
          end
        end
        pairs.join(", ")
      when Prism::ParenthesesNode
        if body = node.body
          expr_to_crystal(body, controller, singular)
        else
          ""
        end
      else
        "nil /* #{node.class} */"
      end
    end

    private def self.convert_call(call : Prism::CallNode, controller : String, singular : String) : String
      receiver = call.receiver
      method = call.name
      args = call.arg_nodes

      case method
      when "find"
        recv = receiver ? expr_to_crystal(receiver, controller, singular) : singular
        if args.size == 1
          arg = expr_to_crystal(args[0], controller, singular)
          # params.expect(:id) → id
          if arg.includes?("params")
            "#{recv}.find(id)"
          else
            "#{recv}.find(#{arg})"
          end
        else
          "#{recv}.find(id)"
        end
      when "new"
        recv = receiver ? expr_to_crystal(receiver, controller, singular) : singular
        if args.empty?
          "#{recv}.new"
        else
          arg = args[0]
          # Article.new(article_params) → Article.new(hash)
          if arg.is_a?(Prism::CallNode) && arg.name.ends_with?("_params")
            "#{recv}.new(extract_model_params(params, \"#{singular}\"))"
          else
            "#{recv}.new(#{expr_to_crystal(arg, controller, singular)})"
          end
        end
      when "save", "save!"
        recv = receiver ? expr_to_crystal(receiver, controller, singular) : singular
        "#{recv}.save"
      when "update"
        recv = receiver ? expr_to_crystal(receiver, controller, singular) : singular
        if args.size == 1 && args[0].is_a?(Prism::CallNode)
          arg_call = args[0].as(Prism::CallNode)
          if arg_call.name.ends_with?("_params")
            "#{recv}.update(extract_model_params(params, \"#{singular}\"))"
          else
            "#{recv}.update(#{expr_to_crystal(args[0], controller, singular)})"
          end
        else
          arg_strs = args.map { |a| expr_to_crystal(a, controller, singular) }
          "#{recv}.update(#{arg_strs.join(", ")})"
        end
      when "destroy", "destroy!"
        recv = receiver ? expr_to_crystal(receiver, controller, singular) : singular
        "#{recv}.destroy"
      when "build"
        recv = receiver ? expr_to_crystal(receiver, controller, singular) : "self"
        if args.size == 1 && args[0].is_a?(Prism::CallNode)
          arg_call = args[0].as(Prism::CallNode)
          if arg_call.name.ends_with?("_params")
            child_singular = CrystalEmitter.singularize(arg_call.name.rchop("_params"))
            "#{recv}.build(extract_model_params(params, \"#{child_singular}\"))"
          else
            "#{recv}.build(#{expr_to_crystal(args[0], controller, singular)})"
          end
        else
          arg_strs = args.map { |a| expr_to_crystal(a, controller, singular) }
          "#{recv}.build(#{arg_strs.join(", ")})"
        end
      when "expect"
        # params.expect(:id) → id, params.expect(article: [...]) → params
        if args.size == 1
          case arg = args[0]
          when Prism::SymbolNode
            arg.value
          when Prism::KeywordHashNode
            "params"
          else
            "params"
          end
        else
          "params"
        end
      when "includes"
        recv = receiver ? expr_to_crystal(receiver, controller, singular) : singular
        arg_strs = args.map { |a| expr_to_crystal(a, controller, singular) }
        "#{recv}.includes(#{arg_strs.join(", ")})"
      when "order"
        recv = receiver ? expr_to_crystal(receiver, controller, singular) : singular
        arg_strs = args.map { |a| expr_to_crystal(a, controller, singular) }
        "#{recv}.order(#{arg_strs.join(", ")})"
      when "comments"
        recv = receiver ? expr_to_crystal(receiver, controller, singular) : singular
        "#{recv}.comments"
      else
        # Generic method call
        if receiver
          recv = expr_to_crystal(receiver, controller, singular)
          if args.empty?
            "#{recv}.#{method}"
          else
            arg_strs = args.map { |a| expr_to_crystal(a, controller, singular) }
            "#{recv}.#{method}(#{arg_strs.join(", ")})"
          end
        else
          if args.empty?
            method
          else
            arg_strs = args.map { |a| expr_to_crystal(a, controller, singular) }
            "#{method}(#{arg_strs.join(", ")})"
          end
        end
      end
    end

    private def self.extract_keyword_string(args : Array(Prism::Node), key : String) : String?
      args.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)
        arg.elements.each do |el|
          next unless el.is_a?(Prism::AssocNode)
          k = el.key
          next unless k.is_a?(Prism::SymbolNode) && k.value == key
          v = el.value_node
          return v.as(Prism::StringNode).value if v.is_a?(Prism::StringNode)
          return v.as(Prism::SymbolNode).value if v.is_a?(Prism::SymbolNode)
        end
      end
      nil
    end
  end
end
