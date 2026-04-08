require "./generator/app_generator"

if ARGV.size < 2
  STDERR.puts "Usage: ruby2cr <rails-app-dir> <output-dir>"
  exit 1
end

rails_dir = ARGV[0]
output_dir = ARGV[1]

unless Dir.exists?(rails_dir)
  STDERR.puts "Rails app directory not found: #{rails_dir}"
  exit 1
end

generator = Ruby2CR::AppGenerator.new(rails_dir, output_dir)
generator.generate
