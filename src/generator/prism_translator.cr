# Translates a complete Prism AST (from Ruby source) to a Crystal AST.
#
# This is a structural 1:1 translation — Ruby syntax to Crystal syntax.
# No Rails-specific transformations happen here. Those are applied as
# separate Crystal::Transformer filters afterward.
#
# The translation is mechanical: Prism::CallNode → Crystal::Call,
# Prism::DefNode → Crystal::Def, etc. Where Ruby and Crystal syntax
# diverge, this translator produces the closest Crystal equivalent.

require "compiler/crystal/syntax"
require "../prism/bindings"
require "../prism/deserializer"

module Ruby2CR
  class PrismTranslator
    # Translate a Ruby source string to a Crystal AST
    def self.translate(source : String) : Crystal::ASTNode
      prism_ast = Prism.parse(source)
      new.translate(prism_ast)
    end

    def translate(node : Prism::Node) : Crystal::ASTNode
      case node
      # --- Program structure ---
      when Prism::ProgramNode
        translate(node.statements)

      when Prism::StatementsNode
        if node.body.size == 1
          translate(node.body[0])
        else
          Crystal::Expressions.new(node.body.map { |s| translate(s) })
        end

      # --- Classes and methods ---
      when Prism::ClassNode
        superclass = node.superclass ? translate(node.superclass.not_nil!) : nil
        body = node.body ? translate(node.body.not_nil!) : Crystal::Nop.new
        Crystal::ClassDef.new(
          translate_path(node),
          body: body,
          superclass: superclass.as?(Crystal::ASTNode)
        )

      when Prism::DefNode
        args = translate_def_params(node)
        body = node.body ? translate(node.body.not_nil!) : Crystal::Nop.new
        Crystal::Def.new(node.name, args, body: body)

      # --- Method calls ---
      when Prism::CallNode
        translate_call(node)

      when Prism::ArgumentsNode
        # ArgumentsNode is typically unwrapped by the parent
        if node.arguments.size == 1
          translate(node.arguments[0])
        else
          Crystal::Expressions.new(node.arguments.map { |a| translate(a) })
        end

      # --- Blocks ---
      when Prism::BlockNode
        params = translate_block_params(node)
        body = node.body ? translate(node.body.not_nil!) : Crystal::Nop.new
        Crystal::Block.new(args: params, body: body)

      # --- Literals ---
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

      # --- Variables ---
      when Prism::LocalVariableReadNode
        Crystal::Var.new(node.name)

      when Prism::LocalVariableWriteNode
        Crystal::Assign.new(
          Crystal::Var.new(node.name),
          translate(node.value)
        )

      when Prism::LocalVariableOperatorWriteNode
        Crystal::OpAssign.new(
          Crystal::Var.new(node.name),
          node.operator,
          translate(node.value)
        )

      when Prism::InstanceVariableReadNode
        Crystal::InstanceVar.new(node.name)

      when Prism::InstanceVariableWriteNode
        Crystal::Assign.new(
          Crystal::InstanceVar.new(node.name),
          translate(node.value)
        )

      # --- Constants ---
      when Prism::ConstantReadNode
        Crystal::Path.new(node.name)

      when Prism::ConstantPathNode
        Crystal::Path.new(node.full_path.split("::"))

      # --- Collections ---
      when Prism::ArrayNode
        Crystal::ArrayLiteral.new(node.elements.map { |e| translate(e) })

      when Prism::HashNode
        translate_hash(node.elements)

      when Prism::KeywordHashNode
        translate_hash(node.elements)

      when Prism::AssocNode
        # Standalone AssocNode shouldn't appear, but handle gracefully
        Crystal::Expressions.new([translate(node.key), translate(node.value_node)])

      # --- Control flow ---
      when Prism::IfNode
        cond = translate(node.condition)
        then_body = node.then_body ? translate(node.then_body.not_nil!) : Crystal::Nop.new
        else_body = if ec = node.else_clause
                      case ec
                      when Prism::ElseNode
                        ec.body ? translate(ec.body.not_nil!) : nil
                      else
                        translate(ec)
                      end
                    else
                      nil
                    end
        Crystal::If.new(cond, then_body, else_body)

      when Prism::ElseNode
        node.body ? translate(node.body.not_nil!) : Crystal::Nop.new

      # --- Containers ---
      when Prism::ParenthesesNode
        if body = node.body
          expr = Crystal::Expressions.new([translate(body)] of Crystal::ASTNode)
          expr.keyword = Crystal::Expressions::Keyword::Paren
          expr
        else
          Crystal::Nop.new
        end

      # --- Generic fallback ---
      when Prism::GenericNode
        # Translate children we can see
        children = node.child_nodes
        if children.empty?
          Crystal::Nop.new
        elsif children.size == 1
          translate(children[0])
        else
          Crystal::Expressions.new(children.map { |c| translate(c) })
        end

      else
        Crystal::Nop.new
      end
    end

    # --- Call translation ---

    private def translate_call(node : Prism::CallNode) : Crystal::ASTNode
      receiver = node.receiver ? translate(node.receiver.not_nil!) : nil
      args = node.arg_nodes.map { |a| translate(a) }

      # Separate keyword args from positional args
      positional = [] of Crystal::ASTNode
      named = [] of Crystal::NamedArgument

      args.each do |arg|
        if arg.is_a?(Crystal::HashLiteral) && is_keyword_hash?(node)
          # Keyword hash → named arguments
          arg.entries.each do |entry|
            if entry.key.is_a?(Crystal::SymbolLiteral)
              named << Crystal::NamedArgument.new(
                entry.key.as(Crystal::SymbolLiteral).value,
                entry.value
              )
            else
              positional << arg
            end
          end
        else
          positional << arg
        end
      end

      # Handle block
      block = if prism_block = node.block
                prism_block.is_a?(Prism::BlockNode) ? translate(prism_block).as(Crystal::Block) : nil
              else
                nil
              end

      Crystal::Call.new(
        receiver,
        node.name,
        positional,
        block: block,
        named_args: named.empty? ? nil : named
      )
    end

    # Check if the last argument is a keyword hash (common Rails pattern)
    private def is_keyword_hash?(node : Prism::CallNode) : Bool
      args = node.arg_nodes
      !args.empty? && args.last.is_a?(Prism::KeywordHashNode)
    end

    # --- Hash translation ---

    private def translate_hash(elements : Array(Prism::Node)) : Crystal::HashLiteral
      entries = elements.compact_map do |el|
        next nil unless el.is_a?(Prism::AssocNode)
        Crystal::HashLiteral::Entry.new(translate(el.key), translate(el.value_node))
      end
      Crystal::HashLiteral.new(entries)
    end

    # --- Path translation ---

    private def translate_path(klass : Prism::ClassNode) : Crystal::Path
      case cp = klass.constant_path
      when Prism::ConstantReadNode
        Crystal::Path.new(cp.name)
      when Prism::ConstantPathNode
        Crystal::Path.new(cp.full_path.split("::"))
      else
        Crystal::Path.new(klass.name)
      end
    end

    # --- Parameter translation ---

    private def translate_def_params(node : Prism::DefNode) : Array(Crystal::Arg)
      args = [] of Crystal::Arg
      params = node.parameters
      return args unless params

      # DefNode.parameters is a GenericNode (ParametersNode type 115)
      # Its children are the parameter nodes
      params.children.each do |child|
        case child
        when Prism::GenericNode
          # RequiredParameterNode (127) — name is in a constant field
          # We extract from locals instead
        else
          # Try to extract name
        end
      end

      # Use the locals list from DefNode as parameter names
      node.locals.each do |name|
        args << Crystal::Arg.new(name)
      end

      args
    end

    private def translate_block_params(node : Prism::BlockNode) : Array(Crystal::Var)
      node.locals.map { |name| Crystal::Var.new(name) }
    end
  end
end
