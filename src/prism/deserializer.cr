# Deserializer for Prism's binary serialization format.
# See: prism/docs/serialization.md
#
# The format is: header, then nodes in prefix traversal order,
# then constant pool. Each node is: type(1) + node_id(varuint) +
# location(varuint start + varuint length) + flags(varuint) + fields.
#
# Field layouts per node type come from prism/config.yml.

require "./nodes"

module Prism
  class Deserializer
    @data : Bytes
    @source : String
    @pos : Int32 = 0
    @constant_pool : Array(String) = [] of String
    @semantics_only : Bool = false

    def initialize(@data, @source)
    end

    def deserialize : ProgramNode
      parse_header
      node = read_node
      node.as(ProgramNode)
    end

    # ----- Header parsing -----

    private def parse_header
      # "PRISM" magic
      5.times { read_byte }

      # Version: major, minor, patch
      _major = read_byte
      _minor = read_byte
      _patch = read_byte

      # Semantics-only flag
      @semantics_only = read_byte == 1

      # Encoding name (simple varuint-length + bytes, not typed string)
      skip_raw_string

      # Start line (varsint)
      read_varsint

      # Newline offsets
      count = read_varuint
      count.times { read_varuint }

      # Comments
      count = read_varuint
      count.times do
        read_byte    # type
        read_varuint # start
        read_varuint # length
      end

      # Magic comments
      count = read_varuint
      count.times do
        read_varuint; read_varuint # key location
        read_varuint; read_varuint # value location
      end

      # __END__ location (optional — indicated by a flag byte)
      flag = read_byte
      if flag != 0
        read_varuint # start
        read_varuint # length
      end

      # Errors
      count = read_varuint
      count.times do
        read_varuint # type
        skip_raw_string  # message
        read_varuint; read_varuint # location
        read_byte    # level
      end

      # Warnings
      count = read_varuint
      count.times do
        read_varuint # type
        skip_raw_string  # message
        read_varuint; read_varuint # location
        read_byte    # level
      end

      # Content pool offset (4 bytes, little-endian)
      pool_offset = read_uint32

      # Content pool size
      pool_size = read_varuint

      # Save position, jump to constant pool, read it, jump back
      saved_pos = @pos
      @pos = pool_offset.to_i32
      load_constant_pool(pool_size)
      @pos = saved_pos
    end

    private def load_constant_pool(size : UInt32)
      entries = [] of {UInt32, UInt32}

      size.times do
        offset = read_uint32
        length = read_uint32
        entries << {offset, length}
      end

      entries.each do |offset, length|
        owned = (offset & 0x80000000_u32) != 0
        real_offset = offset & 0x7FFFFFFF_u32

        if owned
          # Content is embedded in the serialization
          str = String.new(@data[real_offset, length])
        else
          # Content is a slice of the original source
          str = @source.byte_slice(real_offset, length)
        end
        @constant_pool << str
      end
    end

    # ----- Node reading -----

    private def read_node : Node
      type_id = read_byte
      node_id = read_varuint
      loc_start = read_varuint
      loc_length = read_varuint
      flags = read_varuint

      node = read_node_fields(type_id)
      node.node_id = node_id
      node.location_start = loc_start
      node.location_length = loc_length
      node.flags = flags
      node
    end

    # Read fields for a specific node type. The field layouts are from config.yml.
    # For known types, we build typed nodes. For unknown types, we skip fields
    # based on the layout table and return a GenericNode.
    private def read_node_fields(type_id : UInt8) : Node
      case type_id
      when 5 # ArgumentsNode: node[]
        node = ArgumentsNode.new
        node.arguments = read_node_array
        node
      when 6 # ArrayNode: node[], location?, location?
        node = ArrayNode.new
        node.elements = read_node_array
        skip_optional_location # opening_loc
        skip_optional_location # closing_loc
        node
      when 8 # AssocNode: node, node, location?
        node = AssocNode.new
        node.key = read_node
        node.value_node = read_node
        skip_optional_location # operator_loc
        node
      when 14 # BlockNode: constant[], node?, node?, location, location
        node = BlockNode.new
        node.locals = read_constant_array
        node.parameters = read_optional_node
        node.body = read_optional_node
        skip_location # opening_loc
        skip_location # closing_loc
        node
      when 19 # CallNode: node?, location?, constant, location?, location?, node?, location?, location?, node?
        node = CallNode.new
        node.receiver = read_optional_node
        skip_optional_location # call_operator_loc
        node.name = read_constant
        skip_optional_location # message_loc
        skip_optional_location # opening_loc
        node.arguments = read_optional_node
        skip_optional_location # closing_loc
        skip_optional_location # equal_loc
        node.block = read_optional_node
        node
      when 26 # ClassNode: constant[], location, node, location?, node?, node?, location, constant
        node = ClassNode.new
        node.locals = read_constant_array
        skip_location # class_keyword_loc
        node.constant_path = read_node
        skip_optional_location # inheritance_operator_loc
        node.superclass = read_optional_node
        node.body = read_optional_node
        skip_location # end_keyword_loc
        node.name = read_constant
        node
      when 37 # ConstantPathNode: node?, constant?, location, location
        node = ConstantPathNode.new
        node.parent = read_optional_node
        name_id = read_optional_constant_id
        node.name = name_id ? @constant_pool[name_id - 1] : ""
        skip_location # delimiter_loc
        skip_location # name_loc
        node
      when 42 # ConstantReadNode: constant
        node = ConstantReadNode.new
        node.name = read_constant
        node
      when 51 # FalseNode: (no fields)
        FalseNode.new
      when 65 # HashNode: location, node[], location
        node = HashNode.new
        skip_location # opening_loc
        node.elements = read_node_array
        skip_location # closing_loc
        node
      when 82 # IntegerNode: integer
        node = IntegerNode.new
        node.value = read_integer
        node
      when 90 # KeywordHashNode: node[]
        node = KeywordHashNode.new
        node.elements = read_node_array
        node
      when 108 # NilNode: (no fields)
        NilNode.new
      when 121 # ProgramNode: constant[], node
        node = ProgramNode.new
        node.locals = read_constant_array
        node.statements = read_node
        node
      when 133 # SelfNode: (no fields)
        SelfNode.new
      when 140 # StatementsNode: node[]
        node = StatementsNode.new
        node.body = read_node_array
        node
      when 141 # StringNode: location?, location, location?, string
        node = StringNode.new
        skip_optional_location # opening_loc
        skip_location          # content_loc
        skip_optional_location # closing_loc
        node.value = read_string
        node
      when 143 # SymbolNode: location?, location?, location?, string
        node = SymbolNode.new
        skip_optional_location # opening_loc
        skip_optional_location # value_loc
        skip_optional_location # closing_loc
        node.value = read_string
        node
      when 144 # TrueNode: (no fields)
        TrueNode.new
      else
        skip_unknown_node_fields(type_id)
      end
    end

    # Skip fields for an unknown node type using the layout table.
    # This ensures we advance the position correctly so subsequent
    # nodes can be read. We capture any child nodes we find.
    private def skip_unknown_node_fields(type_id : UInt8) : GenericNode
      node = GenericNode.new(type_id)
      layout = NODE_FIELD_LAYOUTS[type_id]?
      unless layout
        return node
      end

      layout.each do |field_type|
        case field_type
        when :node
          node.child_nodes << read_node
        when :optional_node
          if n = read_optional_node
            node.child_nodes << n
          end
        when :node_array
          read_node_array.each { |n| node.child_nodes << n }
        when :location
          skip_location
        when :optional_location
          skip_optional_location
        when :constant
          read_varuint # constant id
        when :optional_constant
          read_varuint # 0 if not present
        when :constant_array
          count = read_varuint
          count.times { read_varuint }
        when :string
          skip_string
        when :integer
          read_integer
        when :double
          @pos += 8
        when :uint8
          read_byte
        when :raw_uint32
          @pos += 4
        when :uint32
          read_varuint
        end
      end

      node
    end

    # ----- Primitive readers -----

    private def read_byte : UInt8
      b = @data[@pos]
      @pos += 1
      b
    end

    private def read_varuint : UInt32
      value = 0_u32
      shift = 0
      loop do
        b = read_byte
        value |= (b.to_u32 & 0x7F) << shift
        break unless (b & 0x80) != 0
        shift += 7
      end
      value
    end

    private def read_varsint : Int32
      unsigned = read_varuint
      # ZigZag decode
      ((unsigned >> 1).to_i32) ^ (-(unsigned & 1).to_i32)
    end

    private def read_uint32 : UInt32
      value = @data[@pos].to_u32 |
              (@data[@pos + 1].to_u32 << 8) |
              (@data[@pos + 2].to_u32 << 16) |
              (@data[@pos + 3].to_u32 << 24)
      @pos += 4
      value
    end

    private def read_string : String
      type = read_byte
      case type
      when 1 # shared: slice of source
        start = read_varuint
        length = read_varuint
        @source.byte_slice(start, length)
      when 2 # embedded: inline bytes
        length = read_varuint
        str = String.new(@data[@pos, length])
        @pos += length.to_i32
        str
      else
        raise "Unknown serialized string type: #{type}"
      end
    end

    private def skip_string
      type = read_byte
      case type
      when 1 # shared
        read_varuint # start
        read_varuint # length
      when 2 # embedded
        length = read_varuint
        @pos += length.to_i32
      else
        raise "Unknown serialized string type: #{type}"
      end
    end

    # Simple varuint-length + bytes format used in headers (encoding, error messages)
    private def skip_raw_string
      length = read_varuint
      @pos += length.to_i32
    end

    private def read_constant : String
      id = read_varuint
      return "" if id == 0
      @constant_pool[id.to_i32 - 1]
    end

    private def read_optional_constant_id : UInt32?
      id = read_varuint
      id == 0 ? nil : id
    end

    private def read_node_array : Array(Node)
      count = read_varuint
      nodes = Array(Node).new(count.to_i32)
      count.times { nodes << read_node }
      nodes
    end

    private def read_optional_node : Node?
      # If next byte is 0, node is absent
      if @data[@pos] == 0
        @pos += 1
        nil
      else
        read_node
      end
    end

    private def skip_location
      read_varuint # start
      read_varuint # length
    end

    private def skip_optional_location
      if @data[@pos] == 0
        @pos += 1
      else
        @pos += 1
        read_varuint # start
        read_varuint # length
      end
    end

    private def read_constant_array : Array(String)
      count = read_varuint
      result = Array(String).new(count.to_i32)
      count.times { result << read_constant }
      result
    end

    private def read_integer : Int64
      negative = read_byte != 0
      word_count = read_varuint
      return 0_i64 if word_count == 0
      value = 0_i64
      word_count.times do |i|
        word = read_varuint
        value |= word.to_i64 << (i * 32)
      end
      negative ? -value : value
    end

    # ----- Node field layout table -----
    # Maps node type ID → array of field types, from config.yml.
    # Used by skip_unknown_node_fields to correctly advance past
    # nodes we don't have typed representations for.

    alias FieldType = Symbol

    NODE_FIELD_LAYOUTS = {
       1_u8 => [:node, :node, :location],                                                                           # AliasGlobalVariableNode
       2_u8 => [:node, :node, :location],                                                                           # AliasMethodNode
       3_u8 => [:node, :node, :location],                                                                           # AlternationPatternNode
       4_u8 => [:node, :node, :location],                                                                           # AndNode
       5_u8 => [:node_array],                                                                                        # ArgumentsNode
       6_u8 => [:node_array, :optional_location, :optional_location],                                                # ArrayNode
       7_u8 => [:optional_node, :node_array, :optional_node, :node_array, :optional_location, :optional_location],   # ArrayPatternNode
       8_u8 => [:node, :node, :optional_location],                                                                   # AssocNode
       9_u8 => [:optional_node, :location],                                                                          # AssocSplatNode
      10_u8 => [:constant],                                                                                          # BackReferenceReadNode
      11_u8 => [:optional_location, :optional_node, :optional_node, :optional_node, :optional_node, :optional_location], # BeginNode
      12_u8 => [:optional_node, :location],                                                                          # BlockArgumentNode
      13_u8 => [:constant],                                                                                          # BlockLocalVariableNode
      14_u8 => [:constant_array, :optional_node, :optional_node, :location, :location],                              # BlockNode
      15_u8 => [:optional_constant, :optional_location, :location],                                                  # BlockParameterNode
      16_u8 => [:optional_node, :node_array, :optional_location, :optional_location],                                # BlockParametersNode
      17_u8 => [:optional_node, :location],                                                                          # BreakNode
      18_u8 => [:optional_node, :optional_location, :optional_location, :constant, :constant, :location, :node],     # CallAndWriteNode
      19_u8 => [:optional_node, :optional_location, :constant, :optional_location, :optional_location, :optional_node, :optional_location, :optional_location, :optional_node], # CallNode
      20_u8 => [:optional_node, :optional_location, :optional_location, :constant, :constant, :constant, :location, :node], # CallOperatorWriteNode
      21_u8 => [:optional_node, :optional_location, :optional_location, :constant, :constant, :location, :node],     # CallOrWriteNode
      22_u8 => [:node, :location, :constant, :location],                                                             # CallTargetNode
      23_u8 => [:node, :node, :location],                                                                            # CapturePatternNode
      24_u8 => [:optional_node, :node_array, :optional_node, :location, :location],                                  # CaseMatchNode
      25_u8 => [:optional_node, :node_array, :optional_node, :location, :location],                                  # CaseNode
      26_u8 => [:constant_array, :location, :node, :optional_location, :optional_node, :optional_node, :location, :constant], # ClassNode
      27_u8 => [:constant, :location, :location, :node],                                                             # ClassVariableAndWriteNode
      28_u8 => [:constant, :location, :location, :node, :constant],                                                  # ClassVariableOperatorWriteNode
      29_u8 => [:constant, :location, :location, :node],                                                             # ClassVariableOrWriteNode
      30_u8 => [:constant],                                                                                          # ClassVariableReadNode
      31_u8 => [:constant],                                                                                          # ClassVariableTargetNode
      32_u8 => [:constant, :location, :node, :location],                                                             # ClassVariableWriteNode
      33_u8 => [:constant, :location, :location, :node],                                                             # ConstantAndWriteNode
      34_u8 => [:constant, :location, :location, :node, :constant],                                                  # ConstantOperatorWriteNode
      35_u8 => [:constant, :location, :location, :node],                                                             # ConstantOrWriteNode
      36_u8 => [:node, :location, :node],                                                                            # ConstantPathAndWriteNode
      37_u8 => [:optional_node, :optional_constant, :location, :location],                                           # ConstantPathNode
      38_u8 => [:node, :location, :node, :constant],                                                                 # ConstantPathOperatorWriteNode
      39_u8 => [:node, :location, :node],                                                                            # ConstantPathOrWriteNode
      40_u8 => [:optional_node, :optional_constant, :location, :location],                                           # ConstantPathTargetNode
      41_u8 => [:node, :location, :node],                                                                            # ConstantPathWriteNode
      42_u8 => [:constant],                                                                                          # ConstantReadNode
      43_u8 => [:constant],                                                                                          # ConstantTargetNode
      44_u8 => [:constant, :location, :node, :location],                                                             # ConstantWriteNode
      45_u8 => [:raw_uint32, :constant, :location, :optional_node, :optional_node, :optional_node, :constant_array, :location, :optional_location, :optional_location, :optional_location, :optional_location, :optional_location], # DefNode (has raw uint32 prefix before fields)
      46_u8 => [:optional_location, :node, :optional_location, :location],                                           # DefinedNode
      47_u8 => [:location, :optional_node, :optional_location],                                                      # ElseNode
      48_u8 => [:location, :optional_node, :location],                                                               # EmbeddedStatementsNode
      49_u8 => [:location, :node],                                                                                   # EmbeddedVariableNode
      50_u8 => [:location, :optional_node, :location],                                                               # EnsureNode
      51_u8 => [] of FieldType,                                                                                      # FalseNode
      52_u8 => [:optional_node, :node, :node_array, :node, :optional_location, :optional_location],                  # FindPatternNode
      53_u8 => [:optional_node, :optional_node, :location],                                                          # FlipFlopNode
      54_u8 => [:double],                                                                                            # FloatNode
      55_u8 => [:node, :node, :optional_node, :location, :location, :optional_location, :location],                  # ForNode
      56_u8 => [] of FieldType,                                                                                      # ForwardingArgumentsNode
      57_u8 => [] of FieldType,                                                                                      # ForwardingParameterNode
      58_u8 => [:optional_node],                                                                                     # ForwardingSuperNode
      59_u8 => [:constant, :location, :location, :node],                                                             # GlobalVariableAndWriteNode
      60_u8 => [:constant, :location, :location, :node, :constant],                                                  # GlobalVariableOperatorWriteNode
      61_u8 => [:constant, :location, :location, :node],                                                             # GlobalVariableOrWriteNode
      62_u8 => [:constant],                                                                                          # GlobalVariableReadNode
      63_u8 => [:constant],                                                                                          # GlobalVariableTargetNode
      64_u8 => [:constant, :location, :node, :location],                                                             # GlobalVariableWriteNode
      65_u8 => [:location, :node_array, :location],                                                                  # HashNode
      66_u8 => [:optional_node, :node_array, :optional_node, :optional_location, :optional_location],                # HashPatternNode
      67_u8 => [:optional_location, :node, :optional_location, :optional_node, :optional_node, :optional_location],  # IfNode
      68_u8 => [:node],                                                                                              # ImaginaryNode
      69_u8 => [:node],                                                                                              # ImplicitNode
      70_u8 => [] of FieldType,                                                                                      # ImplicitRestNode
      71_u8 => [:node, :optional_node, :location, :optional_location],                                               # InNode
      72_u8 => [:optional_node, :optional_location, :location, :optional_node, :location, :optional_node, :location, :node], # IndexAndWriteNode
      73_u8 => [:optional_node, :optional_location, :location, :optional_node, :location, :optional_node, :constant, :location, :node], # IndexOperatorWriteNode
      74_u8 => [:optional_node, :optional_location, :location, :optional_node, :location, :optional_node, :location, :node], # IndexOrWriteNode
      75_u8 => [:node, :location, :optional_node, :location, :optional_node],                                        # IndexTargetNode
      76_u8 => [:constant, :location, :location, :node],                                                             # InstanceVariableAndWriteNode
      77_u8 => [:constant, :location, :location, :node, :constant],                                                  # InstanceVariableOperatorWriteNode
      78_u8 => [:constant, :location, :location, :node],                                                             # InstanceVariableOrWriteNode
      79_u8 => [:constant],                                                                                          # InstanceVariableReadNode
      80_u8 => [:constant],                                                                                          # InstanceVariableTargetNode
      81_u8 => [:constant, :location, :node, :location],                                                             # InstanceVariableWriteNode
      82_u8 => [:integer],                                                                                           # IntegerNode
      83_u8 => [:location, :node_array, :location],                                                                  # InterpolatedMatchLastLineNode
      84_u8 => [:location, :node_array, :location],                                                                  # InterpolatedRegularExpressionNode
      85_u8 => [:optional_location, :node_array, :optional_location],                                                # InterpolatedStringNode
      86_u8 => [:optional_location, :node_array, :optional_location],                                                # InterpolatedSymbolNode
      87_u8 => [:location, :node_array, :location],                                                                  # InterpolatedXStringNode
      88_u8 => [] of FieldType,                                                                                      # ItLocalVariableReadNode
      89_u8 => [] of FieldType,                                                                                      # ItParametersNode
      90_u8 => [:node_array],                                                                                        # KeywordHashNode
      91_u8 => [:optional_constant, :optional_location, :location],                                                  # KeywordRestParameterNode
      92_u8 => [:constant_array, :location, :location, :location, :optional_node, :optional_node],                   # LambdaNode
      93_u8 => [:location, :location, :node, :constant, :uint32],                                                    # LocalVariableAndWriteNode
      94_u8 => [:location, :location, :node, :constant, :constant, :uint32],                                         # LocalVariableOperatorWriteNode
      95_u8 => [:location, :location, :node, :constant, :uint32],                                                    # LocalVariableOrWriteNode
      96_u8 => [:constant, :uint32],                                                                                 # LocalVariableReadNode
      97_u8 => [:constant, :uint32],                                                                                 # LocalVariableTargetNode
      98_u8 => [:constant, :uint32, :location, :node, :location],                                                    # LocalVariableWriteNode
      99_u8 => [:location, :location, :location, :string],                                                           # MatchLastLineNode
     100_u8 => [:node, :node, :location],                                                                            # MatchPredicateNode
     101_u8 => [:node, :node, :location],                                                                            # MatchRequiredNode
     102_u8 => [:node, :node_array],                                                                                 # MatchWriteNode
     103_u8 => [] of FieldType,                                                                                      # MissingNode
     104_u8 => [:constant_array, :location, :node, :optional_node, :location, :constant],                            # ModuleNode
     105_u8 => [:node_array, :optional_node, :node_array, :optional_location, :optional_location],                   # MultiTargetNode
     106_u8 => [:node_array, :optional_node, :node_array, :optional_location, :optional_location, :location, :node], # MultiWriteNode
     107_u8 => [:optional_node, :location],                                                                          # NextNode
     108_u8 => [] of FieldType,                                                                                      # NilNode
     109_u8 => [:location, :location],                                                                               # NoKeywordsParameterNode
     110_u8 => [:uint8],                                                                                             # NumberedParametersNode
     111_u8 => [:uint32],                                                                                            # NumberedReferenceReadNode
     112_u8 => [:constant, :location, :node],                                                                        # OptionalKeywordParameterNode
     113_u8 => [:constant, :location, :location, :node],                                                             # OptionalParameterNode
     114_u8 => [:node, :node, :location],                                                                            # OrNode
     115_u8 => [:node_array, :node_array, :optional_node, :node_array, :node_array, :optional_node, :optional_node], # ParametersNode
     116_u8 => [:optional_node, :location, :location],                                                               # ParenthesesNode
     117_u8 => [:node, :location, :location, :location],                                                             # PinnedExpressionNode
     118_u8 => [:node, :location],                                                                                   # PinnedVariableNode
     119_u8 => [:optional_node, :location, :location, :location],                                                    # PostExecutionNode
     120_u8 => [:optional_node, :location, :location, :location],                                                    # PreExecutionNode
     121_u8 => [:constant_array, :node],                                                                             # ProgramNode
     122_u8 => [:optional_node, :optional_node, :location],                                                          # RangeNode
     123_u8 => [:integer, :integer],                                                                                 # RationalNode
     124_u8 => [] of FieldType,                                                                                      # RedoNode
     125_u8 => [:location, :location, :location, :string],                                                           # RegularExpressionNode
     126_u8 => [:constant, :location],                                                                               # RequiredKeywordParameterNode
     127_u8 => [:constant],                                                                                          # RequiredParameterNode
     128_u8 => [:node, :location, :node],                                                                            # RescueModifierNode
     129_u8 => [:location, :node_array, :optional_location, :optional_node, :optional_location, :optional_node, :optional_node], # RescueNode
     130_u8 => [:optional_constant, :optional_location, :location],                                                  # RestParameterNode
     131_u8 => [] of FieldType,                                                                                      # RetryNode
     132_u8 => [:location, :optional_node],                                                                          # ReturnNode
     133_u8 => [] of FieldType,                                                                                      # SelfNode
     134_u8 => [:node],                                                                                              # ShareableConstantNode
     135_u8 => [:constant_array, :location, :location, :node, :optional_node, :location],                            # SingletonClassNode
     136_u8 => [] of FieldType,                                                                                      # SourceEncodingNode
     137_u8 => [:string],                                                                                            # SourceFileNode
     138_u8 => [] of FieldType,                                                                                      # SourceLineNode
     139_u8 => [:location, :optional_node],                                                                          # SplatNode
     140_u8 => [:node_array],                                                                                        # StatementsNode
     141_u8 => [:optional_location, :location, :optional_location, :string],                                         # StringNode
     142_u8 => [:location, :optional_location, :optional_node, :optional_location, :optional_node],                  # SuperNode
     143_u8 => [:optional_location, :optional_location, :optional_location, :string],                                # SymbolNode
     144_u8 => [] of FieldType,                                                                                      # TrueNode
     145_u8 => [:node_array, :location],                                                                             # UndefNode
     146_u8 => [:location, :node, :optional_location, :optional_node, :optional_node, :optional_location],           # UnlessNode
     147_u8 => [:location, :optional_location, :optional_location, :node, :optional_node],                           # UntilNode
     148_u8 => [:location, :node_array, :optional_location, :optional_node],                                         # WhenNode
     149_u8 => [:location, :optional_location, :optional_location, :node, :optional_node],                           # WhileNode
     150_u8 => [:location, :location, :location, :string],                                                           # XStringNode
     151_u8 => [:location, :optional_location, :optional_node, :optional_location],                                  # YieldNode
    } of UInt8 => Array(FieldType)
  end

  # Convenience: parse Ruby source and return an AST
  def self.parse(source : String) : ProgramNode
    data = serialize_parse(source)
    Deserializer.new(data, source).deserialize
  end
end
