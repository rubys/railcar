# cr2py — Crystal to Python transpiler
#
# Reads a compiled Crystal application (via Compiler.no_codegen),
# walks the typed AST, and emits equivalent Python source.
#
# Usage: cr2py path/to/crystal-app/src/app.cr output-dir
#
# The input must be a compilable Crystal application with shards installed.

require "../../../src/semantic"

entry = ARGV[0]?
output_dir = ARGV[1]?

unless entry && output_dir
  STDERR.puts "Usage: cr2py <crystal-app-entry> <output-dir>"
  exit 1
end

unless File.exists?(entry)
  STDERR.puts "File not found: #{entry}"
  exit 1
end

full_path = File.expand_path(entry)
app_dir = File.dirname(File.dirname(full_path))

puts "cr2py: analyzing #{entry}"

# Run Crystal compiler without codegen
compiler = Crystal::Compiler.new
compiler.no_codegen = true

saved_dir = Dir.current
Dir.cd(app_dir)

source = Crystal::Compiler::Source.new(
  "src/" + File.basename(full_path),
  File.read(full_path)
)

begin
  result = compiler.compile(source, "cr2py_analyze")
rescue ex
  STDERR.puts "Compilation failed: #{ex.message.try(&.lines.first)}"
  exit 1
end

Dir.cd(saved_dir)

puts "cr2py: semantic analysis OK"

# Extract Railcar module types
railcar = result.program.types["Railcar"]?
unless railcar
  STDERR.puts "No Railcar module found"
  exit 1
end

# Report what we found
models = [] of {String, Crystal::Type}
controllers = [] of {String, Crystal::Type}
other = [] of String

railcar.types.each do |name, type|
  if name.ends_with?("Controller")
    controllers << {name, type}
  elsif !%w[ErrorEntry Errors TurboBroadcast Broadcasts Log ValidationError
            RecordNotFound ApplicationRecord Relation CollectionProxy
            RouteHelpers ViewHelpers Router].includes?(name)
    models << {name, type}
  else
    other << name
  end
end

puts "  models: #{models.map(&.[0]).join(", ")}"
puts "  controllers: #{controllers.map(&.[0]).join(", ")}"
puts "  runtime: #{other.join(", ")}"

# Create output directory
Dir.mkdir_p(output_dir)

# For now, just dump the type info
models.each do |name, type|
  puts "\n#{name}:"
  begin
    type.instance_vars.each do |ivar_name, ivar|
      puts "  #{ivar_name}: #{ivar.type?}" if ivar.type?
    end
  rescue
  end
  type.defs.try &.each do |method_name, defs_list|
    defs_list.each do |d|
      args = d.def.args.map { |a| "#{a.name}: #{a.restriction || "?"}" }.join(", ")
      ret = d.def.return_type || d.def.body.try(&.type?)
      puts "  def #{method_name}(#{args}): #{ret || "?"}"
    end
  end
end

controllers.each do |name, type|
  puts "\n#{name}:"
  type.defs.try &.each do |method_name, defs_list|
    defs_list.each do |d|
      args = d.def.args.map { |a| "#{a.name}: #{a.restriction || "?"}" }.join(", ")
      ret = d.def.return_type || d.def.body.try(&.type?)
      puts "  def #{method_name}(#{args}): #{ret || "?"}"
    end
  end
end

puts "\ncr2py: done"
