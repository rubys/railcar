# Prism AST node types — Crystal representations.
# Only the node types needed for Rails model/migration extraction are
# fully represented. Unknown nodes are captured as GenericNode with
# their type ID, so the tree is always complete.

module Prism
  # Node type IDs from prism/ast.h (1-indexed, matching config.yml order)
  enum NodeType : UInt8
    ArgumentsNode    =   5
    ArrayNode        =   6
    AssocNode        =   8
    BlockNode        =  14
    CallNode         =  19
    ClassNode        =  26
    ConstantPathNode =  37
    ConstantReadNode =  42
    FalseNode        =  51
    HashNode         =  65
    IntegerNode      =  82
    KeywordHashNode  =  90
    NilNode          = 108
    ProgramNode      = 121
    SelfNode         = 133
    StatementsNode   = 140
    StringNode       = 141
    SymbolNode       = 143
    TrueNode         = 144
  end

  # Base AST node
  abstract class Node
    property location_start : UInt32 = 0
    property location_length : UInt32 = 0
    property node_id : UInt32 = 0
    property flags : UInt32 = 0

    # Convenience: extract source text for this node
    def source_text(source : String) : String
      source.byte_slice(location_start, location_length)
    end

    # Iterate over child nodes (override in subclasses)
    def children : Array(Node)
      [] of Node
    end

    # Walk all descendants depth-first
    def each_descendant(&block : Node -> _)
      children.each do |child|
        yield child
        child.each_descendant(&block)
      end
    end
  end

  # Fallback for node types we haven't mapped yet
  class GenericNode < Node
    property type_id : UInt8
    property child_nodes : Array(Node) = [] of Node

    def initialize(@type_id)
    end

    def children : Array(Node)
      child_nodes
    end
  end

  class ProgramNode < Node
    property locals : Array(String) = [] of String
    property statements : Node = GenericNode.new(0)

    def children : Array(Node)
      [statements]
    end
  end

  class StatementsNode < Node
    property body : Array(Node) = [] of Node

    def children : Array(Node)
      body
    end
  end

  class ClassNode < Node
    property locals : Array(String) = [] of String
    property constant_path : Node = GenericNode.new(0)
    property superclass : Node? = nil
    property body : Node? = nil
    property name : String = ""

    def children : Array(Node)
      nodes = [constant_path] of Node
      nodes << superclass.not_nil! if superclass
      nodes << body.not_nil! if body
      nodes
    end
  end

  class CallNode < Node
    property receiver : Node? = nil
    property name : String = ""
    property arguments : Node? = nil
    property block : Node? = nil

    def children : Array(Node)
      nodes = [] of Node
      nodes << receiver.not_nil! if receiver
      nodes << arguments.not_nil! if arguments
      nodes << block.not_nil! if block
      nodes
    end

    # Convenience: get argument nodes as an array
    def arg_nodes : Array(Node)
      if args = arguments.as?(ArgumentsNode)
        args.arguments
      else
        [] of Node
      end
    end
  end

  class ArgumentsNode < Node
    property arguments : Array(Node) = [] of Node

    def children : Array(Node)
      arguments
    end
  end

  class BlockNode < Node
    property locals : Array(String) = [] of String
    property parameters : Node? = nil
    property body : Node? = nil

    def children : Array(Node)
      nodes = [] of Node
      nodes << parameters.not_nil! if parameters
      nodes << body.not_nil! if body
      nodes
    end
  end

  class SymbolNode < Node
    property value : String = ""
  end

  class StringNode < Node
    property value : String = ""
  end

  class IntegerNode < Node
    property value : Int64 = 0
  end

  class ArrayNode < Node
    property elements : Array(Node) = [] of Node

    def children : Array(Node)
      elements
    end
  end

  class HashNode < Node
    property elements : Array(Node) = [] of Node

    def children : Array(Node)
      elements
    end
  end

  class KeywordHashNode < Node
    property elements : Array(Node) = [] of Node

    def children : Array(Node)
      elements
    end
  end

  class AssocNode < Node
    property key : Node = GenericNode.new(0)
    property value_node : Node = GenericNode.new(0)

    def children : Array(Node)
      [key, value_node]
    end
  end

  class ConstantReadNode < Node
    property name : String = ""
  end

  class ConstantPathNode < Node
    property parent : Node? = nil
    property name : String = ""

    def children : Array(Node)
      parent ? [parent.not_nil!] : [] of Node
    end

    # Full path like "ActiveRecord::Migration"
    def full_path : String
      if p = parent
        case p
        when ConstantPathNode
          "#{p.full_path}::#{name}"
        when ConstantReadNode
          "#{p.name}::#{name}"
        else
          name
        end
      else
        name
      end
    end
  end

  class TrueNode < Node
  end

  class FalseNode < Node
  end

  class NilNode < Node
  end

  class SelfNode < Node
  end
end
