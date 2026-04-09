require "./generator/app_generator"
require "./generator/rbs_generator"

rbs_mode = ARGV.delete("--rbs")

if ARGV.size < 2
  STDERR.puts "Usage: ruby2cr [--rbs] <rails-app-dir> <output-dir>"
  exit 1
end

rails_dir = ARGV[0]
output_dir = ARGV[1]

unless Dir.exists?(rails_dir)
  STDERR.puts "Rails app directory not found: #{rails_dir}"
  exit 1
end

if rbs_mode
  app = Ruby2CR::AppModel.extract(rails_dir)
  Ruby2CR::RbsGenerator.new(app).generate(output_dir)
else
  generator = Ruby2CR::AppGenerator.new(rails_dir, output_dir)
  generator.generate
end
