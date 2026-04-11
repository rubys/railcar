# Test: pre-expand a Require node with our own AST fragment,
# verify that semantic analysis uses it instead of reading from disk.

require "../src/semantic"

# A simple Crystal program that requires a file
main_source = <<-CR
  require "./models/article"
  x = Article.new
  y = x.title
CR

# Our fragment — what we want to substitute for the require
fragment = Crystal::Parser.parse(<<-CR)
  class Article
    property title : String = ""
    property body : String = ""
    def self.find(id) : Article
      Article.new
    end
  end
CR

# Parse the main source
program = Crystal::Program.new

# Parse just the main source (don't resolve requires yet)
parser = program.new_parser(main_source)
parser.filename = "test.cr"
parsed = parser.parse

# Prepend prelude
nodes = Crystal::Expressions.new([
  Crystal::Require.new("prelude"),
  parsed,
] of Crystal::ASTNode)

# Walk the AST, find the Require node for ./models/article,
# and pre-set its .expanded with our fragment
nodes.expressions.each do |expr|
  walk_and_expand(expr, {"./models/article" => fragment})
end

def walk_and_expand(node : Crystal::ASTNode, fragments : Hash(String, Crystal::ASTNode))
  case node
  when Crystal::Require
    if frag = fragments[node.string]?
      puts "Pre-expanding require \"#{node.string}\" with our fragment"
      node.expanded = frag
    end
  when Crystal::Expressions
    node.expressions.each { |e| walk_and_expand(e, fragments) }
  end
end

# Now normalize + semantic — the require should use our fragment
normalized = program.normalize(nodes)
typed = program.semantic(normalized)

# Check if types resolved
if typed.is_a?(Crystal::Expressions)
  typed.expressions.each do |expr|
    if expr.is_a?(Crystal::Assign)
      t = expr.value.type?
      puts "#{expr.target} : #{t}" if t
    end
  end
end

puts "Done!"
