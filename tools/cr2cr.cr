# cr2cr — Read a Crystal application, write it back out.
# Shows what the typed AST looks like when serialized,
# including macro-expanded ECR templates.
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
puts ""

# Walk the typed AST and group nodes by source file
files = {} of String => Array(String)

def collect_by_file(node : Crystal::ASTNode, files : Hash(String, Array(String)), app_dir : String)
  loc = node.location
  if loc
    filename = loc.original_filename || loc.filename
    if filename.is_a?(String) && filename.starts_with?("src/")
      files[filename] ||= [] of String
      # Only add top-level declarations, not every sub-node
      text = node.to_s
      files[filename] << text unless text.strip.empty?
    end
  end

  case node
  when Crystal::Expressions
    node.expressions.each { |e| collect_by_file(e, files, app_dir) }
  when Crystal::ModuleDef
    collect_by_file(node.body, files, app_dir)
  when Crystal::ClassDef
    # Don't recurse into class bodies — the class to_s includes everything
  when Crystal::Require
    # Show expanded requires
    if expanded = node.expanded
      collect_by_file(expanded, files, app_dir)
    end
  end
end

collect_by_file(result.node, files, app_dir)

# Write each file
files.each do |filename, contents|
  out_path = File.join(output_dir, filename)
  Dir.mkdir_p(File.dirname(out_path))

  # Try to format
  source_text = contents.join("\n\n")
  begin
    formatted = Crystal.format(source_text)
    File.write(out_path, formatted)
  rescue
    File.write(out_path, source_text)
  end
  puts "  #{filename} (#{contents.size} nodes)"
end

# Also dump all unique source filenames referenced in the AST
puts "\nAll source files referenced:"
all_files = Set(String).new

def collect_filenames(node : Crystal::ASTNode, files : Set(String))
  if loc = node.location
    fn = loc.original_filename || loc.filename
    files << fn.to_s if fn.is_a?(String) && fn.to_s.starts_with?("src/")
  end
  case node
  when Crystal::Expressions
    node.expressions.each { |e| collect_filenames(e, files) }
  when Crystal::ModuleDef
    collect_filenames(node.body, files)
  when Crystal::ClassDef
    collect_filenames(node.body, files)
  when Crystal::Def
    collect_filenames(node.body, files) if node.body
  when Crystal::If
    collect_filenames(node.then, files)
    collect_filenames(node.else, files) if node.else
  when Crystal::Call
    node.args.each { |a| collect_filenames(a, files) }
    collect_filenames(node.obj.not_nil!, files) if node.obj
    collect_filenames(node.block.not_nil!.body, files) if node.block
  when Crystal::Assign
    collect_filenames(node.value, files)
  when Crystal::Require
    collect_filenames(node.expanded.not_nil!, files) if node.expanded
  end
rescue
end

collect_filenames(result.node, all_files)
all_files.to_a.sort.each { |f| puts "  #{f}" }

puts "\ncr2cr: done"
