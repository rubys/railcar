# Converts Rails ERB templates to Crystal ECR templates.
#
# Pipeline: ERB → Ruby source (via ErbCompiler) → Prism AST → transform → ECR
#
# The AST transformation handles:
#   - @instance_variables → local variables (function parameters)
#   - link_to with model objects → link_to with path helpers
#   - button_to with model objects → button_to with path helpers
#   - render @collection → loop with partial calls
#   - render "partial", locals → partial helper call
#   - form_with model: ... → explicit <form> with field helpers
#   - turbo_stream_from → stripped
#   - form.label/text_field/text_area/submit → tag helpers

require "./erb_compiler"
require "./crystal_emitter"
require "../prism/bindings"
require "../prism/deserializer"

module Ruby2CR
  class ERBConverter
    # Convert an ERB template to ECR
    def self.convert(erb_source : String, template_name : String, controller : String) : String
      # Step 1: ERB → Ruby source
      compiler = ErbCompiler.new(erb_source)
      ruby_src = compiler.src

      # Step 2: Parse the Ruby with Prism
      ast = Prism.parse(ruby_src)

      # Step 3: Walk the AST and reconstruct as ECR
      ecr = reconstruct_ecr(ast, template_name, controller)
      ecr
    end

    def self.convert_file(path : String, template_name : String, controller : String) : String
      convert(File.read(path), template_name, controller)
    end

    # Walk the parsed render method and emit ECR
    private def self.reconstruct_ecr(ast : Prism::ProgramNode, template_name : String, controller : String) : String
      io = IO::Memory.new

      # The AST is: ProgramNode → StatementsNode → DefNode (render)
      # The DefNode body is: StatementsNode with _buf assignments and control flow
      stmts = ast.statements
      return "" unless stmts.is_a?(Prism::StatementsNode)

      # Find the def node (may be wrapped in generic nodes)
      def_body = find_def_body(stmts)
      return "" unless def_body

      emit_statements(def_body, io, template_name, controller)
      io.to_s
    end

    # Find the body of the render method
    private def self.find_def_body(node : Prism::Node) : Prism::Node?
      # DefNode is type 45, handled as GenericNode
      # Its children include the body (3rd optional_node)
      case node
      when Prism::StatementsNode
        node.body.each do |child|
          result = find_def_body(child)
          return result if result
        end
      when Prism::GenericNode
        if node.type_id == 45 # DefNode
          # DefNode children captured by skip_unknown_node_fields:
          # receiver(opt), parameters(opt), body(opt) — body is what we want
          # The children array has all nodes found during field traversal
          node.child_nodes.each do |child|
            if child.is_a?(Prism::StatementsNode)
              return child
            end
            result = find_def_body(child)
            return result if result
          end
        end
      end
      nil
    end

    # Emit statements as ECR
    private def self.emit_statements(node : Prism::Node, io : IO, template_name : String, controller : String)
      stmts = case node
              when Prism::StatementsNode then node.body
              else [node]
              end

      stmts.each do |stmt|
        emit_statement(stmt, io, template_name, controller)
      end
    end

    private def self.emit_statement(node : Prism::Node, io : IO, template_name : String, controller : String)
      case node
      when Prism::LocalVariableWriteNode
        # _buf = ::String.new — skip initialization
        return if node.name == "_buf"
        # Other local assignments — emit as code
        io << "<% " << expr_to_crystal(node, controller) << " %>\n"
      when Prism::LocalVariableOperatorWriteNode
        if node.name == "_buf" && node.operator == "+"
          # _buf += "literal" — emit the literal HTML or expression
          case val = node.value
          when Prism::StringNode
            io << val.value
          else
            io << "<%= " << expr_to_crystal(val, controller) << " %>"
          end
        else
          io << "<% " << expr_to_crystal(node, controller) << " %>\n"
        end
      when Prism::CallNode
        receiver = node.receiver
        if receiver.is_a?(Prism::LocalVariableReadNode) && receiver.name == "_buf"
          case node.name
          when "append="
            # _buf.append= ( expr ).to_s — output expression
            emit_buf_output(node, io, template_name, controller)
          when "to_s"
            # _buf.to_s — skip (return value)
          else
            io << "<% " << expr_to_crystal(node, controller) << " %>\n"
          end
        else
          # Other calls — emit as code block
          io << "<% " << expr_to_crystal(node, controller) << " %>\n"
        end
      when Prism::GenericNode
        case node.type_id
        when 67 # IfNode
          emit_if(node, io, template_name, controller)
        else
          node.child_nodes.each do |child|
            emit_statement(child, io, template_name, controller)
          end
        end
      when Prism::StatementsNode
        emit_statements(node, io, template_name, controller)
      else
        # Skip unknown
      end
    end

    # _buf += "literal string"
    private def self.emit_buf_append(node : Prism::CallNode, io : IO, template_name : String, controller : String)
      args = node.arg_nodes
      return if args.empty?
      arg = args[0]

      case arg
      when Prism::StringNode
        # Literal HTML — emit directly, unescaping the Ruby string escapes
        io << arg.value
      else
        # Expression — wrap in <%= %>
        io << "<%= " << expr_to_crystal(arg, controller) << " %>"
      end
    end

    # _buf.append= ( expr ).to_s — output expression
    private def self.emit_buf_output(node : Prism::CallNode, io : IO, template_name : String, controller : String)
      args = node.arg_nodes
      return if args.empty?
      expr_node = args[0]

      # The argument might be a CallNode with a block (form_with ... do |form|)
      if expr_node.is_a?(Prism::CallNode) && expr_node.block
        block = expr_node.block.as(Prism::BlockNode)
        emit_block_expression(expr_node, block, io, template_name, controller)
        return
      end

      # Also check the append= node itself for a block
      if block = node.block
        inner = unwrap_to_s_and_parens(expr_node)
        if inner.is_a?(Prism::CallNode)
          emit_block_expression(inner, block.as(Prism::BlockNode), io, template_name, controller)
        end
        return
      end

      # Unwrap ( expr ).to_s → expr
      actual_expr = unwrap_to_s_and_parens(expr_node)

      # Check for special helpers
      if actual_expr.is_a?(Prism::CallNode)
        case actual_expr.name
        when "turbo_stream_from"
          return # Skip turbo streams for now
        when "render"
          emit_render_call(actual_expr, io, template_name, controller)
          return
        when "content_for"
          return # Skip content_for
        end
      end

      io << "<%= " << expr_to_crystal(actual_expr, controller) << " %>"
    end

    # Unwrap ( expr ).to_s → expr, including parentheses
    private def self.unwrap_to_s_and_parens(node : Prism::Node) : Prism::Node
      result = node
      # Unwrap .to_s
      if result.is_a?(Prism::CallNode) && result.name == "to_s" && result.receiver
        result = result.receiver.not_nil!
      end
      # Unwrap parentheses
      if result.is_a?(Prism::ParenthesesNode) && result.body
        result = result.body.not_nil!
        # ParenthesesNode body may be a StatementsNode with one child
        if result.is_a?(Prism::StatementsNode) && result.body.size == 1
          result = result.body[0]
        end
      end
      result
    end

    # Emit a render call
    private def self.emit_render_call(call : Prism::CallNode, io : IO, template_name : String, controller : String)
      args = call.arg_nodes
      return if args.empty?

      first_arg = args[0]

      case first_arg
      when Prism::InstanceVariableReadNode
        # render @articles
        collection = first_arg.name.lchop("@")
        singular = CrystalEmitter.singularize(collection)
        io << "<% " << collection << ".each do |" << singular << "| %>\n"
        io << "  <%= render_" << singular << "_partial(" << partial_args(singular, template_name) << ") %>\n"
        io << "<% end %>"
      when Prism::CallNode
        # render @article.comments or render articles
        receiver = first_arg.receiver
        method = first_arg.name

        if receiver.nil?
          # Bare name: render articles
          collection = method
          singular = CrystalEmitter.singularize(collection)
          io << "<% " << collection << ".each do |" << singular << "| %>\n"
          io << "  <%= render_" << singular << "_partial(" << partial_args(singular, template_name) << ") %>\n"
          io << "<% end %>"
        else
          # Method call: render article.comments
          parent = expr_to_crystal(receiver, controller)
          assoc = method
          singular = CrystalEmitter.singularize(assoc)
          io << "<% " << parent << "." << assoc << ".each do |" << singular << "| %>\n"
          io << "  <%= render_" << singular << "_partial(" << partial_args(singular, template_name) << ") %>\n"
          io << "<% end %>"
        end
      when Prism::StringNode
        # render "form", article: @article
        partial_name = first_arg.value
        # Find the locals in kwargs
        if args.size > 1
          kwargs = args[1]
          if kwargs.is_a?(Prism::KeywordHashNode) && !kwargs.elements.empty?
            assoc = kwargs.elements[0]
            if assoc.is_a?(Prism::AssocNode)
              var_expr = expr_to_crystal(assoc.value_node, controller)
              io << "<%= render_" << partial_name << "_partial(" << var_expr << ") %>"
              return
            end
          end
        end
        io << "<%= render_" << partial_name << "_partial() %>"
      else
        io << "<%= render(" << expr_to_crystal(first_arg, controller) << ") %>"
      end
    end

    # Emit a block expression (form_with)
    private def self.emit_block_expression(call : Prism::CallNode, block : Prism::BlockNode, io : IO, template_name : String, controller : String)
      # For now, only handle form_with
      # Extract model info from arguments
      args = call.arg_nodes

      model_var = nil
      parent_var = nil
      child_class = nil
      css_class = nil

      args.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)
        arg.elements.each do |el|
          next unless el.is_a?(Prism::AssocNode)
          key = el.key
          next unless key.is_a?(Prism::SymbolNode)
          case key.value
          when "model"
            val = el.value_node
            if val.is_a?(Prism::ArrayNode) && val.elements.size == 2
              # model: [@article, Comment.new] — nested
              parent_var = expr_to_crystal(val.elements[0], controller)
              if val.elements[1].is_a?(Prism::CallNode)
                child_call = val.elements[1].as(Prism::CallNode)
                if child_call.receiver.is_a?(Prism::ConstantReadNode)
                  child_class = child_call.receiver.as(Prism::ConstantReadNode).name.downcase
                end
              end
            else
              model_var = expr_to_crystal(val, controller)
            end
          when "class"
            css_class = expr_to_crystal(el.value_node, controller)
          end
        end
      end

      css_attr = css_class ? %( class="#{css_class}") : ""

      if parent_var && child_class
        # Nested form: form_with model: [@article, Comment.new]
        plural = CrystalEmitter.pluralize(child_class)
        io << "<form action=\"<%= #{parent_var}_#{plural}_path(#{parent_var}) %>\" method=\"post\"#{css_attr}>\n"
      elsif model_var
        # Single model form
        plural = CrystalEmitter.pluralize(model_var)
        io << "<% _action = #{model_var}.persisted? ? #{model_var}_path(#{model_var}) : #{plural}_path %>\n"
        io << "<% _method = #{model_var}.persisted? ? \"patch\" : \"post\" %>\n"
        io << "<form action=\"<%= _action %>\" method=\"post\"#{css_attr}>\n"
        io << "  <% if _method != \"post\" %>\n"
        io << "    <input type=\"hidden\" name=\"_method\" value=\"<%= _method %>\">\n"
        io << "  <% end %>\n"
      else
        io << "<form method=\"post\"#{css_attr}>\n"
      end

      # Process form body
      if body = block.body
        emit_form_body(body, io, model_var || child_class || "item", controller)
      end

      io << "</form>"
    end

    # Process form body — convert form.field calls to helpers
    private def self.emit_form_body(node : Prism::Node, io : IO, model_prefix : String, controller : String)
      stmts = case node
              when Prism::StatementsNode then node.body
              else return
              end

      stmts.each do |stmt|
        case stmt
        when Prism::CallNode
          if stmt.name == "+" || stmt.name == "append="
            # Buffer operations inside the form
            if stmt.name == "+"
              arg = stmt.arg_nodes[0]?
              if arg.is_a?(Prism::StringNode)
                io << arg.value
              end
            elsif stmt.name == "append="
              actual = stmt.arg_nodes[0]?
              actual = unwrap_to_s_and_parens(actual) if actual
              if actual.is_a?(Prism::CallNode)
                emit_form_field(actual, io, model_prefix, controller)
              elsif actual
                io << "<%= " << expr_to_crystal(actual, controller) << " %>"
              end
            end
          else
            io << "<% " << expr_to_crystal(stmt, controller) << " %>\n"
          end
        when Prism::GenericNode
          if stmt.type_id == 67 # IfNode
            emit_if(stmt, io, "", controller)
          else
            stmt.child_nodes.each do |child|
              emit_form_body(child, io, model_prefix, controller)
            end
          end
        else
          emit_statement(stmt, io, "", controller)
        end
      end
    end

    # Convert form.field calls
    private def self.emit_form_field(call : Prism::CallNode, io : IO, model_prefix : String, controller : String)
      receiver = call.receiver
      # Check if receiver is the form variable (local var)
      method = call.name
      args = call.arg_nodes

      case method
      when "label"
        field = extract_symbol(args[0]?)
        return unless field
        css = extract_keyword_string(args, "class")
        cls_attr = css ? %(, class: "#{css}") : ""
        io << "<%= label_tag(\"" << model_prefix << "[" << field << "]\", \"" << field.capitalize << "\"" << cls_attr << ") %>"
      when "text_field"
        field = extract_symbol(args[0]?)
        return unless field
        css = extract_keyword_string(args, "class")
        cls_attr = css ? %(, class: "#{css}") : ""
        io << "<%= text_field_tag(\"" << model_prefix << "[" << field << "]\", " << model_prefix << "." << field << cls_attr << ") %>"
      when "text_area", "textarea"
        field = extract_symbol(args[0]?)
        return unless field
        css = extract_keyword_string(args, "class")
        rows = extract_keyword_string(args, "rows")
        cls_attr = css ? %(, class: "#{css}") : ""
        rows_attr = rows ? %(, rows: #{rows}) : ""
        io << "<%= text_area_tag(\"" << model_prefix << "[" << field << "]\", " << model_prefix << "." << field << rows_attr << cls_attr << ") %>"
      when "submit"
        text = case args[0]?
               when Prism::StringNode then args[0].as(Prism::StringNode).value
               else nil
               end
        css = extract_keyword_string(args, "class")
        text_arg = text ? %("#{text}") : %("Submit")
        cls_attr = css ? %(, class: "#{css}") : ""
        io << "<%= submit_tag(#{text_arg}#{cls_attr}) %>"
      else
        # Unknown form method — emit as expression
        io << "<%= " << expr_to_crystal(call, controller) << " %>"
      end
    end

    # Emit an if/else block
    private def self.emit_if(node : Prism::GenericNode, io : IO, template_name : String, controller : String)
      children = node.child_nodes
      # IfNode children: condition, then_body, else_node (optional)
      return if children.empty?

      condition = children[0]?
      then_body = children.size > 1 ? children[1]? : nil
      else_node = children.size > 2 ? children[2]? : nil

      io << "<% if " << expr_to_crystal(condition.not_nil!, controller) << " %>\n" if condition
      emit_statements(then_body.not_nil!, io, template_name, controller) if then_body

      if else_node
        # ElseNode (type 47) has children: the body
        if else_node.is_a?(Prism::GenericNode) && else_node.type_id == 47
          io << "<% else %>\n"
          else_node.child_nodes.each do |child|
            emit_statements(child, io, template_name, controller)
          end
        end
      end

      io << "<% end %>\n"
    end

    # Convert a Prism AST node to a Crystal expression string
    private def self.expr_to_crystal(node : Prism::Node, controller : String) : String
      case node
      when Prism::CallNode
        convert_call(node, controller)
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
        node.name
      when Prism::ArrayNode
        "[#{node.elements.map { |e| expr_to_crystal(e, controller) }.join(", ")}]"
      when Prism::InstanceVariableReadNode
        # @article → article (strip @ prefix)
        node.name.lchop("@")
      when Prism::LocalVariableReadNode
        node.name
      when Prism::LocalVariableOperatorWriteNode
        "#{node.name} #{node.operator}= #{expr_to_crystal(node.value, controller)}"
      when Prism::LocalVariableWriteNode
        "#{node.name} = #{expr_to_crystal(node.value, controller)}"
      when Prism::ParenthesesNode
        if body = node.body
          "(#{expr_to_crystal(body, controller)})"
        else
          "()"
        end
      when Prism::GenericNode
        "/* unknown(#{node.type_id}) */"
      else
        "/* #{node.class} */"
      end
    end

    # Convert a method call, handling Rails helper transformations
    private def self.convert_call(call : Prism::CallNode, controller : String) : String
      receiver = call.receiver
      method = call.name
      args = call.arg_nodes

      case method
      when "link_to"
        convert_link_to(args, controller)
      when "button_to"
        convert_button_to(args, controller)
      when "pluralize"
        arg_strs = args.map { |a| expr_to_crystal(a, controller) }
        "pluralize(#{arg_strs.join(", ")})"
      when "truncate"
        convert_truncate(args, controller)
      when "dom_id"
        arg_strs = args.map { |a| expr_to_crystal(a, controller) }
        "dom_id(#{arg_strs.join(", ")})"
      when "size", "count", "title", "body", "commenter", "id",
           "persisted?", "empty?", "any?", "comments", "errors",
           "each", "new"
        # Method calls on objects — pass through
        if receiver
          recv_str = expr_to_crystal(receiver, controller)
          if args.empty?
            "#{recv_str}.#{method}"
          else
            arg_strs = args.map { |a| expr_to_crystal(a, controller) }
            "#{recv_str}.#{method}(#{arg_strs.join(", ")})"
          end
        else
          # Bare method call — likely a local variable access
          method
        end
      else
        # Generic method call
        if receiver
          recv_str = expr_to_crystal(receiver, controller)
          if args.empty?
            "#{recv_str}.#{method}"
          else
            arg_strs = args.map { |a| expr_to_crystal(a, controller) }
            "#{recv_str}.#{method}(#{arg_strs.join(", ")})"
          end
        else
          if args.empty?
            method
          else
            arg_strs = args.map { |a| expr_to_crystal(a, controller) }
            "#{method}(#{arg_strs.join(", ")})"
          end
        end
      end
    end

    private def self.convert_link_to(args : Array(Prism::Node), controller : String) : String
      return "link_to()" if args.size < 2

      text_expr = expr_to_crystal(args[0], controller)
      target = args[1]

      # Determine if target is a model variable or already a path
      path_expr = model_to_path(target, controller)

      # Extract class option from remaining args
      css = extract_keyword_string(args[2..]? || [] of Prism::Node, "class")
      if css
        "link_to(#{text_expr}, #{path_expr}, class: \"#{css}\")"
      else
        "link_to(#{text_expr}, #{path_expr})"
      end
    end

    private def self.convert_button_to(args : Array(Prism::Node), controller : String) : String
      return "button_to()" if args.size < 2

      text_expr = expr_to_crystal(args[0], controller)
      target = args[1]

      path_expr = model_to_path(target, controller)

      parts = [text_expr, path_expr]

      # Extract keyword options
      kwargs = args[2..]? || [] of Prism::Node
      method = extract_keyword_string(kwargs, "method") || extract_keyword_symbol(kwargs, "method")
      parts << %(method: "#{method}") if method
      css = extract_keyword_string(kwargs, "class")
      parts << %(class: "#{css}") if css
      form_class = extract_keyword_string(kwargs, "form_class")
      parts << %(form_class: "#{form_class}") if form_class

      # Extract data: { turbo_confirm: "..." }
      kwargs.each do |kwarg|
        next unless kwarg.is_a?(Prism::KeywordHashNode)
        kwarg.elements.each do |el|
          next unless el.is_a?(Prism::AssocNode)
          key = el.key
          next unless key.is_a?(Prism::SymbolNode) && key.value == "data"
          data_hash = el.value_node
          if data_hash.is_a?(Prism::HashNode)
            data_hash.elements.each do |de|
              next unless de.is_a?(Prism::AssocNode)
              dk = de.key
              next unless dk.is_a?(Prism::SymbolNode)
              dv = de.value_node
              if dk.value == "turbo_confirm" && dv.is_a?(Prism::StringNode)
                parts << %(data_turbo_confirm: "#{dv.value}")
              end
            end
          end
        end
      end

      "button_to(#{parts.join(", ")})"
    end

    private def self.convert_truncate(args : Array(Prism::Node), controller : String) : String
      parts = [expr_to_crystal(args[0], controller)]
      length = extract_keyword_string(args[1..]? || [] of Prism::Node, "length")
      parts << "length: #{length}" if length
      "truncate(#{parts.join(", ")})"
    end

    # Convert a model reference to a path helper call
    private def self.model_to_path(node : Prism::Node, controller : String) : String
      case node
      when Prism::InstanceVariableReadNode
        name = node.name.lchop("@")
        "#{name}_path(#{name})"
      when Prism::LocalVariableReadNode
        name = node.name
        if name.ends_with?("_path")
          name
        else
          "#{name}_path(#{name})"
        end
      when Prism::CallNode
        if node.receiver.nil? && node.arg_nodes.empty?
          name = node.name
          if name.ends_with?("_path")
            name
          else
            "#{name}_path(#{name})"
          end
        else
          expr_to_crystal(node, controller)
        end
      else
        expr_to_crystal(node, controller)
      end
    end

    # Helper: extract symbol value
    private def self.extract_symbol(node : Prism::Node?) : String?
      node.is_a?(Prism::SymbolNode) ? node.value : nil
    end

    # Helper: extract keyword string value from args
    private def self.extract_keyword_string(args : Array(Prism::Node), key : String) : String?
      args.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)
        arg.elements.each do |el|
          next unless el.is_a?(Prism::AssocNode)
          k = el.key
          next unless k.is_a?(Prism::SymbolNode) && k.value == key
          case v = el.value_node
          when Prism::StringNode  then return v.value
          when Prism::IntegerNode then return v.value.to_s
          end
        end
      end
      nil
    end

    # Helper: extract keyword symbol value from args
    private def self.extract_keyword_symbol(args : Array(Prism::Node), key : String) : String?
      args.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)
        arg.elements.each do |el|
          next unless el.is_a?(Prism::AssocNode)
          k = el.key
          next unless k.is_a?(Prism::SymbolNode) && k.value == key
          v = el.value_node
          return v.as(Prism::SymbolNode).value if v.is_a?(Prism::SymbolNode)
        end
      end
      nil
    end

    # Determine partial args based on singular name and context
    private def self.partial_args(singular : String, template_name : String) : String
      if singular == "comment"
        "article, comment"
      else
        singular
      end
    end
  end
end
