# Converts Rails ERB/ECR templates to Crystal ECR templates.
#
# Pipeline: ERB/ECR → ErbCompiler → source code → parse → filters → emit ECR
#
# View helper transformations (link_to, button_to, render, turbo_stream,
# present?, count, dom_id) are handled by filters applied before this
# converter runs. The converter is purely structural: it walks the
# _buf-based AST and emits <% %> tags, using Crystal's built-in to_s
# for expression serialization.

require "compiler/crystal/syntax"
require "./erb_compiler"
require "./crystal_emitter"
require "./source_parser"

module Railcar
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

      filename = path.empty? ? "template.rb" : (path.ends_with?(".ecr") ? "template.cr" : "template.rb")
      ast = SourceParser.parse_source(ruby_src, filename)

      def_body = find_def_body(ast)
      return "" unless def_body

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
        io << "<% " << node.to_s << " %>\n"
      when Crystal::OpAssign
        target = node.target
        if target.is_a?(Crystal::Var) && target.name == "_buf" && node.op == "+"
          case val = node.value
          when Crystal::StringLiteral then io << val.value
          else io << "<%= " << val.to_s << " %>"
          end
        else
          io << "<% " << node.to_s << " %>\n"
        end
      when Crystal::Call
        obj = node.obj
        if obj.is_a?(Crystal::Var) && obj.name == "_buf"
          case node.name
          when "append=" then emit_buf_output(node, io)
          when "to_s"    then nil
          else io << "<% " << node.to_s << " %>\n"
          end
        elsif node.block
          # Call with block (e.g., errors.each do |error| ... end)
          emit_call_with_block(node, io)
        else
          io << "<% " << node.to_s << " %>\n"
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
      if actual_expr.is_a?(Crystal::Call) && actual_expr.block
        emit_call_with_block(actual_expr, io)
      else
        io << "<%= " << actual_expr.to_s << " %>"
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
      io << "<% " << call_without_block(call) << " do"
      io << " |" << block_args << "|" unless block_args.empty?
      io << " %>\n"

      # Block body — buffer ops go through emit_statements,
      # other calls (like render_partial) are output expressions
      if body = block.body
        emit_block_body(body, io)
      end

      io << "<% end %>"
    end

    private def emit_block_body(node : Crystal::ASTNode, io : IO)
      case node
      when Crystal::Expressions
        node.expressions.each { |stmt| emit_block_body(stmt, io) }
      when Crystal::OpAssign, Crystal::Assign
        # Buffer operations — decompose as template
        emit_statement(node, io)
      when Crystal::Call
        obj = node.obj
        if obj.is_a?(Crystal::Var) && obj.name == "_buf"
          emit_statement(node, io)
        else
          # Non-buffer calls in block body are output expressions
          io << "<%= " << node.to_s << " %>\n"
        end
      when Crystal::If
        emit_if(node, io)
      else
        emit_statement(node, io)
      end
    end

    # Serialize a call without its block
    private def call_without_block(call : Crystal::Call) : String
      # Build a copy without the block and use to_s
      blockless = Crystal::Call.new(call.obj, call.name, call.args,
        named_args: call.named_args)
      blockless.to_s
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
              parent_var = val.elements[0].to_s
              elem1 = val.elements[1]
              if elem1.is_a?(Crystal::Call) && elem1.obj.is_a?(Crystal::Path)
                child_class = elem1.obj.as(Crystal::Path).names.last.downcase
              end
            else
              model_var = val.to_s
            end
          when "class"
            css_class = na.value.is_a?(Crystal::StringLiteral) ? na.value.as(Crystal::StringLiteral).value : na.value.to_s
          end
        end
      end

      css_attr = css_class ? %( class="#{css_class}") : ""

      if parent_var && child_class
        plural = CrystalEmitter.pluralize(child_class)
        io << "<form#{css_attr} action=\"<%= #{parent_var}_#{plural}_path(#{parent_var}) %>\" accept-charset=\"UTF-8\" method=\"post\">\n"
      elsif model_var
        plural = CrystalEmitter.pluralize(model_var)
        io << "<% _action = #{model_var}.persisted? ? #{model_var}_path(#{model_var}) : #{plural}_path %>\n"
        io << "<% _method = #{model_var}.persisted? ? \"patch\" : \"post\" %>\n"
        io << "<form#{css_attr} action=\"<%= _action %>\" accept-charset=\"UTF-8\" method=\"post\">\n"
        io << "  <% if _method != \"post\" %>\n"
        io << "    <input type=\"hidden\" name=\"_method\" value=\"<%= _method %>\">\n"
        io << "  <% end %>\n"
      else
        io << "<form method=\"post\"#{css_attr}>\n"
      end

      if body = block.body
        form_model = model_var || child_class || "item"
        # For nested new forms (Comment.new), initialize the variable
        if child_class && !model_var
          model_class = CrystalEmitter.classify(child_class)
          io << "<% #{child_class} = Railcar::#{model_class}.new %>\n"
        end
        emit_form_body(body, io, form_model)
      end

      io << "</form>"
    end

    # --- Form body ---

    private def emit_form_body(node : Crystal::ASTNode, io : IO)
      emit_form_body(node, io, "item")
    end

    private def emit_form_body(node : Crystal::ASTNode, io : IO, model_prefix : String)
      case node
      when Crystal::Expressions
        node.expressions.each { |stmt| emit_form_body(stmt, io, model_prefix) }
      when Crystal::OpAssign
        target = node.target
        if target.is_a?(Crystal::Var) && target.name == "_buf" && node.op == "+"
          case val = node.value
          when Crystal::StringLiteral then io << val.value
          end
        end
      when Crystal::Call
        obj = node.obj
        if obj.is_a?(Crystal::Var) && obj.name == "_buf"
          if node.name == "append="
            actual = node.args[0]?
            actual = unwrap_to_s(actual) if actual
            if actual.is_a?(Crystal::Call)
              emit_form_field(actual, io, model_prefix)
            elsif actual
              io << "<%= " << actual.to_s << " %>"
            end
          end
        elsif node.block
          # Call with block inside form (e.g., errors.each do |error|)
          emit_call_with_block(node, io)
        else
          io << "<% " << node.to_s << " %>\n"
        end
      when Crystal::If
        emit_if(node, io)
      when Crystal::Nop
        # skip
      end
    end

    private def emit_form_field(call : Crystal::Call, io : IO, model_prefix : String)
      receiver = call.obj
      method = call.name

      # Rails form field id: "article_title" (model_field)
      field_id = nil

      case method
      when "label"
        field = extract_symbol_arg(call)
        return unless field
        field_id = "#{model_prefix}_#{field}"
        css = extract_named_string(call, "class")
        cls_attr = css ? %(, class: "#{css}") : ""
        io << "<%= label_tag(\"#{field_id}\", \"#{field.capitalize}\"#{cls_attr}) %>"
      when "text_field"
        field = extract_symbol_arg(call)
        return unless field
        field_id = "#{model_prefix}_#{field}"
        css = extract_named_string(call, "class")
        cls_attr = css ? %(, class: "#{css}") : ""
        io << "<%= text_field_tag(\"#{model_prefix}[#{field}]\", #{model_prefix}.#{field}, id: \"#{field_id}\"#{cls_attr}) %>"
      when "text_area", "textarea"
        field = extract_symbol_arg(call)
        return unless field
        field_id = "#{model_prefix}_#{field}"
        css = extract_named_string(call, "class")
        rows = extract_named_string(call, "rows")
        cls_attr = css ? %(, class: "#{css}") : ""
        rows_attr = rows ? %(, rows: #{rows}) : ""
        io << "<%= text_area_tag(\"#{model_prefix}[#{field}]\", #{model_prefix}.#{field}, id: \"#{field_id}\"#{rows_attr}#{cls_attr}) %>"
      when "submit"
        explicit_text = call.args[0]?.is_a?(Crystal::StringLiteral) ? call.args[0].as(Crystal::StringLiteral).value : nil
        css = extract_named_string(call, "class")
        if explicit_text
          cls_attr = css ? %(, class: "#{css}") : ""
          io << "<%= submit_tag(\"#{explicit_text}\"#{cls_attr}) %>"
        else
          # Derive submit text from model state
          css_attr = css ? %( class="#{css}") : ""
          io << "<input type=\"submit\" name=\"commit\" value=\""
          io << "<%= #{model_prefix}.persisted? ? \"Update #{model_prefix.capitalize}\" : \"Create #{model_prefix.capitalize}\" %>"
          io << "\"#{css_attr}>"
        end
      else
        io << "<%= " << call.to_s << " %>"
      end
    end

    # --- If/else ---

    private def emit_if(node : Crystal::If, io : IO)
      io << "<% if " << node.cond.to_s << " %>\n"
      emit_statements(node.then, io)
      if else_body = node.else
        unless else_body.is_a?(Crystal::Nop)
          io << "<% else %>\n"
          emit_statements(else_body, io)
        end
      end
      io << "<% end %>\n"
    end

    # --- Helpers ---

    private def extract_symbol_arg(call : Crystal::Call) : String?
      arg = call.args[0]?
      case arg
      when Crystal::SymbolLiteral then arg.value
      when Crystal::StringLiteral then arg.value
      else nil
      end
    end

    private def extract_named_string(call : Crystal::Call, key : String) : String?
      call.named_args.try do |named|
        named.each do |na|
          if na.name == key
            case v = na.value
            when Crystal::StringLiteral then return v.value
            when Crystal::NumberLiteral then return v.value
            when Crystal::ArrayLiteral
              # Simplify conditional class arrays: ["base", {cond: val}] → "base"
              if v.elements.size > 0 && v.elements[0].is_a?(Crystal::StringLiteral)
                return v.elements[0].as(Crystal::StringLiteral).value
              end
              return v.to_s
            end
          end
        end
      end
      nil
    end

    # --- Find def render body ---

    private def find_def_body(node : Crystal::ASTNode) : Crystal::ASTNode?
      case node
      when Crystal::Expressions
        node.expressions.each do |child|
          result = find_def_body(child)
          return result if result
        end
      when Crystal::Def
        return node.body if node.name == "render"
      end
      nil
    end
  end
end
