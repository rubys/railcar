# Extracts and converts seed data from db/seeds.rb using Prism.
#
# Parses Ruby seed code (Model.create!, association.build, etc.)
# and generates equivalent Crystal seed statements.

require "../prism/bindings"
require "../prism/deserializer"

module Railcar
  class SeedExtractor
    # Generate Crystal seed code from a Rails db/seeds.rb file
    def self.generate(seeds_path : String, first_model : String = "Model") : String
      source = File.read(seeds_path)
      ast = Prism.parse(source)
      io = IO::Memory.new

      stmts = ast.statements
      return "" unless stmts.is_a?(Prism::StatementsNode)

      io << "if Railcar::#{first_model}.count == 0\n"

      stmts.body.each do |stmt|
        case stmt
        when Prism::CallNode
          next if stmt.name == "return"
          next if stmt.name == "puts"
        when Prism::IfNode, Prism::GenericNode
          next
        end

        emit_statement(stmt, io, "  ")
      end

      io << "end\n"
      io.to_s
    end

    private def self.emit_statement(node : Prism::Node, io : IO, indent : String)
      case node
      when Prism::LocalVariableWriteNode
        io << indent << node.name << " = " << expr(node.value) << "\n"
      when Prism::CallNode
        io << indent << expr(node) << "\n"
      end
    end

    private def self.expr(node : Prism::Node) : String
      case node
      when Prism::CallNode
        receiver = node.receiver
        method = node.name
        args = node.arg_nodes

        recv_str = receiver ? expr(receiver) : nil

        case method
        when "create!", "create"
          kwargs = args.map { |a| kwargs(a) }.join(", ")
          recv_str ? "#{recv_str}.create!(#{kwargs})" : "create!(#{kwargs})"
        else
          if recv_str
            arg_strs = args.map { |a| expr(a) }
            arg_strs.empty? ? "#{recv_str}.#{method}" : "#{recv_str}.#{method}(#{arg_strs.join(", ")})"
          else
            arg_strs = args.map { |a| expr(a) }
            arg_strs.empty? ? method : "#{method}(#{arg_strs.join(", ")})"
          end
        end
      when Prism::ConstantReadNode
        "Railcar::#{node.name}"
      when Prism::LocalVariableReadNode
        node.name
      when Prism::StringNode
        node.value.inspect
      when Prism::IntegerNode
        node.value.to_s
      when Prism::SymbolNode
        ":#{node.value}"
      else
        "nil"
      end
    end

    private def self.kwargs(node : Prism::Node) : String
      case node
      when Prism::KeywordHashNode
        node.elements.compact_map do |el|
          next nil unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
          "#{el.key.as(Prism::SymbolNode).value}: #{expr(el.value_node)}"
        end.join(", ")
      else
        expr(node)
      end
    end
  end
end
