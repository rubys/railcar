require "./spec_helper"
require "../src/semantic"
require "../src/generator/source_parser"
require "../src/generator/prism_translator"
require "../src/generator/app_model"
require "../src/generator/schema_extractor"
require "../src/generator/model_extractor"
require "../src/generator/controller_extractor"
require "../src/generator/route_extractor"
require "../src/generator/inflector"
require "../src/filters/respond_to_html"
require "../src/filters/instance_var_to_local"

module TypeCollector
  def self.collect(node : Crystal::ASTNode) : Hash(String, String)
    result = {} of String => String
    walk(node, result)
    result
  end

  def self.collect_calls(node : Crystal::ASTNode) : Array(String)
    calls = [] of String
    walk_calls(node, calls)
    calls
  end

  private def self.walk(node : Crystal::ASTNode, result : Hash(String, String))
    case node
    when Crystal::Expressions then node.expressions.each { |e| walk(e, result) }
    when Crystal::ClassDef then walk(node.body, result)
    when Crystal::Def then walk(node.body, result)
    when Crystal::Assign
      if t = node.value.type?
        result[node.target.to_s] = t.to_s
      end
    when Crystal::If
      walk(node.then, result)
      walk(node.else, result) if node.else
    end
  end

  private def self.walk_calls(node : Crystal::ASTNode, calls : Array(String))
    case node
    when Crystal::Expressions then node.expressions.each { |e| walk_calls(e, calls) }
    when Crystal::ClassDef then walk_calls(node.body, calls)
    when Crystal::Def then walk_calls(node.body, calls)
    when Crystal::Assign then walk_calls(node.value, calls)
    when Crystal::Call
      t = node.type?
      obj_t = node.obj.try(&.type?)
      if obj_t && t
        calls << ".#{node.name} on #{obj_t} → #{t}"
      elsif t && !node.obj
        calls << "#{node.name}() → #{t}"
      end
      walk_calls(node.obj.not_nil!, calls) if node.obj
      node.args.each { |a| walk_calls(a, calls) }
    when Crystal::If
      walk_calls(node.cond, calls)
      walk_calls(node.then, calls)
      walk_calls(node.else, calls) if node.else
    end
  end
end

describe "Python semantic type inference" do
  rails_dir = "build/demo/blog"

  it "infers types for individual controller method bodies" do
    app = Railcar::AppModel.extract(rails_dir)
    schema_map = {} of String => Railcar::TableSchema
    app.schemas.each { |s| schema_map[s.name] = s }

    stub_source = String.build do |io|
      io << "class ApplicationController\n"
      io << "  macro before_action(*args, **kwargs)\n  end\n"
      io << "  macro private\n  end\n"
      io << "end\n\n"

      app.models.each_key do |name|
        s = Railcar::Inflector.underscore(name)
        p = Railcar::Inflector.pluralize(s)
        io << "def #{s}_path(*args) : String\n  \"\"\nend\n"
        io << "def #{p}_path(*args) : String\n  \"\"\nend\n"
      end
      io << "\n"

      # Forward declare
      app.models.each_key { |name| io << "class #{name}\nend\n" }
      io << "\n"

      app.models.each do |name, model|
        tn = Railcar::Inflector.pluralize(Railcar::Inflector.underscore(name))
        schema = schema_map[tn]?
        io << "class #{name}\n  property id : Int64 = 0\n"
        schema.try &.columns.each do |col|
          next if col.name == "id"
          ct = Railcar::SchemaExtractor.crystal_type(col.type)
          d = ct == "String" ? "\"\"" : ct == "Time" ? "Time.utc" : "0"
          io << "  property #{col.name} : #{ct} = #{d}\n"
        end
        io << "  class Relation\n    include Enumerable(#{name})\n"
        io << "    def each(& : #{name} ->) : Nil\n    end\n"
        io << "    def order(**a) : Relation\n      self\n    end\n"
        io << "    def includes(*a) : Relation\n      self\n    end\n"
        io << "  end\n"
        model.associations.each do |a|
          if a.kind == :has_many
            t = Railcar::Inflector.classify(Railcar::Inflector.singularize(a.name))
            io << "  def #{a.name} : Array(#{t})\n    [] of #{t}\n  end\n"
          elsif a.kind == :belongs_to
            t = Railcar::Inflector.classify(a.name)
            io << "  def #{a.name} : #{t}\n    #{t}.new\n  end\n"
          end
        end
        io << "  def self.find(id) : #{name}\n    #{name}.new\n  end\n"
        io << "  def self.includes(*a) : Relation\n    Relation.new\n  end\n"
        io << "  def self.order(**a) : Relation\n    Relation.new\n  end\n"
        io << "  def self.new(p) : #{name}\n    #{name}.new\n  end\n"
        io << "  def save : Bool\n    true\n  end\n"
        io << "  def update(p) : Bool\n    true\n  end\n"
        io << "  def destroy! : #{name}\n    self\n  end\n"
        io << "end\n\n"
      end
    end

    info = app.controllers.find { |c| c.name == "ArticlesController" }.not_nil!

    # Test: index method — should have Article.Relation type for articles
    index_action = info.actions.find { |a| a.name == "index" }.not_nil!
    body = index_action.body.not_nil!
    translated = Railcar::PrismTranslator.new.translate(body)

    # Strip instance vars
    translated = translated.transform(Railcar::InstanceVarToLocal.new)

    method_def = Crystal::Def.new("index", body: translated)
    class_def = Crystal::ClassDef.new(Crystal::Path.new("TC"), body: method_def)
    call_site = Crystal::Assign.new(
      Crystal::Var.new("__r"),
      Crystal::Call.new(Crystal::Call.new(Crystal::Path.new("TC"), "new"), "index")
    )

    stub_ast = Crystal::Parser.parse(stub_source)
    program = Crystal::Program.new
    full_ast = Crystal::Expressions.new([
      Crystal::Require.new("prelude"), stub_ast, class_def, call_site,
    ] of Crystal::ASTNode)

    normalized = program.normalize(full_ast)
    typed = program.semantic(normalized)

    # Find the method body and check types — use a module to allow recursion
    types_found = TypeCollector.collect(typed)

    # The return type of index() is captured as __r
    types_found["__r"].should contain "Article::Relation"

    # Test: new method — should infer Article type
    new_action = info.actions.find { |a| a.name == "new" }.not_nil!
    body2 = new_action.body.not_nil!
    translated2 = Railcar::PrismTranslator.new.translate(body2)
    translated2 = translated2.transform(Railcar::InstanceVarToLocal.new)

    method_def2 = Crystal::Def.new("new_action", body: translated2)
    class_def2 = Crystal::ClassDef.new(Crystal::Path.new("TC2"), body: method_def2)
    call_site2 = Crystal::Assign.new(
      Crystal::Var.new("__r2"),
      Crystal::Call.new(Crystal::Call.new(Crystal::Path.new("TC2"), "new"), "new_action")
    )

    stub_ast2 = Crystal::Parser.parse(stub_source)
    program2 = Crystal::Program.new
    full_ast2 = Crystal::Expressions.new([
      Crystal::Require.new("prelude"), stub_ast2, class_def2, call_site2,
    ] of Crystal::ASTNode)

    normalized2 = program2.normalize(full_ast2)
    typed2 = program2.semantic(normalized2)

    types_found2 = TypeCollector.collect(typed2)
    types_found2["__r2"].should eq "Article"
  end
end
