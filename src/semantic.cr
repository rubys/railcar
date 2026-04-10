# Crystal Semantic Analysis loader for railcar.
#
# Loads Crystal's compiler semantic phase using LLVM stubs
# (from stubs/llvm/) so that type inference can run without
# linking LLVM.
#
# Usage:
#   require "./semantic"
#   # Then use Crystal::Compiler or Crystal::Program for type inference

# Forward-declare types from files we don't load
module Crystal
  abstract class DependencyPrinter
  end
end

# Phase 1: annotatable + program (mirrors requires.cr ordering)
require "compiler/crystal/annotatable"
require "compiler/crystal/program"

# Phase 2: remaining top-level compiler files
# (skip command.cr, interpreter.cr, loader.cr)
require "compiler/crystal/compiler"
require "compiler/crystal/config"
require "compiler/crystal/crystal_path"
require "compiler/crystal/error"
require "compiler/crystal/exception"
require "compiler/crystal/formatter"
require "compiler/crystal/progress_tracker"
require "compiler/crystal/syntax"
require "compiler/crystal/types"
require "compiler/crystal/util"
require "compiler/crystal/warnings"

# Phase 2.5: codegen types needed by semantic/macros (not full codegen)
require "compiler/crystal/codegen/ast"
require "compiler/crystal/codegen/cache_dir"
require "compiler/crystal/codegen/experimental"
require "compiler/crystal/codegen/link"
require "compiler/crystal/codegen/llvm_id"
require "compiler/crystal/codegen/target"
require "compiler/crystal/codegen/types"

# Phase 3: semantic analysis
require "compiler/crystal/semantic"

# Phase 4: macros runtime (needed for macro expansion during semantic)
require "compiler/crystal/macros/*"

# Stub codegen methods that compiler.cr / macros reference at compile time.
# These are never called during semantic-only analysis, but Crystal's type
# checker needs them to exist.
class Crystal::Program
  def codegen(node, single_module = false, debug = Crystal::Debug::Default,
              frame_pointers = Crystal::FramePointers::Auto)
    raise "codegen not available — railcar uses LLVM stubs"
  end

  def size_of(type) : UInt64
    8_u64
  end

  def instance_size_of(type) : UInt64
    8_u64
  end

  def align_of(type) : UInt32
    8_u32
  end

  def offset_of(type, index) : UInt64
    0_u64
  end

  def instance_align_of(type) : UInt32
    8_u32
  end

  def instance_offset_of(type, index) : UInt64
    0_u64
  end
end

# Patch ToSVisitor for abstract ASTNode dispatch
# (same patch as railcar's existing crystal_expr.cr)
class Crystal::ToSVisitor
  def visit(node : Crystal::ASTNode)
    node.accept(self)
    false
  end
end
