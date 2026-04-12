# cr2py — Crystal to Python transpiler
#
# Reads a compiled Crystal application via CrystalAnalyzer,
# walks the typed AST, and emits syntactically correct Python.
#
# Two-method approach:
#   to_nodes(node) — statement context, returns Array(PyAST::Node)
#   to_expr(node)  — expression context, returns String
#
# Usage: cr2py path/to/crystal-app/src/app.cr output-dir

require "../../../src/semantic"
require "../../../shards/crystal-analyzer/src/crystal-analyzer"
require "./py_ast"

module Cr2Py
  PYTHON_KEYWORDS = %w[False True None and as assert async await break class
    continue def del elif else except finally for from global if import in is
    lambda nonlocal not or pass raise return try while with yield]

  class Emitter
    getter program : Crystal::Program

    def initialize(@program)
    end

    # ── Statement context: Crystal AST → PyAST nodes ──

    def to_nodes(node : Crystal::ASTNode) : Array(PyAST::Node)
      case node
      when Crystal::Expressions
        nodes = [] of PyAST::Node
        node.expressions.each_with_index do |expr, i|
          next if expr.is_a?(Crystal::Nop)
          nodes << PyAST::Blank.new if i > 0 && needs_blank_line?(expr)
          nodes.concat(to_nodes(expr))
        end
        nodes

      when Crystal::ModuleDef
        to_nodes(node.body)

      when Crystal::ClassDef
        name = node.name.names.last
        superclass = node.superclass.try { |sc| emit_type_name(sc) }
        body = body_to_nodes(node.body)
        [PyAST::Class.new(name, superclass, body)] of PyAST::Node

      when Crystal::Def
        def_to_nodes(node)

      when Crystal::Assign
        assign_to_nodes(node)

      when Crystal::OpAssign
        target = to_expr(node.target)
        value = to_expr(node.value)
        [PyAST::Statement.new("#{target} #{node.op}= #{value}")] of PyAST::Node

      when Crystal::If
        if_to_nodes(node)

      when Crystal::While
        cond = to_expr(node.cond)
        body = body_to_nodes(node.body)
        [PyAST::While.new(cond, body)] of PyAST::Node

      when Crystal::Call
        call_to_nodes(node)

      when Crystal::Return
        expr = node.exp.try { |e| to_expr(e) } || ""
        [PyAST::Return.new(expr)] of PyAST::Node

      when Crystal::Yield
        parts = ["yield"]
        if exps = node.exps
          parts << " "
          parts << exps.map { |e| to_expr(e) }.join(", ")
        end
        [PyAST::Statement.new(parts.join)] of PyAST::Node

      when Crystal::Include
        [PyAST::Raw.new("# include #{node.name}")] of PyAST::Node

      when Crystal::TypeDeclaration
        [PyAST::Raw.new("# #{node.var}: #{node.declared_type}")] of PyAST::Node

      when Crystal::VisibilityModifier
        to_nodes(node.exp)

      when Crystal::Cast
        to_nodes(node.obj)

      when Crystal::Nop, Crystal::Require
        [] of PyAST::Node

      when Crystal::Macro
        [PyAST::Raw.new("# macro: #{node.name}")] of PyAST::Node

      else
        # Fallback: treat as expression in statement context
        [PyAST::Statement.new(to_expr(node))] of PyAST::Node
      end
    end

    # ── Expression context: Crystal AST → Python string ──

    def to_expr(node : Crystal::ASTNode) : String
      case node
      when Crystal::Var
        python_name(node.name)

      when Crystal::InstanceVar
        "self.#{node.name.lstrip('@')}"

      when Crystal::ClassVar
        node.name.lstrip('@').lstrip('@').upcase

      when Crystal::Path
        node.names.join(".")

      when Crystal::Generic
        base = crystal_type_to_python(node.name.to_s)
        args = node.type_vars.map { |tv| crystal_type_to_python(tv.to_s) }.join(", ")
        if args.empty?
          base
        else
          "#{base}[#{args}]"
        end

      when Crystal::Metaclass
        to_expr(node.name)

      when Crystal::StringLiteral
        node.value.inspect

      when Crystal::StringInterpolation
        emit_fstring(node)

      when Crystal::SymbolLiteral
        node.value.inspect

      when Crystal::CharLiteral
        node.value.to_s.inspect

      when Crystal::NumberLiteral
        node.value

      when Crystal::BoolLiteral
        node.value ? "True" : "False"

      when Crystal::NilLiteral
        "None"

      when Crystal::ArrayLiteral
        "[#{node.elements.map { |e| to_expr(e) }.join(", ")}]"

      when Crystal::HashLiteral
        "{#{node.entries.map { |e| "#{to_expr(e.key)}: #{to_expr(e.value)}" }.join(", ")}}"

      when Crystal::NamedTupleLiteral
        "{#{node.entries.map { |e| "#{e.key.inspect}: #{to_expr(e.value)}" }.join(", ")}}"

      when Crystal::TupleLiteral
        "(#{node.elements.map { |e| to_expr(e) }.join(", ")})"

      when Crystal::RangeLiteral
        from = to_expr(node.from)
        to = to_expr(node.to)
        if node.exclusive?
          "slice(#{from}, #{to})"
        else
          "slice(#{from}, #{to} + 1)"
        end

      when Crystal::Not
        "not #{to_expr(node.exp)}"

      when Crystal::And
        "#{to_expr(node.left)} and #{to_expr(node.right)}"

      when Crystal::Or
        "#{to_expr(node.left)} or #{to_expr(node.right)}"

      when Crystal::IsA
        "isinstance(#{to_expr(node.obj)}, #{crystal_type_to_python(node.const.to_s)})"

      when Crystal::Call
        call_to_expr(node)

      when Crystal::If
        # Python ternary
        then_expr = to_expr(node.then)
        cond_expr = to_expr(node.cond)
        else_expr = node.else.is_a?(Crystal::Nop) ? "None" : to_expr(node.else)
        "(#{then_expr} if #{cond_expr} else #{else_expr})"

      when Crystal::Assign
        # Assignment in expression context — just the target name
        # (the assignment itself is hoisted by assign_to_nodes)
        to_expr(node.target)

      when Crystal::Cast
        to_expr(node.obj)

      when Crystal::Expressions
        if node.expressions.size == 1
          to_expr(node.expressions.first)
        else
          to_expr(node.expressions.last)
        end

      when Crystal::Splat
        "*#{to_expr(node.exp)}"

      when Crystal::DoubleSplat
        "**#{to_expr(node.exp)}"

      when Crystal::Nop
        "None"

      when Crystal::MacroId
        node.value.inspect

      else
        "None"
      end
    end

    # ── Def ──

    private def def_to_nodes(node : Crystal::Def) : Array(PyAST::Node)
      name = node.name

      # Crystal operator defs: def [](key), def []=(key, value)
      if name == "[]=" && node.args.size == 2
        func_name = "__setitem__"
        cr_args = node.args.map do |arg|
          aname = python_name(arg.name)
          if restriction = arg.restriction
            "#{aname}: #{crystal_type_to_python(restriction.to_s)}"
          else
            aname
          end
        end
        body = body_to_nodes(node.body)
        return [PyAST::Func.new(func_name, ["self"] + cr_args, body)] of PyAST::Node
      end

      if name == "[]?" && node.args.size >= 1
        func_name = "get"
        cr_args = node.args.map do |arg|
          aname = python_name(arg.name)
          if restriction = arg.restriction
            "#{aname}: #{crystal_type_to_python(restriction.to_s)}"
          else
            aname
          end
        end
        ret = node.return_type.try { |rt| crystal_type_to_python(rt.to_s) }
        body = body_to_nodes(node.body)
        return [PyAST::Func.new(func_name, ["self"] + cr_args, body, ret)] of PyAST::Node
      end

      if name == "[]" && node.args.size >= 1
        func_name = "__getitem__"
        cr_args = node.args.map do |arg|
          aname = python_name(arg.name)
          if restriction = arg.restriction
            "#{aname}: #{crystal_type_to_python(restriction.to_s)}"
          else
            aname
          end
        end
        ret = node.return_type.try { |rt| crystal_type_to_python(rt.to_s) }
        body = body_to_nodes(node.body)
        return [PyAST::Func.new(func_name, ["self"] + cr_args, body, ret)] of PyAST::Node
      end

      # Crystal property setter `def name=(value)` → Python setter method
      if name.ends_with?('=') && !name.ends_with?("==") && node.args.size == 1
        prop = name.rstrip('=')
        arg = node.args[0]
        aname = python_name(arg.name)
        setter_name = "set_#{prop}"
        cr_args = [aname]
        if restriction = arg.restriction
          cr_args = ["#{aname}: #{crystal_type_to_python(restriction.to_s)}"]
        end
        body = [PyAST::Statement.new("self.#{prop} = #{aname}")] of PyAST::Node
        return [PyAST::Func.new(setter_name, cr_args, body)] of PyAST::Node
      end

      name = python_name(name)

      args = node.args.map do |arg|
        aname = python_name(arg.name)
        if restriction = arg.restriction
          "#{aname}: #{crystal_type_to_python(restriction.to_s)}"
        elsif default = arg.default_value
          "#{aname}=#{to_expr(default)}"
        else
          aname
        end
      end

      ret = node.return_type.try { |rt| crystal_type_to_python(rt.to_s) }
      body = body_to_nodes(node.body)

      [PyAST::Func.new(name, args, body, ret)] of PyAST::Node
    end

    # ── Assign ──

    private def assign_to_nodes(node : Crystal::Assign) : Array(PyAST::Node)
      target = to_expr(node.target)

      # If value is an If, emit as if/else with assignments in branches
      if if_node = node.value.as?(Crystal::If)
        return assign_if_to_nodes(target, if_node)
      end

      # If value is Expressions (multi-statement), emit leading stmts then assign last
      if exprs = node.value.as?(Crystal::Expressions)
        return assign_exprs_to_nodes(target, exprs)
      end

      [PyAST::Assign.new(target, to_expr(node.value))] of PyAST::Node
    end

    private def assign_if_to_nodes(target : String, node : Crystal::If) : Array(PyAST::Node)
      nodes = [] of PyAST::Node

      # If the condition is itself an assignment, hoist it
      if cond_assign = node.cond.as?(Crystal::Assign)
        nodes.concat(assign_to_nodes(cond_assign))
        cond_expr = to_expr(cond_assign.target)
      else
        cond_expr = to_expr(node.cond)
      end

      then_nodes = [PyAST::Assign.new(target, to_expr(node.then))] of PyAST::Node

      else_nodes = if node.else.is_a?(Crystal::Nop)
                     nil
                   elsif node.else.is_a?(Crystal::If)
                     assign_if_to_nodes(target, node.else.as(Crystal::If))
                   else
                     [PyAST::Assign.new(target, to_expr(node.else))] of PyAST::Node
                   end

      nodes << PyAST::If.new(cond_expr, then_nodes, else_nodes)
      nodes
    end

    private def assign_exprs_to_nodes(target : String, exprs : Crystal::Expressions) : Array(PyAST::Node)
      nodes = [] of PyAST::Node
      exprs.expressions.each_with_index do |expr, i|
        if i == exprs.expressions.size - 1
          nodes << PyAST::Assign.new(target, to_expr(expr))
        else
          nodes.concat(to_nodes(expr))
        end
      end
      nodes
    end

    # ── If ──

    private def if_to_nodes(node : Crystal::If) : Array(PyAST::Node)
      cond = to_expr(node.cond)
      body = body_to_nodes(node.then)

      else_nodes = if node.else.is_a?(Crystal::Nop)
                     nil
                   elsif node.else.is_a?(Crystal::If)
                     if_to_nodes(node.else.as(Crystal::If))
                   else
                     body_to_nodes(node.else)
                   end

      [PyAST::If.new(cond, body, else_nodes)] of PyAST::Node
    end

    # ── Call (statement context) ──

    private def call_to_nodes(node : Crystal::Call) : Array(PyAST::Node)
      obj = node.obj
      name = node.name
      args = node.args
      block = node.block

      # __str__ << value → BufLiteral or BufAppend
      if name == "<<" && obj.is_a?(Crystal::Var) && obj.name == "__str__"
        if args.size == 1 && args[0].is_a?(Crystal::StringLiteral)
          return [PyAST::BufLiteral.new(args[0].as(Crystal::StringLiteral).value)] of PyAST::Node
        else
          return [PyAST::BufAppend.new(to_expr(args[0]))] of PyAST::Node
        end
      end

      # .to_s(io) → BufAppend
      if name == "to_s" && args.size == 1 && args[0].is_a?(Crystal::Var) &&
         args[0].as(Crystal::Var).name == "__str__"
        return [PyAST::BufAppend.new(to_expr(obj.not_nil!))] of PyAST::Node
      end

      # each/each_with_index → for loop
      if block && (name == "each" || name == "each_with_index") && obj
        return each_to_nodes(node, block)
      end

      # String.build → buf sequence
      if block && name == "build" && obj.to_s == "String"
        return string_build_to_nodes(block)
      end

      # times with block → for i in range(n)
      if block && name == "times" && obj
        var = block.args.first?.try(&.name) || "_"
        n = to_expr(obj)
        body = body_to_nodes(block.body)
        return [PyAST::For.new(var, "range(#{n})", body)] of PyAST::Node
      end

      # General block → call + indented body
      if block
        return block_call_to_nodes(node, block)
      end

      # raise → raise
      if name == "raise" && !obj
        expr = args.empty? ? "Exception()" : to_expr(args[0])
        return [PyAST::Statement.new("raise #{expr}")] of PyAST::Node
      end

      # []= → index assign statement
      if name == "[]=" && obj && args.size == 2
        return [PyAST::Statement.new("#{to_expr(obj)}[#{to_expr(args[0])}] = #{to_expr(args[1])}")] of PyAST::Node
      end

      # property setter: obj.name= value
      if name.ends_with?('=') && !name.ends_with?("==") && args.size == 1 && obj
        prop = name.rstrip('=')
        return [PyAST::Statement.new("#{to_expr(obj)}.#{prop} = #{to_expr(args[0])}")] of PyAST::Node
      end

      # Default: wrap expression in statement
      [PyAST::Statement.new(call_to_expr(node))] of PyAST::Node
    end

    # ── Call (expression context) ──

    private def call_to_expr(node : Crystal::Call) : String
      obj = node.obj
      name = node.name
      args = node.args
      named = node.named_args

      # Operators (but not << which needs special handling)
      if is_operator?(name) && args.size == 1 && obj
        # << on non-__str__ → list append in statement context, but here treat as operator
        return "#{to_expr(obj)} #{python_operator(name)} #{to_expr(args[0])}"
      end

      # Unary minus
      if name == "-" && args.empty? && obj
        return "-#{to_expr(obj)}"
      end

      # .to_s → str()
      if name == "to_s" && args.empty? && obj
        return "str(#{to_expr(obj)})"
      end

      # .to_i / .to_i64 → int()
      if (name == "to_i" || name == "to_i64") && args.empty? && obj
        return "int(#{to_expr(obj)})"
      end

      # .to_f / .to_f64 → float()
      if (name == "to_f" || name == "to_f64") && args.empty? && obj
        return "float(#{to_expr(obj)})"
      end

      # .size / .length → len()
      if (name == "size" || name == "length") && args.empty? && obj
        return "len(#{to_expr(obj)})"
      end

      # .any? → bool()
      if name == "any?" && args.empty? && obj
        return "bool(#{to_expr(obj)})"
      end

      # .empty? → not obj
      if name == "empty?" && args.empty? && obj
        return "not #{to_expr(obj)}"
      end

      # .nil? → (obj is None)
      if name == "nil?" && args.empty? && obj
        return "(#{to_expr(obj)} is None)"
      end

      # .not_nil! → obj
      if name == "not_nil!" && args.empty? && obj
        return to_expr(obj)
      end

      # .class → type()
      if name == "class" && args.empty? && obj
        return "type(#{to_expr(obj)})"
      end

      # .name on type → __name__
      if name == "name" && args.empty? && obj
        if obj.is_a?(Crystal::Call) && obj.name == "class"
          return "type(#{to_expr(obj.obj.not_nil!)}).__name__"
        end
      end

      # .starts_with? → .startswith
      if name == "starts_with?" && obj
        return "#{to_expr(obj)}.startswith(#{args.map { |a| to_expr(a) }.join(", ")})"
      end

      # .ends_with? → .endswith
      if name == "ends_with?" && obj
        return "#{to_expr(obj)}.endswith(#{args.map { |a| to_expr(a) }.join(", ")})"
      end

      # .includes? → in
      if name == "includes?" && args.size == 1 && obj
        return "#{to_expr(args[0])} in #{to_expr(obj)}"
      end

      # .is_a? → isinstance
      if name == "is_a?" && args.size == 1 && obj
        return "isinstance(#{to_expr(obj)}, #{crystal_type_to_python(args[0].to_s)})"
      end

      # .responds_to? → hasattr
      if name == "responds_to?" && args.size == 1 && obj
        return "hasattr(#{to_expr(obj)}, #{to_expr(args[0])})"
      end

      # [] → index
      if name == "[]" && obj
        return "#{to_expr(obj)}[#{args.map { |a| to_expr(a) }.join(", ")}]"
      end

      # []? → .get()
      if name == "[]?" && args.size == 1 && obj
        return "#{to_expr(obj)}.get(#{to_expr(args[0])})"
      end

      # []= in expression context → setitem expression
      if name == "[]=" && obj && args.size == 2
        # Can't be a true expression in Python; emit as side effect
        return "#{to_expr(obj)}.__setitem__(#{to_expr(args[0])}, #{to_expr(args[1])})"
      end

      # .first? / .last?
      if name == "first?" && args.empty? && obj
        return "(#{to_expr(obj)}[0] if #{to_expr(obj)} else None)"
      end
      if name == "last?" && args.empty? && obj
        return "(#{to_expr(obj)}[-1] if #{to_expr(obj)} else None)"
      end

      # .first / .last
      if name == "first" && args.empty? && obj
        return "#{to_expr(obj)}[0]"
      end
      if name == "last" && args.empty? && obj
        return "#{to_expr(obj)}[-1]"
      end

      # .new → constructor: ClassName(...)
      if name == "new" && obj
        return "#{to_expr(obj)}(#{emit_args(args, named)})"
      end

      # .seconds / .minutes etc → just the number
      if (name == "seconds" || name == "minutes" || name == "hours") && args.empty? && obj
        return to_expr(obj)
      end

      # .capitalize / .downcase / .upcase / .strip / .chomp → Python equivalents
      if name == "downcase" && args.empty? && obj
        return "#{to_expr(obj)}.lower()"
      end
      if name == "upcase" && args.empty? && obj
        return "#{to_expr(obj)}.upper()"
      end
      if name == "capitalize" && args.empty? && obj
        return "#{to_expr(obj)}.capitalize()"
      end
      if name == "strip" && args.empty? && obj
        return "#{to_expr(obj)}.strip()"
      end
      if name == "chomp" && args.empty? && obj
        return "#{to_expr(obj)}.rstrip()"
      end
      if name == "split" && obj
        return "#{to_expr(obj)}.split(#{args.map { |a| to_expr(a) }.join(", ")})"
      end
      if name == "join" && obj
        return "#{to_expr(obj)}.join(#{args.map { |a| to_expr(a) }.join(", ")})"
      end
      if name == "map" && obj
        return "#{to_expr(obj)}"  # map with block handled elsewhere
      end
      if name == "select" && obj && args.empty? && !node.block
        return "#{to_expr(obj)}"  # select with block handled elsewhere
      end
      if name == "gsub" && obj && args.size == 2
        return "#{to_expr(obj)}.replace(#{to_expr(args[0])}, #{to_expr(args[1])})"
      end

      # Property access (type-checked)
      if args.empty? && named.nil? && !node.block && obj && is_property?(node)
        return "#{to_expr(obj)}.#{name}"
      end

      # Regular method call
      method_name = python_name(name)
      if obj
        "#{to_expr(obj)}.#{method_name}(#{emit_args(args, named)})"
      else
        "#{method_name}(#{emit_args(args, named)})"
      end
    end

    # ── Each → For ──

    private def each_to_nodes(call : Crystal::Call, block : Crystal::Block) : Array(PyAST::Node)
      vars = block.args.map(&.name).join(", ")
      vars = "_" if vars.empty?
      collection = to_expr(call.obj.not_nil!)
      body = body_to_nodes(block.body)
      [PyAST::For.new(vars, collection, body)] of PyAST::Node
    end

    # ── String.build → buf sequence ──

    private def string_build_to_nodes(block : Crystal::Block) : Array(PyAST::Node)
      nodes = [PyAST::Assign.new("_buf", "''")] of PyAST::Node
      nodes.concat(body_to_nodes(block.body))
      nodes
    end

    # ── General block call ──

    private def block_call_to_nodes(node : Crystal::Call, block : Crystal::Block) : Array(PyAST::Node)
      obj = node.obj
      name = node.name
      args = node.args

      call_str = if obj
                   "#{to_expr(obj)}.#{python_name(name)}(#{emit_args(args, node.named_args)})"
                 else
                   "#{python_name(name)}(#{emit_args(args, node.named_args)})"
                 end
      nodes = [PyAST::Statement.new(call_str)] of PyAST::Node
      nodes.concat(body_to_nodes(block.body))
      nodes
    end

    # ── F-string ──

    private def emit_fstring(node : Crystal::StringInterpolation) : String
      has_complex = node.expressions.any? do |part|
        part.is_a?(Crystal::StringLiteral) && (part.value.includes?('\n') || part.value.includes?('"'))
      end

      io = IO::Memory.new
      if has_complex
        io << "f'''"
        node.expressions.each do |part|
          case part
          when Crystal::StringLiteral
            io << part.value.gsub("{", "{{").gsub("}", "}}")
          else
            io << "{"
            io << to_expr(part)
            io << "}"
          end
        end
        io << "'''"
      else
        io << "f\""
        node.expressions.each do |part|
          case part
          when Crystal::StringLiteral
            io << part.value.gsub('"', "\\\"").gsub("{", "{{").gsub("}", "}}")
          else
            io << "{"
            io << to_expr(part)
            io << "}"
          end
        end
        io << "\""
      end
      io.to_s
    end

    # ── Helpers ──

    private def body_to_nodes(node : Crystal::ASTNode) : Array(PyAST::Node)
      case node
      when Crystal::Nop
        [] of PyAST::Node
      when Crystal::Expressions
        nodes = [] of PyAST::Node
        node.expressions.each_with_index do |expr, i|
          next if expr.is_a?(Crystal::Nop)
          nodes << PyAST::Blank.new if i > 0 && needs_blank_line?(expr)
          nodes.concat(to_nodes(expr))
        end
        nodes
      else
        to_nodes(node)
      end
    end

    private def emit_args(args : Array(Crystal::ASTNode), named : Array(Crystal::NamedArgument)?) : String
      parts = [] of String
      args.each do |a|
        parts << to_expr(a)
      end
      if named
        named.each do |na|
          kwarg = safe_python_name(na.name)
          parts << "#{kwarg}=#{to_expr(na.value)}"
        end
      end
      parts.join(", ")
    end

    private def needs_blank_line?(node : Crystal::ASTNode) : Bool
      node.is_a?(Crystal::Def) || node.is_a?(Crystal::ClassDef)
    end

    private def is_operator?(name : String) : Bool
      %w[+ - * / % == != < > <= >= && || & | ^ << >>].includes?(name)
    end

    private def python_operator(name : String) : String
      case name
      when "&&" then "and"
      when "||" then "or"
      else name
      end
    end

    private def python_name(name : String) : String
      result = case name
               when "initialize" then "__init__"
               when "new"        then "__init__"
               when "nil?"       then "is_none"
               when "[]?"        then "get"
               when "puts"       then "print"
               when "p"          then "print"
               else
                 name.ends_with?('?') ? "is_#{name.rstrip('?')}" : name.rstrip('!')
               end
      safe_python_name(result)
    end

    # Ensure name isn't a Python keyword
    private def safe_python_name(name : String) : String
      PYTHON_KEYWORDS.includes?(name) ? "#{name}_" : name
    end

    private def is_property?(node : Crystal::Call) : Bool
      return false unless obj = node.obj
      if obj_type = obj.type?
        begin
          return obj_type.instance_vars.has_key?("@#{node.name}")
        rescue
        end
      end
      false
    end

    private def emit_type_name(node : Crystal::ASTNode) : String
      case node
      when Crystal::Path then node.names.last
      else node.to_s
      end
    end

    private def crystal_type_to_python(type_str : String) : String
      result = type_str
        # Specific compound types first
        .gsub("DB::Any", "Any")
        .gsub("DB::Database", "Any")
        .gsub("DB::ResultSet", "Any")
        .gsub("HTTP::Server::Context", "Any")
        .gsub("HTTP::Server::Response", "Any")
        .gsub("HTTP::Request", "Any")
        # Remove :: (Crystal namespace separator)
        .gsub("::", "")
        # Type name mappings
        .gsub("String", "str")
        .gsub("Int32", "int")
        .gsub("Int64", "int")
        .gsub("Float64", "float")
        .gsub("Float32", "float")
        .gsub("Bool", "bool")
        .gsub("Nil", "None")
        .gsub("Array", "list")
        .gsub("Hash", "dict")
        .gsub("NamedTuple", "dict")
        .gsub("Symbol", "str")
        .gsub("Time", "str")
        .gsub("IO", "Any")
        .gsub("self", "Self")
        # Generic parens → brackets
        .gsub("(", "[")
        .gsub(")", "]")
      # Clean up empty brackets: dict[] → dict
      result = result.gsub("[]", "")
      result
    end
  end
