# Converts Rails ERB templates to Crystal ECR templates.
#
# Pipeline: ERB → Ruby source (via ErbCompiler) → Prism AST → transform → ECR

require "./erb_compiler"
require "./crystal_expr"
require "./crystal_emitter"

module Ruby2CR
  class ERBConverter
    include CrystalExpr

    getter template_name : String
    getter controller : String

    def initialize(@template_name, @controller)
    end

    # Public class API delegates to instance
    def self.convert(erb_source : String, template_name : String, controller : String) : String
      new(template_name, controller).convert(erb_source)
    end

    def self.convert_file(path : String, template_name : String, controller : String) : String
      new(template_name, controller).convert(File.read(path))
    end

    def convert(erb_source : String) : String
      compiler = ErbCompiler.new(erb_source)
      ast = Prism.parse(compiler.src)
      stmts = ast.statements
      return "" unless stmts.is_a?(Prism::StatementsNode)
      def_body = find_def_body(stmts)
      return "" unless def_body

      io = IO::Memory.new
      emit_statements(def_body, io)
      io.to_s
    end

    # Override CrystalExpr for ERB-specific patterns
    def expr(node : Prism::Node) : String
      case node
      when Prism::ConstantReadNode
        node.name # No Ruby2CR:: prefix in templates
      when Prism::LocalVariableOperatorWriteNode
        "#{node.name} #{node.operator}= #{expr(node.value)}"
      when Prism::GenericNode
        "/* unknown(#{node.type_id}) */"
      else
        super
      end
    end

    # String-level override delegates to AST-level map_call
    def convert_call(call : Prism::CallNode) : String
      map_call(call).to_s
    end

    # Override CrystalExpr#map_call for view helper transformations
    def map_call(call : Prism::CallNode) : Crystal::ASTNode
      receiver = call.receiver
      method = call.name
      args = call.arg_nodes

      case method
      when "link_to"
        Crystal::MacroLiteral.new(convert_link_to(args))
      when "button_to"
        Crystal::MacroLiteral.new(convert_button_to(args))
      when "pluralize"
        Crystal::Call.new(nil, "pluralize", args.map { |a| map_node(a) })
      when "truncate"
        Crystal::MacroLiteral.new(convert_truncate(args))
      when "dom_id"
        crystal_args = args.map do |a|
          a.is_a?(Prism::SymbolNode) ? Crystal::StringLiteral.new(a.value).as(Crystal::ASTNode) : map_node(a)
        end
        Crystal::Call.new(nil, "dom_id", crystal_args)
      when "present?"
        receiver ? map_node(receiver) : Crystal::Call.new(nil, method)
      when "count"
        if receiver && args.empty?
          Crystal::Call.new(map_node(receiver), "size")
        elsif receiver
          Crystal::Call.new(map_node(receiver), "count", args.map { |a| map_node(a) })
        else
          Crystal::Call.new(nil, "count")
        end
      else
        generic_call_node(call)
      end
    end

    # --- Statement emission ---

    private def emit_statements(node : Prism::Node, io : IO)
      stmts = node.is_a?(Prism::StatementsNode) ? node.body : [node]
      stmts.each { |stmt| emit_statement(stmt, io) }
    end

    private def emit_statement(node : Prism::Node, io : IO)
      case node
      when Prism::LocalVariableWriteNode
        return if node.name == "_buf"
        io << "<% " << expr(node) << " %>\n"
      when Prism::LocalVariableOperatorWriteNode
        if node.name == "_buf" && node.operator == "+"
          case val = node.value
          when Prism::StringNode then io << val.value
          else io << "<%= " << expr(val) << " %>"
          end
        else
          io << "<% " << expr(node) << " %>\n"
        end
      when Prism::CallNode
        return if node.name == "content_for" || node.name == "turbo_stream_from"
        receiver = node.receiver
        if receiver.is_a?(Prism::LocalVariableReadNode) && receiver.name == "_buf"
          case node.name
          when "append=" then emit_buf_output(node, io)
          when "to_s"    then nil # skip
          else io << "<% " << expr(node) << " %>\n"
          end
        else
          io << "<% " << expr(node) << " %>\n"
        end
      when Prism::IfNode
        emit_if(node, io)
      when Prism::GenericNode
        node.child_nodes.each { |child| emit_statement(child, io) }
      when Prism::StatementsNode
        emit_statements(node, io)
      end
    end

    # --- Buffer output ---

    private def emit_buf_output(node : Prism::CallNode, io : IO)
      args = node.arg_nodes
      return if args.empty?
      expr_node = args[0]

      if expr_node.is_a?(Prism::CallNode) && expr_node.block
        emit_block_expression(expr_node, expr_node.block.as(Prism::BlockNode), io)
        return
      end

      if block = node.block
        inner = unwrap_to_s_and_parens(expr_node)
        if inner.is_a?(Prism::CallNode)
          emit_block_expression(inner, block.as(Prism::BlockNode), io)
        end
        return
      end

      actual_expr = unwrap_to_s_and_parens(expr_node)

      if actual_expr.is_a?(Prism::CallNode)
        case actual_expr.name
        when "turbo_stream_from", "content_for" then return
        when "render"
          emit_render_call(actual_expr, io)
          return
        end
      end

      io << "<%= " << expr(actual_expr) << " %>"
    end

    private def unwrap_to_s_and_parens(node : Prism::Node) : Prism::Node
      result = node
      if result.is_a?(Prism::CallNode) && result.name == "to_s" && result.receiver
        result = result.receiver.not_nil!
      end
      if result.is_a?(Prism::ParenthesesNode) && result.body
        result = result.body.not_nil!
        if result.is_a?(Prism::StatementsNode) && result.body.size == 1
          result = result.body[0]
        end
      end
      result
    end

    # --- Render calls ---

    private def emit_render_call(call : Prism::CallNode, io : IO)
      args = call.arg_nodes
      return if args.empty?

      case first_arg = args[0]
      when Prism::InstanceVariableReadNode
        collection = first_arg.name.lchop("@")
        singular = CrystalEmitter.singularize(collection)
        io << "<% " << collection << ".each do |" << singular << "| %>\n"
        io << "  <%= render_" << singular << "_partial(" << singular << ") %>\n"
        io << "<% end %>"
      when Prism::CallNode
        receiver = first_arg.receiver
        method = first_arg.name
        if receiver.nil?
          collection = method
          singular = CrystalEmitter.singularize(collection)
          io << "<% " << collection << ".each do |" << singular << "| %>\n"
          io << "  <%= render_" << singular << "_partial(" << singular << ") %>\n"
          io << "<% end %>"
        else
          parent = expr(receiver)
          singular = CrystalEmitter.singularize(method)
          io << "<% " << parent << "." << method << ".each do |" << singular << "| %>\n"
          io << "  <%= render_" << singular << "_partial(" << singular << ") %>\n"
          io << "<% end %>"
        end
      when Prism::StringNode
        partial_name = first_arg.value
        if args.size > 1
          kwargs = args[1]
          if kwargs.is_a?(Prism::KeywordHashNode) && !kwargs.elements.empty?
            assoc = kwargs.elements[0]
            if assoc.is_a?(Prism::AssocNode)
              io << "<%= render_" << partial_name << "_partial(" << expr(assoc.value_node) << ") %>"
              return
            end
          end
        end
        io << "<%= render_" << partial_name << "_partial() %>"
      else
        io << "<%= render(" << expr(first_arg) << ") %>"
      end
    end

    # --- Block expressions (form_with) ---

    private def emit_block_expression(call : Prism::CallNode, block : Prism::BlockNode, io : IO)
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
              parent_var = expr(val.elements[0])
              if val.elements[1].is_a?(Prism::CallNode)
                child_call = val.elements[1].as(Prism::CallNode)
                if child_call.receiver.is_a?(Prism::ConstantReadNode)
                  child_class = child_call.receiver.as(Prism::ConstantReadNode).name.downcase
                end
              end
            else
              model_var = expr(val)
            end
          when "class"
            css_class = expr(el.value_node)
          end
        end
      end

      css_attr = css_class ? %( class="#{css_class}") : ""

      if parent_var && child_class
        plural = CrystalEmitter.pluralize(child_class)
        io << "<form action=\"<%= #{parent_var}_#{plural}_path(#{parent_var}) %>\" method=\"post\"#{css_attr}>\n"
      elsif model_var
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

      if body = block.body
        emit_form_body(body, io, model_var || child_class || "item")
      end
      io << "</form>"
    end

    # --- Form body ---

    private def emit_form_body(node : Prism::Node, io : IO, model_prefix : String)
      stmts = node.is_a?(Prism::StatementsNode) ? node.body : return
      stmts.each do |stmt|
        case stmt
        when Prism::CallNode
          if stmt.name == "+"
            arg = stmt.arg_nodes[0]?
            io << arg.as(Prism::StringNode).value if arg.is_a?(Prism::StringNode)
          elsif stmt.name == "append="
            actual = stmt.arg_nodes[0]?
            actual = unwrap_to_s_and_parens(actual) if actual
            if actual.is_a?(Prism::CallNode)
              emit_form_field(actual, io, model_prefix)
            elsif actual
              io << "<%= " << expr(actual) << " %>"
            end
          else
            io << "<% " << expr(stmt) << " %>\n"
          end
        when Prism::IfNode
          emit_if(stmt, io)
        when Prism::GenericNode
          stmt.child_nodes.each { |child| emit_form_body(child, io, model_prefix) }
        else
          emit_statement(stmt, io)
        end
      end
    end

    private def emit_form_field(call : Prism::CallNode, io : IO, model_prefix : String)
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
        io << "<%= text_field_tag(\"" << model_prefix << "[" << field << "]\"" << cls_attr << ") %>"
      when "text_area", "textarea"
        field = extract_symbol(args[0]?)
        return unless field
        css = extract_keyword_string(args, "class")
        rows = extract_keyword_string(args, "rows")
        cls_attr = css ? %(, class: "#{css}") : ""
        rows_attr = rows ? %(, rows: #{rows}) : ""
        io << "<%= text_area_tag(\"" << model_prefix << "[" << field << "]\"" << rows_attr << cls_attr << ") %>"
      when "submit"
        text = args[0]?.is_a?(Prism::StringNode) ? args[0].as(Prism::StringNode).value : nil
        css = extract_keyword_string(args, "class")
        text_arg = text ? %("#{text}") : %("Submit")
        cls_attr = css ? %(, class: "#{css}") : ""
        io << "<%= submit_tag(#{text_arg}#{cls_attr}) %>"
      else
        io << "<%= " << expr(call) << " %>"
      end
    end

    # --- Control flow ---

    private def emit_if(node : Prism::Node, io : IO)
      case node
      when Prism::IfNode
        io << "<% if " << expr(node.condition) << " %>\n"
        emit_statements(node.then_body.not_nil!, io) if node.then_body
        if else_clause = node.else_clause
          io << "<% else %>\n"
          case else_clause
          when Prism::ElseNode
            emit_statements(else_clause.body.not_nil!, io) if else_clause.body
          else
            emit_statements(else_clause, io)
          end
        end
        io << "<% end %>\n"
      when Prism::GenericNode
        children = node.child_nodes
        return if children.empty?
        io << "<% if " << expr(children[0]) << " %>\n"
        emit_statements(children[1], io) if children.size > 1
        if children.size > 2
          io << "<% else %>\n"
          children[2].children.each { |c| emit_statements(c, io) }
        end
        io << "<% end %>\n"
      end
    end

    # --- Helper conversions ---

    private def convert_link_to(args : Array(Prism::Node)) : String
      return "link_to()" if args.size < 2
      text_expr = expr(args[0])
      path_expr = model_to_path(args[1])
      css = extract_keyword_string(args[2..]? || [] of Prism::Node, "class")
      css ? "link_to(#{text_expr}, #{path_expr}, class: \"#{css}\")" : "link_to(#{text_expr}, #{path_expr})"
    end

    private def convert_button_to(args : Array(Prism::Node)) : String
      return "button_to()" if args.size < 2
      text_expr = expr(args[0])
      target = args[1]

      path_expr = if target.is_a?(Prism::ArrayNode) && target.elements.size == 2
                    parent_expr = expr(target.elements[0])
                    child_expr = expr(target.elements[1])
                    parent_name = parent_expr.split(".").last
                    child_name = child_expr.split(".").first
                    "#{parent_name}_#{child_name}_path(#{parent_expr}, #{child_expr})"
                  else
                    model_to_path(target)
                  end

      parts = [text_expr, path_expr]
      kwargs = args[2..]? || [] of Prism::Node
      method_val = extract_keyword_string(kwargs, "method") || extract_keyword_symbol(kwargs, "method")
      parts << %(method: "#{method_val}") if method_val
      css = extract_keyword_string(kwargs, "class")
      parts << %(class: "#{css}") if css
      form_class = extract_keyword_string(kwargs, "form_class")
      parts << %(form_class: "#{form_class}") if form_class

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
              dv = de.value_node
              if dk.is_a?(Prism::SymbolNode) && dk.value == "turbo_confirm" && dv.is_a?(Prism::StringNode)
                parts << %(data_turbo_confirm: "#{dv.value}")
              end
            end
          end
        end
      end

      "button_to(#{parts.join(", ")})"
    end

    private def convert_truncate(args : Array(Prism::Node)) : String
      parts = [expr(args[0])]
      length = extract_keyword_string(args[1..]? || [] of Prism::Node, "length")
      parts << "length: #{length}" if length
      "truncate(#{parts.join(", ")})"
    end

    private def model_to_path(node : Prism::Node) : String
      case node
      when Prism::InstanceVariableReadNode
        name = node.name.lchop("@")
        "#{name}_path(#{name})"
      when Prism::LocalVariableReadNode
        name = node.name
        name.ends_with?("_path") ? name : "#{name}_path(#{name})"
      when Prism::CallNode
        if node.receiver.nil? && node.arg_nodes.empty?
          name = node.name
          name.ends_with?("_path") ? name : "#{name}_path(#{name})"
        else
          expr(node)
        end
      else
        expr(node)
      end
    end

    private def extract_symbol(node : Prism::Node?) : String?
      node.is_a?(Prism::SymbolNode) ? node.value : nil
    end

    private def extract_keyword_symbol(args : Array(Prism::Node), key : String) : String?
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

    private def find_def_body(node : Prism::Node) : Prism::Node?
      case node
      when Prism::StatementsNode
        node.body.each do |child|
          result = find_def_body(child)
          return result if result
        end
      when Prism::DefNode
        return node.body
      when Prism::GenericNode
        node.child_nodes.each do |child|
          result = find_def_body(child)
          return result if result
        end
      end
      nil
    end
  end
end
