# LLVM stub for railcar
#
# Shadows the standard library's LLVM bindings so that Crystal's
# semantic analysis can be used without linking LLVM.
#
# The semantic phase only exercises LLVM::CallConvention at runtime.
# Everything else just needs to exist as types for compilation.

lib LibLLVM
  VERSION = "18.0.0"
  BUILT_TARGETS = [] of Symbol
  ALL_TARGETS   = [] of String

  IS_LT_90  = false
  IS_LT_100 = false
  IS_LT_110 = false
  IS_LT_120 = false
  IS_LT_130 = false
  IS_LT_140 = false
  IS_LT_150 = false
  IS_LT_160 = false
  IS_LT_170 = false
  IS_LT_180 = false
  IS_LT_190 = false
  IS_LT_200 = false
  IS_LT_210 = false
end

module LLVM
  def self.version : String
    LibLLVM::VERSION
  end

  def self.default_target_triple : String
    {% if flag?(:x86_64) %}
      {% if flag?(:darwin) %}
        "x86_64-apple-darwin"
      {% elsif flag?(:linux) %}
        "x86_64-unknown-linux-gnu"
      {% else %}
        "x86_64-unknown-unknown"
      {% end %}
    {% elsif flag?(:aarch64) %}
      {% if flag?(:darwin) %}
        "aarch64-apple-darwin"
      {% elsif flag?(:linux) %}
        "aarch64-unknown-linux-gnu"
      {% else %}
        "aarch64-unknown-unknown"
      {% end %}
    {% else %}
      "unknown-unknown-unknown"
    {% end %}
  end

  def self.normalize_triple(triple : String) : String
    triple
  end

  # Target init methods (no-ops without real LLVM)
  def self.init_x86 : Nil
  end

  def self.init_aarch64 : Nil
  end

  def self.init_arm : Nil
  end

  def self.init_avr : Nil
  end

  def self.init_webassembly : Nil
  end

  enum CallConvention
    C            =  0
    Fast         =  8
    Cold         =  9
    WebKit_JS    = 12
    AnyReg       = 13
    X86_StdCall  = 64
    X86_FastCall = 65
  end

  enum CodeModel
    Default
    JITDefault
    Tiny
    Small
    Kernel
    Medium
    Large
  end

  enum CodeGenOptLevel
    None
    Less
    Default
    Aggressive
  end

  enum RelocMode
    Default
    Static
    PIC
    DynamicNoPIC
  end

  class Target
    def self.from_triple(triple : String) : Target
      new
    end

    def create_target_machine(triple : String, cpu = "", features = "",
                              opt_level = CodeGenOptLevel::Default,
                              reloc = RelocMode::Default,
                              code_model = CodeModel::Default) : TargetMachine?
      TargetMachine.new
    end
  end

  class TargetMachine
    property enable_global_isel : Bool = false

    def triple : String
      LLVM.default_target_triple
    end

    def cpu : String
      ""
    end

    def data_layout : TargetData
      TargetData.new
    end

    def finalize
    end
  end

  struct TargetData
    def size_in_bits(type : Type) : UInt64
      0_u64
    end

    def abi_size(type : Type) : UInt64
      0_u64
    end

    def abi_alignment(type : Type) : Int32
      0_i32
    end

    def offset_of_element(struct_type : Type, element : UInt32) : UInt64
      0_u64
    end

    def to_data_layout_string : String
      ""
    end
  end

  struct Type
    enum Kind
      Void
      Half
      Float
      Double
      X86_FP80
      FP128
      PPC_FP128
      Label
      Integer
      Function
      Struct
      Array
      Pointer
      Vector
      Metadata
      X86_MMX
      Token
      ScalableVector
      BFloat
      X86_AMX
    end

    getter kind : Kind

    def initialize(@kind = Kind::Void)
    end

    def int_width : Int32
      0
    end

    def packed_struct? : Bool
      false
    end

    def struct_element_types : ::Array(Type)
      [] of Type
    end

    def element_type : Type
      Type.new
    end

    def array_size : Int32
      0
    end
  end

  class Context
    def initialize
    end

    def int1 : Type
      Type.new(Type::Kind::Integer)
    end

    def int8 : Type
      Type.new(Type::Kind::Integer)
    end

    def int16 : Type
      Type.new(Type::Kind::Integer)
    end

    def int32 : Type
      Type.new(Type::Kind::Integer)
    end

    def int64 : Type
      Type.new(Type::Kind::Integer)
    end

    def int128 : Type
      Type.new(Type::Kind::Integer)
    end

    def int(bits : Int32) : Type
      Type.new(Type::Kind::Integer)
    end

    def float : Type
      Type.new(Type::Kind::Float)
    end

    def double : Type
      Type.new(Type::Kind::Double)
    end

    def void : Type
      Type.new(Type::Kind::Void)
    end

    def void_pointer : Type
      Type.new(Type::Kind::Pointer)
    end

    def pointer : Type
      Type.new(Type::Kind::Pointer)
    end

    def struct(name : String, packed = false, &) : Type
      Type.new(Type::Kind::Struct)
    end

    def struct(elements : ::Array(Type), name : String = "", packed = false) : Type
      Type.new(Type::Kind::Struct)
    end
  end

  class Module
    property name : String = ""

    def initialize(@name = "")
    end
  end

  class MemoryBuffer
  end

  class PassManagerBuilder
    def initialize
    end
  end

  class PassRegistry
    def self.instance : PassRegistry
      new
    end

    def initialize
    end

    def initialize_native
    end
  end

  class ModulePassManager
    def initialize
    end
  end

  class PassBuilderOptions
    def initialize
    end

    def self.new(&) : Nil
      options = new
      yield options
    end
  end

  struct Value
    enum Kind
      Argument
      BasicBlock
      MemoryUse
      MemoryDef
      MemoryPhi
      Function
      GlobalAlias
      GlobalIFunc
      GlobalVariable
      BlockAddress
      ConstantExpr
      ConstantArray
      ConstantStruct
      ConstantVector
      UndefValue
      ConstantAggregateZero
      ConstantDataArray
      ConstantDataVector
      ConstantInt
      ConstantFP
      ConstantPointerNull
      ConstantTokenNone
      MetadataAsValue
      InlineAsm
      Instruction
      PoisonValue
    end
  end
end