end

# --- Main ---

entry = ARGV[0]?
output_dir = ARGV[1]?

unless entry && output_dir
  STDERR.puts "Usage: cr2py <crystal-app-entry> <output-dir>"
  exit 1
end

puts "cr2py: analyzing #{entry}"

result = CrystalAnalyzer.analyze(entry)

puts "  #{result.files.size} source files, #{result.views.size} views"

Dir.mkdir_p(output_dir)
emitter = Cr2Py::Emitter.new(result.program)
serializer = PyAST::Serializer.new

# Emit source files
result.files.each do |filename, info|
  py_filename = filename
    .sub(/^src\//, "")
    .sub(/\.cr$/, ".py")

  out_path = File.join(output_dir, py_filename)
  Dir.mkdir_p(File.dirname(out_path))

  nodes = [] of PyAST::Node
  info.nodes.each do |node|
    nodes.concat(emitter.to_nodes(node))
  end

  mod = PyAST::Module.new(nodes)
  File.write(out_path, serializer.serialize(mod))
  puts "  #{py_filename}"
end

# Emit expanded views
result.views.each do |ecr_filename, ast|
  py_filename = ecr_filename
    .sub(/^src\//, "")
    .sub(/\.ecr$/, ".py")

  out_path = File.join(output_dir, py_filename)
  Dir.mkdir_p(File.dirname(out_path))

  nodes = emitter.to_nodes(ast)
  mod = PyAST::Module.new(nodes)
  File.write(out_path, serializer.serialize(mod))
  puts "  #{py_filename}"
end

puts "\ncr2py: done"
