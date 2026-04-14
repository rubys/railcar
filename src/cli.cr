require "./generator/app_generator"
require "./generator/rbs_generator"
require "./generator/python2_generator"

# Ensure Crystal stdlib is findable at runtime for semantic analysis.
# CRYSTAL_STDLIB is set as an env var during `make` and baked in via macro.
CRYSTAL_STDLIB_PATH = {{ env("CRYSTAL_STDLIB") || "" }}
unless CRYSTAL_STDLIB_PATH.empty?
  ENV["CRYSTAL_PATH"] ||= "lib:#{CRYSTAL_STDLIB_PATH}"
end

# Target language aliases — maps flags and file extensions to canonical names.
TARGET_ALIASES = {
  "crystal"    => "crystal",
  "cr"         => "crystal",
  "python"     => "python",
  "py"         => "python",
  "typescript" => "typescript",
  "ts"         => "typescript",
  "rbs"        => "rbs",
}

# Detect target from ARGV flags (--python, --cr, --target=ts, etc.)
target = "crystal"
ARGV.reject! do |arg|
  case arg
  when /^--target=(.+)$/
    name = TARGET_ALIASES[$1]?
    if name
      target = name
      true
    else
      STDERR.puts "Unknown target: #{$1}"
      STDERR.puts "Available targets: #{TARGET_ALIASES.keys.join(", ")}"
      exit 1
    end
  when /^--(.+)$/
    name = TARGET_ALIASES[$1]?
    if name
      target = name
      true
    else
      false  # keep unknown flags (future use)
    end
  else
    false
  end
end

if ARGV.size < 2
  STDERR.puts "Usage: railcar [--target=<target>] <rails-app-dir> <output-dir>"
  STDERR.puts "Targets: crystal (default), python, typescript, rbs"
  STDERR.puts "Aliases: --cr, --py, --ts, --crystal, --python, --typescript, --rbs"
  exit 1
end

rails_dir = ARGV[0]
output_dir = ARGV[1]

unless Dir.exists?(rails_dir)
  STDERR.puts "Rails app directory not found: #{rails_dir}"
  exit 1
end

case target
when "crystal"
  generator = Railcar::AppGenerator.new(rails_dir, output_dir)
  generator.generate
when "python"
  app = Railcar::AppModel.extract(rails_dir)
  Railcar::Python2Generator.new(app, rails_dir).generate(output_dir)
when "typescript"
  STDERR.puts "TypeScript target is not yet implemented."
  exit 1
when "rbs"
  app = Railcar::AppModel.extract(rails_dir)
  Railcar::RbsGenerator.new(app, rails_dir).generate(output_dir)
end
