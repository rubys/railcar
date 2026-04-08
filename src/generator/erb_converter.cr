# Converts Rails ERB/ECR templates to Crystal ECR templates.
#
# Pipeline: ERB/ECR → ErbCompiler → source code → parse → transform → ECR output
#
# Accepts both .erb (parsed via PrismTranslator) and .ecr (parsed via Crystal parser).
# The ErbCompiler extracts code from <% %> tags identically for both formats.

require "compiler/crystal/syntax"
require "./erb_compiler"
require "./crystal_expr"
require "./crystal_emitter"
require "./source_parser"

module Ruby2CR
  class ERBConverter
    include CrystalExpr

    getter template_name : String
    getter controller : String

    def initialize(@template_name, @controller)
    end

    def self.convert(source : String, template_name : String, controller : String) : String
      new(template_name, controller).convert(source)
    end

    def self.convert_file(path : String, template_name : String, controller : String) : String
      new(template_name, controller).convert(File.read(path), path)
    end

    def convert(source : String, path : String = "") : String
      compiler = ErbCompiler.new(source)
      ruby_src = compiler.src

      # Parse via Crystal parser for .ecr, PrismTranslator for .erb
      filename = path.empty? ? "template.rb" : (path.ends_with?(".ecr") ? "template.cr" : "template.rb")
      ast = SourceParser.parse_source(ruby_src, filename)

      def_body = find_def_body(ast)
      return "" unless def_body

      io = IO::Memory.new
      emit_statements(def_body, io)
      io.to_s
    end

    # Override CrystalExpr for template-specific patterns
    def expr(node : Prism::Node) : String
      case node
      when Prism::ConstantReadNode
        node.name
      when Prism::LocalVariableOperatorWriteNode
        "#{node.name} #{node.operator}= #{expr(node.value)}"
      when Prism::GenericNode
        "/* unknown(#{node.type_id}) */"
      else
        super
      end
    end

    # Crystal AST expression — used for nodes from Crystal parser/translator
    # Strips @ from instance variables (templates use locals, not ivars)
    private def crystal_expr(node : Crystal::ASTNode) : String
      case node
      when Crystal::InstanceVar
        node.name.lchop("@")
      when Crystal::Call
        # Recursively handle receiver
        parts = [] of String
        if obj = node.obj
          parts << crystal_expr(obj) << "." << node.name
        else
          parts << node.name
        end
        unless node.args.empty?
          parts << "(" << node.args.map { |a| crystal_expr(a) }.join(", ") << ")"
        end
        if named = node.named_args
          unless named.empty?
            sep = node.args.empty? ? "(" : ", "
            parts << sep << named.map { |na| "#{na.name}: #{crystal_expr(na.value)}" }.join(", ")
            parts << ")" if node.args.empty?
          end
        end
        parts.join
      when Crystal::Path
        node.names.join("::")
      when Crystal::SymbolLiteral
        ":#{node.value}"
      when Crystal::StringLiteral
        node.value.inspect
      else
        node.to_s
      end
    end

    # String-level override delegates to AST-level map_call
    def convert_call(call : Prism::CallNode) : String
      map_call(call).to_s
    end

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

    # --- Statement emission (Crystal AST) ---

    private def emit_statements(node : Crystal::ASTNode, io : IO)
      case node
      when Crystal::Expressions
        node.expressions.each { |stmt| emit_statement(stmt, io) }
      else
        emit_statement(node, io)
      end
    end

    private def emit_statement(node : Crystal::ASTNode, io : IO)
      case node
      when Crystal::Assign
        target = node.target
        if target.is_a?(Crystal::Var) && target.name == "_buf"
          return # skip _buf initialization
        end
        io << "<% " << crystal_expr(node) << " %>\n"
      when Crystal::OpAssign
        target = node.target
        if target.is_a?(Crystal::Var) && target.name == "_buf" && node.op == "+"
          case val = node.value
          when Crystal::StringLiteral then io << val.value
          else io << "<%= " << crystal_expr(val) << " %>"
          end
        else
          io << "<% " << crystal_expr(node) << " %>\n"
        end
      when Crystal::Call
        return if node.name == "content_for" || node.name == "turbo_stream_from"
        obj = node.obj
        if obj.is_a?(Crystal::Var) && obj.name == "_buf"
          case node.name
          when "append=" then emit_buf_output(node, io)
          when "to_s"    then nil
          else io << "<% " << crystal_expr(node) << " %>\n"
          end
        else
          io << "<% " << crystal_expr(node) << " %>\n"
        end
      when Crystal::If
        emit_if(node, io)
      when Crystal::Expressions
        emit_statements(node, io)
      when Crystal::Nop
        # skip
      end
    end

    # --- Buffer output ---

    private def emit_buf_output(node : Crystal::Call, io : IO)
      args = node.args
      return if args.empty?
      expr_node = args[0]

      if expr_node.is_a?(Crystal::Call) && expr_node.block
        emit_block_expression(expr_node, expr_node.block.not_nil!, io)
        return
      end

      if block = node.block
        inner = unwrap_to_s(expr_node)
        if inner.is_a?(Crystal::Call)
          emit_block_expression(inner, block, io)
        end
        return
      end

      actual_expr = unwrap_to_s(expr_node)

      if actual_expr.is_a?(Crystal::Call)
        case actual_expr.name
        when "turbo_stream_from", "content_for" then return
        when "render"
          emit_render_call(actual_expr, io)
          return
        when "link_to"
          io << "<%= " << convert_crystal_link_to(actual_expr) << " %>"
          return
        when "button_to"
          io << "<%= " << convert_crystal_button_to(actual_expr) << " %>"
          return
        end
      end

      io << "<%= " << crystal_expr(actual_expr) << " %>"
    end

    private def unwrap_to_s(node : Crystal::ASTNode) : Crystal::ASTNode
      result = node
      # Unwrap .to_s
      if result.is_a?(Crystal::Call) && result.name == "to_s" && result.obj
        result = result.obj.not_nil!
      end
      # Unwrap single-expression Expressions (from parenthesized expressions)
      if result.is_a?(Crystal::Expressions) && result.expressions.size == 1
        result = result.expressions[0]
      end
      result
    end

    # --- Render calls ---

    private def emit_render_call(call : Crystal::Call, io : IO)
      args = call.args
      return if args.empty?

      case first_arg = args[0]
      when Crystal::InstanceVar
        collection = first_arg.name.lchop("@")
        singular = CrystalEmitter.singularize(collection)
        io << "<% " << collection << ".each do |" << singular << "| %>\n"
        io << "  <%= render_" << singular << "_partial(" << singular << ") %>\n"
        io << "<% end %>"
      when Crystal::Call
        obj = first_arg.obj
        method = first_arg.name
        if obj.nil?
          collection = method
          singular = CrystalEmitter.singularize(collection)
          io << "<% " << collection << ".each do |" << singular << "| %>\n"
          io << "  <%= render_" << singular << "_partial(" << singular << ") %>\n"
          io << "<% end %>"
        else
          parent = crystal_expr(obj)
          singular = CrystalEmitter.singularize(method)
          io << "<% " << parent << "." << method << ".each do |" << singular << "| %>\n"
          io << "  <%= render_" << singular << "_partial(" << singular << ") %>\n"
          io << "<% end %>"
        end
      when Crystal::StringLiteral
        partial_name = first_arg.value
        if named = call.named_args
          if !named.empty?
            io << "<%= render_" << partial_name << "_partial(" << crystal_expr(named[0].value) << ") %>"
            return
          end
        end
        io << "<%= render_" << partial_name << "_partial() %>"
      else
        io << "<%= render(" << crystal_expr(first_arg) << ") %>"
      end
    end

    # --- Block expressions (form_with) ---

    private def emit_block_expression(call : Crystal::Call, block : Crystal::Block, io : IO)
      model_var = nil
      parent_var = nil
      child_class = nil
      css_class = nil

      if named = call.named_args
        named.each do |na|
          case na.name
          when "model"
            val = na.value
            if val.is_a?(Crystal::ArrayLiteral) && val.elements.size == 2
              parent_var = crystal_expr(val.elements[0])
              elem1 = val.elements[1]
              if elem1.is_a?(Crystal::Call) && elem1.obj.is_a?(Crystal::Path)
                child_class = elem1.obj.as(Crystal::Path).names.last.downcase
              end
            else
              model_var = crystal_expr(val)
            end
          when "class"
            css_class = crystal_expr(na.value)
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

    private def emit_form_body(node : Crystal::ASTNode, io : IO, model_prefix : String)
      stmts = node.is_a?(Crystal::Expressions) ? node.expressions : return
      stmts.each do |stmt|
        case stmt
        when Crystal::Call
          if stmt.name == "+" && !stmt.args.empty?
            arg = stmt.args[0]
            io << arg.as(Crystal::StringLiteral).value if arg.is_a?(Crystal::StringLiteral)
          elsif stmt.name == "append=" && !stmt.args.empty?
            actual = unwrap_to_s(stmt.args[0])
            if actual.is_a?(Crystal::Call)
              emit_form_field(actual, io, model_prefix)
            else
              io << "<%= " << crystal_expr(actual) << " %>"
            end
          else
            io << "<% " << crystal_expr(stmt) << " %>\n"
          end
        when Crystal::If
          emit_if(stmt, io)
        else
          emit_statement(stmt, io)
        end
      end
    end

    private def emit_form_field(call : Crystal::Call, io : IO, model_prefix : String)
      method = call.name
      args = call.args
      named = call.named_args

      case method
      when "label"
        field = args[0]?.is_a?(Crystal::SymbolLiteral) ? args[0].as(Crystal::SymbolLiteral).value : return
        css = named.try(&.find { |n| n.name == "class" }).try(&.value.to_s.strip('"'))
        cls_attr = css ? %(, class: "#{css}") : ""
        io << "<%= label_tag(\"" << model_prefix << "[" << field << "]\", \"" << field.capitalize << "\"" << cls_attr << ") %>"
      when "text_field"
        field = args[0]?.is_a?(Crystal::SymbolLiteral) ? args[0].as(Crystal::SymbolLiteral).value : return
        css = named.try(&.find { |n| n.name == "class" }).try(&.value.to_s.strip('"'))
        cls_attr = css ? %(, class: "#{css}") : ""
        io << "<%= text_field_tag(\"" << model_prefix << "[" << field << "]\"" << cls_attr << ") %>"
      when "text_area", "textarea"
        field = args[0]?.is_a?(Crystal::SymbolLiteral) ? args[0].as(Crystal::SymbolLiteral).value : return
        css = named.try(&.find { |n| n.name == "class" }).try(&.value.to_s.strip('"'))
        rows = named.try(&.find { |n| n.name == "rows" }).try(&.value.to_s)
        cls_attr = css ? %(, class: "#{css}") : ""
        rows_attr = rows ? %(, rows: #{rows}) : ""
        io << "<%= text_area_tag(\"" << model_prefix << "[" << field << "]\"" << rows_attr << cls_attr << ") %>"
      when "submit"
        text = args[0]?.is_a?(Crystal::StringLiteral) ? args[0].as(Crystal::StringLiteral).value : nil
        css = named.try(&.find { |n| n.name == "class" }).try(&.value.to_s.strip('"'))
        text_arg = text ? %("#{text}") : %("Submit")
        cls_attr = css ? %(, class: "#{css}") : ""
        io << "<%= submit_tag(#{text_arg}#{cls_attr}) %>"
      else
        io << "<%= " << crystal_expr(call) << " %>"
      end
    end

    # --- Control flow ---

    private def emit_if(node : Crystal::If, io : IO)
      io << "<% if " << crystal_expr(node.cond) << " %>\n"
      emit_statements(node.then, io)
      if else_node = node.else
        unless else_node.is_a?(Crystal::Nop)
          io << "<% else %>\n"
          emit_statements(else_node, io)
        end
      end
      io << "<% end %>\n"
    end

    # --- Crystal AST helper conversions ---

    private def convert_crystal_link_to(call : Crystal::Call) : String
      args = call.args
      named = call.named_args
      return "link_to()" if args.size < 2

      text = crystal_expr(args[0])
      path = crystal_model_to_path(args[1])

      if css = named.try(&.find { |n| n.name == "class" })
        "link_to(#{text}, #{path}, class: #{crystal_expr(css.value)})"
      else
        "link_to(#{text}, #{path})"
      end
    end

    private def convert_crystal_button_to(call : Crystal::Call) : String
      args = call.args
      named = call.named_args
      return "button_to()" if args.size < 2

      text = crystal_expr(args[0])
      target = args[1]

      path = if target.is_a?(Crystal::ArrayLiteral) && target.elements.size == 2
               parent_expr = crystal_expr(target.elements[0])
               child_expr = crystal_expr(target.elements[1])
               "#{parent_expr.split(".").last}_#{child_expr.split(".").first}_path(#{parent_expr}, #{child_expr})"
             else
               crystal_model_to_path(target)
             end

      parts = [text, path]
      if named
        named.each do |na|
          case na.name
          when "method"
            parts << %(method: #{crystal_expr(na.value)})
          when "class"
            parts << %(class: #{crystal_expr(na.value)})
          when "form_class"
            parts << %(form_class: #{crystal_expr(na.value)})
          when "data"
            if na.value.is_a?(Crystal::HashLiteral)
              na.value.as(Crystal::HashLiteral).entries.each do |entry|
                key = entry.key
                val = entry.value
                if key.is_a?(Crystal::SymbolLiteral) && key.value == "turbo_confirm" && val.is_a?(Crystal::StringLiteral)
                  parts << %(data_turbo_confirm: "#{val.value}")
                end
              end
            end
          end
        end
      end

      "button_to(#{parts.join(", ")})"
    end

    private def crystal_model_to_path(node : Crystal::ASTNode) : String
      case node
      when Crystal::InstanceVar
        name = node.name.lchop("@")
        "#{name}_path(#{name})"
      when Crystal::Var
        name = node.name
        name.ends_with?("_path") ? name : "#{name}_path(#{name})"
      when Crystal::Call
        if node.obj.nil? && node.args.empty?
          name = node.name
          name.ends_with?("_path") ? name : "#{name}_path(#{name})"
        else
          crystal_expr(node)
        end
      else
        crystal_expr(node)
      end
    end

    # --- Legacy helper conversions (Prism nodes, used by CrystalExpr map_call) ---

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

    # --- AST navigation ---

    private def find_def_body(node : Crystal::ASTNode) : Crystal::ASTNode?
      case node
      when Crystal::Expressions
        node.expressions.each do |child|
          result = find_def_body(child)
          return result if result
        end
      when Crystal::Def
        return node.body
      end
      nil
    end
  end
end
