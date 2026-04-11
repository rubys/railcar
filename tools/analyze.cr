# Standalone tool: run semantic analysis on a generated Crystal app.
# Usage: crystal run tools/analyze.cr -- path/to/crystal-blog/src/app.cr

require "../src/semantic"

entry = ARGV[0]? || "build/crystal-blog/src/app.cr"

unless File.exists?(entry)
  STDERR.puts "File not found: #{entry}"
  exit 1
end

puts "Analyzing: #{entry}"

# Resolve the full path before changing directory
full_path = File.expand_path(entry)
app_dir = File.dirname(File.dirname(full_path))

# Use Crystal::Compiler with no_codegen to get semantic analysis
compiler = Crystal::Compiler.new
compiler.no_codegen = true

# Change to the app directory so relative requires work
Dir.cd(app_dir)
relative_entry = "src/" + File.basename(full_path)

source = Crystal::Compiler::Source.new(relative_entry, File.read(full_path))

begin
  result = compiler.compile(source, "analyze_out")

  puts "Semantic analysis OK"
  puts ""

  # Report types from the Railcar module
  railcar = result.program.types["Railcar"]?
  if railcar
    railcar.types.each do |name, type|
      begin
        puts "#{name}:"
        type.instance_vars.each do |ivar_name, ivar|
          puts "  #{ivar_name}: #{ivar.type?}" if ivar.type?
        end
        type.defs.try &.each do |method_name, defs_list|
          defs_list.each do |d|
            ret = d.def.return_type
            body_type = d.def.body.type? if d.def.body
            display_type = ret || body_type
            puts "  def #{method_name}: #{display_type}" if display_type
          end
        end
        puts ""
      rescue
        puts "  (skipped)\n"
      end
    end
  else
    puts "Railcar module not found in program types"
  end
rescue ex
  STDERR.puts "Analysis failed: #{ex.message.try(&.lines.reject(&.empty?).first(3).join(" | "))}"
  exit 1
end

def walk_module(node, indent)
  case node
  when Crystal::Expressions
    node.expressions.each { |e| walk_module(e, indent) }
  when Crystal::ClassDef
    puts "#{indent}class #{node.name}:"
    walk_class(node.body, indent + "  ")
  end
end

def walk_class(node, indent)
  case node
  when Crystal::Expressions
    node.expressions.each { |e| walk_class(e, indent) }
  when Crystal::Def
    ret = node.return_type || node.body.type?
    puts "#{indent}def #{node.name}: #{ret || "void"}"
  when Crystal::ClassDef
    puts "#{indent}class #{node.name}:"
    walk_class(node.body, indent + "  ")
  end
end
