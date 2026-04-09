# Shared Prism AST → Crystal AST/expression conversion.
#
# Two-level API:
#   map_node(prism_node) → Crystal::ASTNode  (AST-level, for structured output)
#   expr(prism_node)     → String            (string-level, backward compatible)
#
# Consumers include this module and override convert_call (string-level) or
# map_call (AST-level) for domain-specific transformations.

require "compiler/crystal/syntax"
require "compiler/crystal/formatter"
require "../prism/bindings"
require "../prism/deserializer"

# Enable to_s on programmatically constructed Crystal AST trees.
# Crystal's ToSVisitor uses method overloading which requires concrete types.
# This overload adds runtime dispatch for the abstract ASTNode type,
# allowing trees with abstract-typed children to serialize correctly.
class Crystal::ToSVisitor
  def visit(node : Crystal::ASTNode)
    node.accept(self)
    false
  end
end

# Extend Crystal::ASTNode with a to_s that works for programmatically
# constructed trees (avoids visitor dispatch requiring concrete types)
class Crystal::ASTNode
  def to_crystal_s : String
    io = IO::Memory.new
    visitor = Crystal::ToSVisitor.new(io)
    self.accept(visitor)
    io.to_s
  end
end

module Railcar
  module CrystalExpr
    # --- AST-level API ---

    # Convert a Prism AST node to a Crystal AST node.
    def map_node(node : Prism::Node) : Crystal::ASTNode
      case node
      when Prism::CallNode
        map_call(node)
      when Prism::InstanceVariableReadNode
        Crystal::Var.new(node.name.lchop("@"))
      when Prism::InstanceVariableWriteNode
        Crystal::Assign.new(
          Crystal::Var.new(node.name.lchop("@")),
          map_node(node.value)
        )
      when Prism::LocalVariableReadNode
        Crystal::Var.new(node.name)
      when Prism::LocalVariableWriteNode
        Crystal::Assign.new(
          Crystal::Var.new(node.name),
          map_node(node.value)
        )
      when Prism::StringNode
        Crystal::StringLiteral.new(node.value)
      when Prism::SymbolNode
        Crystal::SymbolLiteral.new(node.value)
      when Prism::IntegerNode
        Crystal::NumberLiteral.new(node.value.to_s)
      when Prism::TrueNode
        Crystal::BoolLiteral.new(true)
      when Prism::FalseNode
        Crystal::BoolLiteral.new(false)
      when Prism::NilNode
        Crystal::NilLiteral.new
      when Prism::SelfNode
        Crystal::Var.new("self")
      when Prism::ConstantReadNode
        Crystal::Path.new(["Railcar", node.name])
      when Prism::ConstantPathNode
        Crystal::Path.new(node.full_path.split("::"))
      when Prism::ArrayNode
        Crystal::ArrayLiteral.new(node.elements.map { |e| map_node(e) })
      when Prism::HashNode
        map_hash(node.elements)
      when Prism::KeywordHashNode
        map_hash(node.elements)
      when Prism::ParenthesesNode
        body = node.body
        body ? map_node(body) : Crystal::Nop.new
      when Prism::StatementsNode
        if node.body.size == 1
          map_node(node.body[0])
        else
          Crystal::Expressions.new(node.body.map { |s| map_node(s) })
        end
      when Prism::IfNode
        map_if(node)
      else
        Crystal::Nop.new
      end
    end

    # Default call conversion: generic Crystal::Call.
    # Override in consumers for domain-specific AST transformations.
    def map_call(call : Prism::CallNode) : Crystal::ASTNode
      generic_call_node(call)
    end

    # Generic method call as Crystal AST node
    def generic_call_node(call : Prism::CallNode) : Crystal::Call
      receiver = call.receiver
      crystal_recv = receiver ? map_node(receiver).as(Crystal::ASTNode) : nil
      crystal_args = call.arg_nodes.map { |a| map_node(a) }
      Crystal::Call.new(crystal_recv, call.name, crystal_args)
    end

    # Convert hash elements to Crystal::HashLiteral
    def map_hash(elements : Array(Prism::Node)) : Crystal::ASTNode
      entries = elements.compact_map do |el|
        next nil unless el.is_a?(Prism::AssocNode)
        Crystal::HashLiteral::Entry.new(map_node(el.key), map_node(el.value_node))
      end
      Crystal::HashLiteral.new(entries)
    end

    # Map if/else
    def map_if(node : Prism::IfNode) : Crystal::If
      cond = map_node(node.condition)
      then_body = node.then_body ? map_node(node.then_body.not_nil!) : Crystal::Nop.new
      else_body = if ec = node.else_clause
                    case ec
                    when Prism::ElseNode
                      ec.body ? map_node(ec.body.not_nil!) : Crystal::Nop.new
                    else
                      map_node(ec)
                    end
                  else
                    nil
                  end
      Crystal::If.new(cond, then_body, else_body)
    end

    # --- String-level API (backward compatible) ---
    # Consumers currently override convert_call for domain-specific string output.
    # As consumers migrate to map_call, these string methods will thin out.

    # Convert a Prism AST node to a Crystal expression string.
    # Routes calls through convert_call so consumer overrides work.
    def expr(node : Prism::Node) : String
      case node
      when Prism::CallNode
        convert_call(node)
      else
        map_node(node).to_s
      end
    end

    # String-level call conversion. Override in consumers for
    # domain-specific string output. Will be replaced by map_call.
    def convert_call(call : Prism::CallNode) : String
      generic_call(call)
    end

    # String-level generic call
    def generic_call(call : Prism::CallNode) : String
      generic_call_node(call).to_s
    end

    # Convert hash/keyword hash elements to Crystal syntax string
    def hash_pairs(elements : Array(Prism::Node)) : String
      map_hash(elements).to_s
    end

    # Helper: extract a keyword string value from argument list
    def extract_keyword_string(args : Array(Prism::Node), key : String) : String?
      args.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)
        arg.elements.each do |el|
          next unless el.is_a?(Prism::AssocNode)
          k = el.key
          next unless k.is_a?(Prism::SymbolNode) && k.value == key
          case v = el.value_node
          when Prism::StringNode  then return v.value
          when Prism::IntegerNode then return v.value.to_s
          when Prism::SymbolNode  then return v.value
          end
        end
      end
      nil
    end
  end
end
