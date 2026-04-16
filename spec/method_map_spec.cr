require "spec"
require "../src/filters/method_map"

describe Railcar do
  describe ".lookup_method" do
    # ── Go ──

    it "maps String#downcase to Go" do
      m = Railcar.lookup_method(:go, "String", "downcase")
      m.should_not be_nil
      m.not_nil!.target.should eq "strings.ToLower(RECV)"
    end

    it "maps String#include? to Go" do
      m = Railcar.lookup_method(:go, "String", "include?")
      m.not_nil!.target.should eq "strings.Contains(RECV, ARG0)"
    end

    it "maps String#empty? to Go" do
      m = Railcar.lookup_method(:go, "String", "empty?")
      m.not_nil!.target.should eq "RECV == \"\""
    end

    it "maps Array#size to Go" do
      m = Railcar.lookup_method(:go, "Array", "size")
      m.not_nil!.target.should eq "len(RECV)"
    end

    it "maps Array#empty? to Go" do
      m = Railcar.lookup_method(:go, "Array", "empty?")
      m.not_nil!.target.should eq "len(RECV) == 0"
    end

    it "maps Array#any? to Go" do
      m = Railcar.lookup_method(:go, "Array", "any?")
      m.not_nil!.target.should eq "len(RECV) > 0"
    end

    it "maps Any#nil? to Go" do
      m = Railcar.lookup_method(:go, "Any", "nil?")
      m.not_nil!.target.should eq "RECV == nil"
    end

    it "falls back to Any for unknown receiver type in Go" do
      m = Railcar.lookup_method(:go, "Comment", "nil?")
      m.not_nil!.target.should eq "RECV == nil"
    end

    it "returns nil for unknown method in Go" do
      m = Railcar.lookup_method(:go, "String", "unknown_method")
      m.should be_nil
    end

    # ── Rust ──

    it "maps String#downcase to Rust" do
      m = Railcar.lookup_method(:rust, "String", "downcase")
      m.not_nil!.target.should eq ".to_lowercase()"
    end

    it "maps String#include? to Rust" do
      m = Railcar.lookup_method(:rust, "String", "include?")
      m.not_nil!.target.should eq ".contains(ARG0)"
    end

    it "maps String#empty? to Rust" do
      m = Railcar.lookup_method(:rust, "String", "empty?")
      m.not_nil!.target.should eq ".is_empty()"
    end

    it "maps Array#size to Rust" do
      m = Railcar.lookup_method(:rust, "Array", "size")
      m.not_nil!.target.should eq ".len()"
    end

    it "maps Array#empty? to Rust" do
      m = Railcar.lookup_method(:rust, "Array", "empty?")
      m.not_nil!.target.should eq ".is_empty()"
    end

    it "maps Array#first to Rust" do
      m = Railcar.lookup_method(:rust, "Array", "first")
      m.not_nil!.target.should eq ".first()"
    end

    it "maps Hash#keys to Rust" do
      m = Railcar.lookup_method(:rust, "Hash", "keys")
      m.not_nil!.target.should eq ".keys().collect::<Vec<_>>()"
    end

    # ── Python ──

    it "maps String#downcase to Python" do
      m = Railcar.lookup_method(:python, "String", "downcase")
      m.not_nil!.target.should eq ".lower()"
    end

    it "maps Array#include? to Python" do
      m = Railcar.lookup_method(:python, "Array", "include?")
      m.not_nil!.target.should eq "ARG0 in RECV"
    end

    it "maps Array#last to Python" do
      m = Railcar.lookup_method(:python, "Array", "last")
      m.not_nil!.target.should eq "RECV[-1]"
    end

    it "maps Hash#merge to Python" do
      m = Railcar.lookup_method(:python, "Hash", "merge")
      m.not_nil!.target.should eq "{**RECV, **ARG0}"
    end

    # ── Elixir ──

    it "maps String#downcase to Elixir" do
      m = Railcar.lookup_method(:elixir, "String", "downcase")
      m.not_nil!.target.should eq "String.downcase(RECV)"
    end

    it "maps Array#size to Elixir" do
      m = Railcar.lookup_method(:elixir, "Array", "size")
      m.not_nil!.target.should eq "length(RECV)"
    end

    it "maps Hash#merge to Elixir" do
      m = Railcar.lookup_method(:elixir, "Hash", "merge")
      m.not_nil!.target.should eq "Map.merge(RECV, ARG0)"
    end

    it "maps Any#nil? to Elixir" do
      m = Railcar.lookup_method(:elixir, "Any", "nil?")
      m.not_nil!.target.should eq "is_nil(RECV)"
    end

    # ── TypeScript ──

    it "maps String#downcase to TypeScript" do
      m = Railcar.lookup_method(:typescript, "String", "downcase")
      m.not_nil!.target.should eq ".toLowerCase()"
    end

    it "maps Array#size to TypeScript as property" do
      m = Railcar.lookup_method(:typescript, "Array", "size")
      m.not_nil!.target.should eq ".length"
      m.not_nil!.property.should be_true
    end

    it "maps Array#flatten to TypeScript" do
      m = Railcar.lookup_method(:typescript, "Array", "flatten")
      m.not_nil!.target.should eq ".flat()"
    end

    it "maps Hash#keys to TypeScript" do
      m = Railcar.lookup_method(:typescript, "Hash", "keys")
      m.not_nil!.target.should eq "Object.keys(RECV)"
    end

    # ── Cross-target consistency ──

    it "has freeze for all targets" do
      [:go, :rust, :python, :elixir, :typescript].each do |target|
        m = Railcar.lookup_method(target, "Any", "freeze")
        m.should_not be_nil
      end
    end

    it "has to_s for all targets" do
      [:go, :rust, :python, :elixir, :typescript].each do |target|
        m = Railcar.lookup_method(target, "Any", "to_s")
        m.should_not be_nil
      end
    end

    it "returns nil for unknown target" do
      m = Railcar.lookup_method(:java, "String", "downcase")
      m.should be_nil
    end
  end
end
