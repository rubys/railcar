# Shared Prism AST → Crystal expression conversion.
#
# Provides base conversion for literals, variables, constants, and generic
# method calls. Consumers include this module and override convert_call
# for domain-specific transformations (controller actions, test assertions,
# template helpers).
#
# Usage:
#   class MyConverter
#     include CrystalExpr
#     def convert_call(call : Prism::CallNode) : String
#       # domain-specific handling, fall back to super for generic calls
#     end
#   end

require "../prism/bindings"
require "../prism/deserializer"

module Ruby2CR
  module CrystalExpr
    # Convert a Prism AST node to a Crystal expression string.
    def expr(node : Prism::Node) : String
      case node
      when Prism::CallNode
        convert_call(node)
      when Prism::InstanceVariableReadNode
        node.name.lchop("@")
      when Prism::InstanceVariableWriteNode
        "#{node.name.lchop("@")} = #{expr(node.value)}"
      when Prism::LocalVariableReadNode
        node.name
      when Prism::LocalVariableWriteNode
        "#{node.name} = #{expr(node.value)}"
      when Prism::StringNode
        node.value.inspect
      when Prism::SymbolNode
        ":#{node.value}"
      when Prism::IntegerNode
        node.value.to_s
      when Prism::TrueNode
        "true"
      when Prism::FalseNode
        "false"
      when Prism::NilNode
        "nil"
      when Prism::ConstantReadNode
        "Ruby2CR::#{node.name}"
      when Prism::ArrayNode
        "[#{node.elements.map { |e| expr(e) }.join(", ")}]"
      when Prism::HashNode
        hash_pairs(node.elements)
      when Prism::KeywordHashNode
        hash_pairs(node.elements)
      when Prism::ParenthesesNode
        body = node.body
        body ? expr(body) : ""
      when Prism::StatementsNode
        node.body.map { |s| expr(s) }.last? || ""
      else
        "nil"
      end
    end

    # Default call conversion: generic method call passthrough.
    # Override in consumers for domain-specific behavior.
    def convert_call(call : Prism::CallNode) : String
      generic_call(call)
    end

    # Generic method call — available for consumers to fall back to
    def generic_call(call : Prism::CallNode) : String
      receiver = call.receiver
      method = call.name
      args = call.arg_nodes

      if receiver
        recv = expr(receiver)
        args.empty? ? "#{recv}.#{method}" : "#{recv}.#{method}(#{args.map { |a| expr(a) }.join(", ")})"
      else
        args.empty? ? method : "#{method}(#{args.map { |a| expr(a) }.join(", ")})"
      end
    end

    # Convert hash/keyword hash elements to Crystal syntax
    def hash_pairs(elements : Array(Prism::Node)) : String
      elements.compact_map do |el|
        next nil unless el.is_a?(Prism::AssocNode)
        key = el.key
        val = el.value_node
        if key.is_a?(Prism::SymbolNode)
          "#{key.value}: #{expr(val)}"
        else
          "#{expr(key)} => #{expr(val)}"
        end
      end.join(", ")
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
