# Translates a complete Prism AST (from Ruby source) to a Crystal AST.
#
# This is a structural 1:1 translation — Ruby syntax to Crystal syntax.
# No Rails-specific transformations happen here. Those are applied as
# separate Crystal::Transformer filters afterward.
#
# The translation is mechanical: Prism::CallNode → Crystal::Call,
# Prism::DefNode → Crystal::Def, etc. Where Ruby and Crystal syntax
# diverge, this translator produces the closest Crystal equivalent.
#
# Source locations from Prism nodes are mapped onto Crystal AST nodes,
# enabling source maps, better error messages, and Crystal's
# TypeGuessVisitor (which requires locations on instance variables).

require "compiler/crystal/syntax"
require "../prism/bindings"
require "../prism/deserializer"

module Railcar
  class PrismTranslator
    @source : String
    @filename : String
    @line_offsets : Array(Int32)

    def initialize(@source = "", @filename = "")
      @line_offsets = build_line_offsets(@source)
    end

    # Translate a Ruby source string to a Crystal AST
    def self.translate(source : String, filename : String = "") : Crystal::ASTNode
      prism_ast = Prism.parse(source)
      new(source, filename).translate(prism_ast)
    end

    # Build a table mapping line numbers to byte offsets.
    # Line 1 starts at offset 0; each subsequent line starts
    # after a newline character.
    private def build_line_offsets(source : String) : Array(Int32)
      offsets = [0]
      source.each_byte.with_index do |byte, index|
        offsets << (index + 1) if byte == '\n'.ord
      end
      offsets
    end

    # Convert a byte offset to a Crystal::Location (line, column).
    private def location_for(node : Prism::Node) : Crystal::Location
      offset = node.location_start.to_i32
      line = 1
      @line_offsets.each_with_index do |line_offset, i|
        if offset < line_offset
          break
        end
        line = i + 1
      end
      column = offset - @line_offsets[line - 1] + 1
      Crystal::Location.new(@filename, line, column)
    end

    # Set location on a Crystal node from a Prism node and return it.
    private def locate(crystal_node : Crystal::ASTNode, prism_node : Prism::Node) : Crystal::ASTNode
      crystal_node.location = location_for(prism_node)
      crystal_node
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
          locate(Crystal::Expressions.new(node.body.map { |s| translate(s) }), node)
        end

      # --- Classes and methods ---
      when Prism::ClassNode
        superclass = node.superclass ? translate(node.superclass.not_nil!) : nil
        body = node.body ? translate(node.body.not_nil!) : Crystal::Nop.new
        locate(Crystal::ClassDef.new(
          translate_path(node),
          body: body,
          superclass: superclass.as?(Crystal::ASTNode)
        ), node)

      when Prism::DefNode
        args = translate_def_params(node)
        body = node.body ? translate(node.body.not_nil!) : Crystal::Nop.new
        receiver = node.receiver ? translate(node.receiver.not_nil!) : nil
        crystal_def = Crystal::Def.new(node.name, args, body: body, receiver: receiver)
        locate(crystal_def, node)

      # --- Method calls ---
      when Prism::CallNode
        translate_call(node)

      when Prism::ArgumentsNode
        # ArgumentsNode is typically unwrapped by the parent
        if node.arguments.size == 1
          translate(node.arguments[0])
        else
          locate(Crystal::Expressions.new(node.arguments.map { |a| translate(a) }), node)
        end

      # --- Blocks ---
      when Prism::BlockNode
        params = translate_block_params(node)
        body = node.body ? translate(node.body.not_nil!) : Crystal::Nop.new
        locate(Crystal::Block.new(args: params, body: body), node)

      # --- Lambdas ---
      when Prism::LambdaNode
        params = node.locals.map { |name| Crystal::Var.new(name) }
        body = node.body ? translate(node.body.not_nil!) : Crystal::Nop.new
        # Crystal doesn't have -> syntax for procs in the same way
        # Translate as a block-like construct (ProcLiteral)
        locate(Crystal::ProcLiteral.new(Crystal::Def.new("->", node.locals.map { |n| Crystal::Arg.new(n) }, body: body)), node)

      # --- Literals ---
      when Prism::StringNode
        locate(Crystal::StringLiteral.new(node.value), node)

      when Prism::InterpolatedStringNode
        parts = node.parts.map do |part|
          case part
          when Prism::StringNode
            locate(Crystal::StringLiteral.new(part.value), part).as(Crystal::ASTNode)
          when Prism::EmbeddedStatementsNode
            if stmts = part.statements
              case stmts
              when Prism::StatementsNode
                if stmts.body.size == 1
                  translate(stmts.body[0])
                else
                  Crystal::Expressions.new(stmts.body.map { |s| translate(s) })
                end
              else
                translate(stmts)
              end
            else
              Crystal::Nop.new.as(Crystal::ASTNode)
            end
          else
            translate(part)
          end
        end
        locate(Crystal::StringInterpolation.new(parts), node)

      when Prism::SymbolNode
        locate(Crystal::SymbolLiteral.new(node.value), node)

      when Prism::IntegerNode
        locate(Crystal::NumberLiteral.new(node.value.to_s), node)

      when Prism::TrueNode
        locate(Crystal::BoolLiteral.new(true), node)

      when Prism::FalseNode
        locate(Crystal::BoolLiteral.new(false), node)

      when Prism::NilNode
        locate(Crystal::NilLiteral.new, node)

      when Prism::SelfNode
        locate(Crystal::Var.new("self"), node)

      # --- Variables ---
      when Prism::LocalVariableReadNode
        locate(Crystal::Var.new(node.name), node)

      when Prism::LocalVariableWriteNode
        locate(Crystal::Assign.new(
          locate(Crystal::Var.new(node.name), node),
          translate(node.value)
        ), node)

      when Prism::LocalVariableOperatorWriteNode
        locate(Crystal::OpAssign.new(
          locate(Crystal::Var.new(node.name), node),
          node.operator,
          translate(node.value)
        ), node)

      when Prism::InstanceVariableReadNode
        locate(Crystal::InstanceVar.new(node.name), node)

      when Prism::InstanceVariableWriteNode
        locate(Crystal::Assign.new(
          locate(Crystal::InstanceVar.new(node.name), node),
          translate(node.value)
        ), node)

      # --- Constants ---
      when Prism::ConstantReadNode
        locate(Crystal::Path.new(node.name), node)

      when Prism::ConstantPathNode
        locate(Crystal::Path.new(node.full_path.split("::")), node)

      # --- Collections ---
      when Prism::ArrayNode
        locate(Crystal::ArrayLiteral.new(node.elements.map { |e| translate(e) }), node)

      when Prism::HashNode
        locate(translate_hash(node.elements), node)

      when Prism::KeywordHashNode
        locate(translate_hash(node.elements), node)

      when Prism::AssocNode
        # Standalone AssocNode shouldn't appear, but handle gracefully
        locate(Crystal::Expressions.new([translate(node.key), translate(node.value_node)]), node)

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
        locate(Crystal::If.new(cond, then_body, else_body), node)

      when Prism::ElseNode
        node.body ? translate(node.body.not_nil!) : Crystal::Nop.new

      # --- Containers ---
      when Prism::ParenthesesNode
        if body = node.body
          expr = Crystal::Expressions.new([translate(body)] of Crystal::ASTNode)
          expr.keyword = Crystal::Expressions::Keyword::Paren
          locate(expr, node)
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
          locate(Crystal::Expressions.new(children.map { |c| translate(c) }), node)
        end

      else
        STDERR.puts "railcar: unhandled Prism node type: #{node.class.name}"
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

      locate(Crystal::Call.new(
        receiver,
        node.name,
        positional,
        block: block,
        named_args: named.empty? ? nil : named
      ), node)
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
