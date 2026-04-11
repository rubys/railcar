# Crystal AST Builder — concise API for programmatic AST construction.
#
# Reduces verbosity when building Crystal AST nodes in filters,
# code generators, and transpilers.
#
# Usage:
#   include CrystalAST::Builder
#
#   node = call(var("response"), "status_code=", [int(302)])
#   node = assign(var("x"), str("hello"))
#   node = if_(call(var("article"), "save"), redirect, render)

require "compiler/crystal/syntax"

module CrystalAST
  module Builder
    # --- Literals ---

    def str(value : String) : Crystal::StringLiteral
      Crystal::StringLiteral.new(value)
    end

    def int(value : Int) : Crystal::NumberLiteral
      Crystal::NumberLiteral.new(value.to_s)
    end

    def num(value : String) : Crystal::NumberLiteral
      Crystal::NumberLiteral.new(value)
    end

    def bool(value : Bool) : Crystal::BoolLiteral
      Crystal::BoolLiteral.new(value)
    end

    def nil_ : Crystal::NilLiteral
      Crystal::NilLiteral.new
    end

    def sym(value : String) : Crystal::SymbolLiteral
      Crystal::SymbolLiteral.new(value)
    end

    # --- Variables and paths ---

    def var(name : String) : Crystal::Var
      Crystal::Var.new(name)
    end

    def ivar(name : String) : Crystal::InstanceVar
      Crystal::InstanceVar.new(name.starts_with?('@') ? name : "@#{name}")
    end

    def path(name : String) : Crystal::Path
      Crystal::Path.new(name)
    end

    def path(names : Array(String)) : Crystal::Path
      Crystal::Path.new(names)
    end

    # --- Calls ---

    def call(receiver : Crystal::ASTNode?, name : String,
             args : Array(Crystal::ASTNode) = [] of Crystal::ASTNode,
             named_args : Array(Crystal::NamedArgument)? = nil,
             block : Crystal::Block? = nil) : Crystal::Call
      Crystal::Call.new(receiver, name, args, named_args: named_args, block: block)
    end

    # Call with no receiver: `method(args)`
    def call(name : String,
             args : Array(Crystal::ASTNode) = [] of Crystal::ASTNode,
             named_args : Array(Crystal::NamedArgument)? = nil) : Crystal::Call
      Crystal::Call.new(nil, name, args, named_args: named_args)
    end

    # Method call on receiver: `obj.method`
    def call(receiver : Crystal::ASTNode, name : String) : Crystal::Call
      Crystal::Call.new(receiver, name)
    end

    # --- Named arguments ---

    def named(name : String, value : Crystal::ASTNode) : Crystal::NamedArgument
      Crystal::NamedArgument.new(name, value)
    end

    def named(name : String, value : String) : Crystal::NamedArgument
      Crystal::NamedArgument.new(name, str(value))
    end

    # --- Assignments ---

    def assign(target : Crystal::ASTNode, value : Crystal::ASTNode) : Crystal::Assign
      Crystal::Assign.new(target, value)
    end

    def assign(name : String, value : Crystal::ASTNode) : Crystal::Assign
      Crystal::Assign.new(var(name), value)
    end

    def op_assign(target : Crystal::ASTNode, op : String, value : Crystal::ASTNode) : Crystal::OpAssign
      Crystal::OpAssign.new(target, op, value)
    end

    # --- Control flow ---

    def if_(cond : Crystal::ASTNode, then_body : Crystal::ASTNode,
            else_body : Crystal::ASTNode? = nil) : Crystal::If
      Crystal::If.new(cond, then_body, else_body)
    end

    def return_(exp : Crystal::ASTNode? = nil) : Crystal::Return
      Crystal::Return.new(exp)
    end

    # --- Blocks ---

    def block(args : Array(String) = [] of String,
              body : Crystal::ASTNode = Crystal::Nop.new) : Crystal::Block
      Crystal::Block.new(
        args: args.map { |a| Crystal::Var.new(a) },
        body: body
      )
    end

    # --- Collections ---

    def array(elements : Array(Crystal::ASTNode)) : Crystal::ArrayLiteral
      Crystal::ArrayLiteral.new(elements)
    end

    def hash(entries : Array(Tuple(Crystal::ASTNode, Crystal::ASTNode))) : Crystal::HashLiteral
      Crystal::HashLiteral.new(
        entries.map { |k, v| Crystal::HashLiteral::Entry.new(k, v) }
      )
    end

    def named_tuple(entries : Array(Tuple(String, Crystal::ASTNode))) : Crystal::NamedTupleLiteral
      Crystal::NamedTupleLiteral.new(
        entries.map { |k, v| Crystal::NamedTupleLiteral::Entry.new(k, v) }
      )
    end

    # --- Definitions ---

    def def_(name : String, args : Array(Crystal::Arg) = [] of Crystal::Arg,
             body : Crystal::ASTNode = Crystal::Nop.new,
             return_type : Crystal::ASTNode? = nil) : Crystal::Def
      d = Crystal::Def.new(name, args, body: body)
      d.return_type = return_type if return_type
      d
    end

    def arg(name : String, default_value : Crystal::ASTNode? = nil,
            restriction : Crystal::ASTNode? = nil) : Crystal::Arg
      Crystal::Arg.new(name, default_value: default_value, restriction: restriction)
    end

    # --- Expressions ---

    def exprs(nodes : Array(Crystal::ASTNode)) : Crystal::Expressions
      Crystal::Expressions.new(nodes)
    end

    def nop : Crystal::Nop
      Crystal::Nop.new
    end

    # --- Compound helpers ---

    # _buf += "string"
    def buf_str(s : String) : Crystal::OpAssign
      op_assign(var("_buf"), "+", str(s))
    end

    # _buf.append= expr.to_s
    def buf_append(expr : Crystal::ASTNode) : Crystal::Call
      call(var("_buf"), "append=", [call(expr, "to_s")] of Crystal::ASTNode)
    end

    # _buf += "before" + str(expr) + "after"
    # Emitted as three statements: buf_str + buf_append + buf_str
    def buf_concat(before : String, expr : Crystal::ASTNode, after : String) : Crystal::Expressions
      exprs([buf_str(before), buf_append(expr), buf_str(after)] of Crystal::ASTNode)
    end
  end
end
