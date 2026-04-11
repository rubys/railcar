# Serializes a Crystal AST to Python source code.
#
# Walks Crystal AST nodes (produced by PrismTranslator from Ruby source,
# then transformed through filter chains) and emits equivalent Python.
#
# This is the Python counterpart of Crystal's built-in .to_s() method.
# Where Crystal can serialize its own AST natively, Python output requires
# an explicit emitter that understands the syntax differences:
#   - Indentation-based blocks (no `end`)
#   - `def` → `def`, but `do |x|` → `for x in`
#   - `:symbol` → `"string"`
#   - `nil` → `None`, `true` → `True`
#   - String interpolation → f-strings

require "compiler/crystal/syntax"

module Railcar
  class PythonEmitter
    getter indent : Int32

    # Property names per type — populated by semantic analysis or AppModel metadata.
    # If a Call node's receiver type has properties listed here, emit without parens.
    # Key: type name (e.g., "Article"), Value: set of property names
    getter properties : Hash(String, Set(String))

    def initialize(@indent : Int32 = 0, @properties : Hash(String, Set(String)) = {} of String => Set(String))
    end

    # Check if a method call is a property access.
    # Uses semantic type info (.type?) if available, falls back to properties hash.
    private def is_property_access?(node : Crystal::Call) : Bool
      return false unless node.args.empty? && node.named_args.nil? && node.block.nil?
      return false unless obj = node.obj

      # Try semantic type info first (only available when semantic module is loaded)
      {% if Crystal::ASTNode.has_method?("type?") %}
        if obj_type = obj.type?
          begin
            return obj_type.instance_vars.has_key?("@#{node.name}")
          rescue
          end
        end
      {% end %}

      # Fall back to properties hash
      # Infer type name from variable name conventions
      type_name = infer_type_name(obj)
      if type_name && (props = @properties[type_name]?)
        return props.includes?(node.name)
      end

      false
    end

    private def infer_type_name(node : Crystal::ASTNode) : String?
      case node
      when Crystal::Var
        Inflector.classify(node.name) # article → Article
      else
        nil
      end
    end

    def emit(node : Crystal::ASTNode) : String
      io = IO::Memory.new
      emit(node, io)
      io.to_s
    end

    def emit_body(node : Crystal::ASTNode) : String
      io = IO::Memory.new
      emit_body(node, io)
      io.to_s
    end

    def emit(node : Crystal::ASTNode, io : IO) : Nil
      case node
      when Crystal::Expressions
        emit_expressions(node, io)
      when Crystal::ClassDef
        emit_class(node, io)
      when Crystal::Def
        emit_def(node, io)
      when Crystal::Call
        emit_call(node, io)
      when Crystal::Assign
        emit_assign(node, io)
      when Crystal::OpAssign
        emit_op_assign(node, io)
      when Crystal::If
        emit_if(node, io)
      when Crystal::While
        emit_while(node, io)
      when Crystal::Return
        emit_return(node, io)
      when Crystal::Var
        io << node.name
      when Crystal::InstanceVar
        io << "self." << node.name.lstrip('@')
      when Crystal::Path
        emit_path(node, io)
      when Crystal::StringLiteral
        io << node.value.inspect
      when Crystal::StringInterpolation
        emit_string_interpolation(node, io)
      when Crystal::SymbolLiteral
        io << node.value.inspect
      when Crystal::NumberLiteral
        io << node.value
      when Crystal::BoolLiteral
        io << (node.value ? "True" : "False")
      when Crystal::NilLiteral
        io << "None"
      when Crystal::ArrayLiteral
        emit_array(node, io)
      when Crystal::HashLiteral
        emit_hash(node, io)
      when Crystal::NamedTupleLiteral
        emit_named_tuple(node, io)
      when Crystal::Block
        emit_block(node, io)
      when Crystal::ProcLiteral
        emit_proc(node, io)
      when Crystal::Not
        io << "not "
        emit(node.exp, io)
      when Crystal::And
        emit(node.left, io)
        io << " and "
        emit(node.right, io)
      when Crystal::Or
        emit(node.left, io)
        io << " or "
        emit(node.right, io)
      when Crystal::Nop
        # skip
      when Crystal::Require
        # skip — Python uses import
      else
        io << "# TODO: unhandled node #{node.class.name}"
      end
    end

    # Emit a node as a block body (handles both Expressions and single nodes)
    # Emit a node as a block body (handles both Expressions and single nodes)
    # Public so controller generator can use it for action bodies.
    def emit_body(node : Crystal::ASTNode, io : IO)
      case node
      when Crystal::Nop
        write_indent(io)
        io << "pass\n"
      when Crystal::Expressions
        if node.keyword.paren?
          io << "("
          node.expressions.each_with_index do |expr, i|
            io << ", " if i > 0
            emit(expr, io)
          end
          io << ")"
          return
        end

        node.expressions.each_with_index do |expr, i|
          io << "\n" if i > 0 && needs_newline?(expr)
          emit_statement(expr, io)
        end
      else
        emit_statement(node, io)
      end
    end

    # Emit a single statement with indentation and newline
    private def emit_statement(node : Crystal::ASTNode, io : IO)
      write_indent(io)
      emit(node, io)
      io << "\n"
    end

    private def emit_expressions(node : Crystal::Expressions, io : IO)
      # Parenthesized expressions
      if node.keyword.paren?
        io << "("
        node.expressions.each_with_index do |expr, i|
          io << ", " if i > 0
          emit(expr, io)
        end
        io << ")"
        return
      end

      node.expressions.each_with_index do |expr, i|
        io << "\n" if i > 0 && needs_newline?(expr)
        emit_statement(expr, io)
      end
    end

    private def emit_class(node : Crystal::ClassDef, io : IO)
      io << "class " << node.name.names.join(".")
      if sc = node.superclass
        io << "("
        emit(sc, io)
        io << ")"
      end
      io << ":\n"
      indented { emit_body(node.body, io) }
    end

    private def emit_def(node : Crystal::Def, io : IO)
      io << "def " << python_method_name(node.name) << "("
      node.args.each_with_index do |arg, i|
        io << ", " if i > 0
        io << arg.name
      end
      io << "):\n"
      indented { emit_body(node.body, io) }
    end

    private def emit_call(node : Crystal::Call, io : IO)
      obj = node.obj
      name = node.name
      args = node.args
      named = node.named_args
      block = node.block

      # raise is a statement, not a function
      if name == "raise" && obj.nil? && args.size == 1
        io << "raise "
        emit(args[0], io)
        return
      end

      # Operators
      if is_operator?(name) && args.size == 1 && obj
        emit(obj, io)
        io << " " << name << " "
        emit(args[0], io)
        return
      end

      # Unary operators
      if name == "-" && args.empty? && obj
        io << "-"
        emit(obj, io)
        return
      end

      # Unary !
      if name == "!" && args.empty? && obj
        io << "not "
        emit(obj, io)
        return
      end

      # Index access: obj[key]
      if name == "[]" && obj
        emit(obj, io)
        io << "["
        args.each_with_index do |arg, i|
          io << ", " if i > 0
          emit(arg, io)
        end
        io << "]"
        return
      end

      # Index assign: obj[key] = value (used as call target in Assign)
      if name == "[]=" && obj && args.size == 2
        emit(obj, io)
        io << "["
        emit(args[0], io)
        io << "] = "
        emit(args[1], io)
        return
      end

      # _buf.append= expr → _buf += str(expr)
      # Special case: if expr is a call with block (each loop from RenderToPartial),
      # emit as a for loop that appends to _buf
      if name == "append=" && args.size == 1 && obj.is_a?(Crystal::Var) && obj.name == "_buf"
        arg = args[0]
        if arg.is_a?(Crystal::Call) && arg.block && (arg.name == "each" || arg.name == "each_with_index")
          block = arg.block.not_nil!
          io << "for "
          block.args.each_with_index do |ba, i|
            io << ", " if i > 0
            io << ba.name
          end
          io << " in "
          emit(arg.obj.not_nil!, io)
          io << ":\n"
          # The block body should be a call to render_*_partial — append its result to _buf
          indented do
            write_indent(io)
            io << "_buf += "
            emit(block.body, io)
            io << "\n"
          end
          return
        end

        io << "_buf += str("
        emit(arg, io)
        io << ")"
        return
      end

      # _buf.to_s → return _buf (at statement level, handled by caller)
      if name == "to_s" && args.empty? && obj.is_a?(Crystal::Var) && obj.name == "_buf"
        io << "return _buf"
        return
      end

      # Property setter: obj.name = value
      if name.ends_with?('=') && args.size == 1 && obj
        emit(obj, io)
        io << "." << name.rstrip('=') << " = "
        emit(args[0], io)
        return
      end

      # Block call: obj.each do |x| ... end → for x in obj:
      if block && (name == "each" || name == "each_with_index")
        emit_each_block(node, block, io)
        return
      end

      # Property access (type-aware): article.title → no parens
      if obj && is_property_access?(node)
        emit(obj, io)
        io << "." << name
        return
      end

      # Regular method call
      if obj
        emit(obj, io)
        io << "." << python_method_name(name)
      else
        io << python_method_name(name)
      end

      io << "("
      args.each_with_index do |arg, i|
        io << ", " if i > 0
        emit(arg, io)
      end
      if named
        named.each_with_index do |na, i|
          io << ", " if i > 0 || !args.empty?
          io << na.name << "="
          emit(na.value, io)
        end
      end
      io << ")"
    end

    private def emit_assign(node : Crystal::Assign, io : IO)
      target = node.target
      value = node.value

      # Handle obj[key] = value
      if target.is_a?(Crystal::Call) && target.name == "[]"
        emit(target.obj.not_nil!, io)
        io << "["
        target.args.each_with_index do |arg, i|
          io << ", " if i > 0
          emit(arg, io)
        end
        io << "] = "
        emit(value, io)
        return
      end

      # Handle property setter: obj.prop = value
      if target.is_a?(Crystal::Call) && target.obj
        emit(target.obj.not_nil!, io)
        io << "." << target.name.rstrip('=')
        io << " = "
        emit(value, io)
        return
      end

      emit(target, io)
      io << " = "
      emit(value, io)
    end

    private def emit_op_assign(node : Crystal::OpAssign, io : IO)
      emit(node.target, io)
      io << " " << node.op << "= "
      emit(node.value, io)
    end

    private def emit_if(node : Crystal::If, io : IO)
      io << "if "
      emit(node.cond, io)
      io << ":\n"
      indented { emit_body(node.then, io) }

      if else_body = node.else
        unless else_body.is_a?(Crystal::Nop)
          if else_body.is_a?(Crystal::If)
            write_indent(io)
            io << "el"
            emit_if(else_body, io)
          else
            write_indent(io)
            io << "else:\n"
            indented { emit_body(else_body, io) }
          end
        end
      end
    end

    private def emit_while(node : Crystal::While, io : IO)
      io << "while "
      emit(node.cond, io)
      io << ":\n"
      indented { emit_body(node.body, io) }
    end

    private def emit_return(node : Crystal::Return, io : IO)
      io << "return"
      if exp = node.exp
        io << " "
        emit(exp, io)
      end
    end

    private def emit_path(node : Crystal::Path, io : IO)
      io << node.names.join(".")
    end

    private def emit_string_interpolation(node : Crystal::StringInterpolation, io : IO)
      io << "f\""
      node.expressions.each do |part|
        case part
        when Crystal::StringLiteral
          io << part.value.gsub('"', "\\\"").gsub('{', "{{").gsub('}', "}}")
        else
          io << "{"
          emit(part, io)
          io << "}"
        end
      end
      io << "\""
    end

    private def emit_array(node : Crystal::ArrayLiteral, io : IO)
      io << "["
      node.elements.each_with_index do |el, i|
        io << ", " if i > 0
        emit(el, io)
      end
      io << "]"
    end

    private def emit_hash(node : Crystal::HashLiteral, io : IO)
      io << "{"
      node.entries.each_with_index do |entry, i|
        io << ", " if i > 0
        emit(entry.key, io)
        io << ": "
        emit(entry.value, io)
      end
      io << "}"
    end

    private def emit_named_tuple(node : Crystal::NamedTupleLiteral, io : IO)
      io << "{"
      node.entries.each_with_index do |entry, i|
        io << ", " if i > 0
        io << entry.key.inspect << ": "
        emit(entry.value, io)
      end
      io << "}"
    end

    private def emit_block(node : Crystal::Block, io : IO)
      # Standalone block — shouldn't normally appear outside of calls
      io << "# block"
    end

    private def emit_proc(node : Crystal::ProcLiteral, io : IO)
      d = node.def
      io << "lambda "
      d.args.each_with_index do |arg, i|
        io << ", " if i > 0
        io << arg.name
      end
      io << ": "
      emit(d.body, io)
    end

    private def emit_each_block(call : Crystal::Call, block : Crystal::Block, io : IO)
      io << "for "
      block.args.each_with_index do |arg, i|
        io << ", " if i > 0
        io << arg.name
      end
      io << " in "
      emit(call.obj.not_nil!, io)
      io << ":\n"
      indented { emit_body(block.body, io) }
    end

    # --- Helpers ---

    private def write_indent(io : IO)
      @indent.times { io << "    " }
    end

    private def indented(&)
      @indent += 1
      yield
      @indent -= 1
    end

    private def needs_newline?(node : Crystal::ASTNode) : Bool
      node.is_a?(Crystal::Def) || node.is_a?(Crystal::ClassDef) || node.is_a?(Crystal::If)
    end

    private def is_operator?(name : String) : Bool
      %w[+ - * / % == != < > <= >= && || & | ^ << >> <=> =~ !~].includes?(name)
    end

    private def python_method_name(name : String) : String
      # Ruby ? suffix → is_ prefix (e.g. persisted? → is_persisted)
      if name.ends_with?('?')
        "is_#{name.rstrip('?')}"
      elsif name.ends_with?('!')
        name.rstrip('!')
      else
        name
      end
    end
  end
end
