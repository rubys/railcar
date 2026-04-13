require "./generator/app_generator"
require "./generator/rbs_generator"
require "./generator/python_generator"
require "./generator/python2_generator"

# Ensure Crystal stdlib is findable at runtime for semantic analysis.
# CRYSTAL_STDLIB is set as an env var during `make` and baked in via macro.
CRYSTAL_STDLIB_PATH = {{ env("CRYSTAL_STDLIB") || "" }}
unless CRYSTAL_STDLIB_PATH.empty?
  ENV["CRYSTAL_PATH"] ||= "lib:#{CRYSTAL_STDLIB_PATH}"
end

rbs_mode = ARGV.delete("--rbs")
python0_mode = ARGV.delete("--python0")
python_mode = ARGV.delete("--python")

if ARGV.size < 2
  STDERR.puts "Usage: railcar [--rbs|--python|--python0] <rails-app-dir> <output-dir>"
  exit 1
end

rails_dir = ARGV[0]
output_dir = ARGV[1]

unless Dir.exists?(rails_dir)
  STDERR.puts "Rails app directory not found: #{rails_dir}"
  exit 1
end

if rbs_mode
  app = Railcar::AppModel.extract(rails_dir)
  Railcar::RbsGenerator.new(app, rails_dir).generate(output_dir)
elsif python0_mode
  app = Railcar::AppModel.extract(rails_dir)
  Railcar::PythonGenerator.new(app, rails_dir).generate(output_dir)
elsif python_mode
  app = Railcar::AppModel.extract(rails_dir)
  Railcar::Python2Generator.new(app, rails_dir).generate(output_dir)
else
  generator = Railcar::AppGenerator.new(rails_dir, output_dir)
  generator.generate
end
