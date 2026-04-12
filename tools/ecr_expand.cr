# ecr_expand — Compile a Crystal app and output an expanded ECR template.
#
# Two-pass approach:
#   Pass 1: Compile with no_codegen to find ECR.embed calls and their
#           containing method signatures.
#   Pass 2: Recompile with a synthetic call appended (using `uninitialized`)
#           to force the MainVisitor to visit the method body, which triggers
#           macro expansion of the ECR.embed.  After expansion, the ECR.embed
#           Call is replaced inline — the typed Def body contains the expanded
#           template code directly.
#
# Usage: ecr_expand path/to/crystal-app/src/app.cr

require "../src/semantic"

entry = ARGV[0]?

unless entry
  STDERR.puts "Usage: ecr_expand <crystal-app-entry>"
  exit 1
end

full_path = File.expand_path(entry)
app_dir = File.dirname(File.dirname(full_path))
source_text = File.read(full_path)
relative_entry = "src/" + File.basename(full_path)

Dir.cd(app_dir)

# --- Pass 1: compile and find ECR.embed calls ---

STDERR.puts "Pass 1: finding ECR.embed calls..."

compiler = Crystal::Compiler.new
compiler.no_codegen = true

source = Crystal::Compiler::Source.new(relative_entry, source_text)

begin
  result = compiler.compile(source, "ecr_pass1")
rescue ex
  STDERR.puts "Pass 1 failed: #{ex.message.try(&.lines.first)}"
  exit 1
end

# Visitor that locates ECR.embed calls and records their enclosing
# Def node + fully qualified type name.
class EcrFinder < Crystal::Visitor
  record EcrCall,
    ecr_filename : String,
    def_node : Crystal::Def,
    type_name : String

  getter found = [] of EcrCall
  @type_stack = [] of String
  @def_stack = [] of Crystal::Def

  def visit(node : Crystal::ClassDef)
    @type_stack.push(node.name.names.join("::"))
    true
  end

  def end_visit(node : Crystal::ClassDef)
    @type_stack.pop
  end

  def visit(node : Crystal::ModuleDef)
    @type_stack.push(node.name.names.join("::"))
    true
  end

  def end_visit(node : Crystal::ModuleDef)
    @type_stack.pop
  end

  def visit(node : Crystal::Def)
    @def_stack.push(node)
    true
  end

  def end_visit(node : Crystal::Def)
    @def_stack.pop
  end

  def visit(node : Crystal::Call)
    if node.name == "embed" &&
       (obj = node.obj).is_a?(Crystal::Path) &&
       obj.names.last == "ECR" &&
       (d = @def_stack.last?)
      if (first_arg = node.args[0]?) && first_arg.is_a?(Crystal::StringLiteral)
        # Skip stdlib files — only collect app ECR embeds
        ecr_file = first_arg.value
        if ecr_file.starts_with?("src/")
          @found << EcrCall.new(
            ecr_filename: ecr_file,
            def_node: d,
            type_name: @type_stack.join("::")
          )
        end
      end
    end
    true
  end

  def visit(node)
    true
  end
end

finder = EcrFinder.new
result.node.accept(finder)

if finder.found.empty?
  STDERR.puts "No ECR.embed calls found"
  exit 1
end

target = finder.found.first
full_type = target.type_name
def_node = target.def_node

STDERR.puts "Found: #{full_type}##{def_node.name} → ECR.embed(\"#{target.ecr_filename}\")"

# --- Build synthetic call to force the MainVisitor into the method ---

args_str = def_node.args.map do |arg|
  if r = arg.restriction
    "uninitialized #{r}"
  else
    "nil"
  end
end.join(", ")

has_block = def_node.block_arg || def_node.block_arity

synthetic = String.build do |s|
  s << "\n_ecr_inst_ = uninitialized #{full_type}\n"
  if has_block
    s << "_ecr_inst_.#{def_node.name}(#{args_str}) { \"\" }\n"
  else
    s << "_ecr_inst_.#{def_node.name}(#{args_str})\n"
  end
end

STDERR.puts "Appending synthetic call:#{synthetic}"

# --- Pass 2: recompile with synthetic call ---

STDERR.puts "Pass 2: recompiling with forced method visit..."

compiler2 = Crystal::Compiler.new
compiler2.no_codegen = true

source2 = Crystal::Compiler::Source.new(relative_entry, source_text + synthetic)

begin
  result2 = compiler2.compile(source2, "ecr_pass2")
rescue ex
  STDERR.puts "Pass 2 failed: #{ex.message.try(&.lines.first)}"
  exit 1
end

# --- Find the typed Def body via the call graph ---
#
# After macro expansion, the ECR.embed Call no longer exists in the typed
# body — it's been replaced with inline template code (`io << "..."`, etc.).
# So we find the method through the synthetic call's target_defs and print
# the fully typed body.

class TypedDefFinder < Crystal::Visitor
  getter typed_body : Crystal::ASTNode? = nil
  @target_def_name : String
  @target_type : String

  def initialize(@target_def_name, @target_type)
  end

  def visit(node : Crystal::Call)
    if node.name == @target_def_name && !@typed_body
      node.target_defs.try &.each do |d|
        if d.owner.to_s == @target_type
          @typed_body = d.body
        end
      end
    end
    true
  end

  def visit(node)
    true
  end
end

tf = TypedDefFinder.new(def_node.name, full_type)
result2.node.accept(tf)

if body = tf.typed_body
  STDERR.puts "\n--- #{full_type}##{def_node.name} (expanded #{target.ecr_filename}) ---\n"
  puts body.to_s
else
  STDERR.puts "\nCould not find typed body for #{full_type}##{def_node.name}"
  exit 1
end
