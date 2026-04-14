# cr2py — Crystal to Python emitter
#
# Walks a typed Crystal AST and emits syntactically correct Python via PyAST.
#
# Two-method approach:
#   to_nodes(node) — statement context, returns Array(PyAST::Node)
#   to_expr(node)  — expression context, returns String

require "../../../src/semantic"
require "./py_ast"
require "./filters/db_filter"
require "./type_index"
require "./filters/pyast_dunder_filter"

module Cr2Py
  PYTHON_KEYWORDS = %w[False True None and as assert async await break class
    continue def del elif else except finally for from global if import in is
    lambda nonlocal not or pass raise return try while with yield]

  # Properties known to be attributes (not methods) on framework objects
  KNOWN_PROPERTIES = %w[id errors persisted match_info status headers body text method path]

  PYTHON_BUILTINS = %w[print len int str float bool isinstance hasattr type
    range enumerate zip sorted reversed list dict set tuple super abs min max
    sum any all map filter open getattr setattr delattr repr hash input
    web
    round format]

  class Emitter
    getter program : Crystal::Program
    getter type_index : TypeIndex
    property in_class : Bool = false
    property in_method : Bool = false
    property in_classmethod : Bool = false
    property current_double_splat : String? = nil
    property current_method_name : String? = nil
    property current_class_type : Crystal::Type? = nil
    property current_class_name : String? = nil

    # Model column names — used for property detection on untyped variables.
    # Maps model name → set of column names (e.g. "Article" → {"title", "body", ...})
    property model_columns : Hash(String, Set(String)) = {} of String => Set(String)

    getter debug_target : String?

    def initialize(@program, @type_index = TypeIndex.build(program))
      @debug_target = ENV["CR2PY_DEBUG"]?
    end

    private def debug?(context : String) : Bool
      return false unless dt = @debug_target
      dt == "all" || context.includes?(dt)
    end

    private def debug(msg : String)
      STDERR.puts "  CR2PY_DEBUG: #{msg}"
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
        old_in_class = @in_class
        old_class_type = @current_class_type
        old_class_name = @current_class_name
        @in_class = true
        @current_class_type = find_type(node.name.names)
        @current_class_name = @current_class_type.try(&.to_s)
        body = body_to_nodes(node.body)
        @in_class = old_in_class
        @current_class_type = old_class_type
        @current_class_name = old_class_name
        # Deduplicate methods with same Python name (e.g., create and create!)
        seen_methods = Set(String).new
        body = body.reject do |n|
          if n.is_a?(PyAST::Func) && seen_methods.includes?(n.name)
            true
          else
            seen_methods << n.name if n.is_a?(PyAST::Func)
            false
          end
        end
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

      when Crystal::ExceptionHandler
        body_nodes = body_to_nodes(node.body)
        if rescues = node.rescues
          if r = rescues.first?
            rescue_body = body_to_nodes(r.body)
            exc_type = r.types.try(&.first.try(&.to_s)) || "Exception"
            exc_var = r.name || "e"
            return [PyAST::Try.new(body_nodes, crystal_type_to_python(exc_type), exc_var, rescue_body)] of PyAST::Node
          end
        end
        body_nodes

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
        name = python_name(node.name)
        # In classmethods, Crystal's self refers to the class → Python's cls
        if name == "self" && @in_classmethod
          return "cls"
        end
        # Avoid Python name mangling: __x inside a class becomes _Class__x
        name = name.lstrip('_').empty? ? name : name.gsub(/^__/, "_t_") if name.starts_with?("__") && !name.ends_with?("__")
        name

      when Crystal::InstanceVar
        "self.#{node.name.lstrip('@')}"

      when Crystal::ClassVar
        attr = node.name.lstrip('@').lstrip('@')
        if @in_method
          "self.__class__.#{attr}"
        else
          attr
        end

      when Crystal::Path
        names = node.names
        names = names[1..] if names.first? == "Railcar" && names.size > 1
        result = names.join(".")
        # Class constants (UPPERCASE) need cls/self.__class__ prefix inside methods
        # But only if they're defined on the current class, not module-level imports
        if @in_class && @in_method && names.size == 1 && result == result.upcase && result.size > 1 && is_class_constant?(result)
          prefix = @in_classmethod ? "cls" : "self.__class__"
          "#{prefix}.#{result}"
        else
          result
        end

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
        py_type = crystal_type_to_python(node.const.to_s)
        if py_type == "None"
          "(#{to_expr(node.obj)} is None)"
        else
          "isinstance(#{to_expr(node.obj)}, #{py_type})"
        end

      when Crystal::Call
        call_to_expr(node)

      when Crystal::If
        # Crystal desugars x?.try{|v| v} and || to:
        #   if __temp = expr; __temp; else nil/default; end
        # Collapse: else nil → just expr, else default → expr or default
        if (cond_assign = node.cond.as?(Crystal::Assign)) &&
           (node.then.is_a?(Crystal::Var) &&
            node.then.as(Crystal::Var).name == cond_assign.target.to_s)
          expr = to_expr(cond_assign.value)
          if node.else.is_a?(Crystal::Nop) || node.else.is_a?(Crystal::NilLiteral)
            expr
          else
            "(#{expr} or #{to_expr(node.else)})"
          end
        else
          # Python ternary
          then_expr = to_expr(node.then)
          cond_expr = to_expr(node.cond)
          else_expr = node.else.is_a?(Crystal::Nop) ? "None" : to_expr(node.else)
          "(#{then_expr} if #{cond_expr} else #{else_expr})"
        end

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
        cr_args = @in_class ? ["self"] : [] of String
        if restriction = arg.restriction
          cr_args << "#{aname}: #{crystal_type_to_python(restriction.to_s)}"
        else
          cr_args << aname
        end
        body = [PyAST::Statement.new("self.#{prop} = #{aname}")] of PyAST::Node
        return [PyAST::Func.new(setter_name, cr_args, body)] of PyAST::Node
      end

      name = python_name(name)

      # Skip trivial getter methods for instance variables.
      # Crystal: def attributes; @attributes; end
      # Python doesn't need these — the attribute is accessed directly.
      # Note: class var getters (@@db) are kept — they may be called from
      # outside the class where direct attribute access doesn't work.
      if @in_class && node.args.empty? && !node.double_splat
        body = node.body
        is_trivial_getter = case body
                            when Crystal::InstanceVar
                              body.name.lstrip('@') == node.name
                            else
                              false
                            end
        return [] of PyAST::Node if is_trivial_getter
      end

      # Determine if this is a class method (def self.method_name)
      is_class_method = @in_class && node.receiver.try { |r|
        r.is_a?(Crystal::Var) && r.name == "self"
      }

      args = node.args.map do |arg|
        aname = python_name(arg.name)
        type_ann = if restriction = arg.restriction
                     ": #{crystal_type_to_python(restriction.to_s)}"
                   else
                     ""
                   end
        default_part = if default = arg.default_value
                         default_str = to_expr(default)
                         if default_str.includes?("self.")
                           "=None"
                         else
                           "=#{default_str}"
                         end
                       else
                         ""
                       end
        "#{aname}#{type_ann}#{default_part}"
      end

      # Add *splat and **double_splat
      if si = node.splat_index
        args.insert(si, "*#{args.delete_at(si)}")
      end
      if ds = node.double_splat
        args << "**#{python_name(ds.name)}"
      end

      # Add self/cls for class members
      if @in_class
        if is_class_method
          args.unshift("cls")
        else
          args.unshift("self")
        end
      end

      ret = node.return_type.try { |rt| crystal_type_to_python(rt.to_s) }
      old_in_method = @in_method
      old_in_classmethod = @in_classmethod
      old_double_splat = @current_double_splat
      old_method_name = @current_method_name
      @in_method = true
      @in_classmethod = is_class_method || false
      @current_double_splat = node.double_splat.try(&.name)
      @current_method_name = node.name

      method_ctx = "#{@current_class_name || "?"}##{name}"
      if debug?(method_ctx)
        debug "#{method_ctx}: in_class=#{@in_class} classmethod=#{@in_classmethod} class_name=#{@current_class_name}"
      end

      body = body_to_nodes(node.body)
      @in_method = old_in_method
      @in_classmethod = old_in_classmethod
      @current_double_splat = old_double_splat
      @current_method_name = old_method_name


      decorators = [] of String
      decorators << "classmethod" if is_class_method

      [PyAST::Func.new(name, args, body, ret, decorators)] of PyAST::Node
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
      result = [] of PyAST::Node

      # If condition is an assignment (Crystal: if x = expr), hoist it
      if cond_assign = node.cond.as?(Crystal::Assign)
        result.concat(assign_to_nodes(cond_assign))
        cond = to_expr(cond_assign.target)
      else
        cond = to_expr(node.cond)
      end

      body = body_to_nodes(node.then)

      else_nodes = if node.else.is_a?(Crystal::Nop)
                     nil
                   elsif node.else.is_a?(Crystal::If)
                     if_to_nodes(node.else.as(Crystal::If))
                   else
                     body_to_nodes(node.else)
                   end

      result << PyAST::If.new(cond, body, else_nodes)
      result
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

      # << on non-__str__ → .append()
      if name == "<<" && obj && args.size == 1
        return [PyAST::Statement.new("#{to_expr(obj)}.append(#{to_expr(args[0])})")]  of PyAST::Node
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

      # .map { |x| expr } → [expr for x in collection] (statement context)
      if name == "map" && block && obj && block.args.size > 0
        var = block.args[0].name
        expr = to_expr(block.body)
        collection = to_expr(obj)
        return [PyAST::Statement.new("[#{expr} for #{var} in #{collection}]")] of PyAST::Node
      end

      # .try { |v| expr } → var = obj; result = expr if var is not None else None
      if name == "try" && block && obj
        obj_expr = to_expr(obj)
        if block.args.size > 0
          var_name = block.args[0].name
          body_expr = to_expr(block.body)
          # Replace block arg references with a temp var
          # Apply same name mangling as the Var handler
          mangled_name = var_name.starts_with?("__") && !var_name.ends_with?("__") ? var_name.gsub(/^__/, "_t_") : var_name
          temp = "_try_val"
          body_expr = body_expr.gsub(mangled_name, temp)
          return [
            PyAST::Assign.new(temp, obj_expr),
            PyAST::Statement.new("(#{body_expr} if #{temp} is not None else None)"),
          ] of PyAST::Node
        else
          return [PyAST::Statement.new("(#{to_expr(block.body)} if #{obj_expr} is not None else None)")] of PyAST::Node
        end
      end

      # General block → call + indented body
      if block
        return block_call_to_nodes(node, block)
      end

      # super → super().current_method()
      if name == "super" && !obj
        return [PyAST::Statement.new("super().#{python_name(@current_method_name || "unknown")}()")] of PyAST::Node
      end

      # assert → assert statement
      if name == "assert" && !obj && args.size == 1
        return [PyAST::Statement.new("assert #{to_expr(args[0])}")] of PyAST::Node
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

      # super → super().current_method()
      if name == "super" && !obj
        return "super().#{python_name(@current_method_name || "unknown")}()"
      end

      # << on non-IO → .append() in expression context
      if name == "<<" && args.size == 1 && obj
        unless obj.is_a?(Crystal::Var) && obj.name == "__str__"
          return "#{to_expr(obj)}.append(#{to_expr(args[0])})"
        end
      end

      # Operators
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

      # .present? → bool(obj) (truthy check)
      if name == "present?" && args.empty? && obj
        return to_expr(obj)
      end

      # .nil? → (obj is None)
      if name == "nil?" && args.empty? && obj
        return "(#{to_expr(obj)} is None)"
      end

      # .not_nil! → obj
      if name == "not_nil!" && args.empty? && obj
        return to_expr(obj)
      end

      # .try { |v| expr } → (expr if obj is not None else None)
      if name == "try" && obj && node.block
        block = node.block.not_nil!
        obj_expr = to_expr(obj)
        if block.args.size > 0
          body_expr = to_expr(block.body)
          temp = "_try_val"
          body_expr = body_expr.gsub(block.args[0].name, temp)
          # Inline: assign temp, then ternary
          return "(#{body_expr.gsub(temp, obj_expr)} if #{obj_expr} is not None else None)"
        else
          return "(#{to_expr(block.body)} if #{obj_expr} is not None else None)"
        end
      end

      # .class → type() or cls in classmethods
      if name == "class" && args.empty? && obj
        if @in_classmethod
          return "cls"
        else
          return "type(#{to_expr(obj)})"
        end
      end

      # .name on type/class → __name__
      if name == "name" && args.empty? && obj
        if obj.is_a?(Crystal::Call) && obj.name == "class"
          return "type(#{to_expr(obj.obj.not_nil!)}).__name__"
        end
        # self.name in classmethod → cls.__name__
        if obj.is_a?(Crystal::Var) && obj.name == "self" && @in_classmethod
          return "cls.__name__"
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

      # .has_key? → in
      if name == "has_key?" && args.size == 1 && obj
        return "#{to_expr(args[0])} in #{to_expr(obj)}"
      end

      # .keys → .keys()
      if name == "keys" && args.empty? && obj
        return "#{to_expr(obj)}.keys()"
      end

      # .reject { |x| expr } → [x for x in list if not expr]
      if name == "reject" && obj && node.block
        block = node.block.not_nil!
        if block.args.size > 0
          var = block.args[0].name
          cond = to_expr(block.body)
          return "[#{var} for #{var} in #{to_expr(obj)} if not (#{cond})]"
        end
      end

      # .map { |x| expr } → [expr for x in list]
      if name == "map" && obj && node.block
        block = node.block.not_nil!
        if block.args.size > 0
          var = block.args[0].name
          expr = to_expr(block.body)
          return "[#{expr} for #{var} in #{to_expr(obj)}]"
        else
          # map without block args → [expr for _ in list]
          expr = to_expr(block.body)
          return "[#{expr} for _ in #{to_expr(obj)}]"
        end
      end

      # .join(sep) → sep.join(list)
      if name == "join" && args.size == 1 && obj
        return "#{to_expr(args[0])}.join(#{to_expr(obj)})"
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
        # Class.last → Class.last() (classmethod), collection.last → collection[-1]
        if obj.is_a?(Crystal::Path)
          return "#{to_expr(obj)}.last()"
        end
        return "#{to_expr(obj)}[-1]"
      end

      # bare new() inside a class → cls() (classmethod constructor)
      if name == "new" && !obj && @in_class
        return "cls(#{emit_args(args, named)})"
      end

      # .new → constructor: ClassName(...)
      if name == "new" && obj
        # Generic collection constructors → empty literals
        if obj.is_a?(Crystal::Generic) && args.empty? && named.nil?
          base = obj.name.to_s.gsub("Railcar::", "").gsub("::", "")
          case base
          when "Hash", "NamedTuple"     then return "{}"
          when "Array"                  then return "[]"
          when "Set"                    then return "set()"
          else
            # Other generics with no args → just call the base type
            return "#{crystal_type_to_python(base)}()"
          end
        end
        return "#{to_expr(obj)}(#{emit_args(args, named)})"
      end

      # .seconds / .minutes etc → just the number
      if (name == "seconds" || name == "minutes" || name == "hours") && args.empty? && obj
        return to_expr(obj)
      end

      # .to_set → set()
      if name == "to_set" && args.empty? && obj
        return "set(#{to_expr(obj)})"
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

      # Property access (type-checked or known framework properties)
      if args.empty? && named.nil? && !node.block && obj
        prop_name = name.rstrip('!').rstrip('?')
        if is_property?(node) || KNOWN_PROPERTIES.includes?(prop_name)
          return "#{to_expr(obj)}.#{prop_name}"
        end
      end

      # type(self).classvar → access class attribute without parens
      if args.empty? && named.nil? && !node.block && obj && @in_class
        stripped = name.rstrip('!').rstrip('?')
        if obj.is_a?(Crystal::Call) && obj.name == "class" && is_ivar_of_current_class?(stripped)
          return "#{to_expr(obj)}.#{stripped}"
        end
      end

      # Regular method call
      method_name = python_name(name)
      if obj
        obj_str = to_expr(obj)
        # Drop bare "Railcar" namespace — functions are at module level in Python
        if obj_str == "Railcar"
          "#{method_name}(#{emit_args(args, named)})"
        else
          "#{obj_str}.#{method_name}(#{emit_args(args, named)})"
        end
      elsif @in_class && @in_method && !PYTHON_BUILTINS.includes?(method_name) && !method_name.starts_with?("test_")
        prefix = @in_classmethod ? "cls" : "self"
        # Bare property access → self.name / cls.name without parens
        stripped_name = name.rstrip('!').rstrip('?')
        if args.empty? && named.nil? && is_ivar_of_current_class?(stripped_name)
          "#{prefix}.#{stripped_name}"
        else
          "#{prefix}.#{method_name}(#{emit_args(args, named)})"
        end
      else
        if args.empty? && named.nil? && PYTHON_BUILTINS.includes?(method_name)
          method_name  # Module or builtin reference, no parens
        else
          "#{method_name}(#{emit_args(args, named)})"
        end
      end
    end

    # ── Each → For ──

    private def each_to_nodes(call : Crystal::Call, block : Crystal::Block) : Array(PyAST::Node)
      vars = block.args.map(&.name).join(", ")
      vars = "_" if vars.empty?
      collection = to_expr(call.obj.not_nil!)
      # Crystal Hash#each yields (key, value) pairs — Python needs .items()
      if is_hash_type?(call.obj.not_nil!)
        collection = "#{collection}.items()"
      end
      body = body_to_nodes(block.body)
      [PyAST::For.new(vars, collection, body)] of PyAST::Node
    end

    private def is_hash_type?(node : Crystal::ASTNode) : Bool
      # Direct type on node
      if obj_type = node.type?
        return obj_type.to_s.starts_with?("Hash")
      end
      # Double splat parameter is always a dict
      if node.is_a?(Crystal::Var) && node.name == @current_double_splat
        return true
      end
      # Instance var — look up type in index
      if node.is_a?(Crystal::InstanceVar) && (cn = @current_class_name)
        if t = @type_index.ivar_type(cn, node.name)
          return @type_index.is_hash_type?(t)
        end
      end
      # Call to a getter that returns a Hash (e.g., attributes)
      if node.is_a?(Crystal::Call) && node.args.empty? && (cn = @current_class_name)
        if t = @type_index.ivar_type(cn, "@#{node.name}")
          return @type_index.is_hash_type?(t)
        end
      end
      false
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

    # Check if a constant name is defined on the current class (vs module-level)
    private def is_class_constant?(name : String) : Bool
      if ct = @current_class_type
        # Check if the class body defines this constant
        begin
          ct.types.has_key?(name)
        rescue
          false
        end
      else
        false
      end
    end

    private def is_operator?(name : String) : Bool
      %w[+ - * / % == != < > <= >= && || & | ^ << >> in is not_in].includes?(name) || name == "is not" || name == "not in"
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
               when "new"        then @in_class ? "__init__" : "new"
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
      name = node.name.rstrip('!').rstrip('?')
      ctx = "#{@current_class_name || "?"}#is_property?(#{name})"
      do_debug = debug?(ctx) || debug?(name)

      # Check obj's type directly (works when typed nodes are available)
      if obj_type = obj.type?
        obj_type_name = obj_type.to_s.rstrip('+')
        if @type_index.has_instance_var?(obj_type_name, "@#{name}")
          debug "#{ctx}: found ivar @#{name} on obj type #{obj_type_name}" if do_debug
          return true
        end
        if @type_index.has_class_var?(obj_type_name, "@@#{name}")
          debug "#{ctx}: found cvar @@#{name} on obj type #{obj_type_name}" if do_debug
          return true
        end
      end

      # Check current class's ivars and cvars
      if cn = @current_class_name
        if @type_index.has_instance_var?(cn, "@#{name}")
          debug "#{ctx}: found ivar @#{name} on #{cn}" if do_debug
          return true
        end
        if @type_index.has_class_var?(cn, "@@#{name}")
          debug "#{ctx}: found cvar @@#{name} on #{cn}" if do_debug
          return true
        end
      end

      # obj.class.method — resolve obj's type and check its class vars
      if obj.is_a?(Crystal::Call) && obj.name == "class"
        if inner_obj = obj.obj
          resolved = resolve_type_name(inner_obj)
          debug "#{ctx}: .class chain, inner=#{inner_obj.class.name.split("::").last}(#{inner_obj}), resolved=#{resolved}" if do_debug
          if resolved
            if @type_index.has_class_var?(resolved, "@@#{name}")
              debug "#{ctx}: found cvar @@#{name} on #{resolved} via .class" if do_debug
              return true
            end
            if @type_index.has_instance_var?(resolved, "@#{name}")
              debug "#{ctx}: found ivar @#{name} on #{resolved} via .class" if do_debug
              return true
            end
          end
        end
      end

      # Fallback: check model_columns for untyped variables (views, tests, helpers)
      if !@model_columns.empty?
        model_name = infer_model_name(obj)
        if model_name
          if props = @model_columns[model_name]?
            if props.includes?(name)
              debug "#{ctx}: found model column #{name} on #{model_name}" if do_debug
              return true
            end
          end
        end
      end

      debug "#{ctx}: NOT a property (cn=#{@current_class_name})" if do_debug
      false
    end

    # Infer model name from an expression for model_columns lookup
    private def infer_model_name(node : Crystal::ASTNode) : String?
      case node
      when Crystal::Var
        # article → Article
        node.name.capitalize.gsub(/_([a-z])/) { $1.upcase }
      when Crystal::Call
        if node.obj.is_a?(Crystal::Path)
          # Article.last(), Article.find() → Article
          node.obj.as(Crystal::Path).names.last
        elsif node.obj
          # chain: something.method() → infer from inner
          infer_model_name(node.obj.not_nil!)
        else
          nil
        end
      else
        nil
      end
    end

    # Resolve the type name of an expression using the type index
    private def resolve_type_name(node : Crystal::ASTNode) : String?
      result = nil
      # Direct type on node
      if t = node.type?
        result = t.to_s
      end
      # Instance var — look up in current class
      if result.nil? && node.is_a?(Crystal::InstanceVar) && (cn = @current_class_name)
        result = @type_index.ivar_type(cn, node.name)
      end
      # Var named "self" — it's the current class
      if result.nil? && node.is_a?(Crystal::Var) && node.name == "self"
        result = @current_class_name
      end
      # Strip Crystal union suffix (+) for index lookup
      result.try(&.rstrip('+'))
    end

    private def is_ivar_of_current_class?(name : String) : Bool
      if cn = @current_class_name
        return true if @type_index.has_instance_var?(cn, "@#{name}")
        return true if @type_index.has_class_var?(cn, "@@#{name}")
      end
      false
    end

    private def find_type(names : Array(String)) : Crystal::Type?
      # Try Railcar::ClassName first, then just ClassName
      begin
        type = @program.types["Railcar"]?
        if type
          names.each do |n|
            if type.responds_to?(:types)
              type = type.types[n]?
            else
              return nil
            end
          end
          return type
        end
      rescue
      end
      nil
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
        .gsub("SQLite3::Exception", "sqlite3.OperationalError")
        .gsub("DB::Database", "Any")
        .gsub("DB::ResultSet", "Any")
        .gsub("HTTP::Server::Context", "Any")
        .gsub("HTTP::Server::Response", "Any")
        .gsub("HTTP::Request", "Any")
        # Remove :: and Railcar namespace
        .gsub("Railcar::", "")
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
        .gsub(/NamedTuple\([^)]*\)/, "dict")
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
