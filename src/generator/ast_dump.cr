# AstDump — structural pretty-printer for Crystal::ASTNode.
#
# Crystal's standard AST APIs (to_s, inspect) don't give a readable
# structural view: to_s emits re-parseable Crystal source (lossy for
# debugging — named_args hidden, types erased), and inspect dumps memory
# addresses. This walks a Crystal::ASTNode explicitly and emits an
# s-expression-ish form that's useful when developing filters and
# emitters, and especially when working with post-semantic typed ASTs.
#
# Crystal AST nodes don't share a uniform children accessor (unlike the
# Ruby parser gem), so each common node type has an explicit handler.
# Unknown types fall through to a generic "(ClassName ...)" form with
# the original to_s output for reference.
#
# Usage:
#   puts AstDump.dump(ast)                             # structural
#   puts AstDump.dump(typed_ast, with_types: true)     # with :: Type
#   puts AstDump.dump(ast, with_locations: true)       # with @line:col

require "compiler/crystal/syntax"
# semantic is required so `node.type?` resolves — post-semantic annotations
# are a core use case of AstDump.
require "../semantic"

module Railcar
  class AstDump
    getter with_types : Bool
    getter with_locations : Bool

    def self.dump(node : Crystal::ASTNode?, with_types : Bool = false,
                  with_locations : Bool = false) : String
      new(with_types, with_locations).emit(node, 0)
    end

    def initialize(@with_types = false, @with_locations = false)
    end

    def emit(node : Crystal::ASTNode?, indent : Int32) : String
      return pad(indent, "nil") if node.nil?

      body = emit_node(node, indent)
      # Optionally append type and location annotations to the first line
      suffix = String.build do |io|
        if @with_types && (t = node.type?)
          io << " :: " << t.to_s
        end
        if @with_locations && (loc = node.location)
          io << " @" << loc.line_number << ":" << loc.column_number
        end
      end
      return body if suffix.empty?
      # Put suffix at end of the first (opening) line so it stays readable
      if idx = body.index('\n')
        body[0...idx] + suffix + body[idx..]
      else
        body + suffix
      end
    end

    private def pad(indent : Int32, text : String) : String
      "  " * indent + text
    end

    private def emit_node(node : Crystal::ASTNode, indent : Int32) : String
      case node
      when Crystal::Nop
        pad(indent, "(Nop)")
      when Crystal::NilLiteral
        pad(indent, "(NilLiteral)")
      when Crystal::BoolLiteral
        pad(indent, "(BoolLiteral #{node.value})")
      when Crystal::NumberLiteral
        pad(indent, "(NumberLiteral #{node.value} #{node.kind})")
      when Crystal::StringLiteral
        pad(indent, "(StringLiteral #{node.value.inspect})")
      when Crystal::SymbolLiteral
        pad(indent, "(SymbolLiteral :#{node.value})")
      when Crystal::CharLiteral
        pad(indent, "(CharLiteral #{node.value.inspect})")
      when Crystal::Var
        pad(indent, "(Var #{node.name})")
      when Crystal::InstanceVar
        pad(indent, "(InstanceVar #{node.name})")
      when Crystal::ClassVar
        pad(indent, "(ClassVar #{node.name})")
      when Crystal::Global
        pad(indent, "(Global #{node.name})")
      when Crystal::Underscore
        pad(indent, "(Underscore)")
      when Crystal::Self
        pad(indent, "(Self)")
      when Crystal::Path
        pad(indent, "(Path #{node.names.join("::")}#{node.global? ? " :global" : ""})")
      when Crystal::StringInterpolation
        emit_children(indent, "StringInterpolation", node.expressions)
      when Crystal::ArrayLiteral
        emit_children(indent, "ArrayLiteral", node.elements)
      when Crystal::TupleLiteral
        emit_children(indent, "TupleLiteral", node.elements)
      when Crystal::HashLiteral
        emit_hash(indent, node)
      when Crystal::NamedTupleLiteral
        emit_named_tuple(indent, node)
      when Crystal::RangeLiteral
        emit_range(indent, node)
      when Crystal::RegexLiteral
        pad(indent, "(RegexLiteral)") + "\n" + emit(node.value, indent + 1)
      when Crystal::Expressions
        emit_children(indent, "Expressions", node.expressions)
      when Crystal::Assign
        emit_labeled(indent, "Assign", {"target" => node.target, "value" => node.value})
      when Crystal::OpAssign
        pad(indent, "(OpAssign op=#{node.op}") + "\n" +
          emit(node.target, indent + 1) + "\n" +
          emit(node.value, indent + 1) + ")"
      when Crystal::MultiAssign
        s = String.build do |io|
          io << pad(indent, "(MultiAssign\n")
          io << pad(indent + 1, "targets:\n")
          node.targets.each_with_index do |t, i|
            io << emit(t, indent + 2)
            io << "\n" if i < node.targets.size - 1
          end
          io << "\n" << pad(indent + 1, "values:\n")
          node.values.each_with_index do |v, i|
            io << emit(v, indent + 2)
            io << "\n" if i < node.values.size - 1
          end
          io << ")"
        end
        s
      when Crystal::Call
        emit_call(indent, node)
      when Crystal::Block
        emit_block(indent, node)
      when Crystal::Def
        emit_def(indent, node)
      when Crystal::Arg
        emit_arg(indent, node)
      when Crystal::Splat
        pad(indent, "(Splat)") + "\n" + emit(node.exp, indent + 1)
      when Crystal::DoubleSplat
        pad(indent, "(DoubleSplat)") + "\n" + emit(node.exp, indent + 1)
      when Crystal::If
        emit_if(indent, node)
      when Crystal::Unless
        emit_conditional(indent, "Unless", node.cond, node.then, node.else)
      when Crystal::While
        emit_conditional(indent, "While", node.cond, node.body, nil)
      when Crystal::Until
        emit_conditional(indent, "Until", node.cond, node.body, nil)
      when Crystal::Case
        emit_case(indent, node)
      when Crystal::Return
        body = node.exp ? "\n" + emit(node.exp, indent + 1) : ""
        pad(indent, "(Return)") + body
      when Crystal::Yield
        emit_children(indent, "Yield", node.exps)
      when Crystal::Break
        body = node.exp ? "\n" + emit(node.exp, indent + 1) : ""
        pad(indent, "(Break)") + body
      when Crystal::Next
        body = node.exp ? "\n" + emit(node.exp, indent + 1) : ""
        pad(indent, "(Next)") + body
      when Crystal::Cast
        pad(indent, "(Cast)") + "\n" +
          emit(node.obj, indent + 1) + "\n" +
          emit(node.to, indent + 1)
      when Crystal::NilableCast
        pad(indent, "(NilableCast)") + "\n" +
          emit(node.obj, indent + 1) + "\n" +
          emit(node.to, indent + 1)
      when Crystal::IsA
        pad(indent, "(IsA)") + "\n" +
          emit(node.obj, indent + 1) + "\n" +
          emit(node.const, indent + 1)
      when Crystal::Not
        pad(indent, "(Not)") + "\n" + emit(node.exp, indent + 1)
      when Crystal::And
        pad(indent, "(And)") + "\n" +
          emit(node.left, indent + 1) + "\n" +
          emit(node.right, indent + 1)
      when Crystal::Or
        pad(indent, "(Or)") + "\n" +
          emit(node.left, indent + 1) + "\n" +
          emit(node.right, indent + 1)
      when Crystal::ClassDef
        emit_classdef(indent, node)
      when Crystal::ModuleDef
        pad(indent, "(ModuleDef #{node.name})") + "\n" + emit(node.body, indent + 1)
      when Crystal::EnumDef
        emit_children(indent, "EnumDef #{node.name}", node.members)
      when Crystal::Include
        pad(indent, "(Include)") + "\n" + emit(node.name, indent + 1)
      when Crystal::Extend
        pad(indent, "(Extend)") + "\n" + emit(node.name, indent + 1)
      when Crystal::Require
        pad(indent, "(Require #{node.string.inspect})")
      when Crystal::TypeDeclaration
        s = pad(indent, "(TypeDeclaration)") + "\n" +
          emit(node.var, indent + 1) + "\n" +
          emit(node.declared_type, indent + 1)
        if val = node.value
          s += "\n" + emit(val, indent + 1)
        end
        s
      when Crystal::Annotation
        pad(indent, "(Annotation)") + "\n" + emit(node.path, indent + 1)
      when Crystal::Generic
        emit_children(indent, "Generic #{node.name}", node.type_vars.map(&.as(Crystal::ASTNode)))
      when Crystal::Union
        emit_children(indent, "Union", node.types.map(&.as(Crystal::ASTNode)))
      when Crystal::ProcLiteral
        pad(indent, "(ProcLiteral)") + "\n" + emit(node.def, indent + 1)
      when Crystal::ExceptionHandler
        emit_exception_handler(indent, node)
      else
        # Fallback: class name plus to_s for context
        pad(indent, "(#{node.class.name.split("::").last} «#{short_to_s(node)}»)")
      end
    end

    private def emit_children(indent : Int32, tag : String, children : Array) : String
      if children.empty?
        return pad(indent, "(#{tag})")
      end
      String.build do |io|
        io << pad(indent, "(#{tag}")
        children.each do |child|
          io << "\n" << emit(child, indent + 1)
        end
        io << ")"
      end
    end

    private def emit_labeled(indent : Int32, tag : String,
                             children : Hash(String, Crystal::ASTNode?)) : String
      String.build do |io|
        io << pad(indent, "(#{tag}")
        children.each do |label, child|
          io << "\n" << pad(indent + 1, "#{label}:") << "\n" << emit(child, indent + 2)
        end
        io << ")"
      end
    end

    private def emit_hash(indent : Int32, node : Crystal::HashLiteral) : String
      if node.entries.empty?
        return pad(indent, "(HashLiteral)")
      end
      String.build do |io|
        io << pad(indent, "(HashLiteral")
        node.entries.each do |entry|
          io << "\n" << pad(indent + 1, "(Entry")
          io << "\n" << emit(entry.key, indent + 2)
          io << "\n" << emit(entry.value, indent + 2) << ")"
        end
        io << ")"
      end
    end

    private def emit_named_tuple(indent : Int32, node : Crystal::NamedTupleLiteral) : String
      if node.entries.empty?
        return pad(indent, "(NamedTupleLiteral)")
      end
      String.build do |io|
        io << pad(indent, "(NamedTupleLiteral")
        node.entries.each do |entry|
          io << "\n" << pad(indent + 1, "(Entry :key #{entry.key}")
          io << "\n" << emit(entry.value, indent + 2) << ")"
        end
        io << ")"
      end
    end

    private def emit_range(indent : Int32, node : Crystal::RangeLiteral) : String
      tag = node.exclusive? ? "RangeLiteral (exclusive)" : "RangeLiteral"
      pad(indent, "(#{tag}") + "\n" +
        emit(node.from, indent + 1) + "\n" +
        emit(node.to, indent + 1) + ")"
    end

    private def emit_call(indent : Int32, node : Crystal::Call) : String
      String.build do |io|
        io << pad(indent, "(Call ") << node.name.inspect
        io << ")" if !node.obj && node.args.empty? && node.named_args.nil? && node.block.nil?
        next if !node.obj && node.args.empty? && node.named_args.nil? && node.block.nil?
        if obj = node.obj
          io << "\n" << pad(indent + 1, "obj:") << "\n" << emit(obj, indent + 2)
        end
        unless node.args.empty?
          io << "\n" << pad(indent + 1, "args:")
          node.args.each { |a| io << "\n" << emit(a, indent + 2) }
        end
        if named = node.named_args
          io << "\n" << pad(indent + 1, "named_args:")
          named.each do |na|
            io << "\n" << pad(indent + 2, "(NamedArg #{na.name}")
            io << "\n" << emit(na.value, indent + 3) << ")"
          end
        end
        if block = node.block
          io << "\n" << pad(indent + 1, "block:") << "\n" << emit(block, indent + 2)
        end
        if block_arg = node.block_arg
          io << "\n" << pad(indent + 1, "block_arg:") << "\n" << emit(block_arg, indent + 2)
        end
        io << ")"
      end
    end

    private def emit_block(indent : Int32, node : Crystal::Block) : String
      String.build do |io|
        io << pad(indent, "(Block")
        unless node.args.empty?
          io << "\n" << pad(indent + 1, "args: [" + node.args.map(&.name).join(", ") + "]")
        end
        io << "\n" << emit(node.body, indent + 1) << ")"
      end
    end

    private def emit_def(indent : Int32, node : Crystal::Def) : String
      String.build do |io|
        io << pad(indent, "(Def #{node.name}")
        unless node.args.empty?
          io << "\n" << pad(indent + 1, "args:")
          node.args.each { |a| io << "\n" << emit(a, indent + 2) }
        end
        if rt = node.return_type
          io << "\n" << pad(indent + 1, "return_type:") << "\n" << emit(rt, indent + 2)
        end
        io << "\n" << pad(indent + 1, "body:") << "\n" << emit(node.body, indent + 2)
        io << ")"
      end
    end

    private def emit_arg(indent : Int32, node : Crystal::Arg) : String
      tag = "Arg #{node.name}"
      String.build do |io|
        io << pad(indent, "(#{tag}")
        if rt = node.restriction
          io << "\n" << pad(indent + 1, "restriction:") << "\n" << emit(rt, indent + 2)
        end
        if dv = node.default_value
          io << "\n" << pad(indent + 1, "default_value:") << "\n" << emit(dv, indent + 2)
        end
        io << ")"
      end
    end

    private def emit_if(indent : Int32, node : Crystal::If) : String
      String.build do |io|
        io << pad(indent, "(If")
        io << "\n" << pad(indent + 1, "cond:") << "\n" << emit(node.cond, indent + 2)
        io << "\n" << pad(indent + 1, "then:") << "\n" << emit(node.then, indent + 2)
        unless node.else.is_a?(Crystal::Nop)
          io << "\n" << pad(indent + 1, "else:") << "\n" << emit(node.else, indent + 2)
        end
        io << ")"
      end
    end

    private def emit_conditional(indent : Int32, tag : String, cond : Crystal::ASTNode,
                                 body : Crystal::ASTNode, else_branch : Crystal::ASTNode?) : String
      String.build do |io|
        io << pad(indent, "(#{tag}")
        io << "\n" << pad(indent + 1, "cond:") << "\n" << emit(cond, indent + 2)
        io << "\n" << pad(indent + 1, "body:") << "\n" << emit(body, indent + 2)
        if else_branch && !else_branch.is_a?(Crystal::Nop)
          io << "\n" << pad(indent + 1, "else:") << "\n" << emit(else_branch, indent + 2)
        end
        io << ")"
      end
    end

    private def emit_case(indent : Int32, node : Crystal::Case) : String
      String.build do |io|
        io << pad(indent, "(Case")
        if cond = node.cond
          io << "\n" << pad(indent + 1, "cond:") << "\n" << emit(cond, indent + 2)
        end
        node.whens.each do |when_node|
          io << "\n" << pad(indent + 1, "(When")
          io << "\n" << pad(indent + 2, "conds:")
          when_node.conds.each { |c| io << "\n" << emit(c, indent + 3) }
          io << "\n" << pad(indent + 2, "body:") << "\n" << emit(when_node.body, indent + 3)
          io << ")"
        end
        if el = node.else
          io << "\n" << pad(indent + 1, "else:") << "\n" << emit(el, indent + 2)
        end
        io << ")"
      end
    end

    private def emit_classdef(indent : Int32, node : Crystal::ClassDef) : String
      String.build do |io|
        io << pad(indent, "(ClassDef #{node.name}")
        if sc = node.superclass
          io << "\n" << pad(indent + 1, "superclass:") << "\n" << emit(sc, indent + 2)
        end
        io << "\n" << emit(node.body, indent + 1)
        io << ")"
      end
    end

    private def emit_exception_handler(indent : Int32, node : Crystal::ExceptionHandler) : String
      String.build do |io|
        io << pad(indent, "(ExceptionHandler")
        io << "\n" << pad(indent + 1, "body:") << "\n" << emit(node.body, indent + 2)
        if rescues = node.rescues
          rescues.each do |rescue_node|
            io << "\n" << pad(indent + 1, "(Rescue")
            io << "\n" << emit(rescue_node.body, indent + 2) << ")"
          end
        end
        if el = node.else
          io << "\n" << pad(indent + 1, "else:") << "\n" << emit(el, indent + 2)
        end
        if ensure_node = node.ensure
          io << "\n" << pad(indent + 1, "ensure:") << "\n" << emit(ensure_node, indent + 2)
        end
        io << ")"
      end
    end

    # Single-line abbreviated to_s for the fallback form.
    private def short_to_s(node : Crystal::ASTNode) : String
      s = node.to_s.gsub('\n', ' ').gsub(/\s+/, ' ').strip
      s.size > 80 ? s[0, 77] + "..." : s
    end
  end
end
