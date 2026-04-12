# cr2cr — Read a Crystal application, write it back out grouped by source file.
# Two-pass: first pass finds ECR.embed calls, second pass forces their expansion
# via synthetic calls with `uninitialized`, then outputs expanded code.
#
# Usage: cr2cr path/to/crystal-app/src/app.cr output-dir

require "../src/semantic"

entry = ARGV[0]?
output_dir = ARGV[1]?

unless entry && output_dir
  STDERR.puts "Usage: cr2cr <crystal-app-entry> <output-dir>"
  exit 1
end

full_path = File.expand_path(entry)
app_dir = File.dirname(File.dirname(full_path))
source_text = File.read(full_path)
relative_entry = "src/" + File.basename(full_path)

Dir.cd(app_dir)

puts "cr2cr: pass 1 — analyzing #{entry}"

# --- Pass 1: compile and find ECR.embed calls ---

compiler = Crystal::Compiler.new
compiler.no_codegen = true
source = Crystal::Compiler::Source.new(relative_entry, source_text)

begin
  result = compiler.compile(source, "cr2cr_pass1")
rescue ex
  STDERR.puts "Pass 1 failed: #{ex.message.try(&.lines.first)}"
  exit 1
end

# Find all ECR.embed calls with their enclosing method and type
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

puts "  found #{finder.found.size} ECR.embed calls"

# --- Build synthetic calls for pass 2 ---

# Group by type::method to avoid duplicates
seen = Set(String).new
idx = 0
synthetic = String.build do |s|
  s << "\n# Synthetic calls to force ECR expansion\n"
  finder.found.each do |ecr|
    key = "#{ecr.type_name}##{ecr.def_node.name}"
    next if seen.includes?(key)
    seen << key
    idx += 1

    # Declare uninitialized variables for each arg type
    arg_names = ecr.def_node.args.map_with_index do |arg, ai|
      vname = "_cr2cr_#{idx}_a#{ai}_"
      if r = arg.restriction
        s << "#{vname} = uninitialized #{r}\n"
      else
        s << "#{vname} = nil\n"
      end
      vname
    end

    has_block = ecr.def_node.block_arg || ecr.def_node.block_arity
    s << "_cr2cr_#{idx}_ = uninitialized #{ecr.type_name}\n"
    if has_block
      s << "_cr2cr_#{idx}_.#{ecr.def_node.name}(#{arg_names.join(", ")}) { \"\" }\n"
    else
      s << "_cr2cr_#{idx}_.#{ecr.def_node.name}(#{arg_names.join(", ")})\n"
    end
  end
end

# --- Pass 2: recompile with synthetic calls ---

puts "cr2cr: pass 2 — recompiling with forced ECR expansion"

compiler2 = Crystal::Compiler.new
compiler2.no_codegen = true
source2 = Crystal::Compiler::Source.new(relative_entry, source_text + synthetic)

begin
  result2 = compiler2.compile(source2, "cr2cr_pass2")
rescue ex
  STDERR.puts "Pass 2 failed: #{ex.message.try(&.lines.first)}"
  exit 1
end

# --- Build map of expanded method bodies from target_defs ---

class TypedBodyCollector < Crystal::Visitor
  # method key (type::method) → expanded body
  getter bodies = {} of String => Crystal::ASTNode

  def visit(node : Crystal::Call)
    node.target_defs.try &.each do |d|
      key = "#{d.owner}##{d.name}"
      unless @bodies.has_key?(key)
        @bodies[key] = d.body
      end
    end
    true
  end

  def visit(node)
    true
  end
end

collector = TypedBodyCollector.new
result2.node.accept(collector)

# Build a set of methods that have expanded ECR
ecr_methods = {} of String => Crystal::ASTNode
finder.found.each do |ecr|
  key = "#{ecr.type_name}##{ecr.def_node.name}"
  if body = collector.bodies[key]?
    ecr_methods[key] = body
  end
end

puts "  expanded #{ecr_methods.size} method bodies"

# --- Collect files from pass 2 AST ---

def source_file(node : Crystal::ASTNode) : String?
  if loc = node.location
    fn = loc.original_filename || loc.filename
    if fn.is_a?(String) && fn.starts_with?("src/") && !fn.includes?("/crystal/src/")
      return fn
    end
  end
  nil
end

files = {} of String => Array(Crystal::ASTNode)

