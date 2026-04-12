# cr2cr — Read a Crystal application, write it back out grouped by source file.
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

puts "cr2cr: analyzing #{entry}"

compiler = Crystal::Compiler.new
compiler.no_codegen = true

saved_dir = Dir.current
Dir.cd(app_dir)

source = Crystal::Compiler::Source.new(
  "src/" + File.basename(full_path),
  File.read(full_path)
)

begin
  result = compiler.compile(source, "cr2cr_out")
rescue ex
  STDERR.puts "Compilation failed: #{ex.message.try(&.lines.first)}"
  exit 1
end

Dir.cd(saved_dir)
Dir.mkdir_p(output_dir)

puts "cr2cr: semantic analysis OK"

# Collect top-level declarations grouped by source file
files = {} of String => Array(Crystal::ASTNode)

def source_file(node : Crystal::ASTNode) : String?
  if loc = node.location
    fn = loc.original_filename || loc.filename
    if fn.is_a?(String) && fn.starts_with?("src/") && !fn.includes?("/crystal/src/")
      return fn
    end
  end
  nil
end

# Walk the top-level AST — FileNodes wrap each required file's content
def collect(node : Crystal::ASTNode, files : Hash(String, Array(Crystal::ASTNode)))
  case node
  when Crystal::Expressions
    node.expressions.each { |e| collect(e, files) }
  when Crystal::FileNode
    fn = node.filename
    if fn.starts_with?("src/") || fn.includes?("/src/")
      # Extract relative path from app dir
      rel = fn.includes?("/src/") ? "src/" + fn.split("/src/").last : fn
      if rel.starts_with?("src/") && !rel.includes?("crystal/src/") && !rel.includes?("/lib/")
        # Collect the entire file node's content under this filename
        files[rel] ||= [] of Crystal::ASTNode
        inner = node.node
        case inner
        when Crystal::Expressions
          inner.expressions.each do |e|
            case e
            when Crystal::FileNode
              collect(e, files)
            when Crystal::Nop
              # skip
            else
              files[rel] << e
            end
          end
        else
          files[rel] << inner unless inner.is_a?(Crystal::Nop)
        end
      else
        # Stdlib/shard file — recurse to find app files inside
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
  when Crystal::ClassDef, Crystal::Def, Crystal::Assign, Crystal::Call, Crystal::If
    if fn = source_file(node)
      files[fn] ||= [] of Crystal::ASTNode
      files[fn] << node
    end
  end
end

collect(result.node, files)

# Write each file
files.each do |filename, nodes|
  out_path = File.join(output_dir, filename)
  Dir.mkdir_p(File.dirname(out_path))

  content = String.build do |io|
    nodes.each_with_index do |node, i|
      io << "\n" if i > 0
      io << node.to_s
      io << "\n"
    end
  end

  # Try to format
  begin
    formatted = Crystal.format(content)
    File.write(out_path, formatted)
  rescue
    File.write(out_path, content)
  end

  puts "  #{filename} (#{nodes.size} declarations)"
end

puts "\ncr2cr: done"
