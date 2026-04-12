# Minimal Python AST — just enough to represent the constructs cr2py emits.
# The serializer handles all indentation.

module PyAST
  abstract class Node
  end

  # _buf += "literal text"
  class BufLiteral < Node
    getter text : String
    def initialize(@text); end
  end

  # _buf += str(expr)
  class BufAppend < Node
    getter expr : String
    def initialize(@expr); end
  end

  # if condition: body [elif ...] [else: else_body]
  class If < Node
    getter cond : String
    getter body : Array(Node)
    getter else_body : Array(Node)?
    def initialize(@cond, @body, @else_body = nil); end
  end

  # for var in collection: body
  class For < Node
    getter var : String
    getter collection : String
    getter body : Array(Node)
    def initialize(@var, @collection, @body); end
  end

  # while condition: body
  class While < Node
    getter cond : String
    getter body : Array(Node)
    def initialize(@cond, @body); end
  end

  # variable = value
  class Assign < Node
    getter target : String
    getter value : String
    def initialize(@target, @value); end
  end

  # expression as a statement
  class Statement < Node
    getter code : String
    def initialize(@code); end
  end

  # return expr
  class Return < Node
    getter expr : String
    def initialize(@expr); end
  end

  # def name(args): body
  class Func < Node
    getter name : String
    getter args : Array(String)
    getter body : Array(Node)
    getter return_type : String?
    getter decorators : Array(String)
    def initialize(@name, @args, @body, @return_type = nil, @decorators = [] of String); end
  end

  # async def name(args): body
  class AsyncFunc < Node
    getter name : String
    getter args : Array(String)
    getter body : Array(Node)
    def initialize(@name, @args, @body); end
  end

  # class Name(Base): body
  class Class < Node
    getter name : String
    getter superclass : String?
    getter body : Array(Node)
    def initialize(@name, @superclass, @body); end
  end

  # Raw Python line (for imports, class declarations, etc.)
  class Raw < Node
    getter code : String
    def initialize(@code); end
  end

  # Blank line
  class Blank < Node
    def initialize; end
  end

  # A module/file — collection of top-level nodes
  class Module < Node
    getter nodes : Array(Node)
    def initialize(@nodes); end
  end

  # --- Serializer ---

  class Serializer
    def serialize(mod : Module) : String
      io = IO::Memory.new
      mod.nodes.each do |node|
        emit(node, io, 0)
      end
      io.to_s
    end

    private def emit(node : Node, io : IO, depth : Int32)
      indent = "    " * depth

      case node
      when Raw
        io << indent << node.code << "\n"

      when Blank
        io << "\n"

      when Class
        io << indent << "class " << node.name
        if sc = node.superclass
          io << "(" << sc << ")"
        end
        io << ":\n"
        emit_body(node.body, io, depth + 1)
        io << "\n"

      when Func
        node.decorators.each { |d| io << indent << "@" << d << "\n" }
        io << indent << "def " << node.name << "(" << node.args.join(", ") << ")"
        if rt = node.return_type
          io << " -> " << rt
        end
        io << ":\n"
        emit_body(node.body, io, depth + 1)
        io << "\n"

      when AsyncFunc
        io << indent << "async def " << node.name << "(" << node.args.join(", ") << "):\n"
        emit_body(node.body, io, depth + 1)
        io << "\n"

      when BufLiteral
        text = node.text
        unless text.empty?
          io << indent << "_buf += " << python_string(text) << "\n"
        end

      when BufAppend
        io << indent << "_buf += str(" << node.expr << ")\n"

      when If
        io << indent << "if " << node.cond << ":\n"
        emit_body(node.body, io, depth + 1)
        if else_body = node.else_body
          # elif: else body is a single If node
          if else_body.size == 1 && else_body[0].is_a?(If)
            io << indent << "el"
            emit(else_body[0], io, depth)
          else
            io << indent << "else:\n"
            emit_body(else_body, io, depth + 1)
          end
        end

      when While
        io << indent << "while " << node.cond << ":\n"
        emit_body(node.body, io, depth + 1)

      when For
        io << indent << "for " << node.var << " in " << node.collection << ":\n"
        emit_body(node.body, io, depth + 1)

      when Assign
        io << indent << node.target << " = " << node.value << "\n"

      when Statement
        io << indent << node.code << "\n"

      when Return
        io << indent << "return " << node.expr << "\n"
      end
    end

    private def emit_body(nodes : Array(Node), io : IO, depth : Int32)
      if nodes.empty?
        io << "    " * depth << "pass\n"
      else
        nodes.each { |n| emit(n, io, depth) }
      end
    end

    private def python_string(s : String) : String
      if s.includes?('\n') || s.includes?('"')
        "'''#{s.gsub("\\", "\\\\").gsub("'''", "\\'\\'\\'") }'''"
      else
        s.inspect
      end
    end
  end
end
