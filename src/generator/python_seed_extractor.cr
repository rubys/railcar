# Extracts and converts seed data from db/seeds.rb using Prism.
#
# Parses Ruby seed code (Model.create!, association.build, etc.)
# and generates equivalent Python seed statements.

require "../prism/bindings"
require "../prism/deserializer"

module Railcar
  class PythonSeedExtractor
    # Generate Python seed code from a Rails db/seeds.rb file
    def self.generate(seeds_path : String, first_model : String = "Model") : String
      source = File.read(seeds_path)
      ast = Prism.parse(source)
      io = IO::Memory.new

      stmts = ast.statements
      return "" unless stmts.is_a?(Prism::StatementsNode)

      io << "def seed_db():\n"
      io << "    if len(#{first_model}.all()) > 0:\n"
      io << "        return\n"

      stmts.body.each do |stmt|
        case stmt
        when Prism::CallNode
          next if stmt.name == "return"
          next if stmt.name == "puts"
        when Prism::IfNode, Prism::GenericNode
          next
        end

        emit_statement(stmt, io, "    ")
      end

      io << "\n"
      io.to_s
    end

    private def self.emit_statement(node : Prism::Node, io : IO, indent : String)
      case node
      when Prism::LocalVariableWriteNode
        result = create_expr(node.value)
        if result
          var, init, save = result
          io << indent << node.name << " = " << init << "\n"
          io << indent << node.name << ".save()\n"
        else
          io << indent << node.name << " = " << expr(node.value) << "\n"
        end
      when Prism::CallNode
        result = create_expr(node)
        if result
          _, init, _ = result
          io << indent << init << ".save()\n"
        else
          io << indent << expr(node) << "\n"
        end
      end
    end

    # Returns {model_name, constructor_call, _} for create!/create calls, nil otherwise
    private def self.create_expr(node : Prism::Node) : Tuple(String, String, Nil)?
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless node.name == "create!" || node.name == "create"

      receiver = node.receiver
      return nil unless receiver
      args = node.arg_nodes

      if receiver.is_a?(Prism::ConstantReadNode)
        # Article.create!(title: "...", body: "...")
        model = receiver.name
        kwargs = args.map { |a| kwargs(a) }.join(", ")
        {model, "#{model}(#{kwargs})", nil}
      elsif receiver.is_a?(Prism::CallNode) && receiver.receiver
        # article1.comments.create!(commenter: "...", body: "...")
        assoc_name = receiver.name
        parent_str = expr(receiver.receiver.not_nil!)
        model_name = Inflector.classify(Inflector.singularize(assoc_name))
        fk = Inflector.underscore(model_name).downcase + "_id" # guess: strip to base
        # Actually derive FK from the parent variable name minus trailing digits
        parent_base = parent_str.gsub(/[0-9]+$/, "")
        fk = parent_base + "_id"
        kwargs = args.map { |a| kwargs(a) }.join(", ")
        fk_kwarg = "#{fk}=#{parent_str}.id"
        all_kwargs = kwargs.empty? ? fk_kwarg : "#{fk_kwarg}, #{kwargs}"
        {model_name, "#{model_name}(#{all_kwargs})", nil}
      else
        nil
      end
    end

    private def self.expr(node : Prism::Node) : String
      case node
      when Prism::CallNode
        receiver = node.receiver
        method = node.name
        args = node.arg_nodes

        recv_str = receiver ? expr(receiver) : nil

        if recv_str
          arg_strs = args.map { |a| expr(a) }
          arg_strs.empty? ? "#{recv_str}.#{method}()" : "#{recv_str}.#{method}(#{arg_strs.join(", ")})"
        else
          arg_strs = args.map { |a| expr(a) }
          arg_strs.empty? ? method : "#{method}(#{arg_strs.join(", ")})"
        end
      when Prism::ConstantReadNode
        node.name
      when Prism::LocalVariableReadNode
        node.name
      when Prism::StringNode
        node.value.inspect
      when Prism::IntegerNode
        node.value.to_s
      when Prism::SymbolNode
        "\"#{node.value}\""
      else
        "None"
      end
    end

    private def self.kwargs(node : Prism::Node) : String
      case node
      when Prism::KeywordHashNode
        node.elements.compact_map do |el|
          next nil unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
          "#{el.key.as(Prism::SymbolNode).value}=#{expr(el.value_node)}"
        end.join(", ")
      else
        expr(node)
      end
    end
  end
end
