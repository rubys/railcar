# cr2cr — Read a Crystal application, write it back out grouped by source file.
# Uses CrystalAnalyzer shard for two-pass compilation with ECR expansion.
#
# Usage: cr2cr path/to/crystal-app/src/app.cr output-dir

require "../src/semantic"
require "../shards/crystal-analyzer/src/crystal-analyzer"

entry = ARGV[0]?
output_dir = ARGV[1]?

unless entry && output_dir
  STDERR.puts "Usage: cr2cr <crystal-app-entry> <output-dir>"
  exit 1
end

puts "cr2cr: analyzing #{entry}"

result = CrystalAnalyzer.analyze(entry)

puts "  #{result.files.size} source files, #{result.views.size} views"

Dir.mkdir_p(output_dir)

# Write source files
result.files.each do |filename, info|
  out_path = File.join(output_dir, filename)
  Dir.mkdir_p(File.dirname(out_path))

  content = String.build do |io|
    info.nodes.each_with_index do |node, i|
      io << "\n" if i > 0
      io << node.to_s
      io << "\n"
    end
  end

  begin
    formatted = Crystal.format(content)
    File.write(out_path, formatted)
  rescue
    File.write(out_path, content)
  end

  puts "  #{filename} (exports: #{info.exports.join(", ")})"
end

# Write expanded ECR views as .cr files
result.views.each do |ecr_filename, ast|
  cr_filename = ecr_filename.chomp(".ecr") + ".cr"
  out_path = File.join(output_dir, cr_filename)
  Dir.mkdir_p(File.dirname(out_path))

  content = ast.to_s

  begin
    formatted = Crystal.format(content)
    File.write(out_path, formatted)
  rescue
    File.write(out_path, content)
  end

  puts "  #{cr_filename}"
end

puts "\ncr2cr: done"
