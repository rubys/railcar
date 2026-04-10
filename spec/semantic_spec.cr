require "./spec_helper"
require "../src/semantic"

describe "Crystal semantic analysis (LLVM-free)" do
  it "infers types for simple expressions" do
    compiler = Crystal::Compiler.new
    compiler.no_codegen = true
    source = Crystal::Compiler::Source.new("test.cr", <<-CRYSTAL)
      x = 1 + 2
      y = "hello"
      z = [1, 2, 3]
      w = {"key" => 42}
    CRYSTAL

    result = compiler.compile(source, "test_out")

    types = {} of String => String
    node = result.node
    if node.is_a?(Crystal::Expressions)
      node.expressions.each do |expr|
        if expr.is_a?(Crystal::Assign)
          if type = expr.value.type?
            types[expr.target.to_s] = type.to_s
          end
        end
      end
    end

    types["x"].should eq "Int32"
    types["y"].should eq "String"
    types["z"].should eq "Array(Int32)"
    types["w"].should eq "Hash(String, Int32)"
  end
end
