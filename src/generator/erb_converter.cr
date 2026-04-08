# Converts Rails ERB/ECR templates to Crystal ECR templates.
#
# Pipeline: ERB/ECR → ErbCompiler → source code → parse → filters → emit ECR
#
# View helper transformations (link_to, button_to, render, turbo_stream)
# are handled by filters applied before this converter runs. The converter
# is purely structural: it walks the _buf-based AST and emits <% %> tags.

require "compiler/crystal/syntax"
require "./erb_compiler"
require "./crystal_emitter"
require "./source_parser"

module Ruby2CR
  class ERBConverter
    getter template_name : String
    getter controller : String

    def initialize(@template_name, @controller)
    end

    def self.convert(source : String, template_name : String, controller : String,
                      view_filters : Array(Crystal::Transformer) = [] of Crystal::Transformer) : String
      new(template_name, controller).convert(source, view_filters: view_filters)
    end

    def self.convert_file(path : String, template_name : String, controller : String,
                          view_filters : Array(Crystal::Transformer) = [] of Crystal::Transformer) : String
      new(template_name, controller).convert(File.read(path), path, view_filters)
    end

    def convert(source : String, path : String = "",
                view_filters : Array(Crystal::Transformer) = [] of Crystal::Transformer) : String
      compiler = ErbCompiler.new(source)
      ruby_src = compiler.src

      # Parse via Crystal parser for .ecr, PrismTranslator for .erb
      filename = path.empty? ? "template.rb" : (path.ends_with?(".ecr") ? "template.cr" : "template.rb")
      ast = SourceParser.parse_source(ruby_src, filename)

      def_body = find_def_body(ast)
      return "" unless def_body

      # Apply view filters to the template AST
      filtered = def_body
      view_filters.each { |f| filtered = filtered.transform(f) }

      io = IO::Memory.new
      emit_statements(filtered, io)
      io.to_s
    end

    # --- Statement emission ---

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
        return if target.is_a?(Crystal::Var) && target.name == "_buf"
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
      # If the expression has a block (e.g., from RenderToPartial filter),
      # emit as a code block with nested output
      if actual_expr.is_a?(Crystal::Call) && actual_expr.block
        emit_call_with_block(actual_expr, io)
      else
        io << "<%= " << crystal_expr(actual_expr) << " %>"
      end
    end

    private def unwrap_to_s(node : Crystal::ASTNode) : Crystal::ASTNode
      result = node
      if result.is_a?(Crystal::Call) && result.name == "to_s" && result.obj
        result = result.obj.not_nil!
      end
      if result.is_a?(Crystal::Expressions) && result.expressions.size == 1
        result = result.expressions[0]
      end
      result
    end

    # --- Call with block (e.g., collection.each from RenderToPartial) ---

    private def emit_call_with_block(call : Crystal::Call, io : IO)
      block = call.block.not_nil!
      block_args = block.args.map(&.name).join(", ")

      # <% collection.each do |item| %>
      io << "<% " << crystal_expr_no_block(call) << " do"
      io << " |" << block_args << "|" unless block_args.empty?
      io << " %>\n"

      # Block body — each statement as ECR
      if body = block.body
        case body
        when Crystal::Expressions
          body.expressions.each { |stmt| io << "  <%= " << crystal_expr(stmt) << " %>\n" }
        else
          io << "  <%= " << crystal_expr(body) << " %>\n"
        end
      end

      io << "<% end %>"
    end

    # Serialize a call without its block (for the do...end wrapper)
    private def crystal_expr_no_block(call : Crystal::Call) : String
      parts = [] of String
      if obj = call.obj
        parts << crystal_expr(obj) << "." << call.name
      else
        parts << call.name
      end
      unless call.args.empty?
        parts << "(" << call.args.map { |a| crystal_expr(a) }.join(", ") << ")"
      end
      parts.join
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
        css = extract_named_arg(named, "class")
        cls_attr = css ? %(, class: "#{css}") : ""
        io << "<%= label_tag(\"" << model_prefix << "[" << field << "]\", \"" << field.capitalize << "\"" << cls_attr << ") %>"
      when "text_field"
        field = args[0]?.is_a?(Crystal::SymbolLiteral) ? args[0].as(Crystal::SymbolLiteral).value : return
        css = extract_named_arg(named, "class")
        cls_attr = css ? %(, class: "#{css}") : ""
        io << "<%= text_field_tag(\"" << model_prefix << "[" << field << "]\"" << cls_attr << ") %>"
      when "text_area", "textarea"
        field = args[0]?.is_a?(Crystal::SymbolLiteral) ? args[0].as(Crystal::SymbolLiteral).value : return
        css = extract_named_arg(named, "class")
        rows = extract_named_arg(named, "rows")
        cls_attr = css ? %(, class: "#{css}") : ""
        rows_attr = rows ? %(, rows: #{rows}) : ""
        io << "<%= text_area_tag(\"" << model_prefix << "[" << field << "]\"" << rows_attr << cls_attr << ") %>"
      when "submit"
        text = args[0]?.is_a?(Crystal::StringLiteral) ? args[0].as(Crystal::StringLiteral).value : nil
        css = extract_named_arg(named, "class")
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

    # --- Crystal AST to string ---

    private def crystal_expr(node : Crystal::ASTNode) : String
      case node
      when Crystal::InstanceVar
        node.name.lchop("@")
      when Crystal::Call
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

    # --- Helpers ---

    private def extract_named_arg(named : Array(Crystal::NamedArgument)?, key : String) : String?
      named.try(&.find { |n| n.name == key }).try { |n|
        case v = n.value
        when Crystal::StringLiteral then v.value
        when Crystal::NumberLiteral then v.value
        else v.to_s
        end
      }
    end

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
