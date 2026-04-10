require "./generator/app_generator"
require "./generator/rbs_generator"

rbs_mode = ARGV.delete("--rbs")

if ARGV.size < 2
  STDERR.puts "Usage: railcar [--rbs] <rails-app-dir> <output-dir>"
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
else
  generator = Railcar::AppGenerator.new(rails_dir, output_dir)
  generator.generate
end