def collect(node : Crystal::ASTNode, files : Hash(String, Array(Crystal::ASTNode)))
  case node
  when Crystal::Expressions
    node.expressions.each { |e| collect(e, files) }
  when Crystal::FileNode
    fn = node.filename
    if fn.starts_with?("src/") || fn.includes?("/src/")
      rel = fn.includes?("/src/") ? "src/" + fn.split("/src/").last : fn
      if rel.starts_with?("src/") && !rel.includes?("crystal/src/") && !rel.includes?("/lib/")
        files[rel] ||= [] of Crystal::ASTNode
        inner = node.node
        case inner
        when Crystal::Expressions
          inner.expressions.each do |e|
            case e
            when Crystal::FileNode then collect(e, files)
            when Crystal::Nop then nil
            else files[rel] << e
            end
          end
        else
          files[rel] << inner unless inner.is_a?(Crystal::Nop)
        end
      else
        collect(node.node, files)
      end
    else
      collect(node.node, files)
    end
  when Crystal::Require
    if expanded = node.expanded
      collect(expanded, files)
    end
  when Crystal::ModuleDef
    if fn = source_file(node)
      files[fn] ||= [] of Crystal::ASTNode
      files[fn] << node
    else
      collect(node.body, files)
    end
  when Crystal::MacroExpression, Crystal::MacroIf, Crystal::MacroFor, Crystal::MacroVerbatim
    if expanded = node.expanded
      collect(expanded, files)
    end
  when Crystal::ClassDef, Crystal::Def, Crystal::Assign, Crystal::Call, Crystal::If
    if fn = source_file(node)
      files[fn] ||= [] of Crystal::ASTNode
      files[fn] << node
    end
  end
end

collect(result2.node, files)

# --- Transformer: replace macro nodes AND ECR.embed calls with expanded content ---

class ExpandTransformer < Crystal::Transformer
  getter ecr_methods : Hash(String, Crystal::ASTNode)
  @type_stack = [] of String
  @def_stack = [] of String

  def initialize(@ecr_methods)
  end

  def transform(node : Crystal::ModuleDef)
    @type_stack.push(node.name.names.join("::"))
    result = super
    @type_stack.pop
    result
  end

  def transform(node : Crystal::ClassDef)
    @type_stack.push(node.name.names.join("::"))
    result = super
    @type_stack.pop
    result
  end

  def transform(node : Crystal::Def)
    @def_stack.push(node.name)
    result = super
    @def_stack.pop
    result
  end

  def transform(node : Crystal::Call)
    # Replace ECR.embed(...) with expanded body
    if node.name == "embed" &&
       (obj = node.obj).is_a?(Crystal::Path) &&
       obj.names.last == "ECR"
      type = @type_stack.join("::")
      method = @def_stack.last?
      if method
        key = "#{type}##{method}"
        if body = @ecr_methods[key]?
          return body
        end
      end
    end

    # Replace macro-expanded calls
    if node.expanded_macro && (expanded = node.expanded)
      return expanded.transform(self)
    end

    super
  end

  def transform(node : Crystal::MacroExpression)
    if expanded = node.expanded
      expanded.transform(self)
    else
      node
    end
  end

  def transform(node : Crystal::MacroIf)
    if expanded = node.expanded
      expanded.transform(self)
    else
      node
    end
  end

  def transform(node : Crystal::MacroFor)
    if expanded = node.expanded
      expanded.transform(self)
    else
      node
    end
  end

  def transform(node : Crystal::MacroVerbatim)
    if expanded = node.expanded
      expanded.transform(self)
    else
      node
    end
  end
end

# --- Write output files (only app src, not stdlib/shards) ---

Dir.mkdir_p(output_dir)
expander = ExpandTransformer.new(ecr_methods)

# Scan original app directory for source files
app_sources = Set(String).new
Dir.glob(File.join(app_dir, "src/**/*.cr")).each do |path|
  rel = path.sub(app_dir + "/", "")
  app_sources << rel
end

files.each do |filename, nodes|
  next unless app_sources.includes?(filename)

  out_path = File.join(output_dir, filename)
  Dir.mkdir_p(File.dirname(out_path))

  content = String.build do |io|
    nodes.each_with_index do |node, i|
      io << "\n" if i > 0
      io << node.transform(expander).to_s
      io << "\n"
    end
  end

  begin
    formatted = Crystal.format(content)
    File.write(out_path, formatted)
  rescue
    File.write(out_path, content)
  end

  puts "  #{filename}"
end

puts "\ncr2cr: done"
