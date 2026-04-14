require "spec"
require "compiler/crystal/syntax"
require "../src/semantic"
require "../tools/cr2py/src/py_ast"
require "../tools/cr2py/src/filters/db_filter"
require "../tools/cr2py/src/cr2py"
require "../src/generator/python2_generator"

# Helper: parse Crystal code and get the AST
def parse_crystal(code : String) : Crystal::ASTNode
  Crystal::Parser.new(code).parse
end

# Helper: build a minimal emitter for testing
# (We can't use the full Emitter without a compiled program,
# so we test filters and PyAST independently)

describe "PyAST::Serializer" do
  serializer = PyAST::Serializer.new

  it "serializes a simple function" do
    func = PyAST::Func.new("greet", ["self", "name: str"], [
      PyAST::Return.new("f'Hello {name}'"),
    ] of PyAST::Node)
    mod = PyAST::Module.new([func] of PyAST::Node)
    output = serializer.serialize(mod)
    output.should contain "def greet(self, name: str):"
    output.should contain "return f'Hello {name}'"
  end

  it "serializes a class with methods" do
    func = PyAST::Func.new("name", ["self"], [
      PyAST::Return.new("self._name"),
    ] of PyAST::Node, "str")
    cls = PyAST::Class.new("Article", "Base", [func] of PyAST::Node)
    mod = PyAST::Module.new([cls] of PyAST::Node)
    output = serializer.serialize(mod)
    output.should contain "class Article(Base):"
    output.should contain "    def name(self) -> str:"
    output.should contain "        return self._name"
  end

  it "serializes decorators on functions" do
    func = PyAST::Func.new("find", ["cls", "id: int"], [
      PyAST::Return.new("None"),
    ] of PyAST::Node, "Self", ["classmethod"])
    cls = PyAST::Class.new("Article", nil, [func] of PyAST::Node)
    mod = PyAST::Module.new([cls] of PyAST::Node)
    output = serializer.serialize(mod)
    output.should contain "    @classmethod"
    output.should contain "    def find(cls, id: int) -> Self:"
  end

  it "serializes if/elif/else" do
    inner_if = PyAST::If.new("x > 10", [PyAST::Return.new("'big'")] of PyAST::Node)
    if_node = PyAST::If.new("x > 100", [PyAST::Return.new("'huge'")] of PyAST::Node, [inner_if] of PyAST::Node)
    mod = PyAST::Module.new([if_node] of PyAST::Node)
    output = serializer.serialize(mod)
    output.should contain "if x > 100:"
    output.should contain "elif x > 10:"
  end

  it "serializes buf literals with triple quotes" do
    buf = PyAST::BufLiteral.new("<div class=\"test\">\n  <p>hello</p>\n</div>")
    mod = PyAST::Module.new([buf] of PyAST::Node)
    output = serializer.serialize(mod)
    output.should contain "_buf += '''"
  end

  it "serializes empty body as pass" do
    func = PyAST::Func.new("noop", ["self"], [] of PyAST::Node)
    mod = PyAST::Module.new([func] of PyAST::Node)
    output = serializer.serialize(mod)
    output.should contain "pass"
  end

  it "serializes for loop" do
    loop_node = PyAST::For.new("item", "items", [
      PyAST::Statement.new("process(item)"),
    ] of PyAST::Node)
    mod = PyAST::Module.new([loop_node] of PyAST::Node)
    output = serializer.serialize(mod)
    output.should contain "for item in items:"
    output.should contain "    process(item)"
  end
end

describe "Cr2Py::DbFilter" do
  filter = Cr2Py::DbFilter.new

  it "transforms DB.open to sqlite3.connect" do
    code = %{DB.open("sqlite3::memory:")}
    ast = parse_crystal(code)
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "sqlite3"
    output.should contain "connect"
    output.should contain ":memory:"
  end

  it "transforms db.exec to db.execute" do
    code = %{db.exec("CREATE TABLE foo")}
    ast = parse_crystal(code)
    result = ast.transform(filter)
    output = result.to_s
    output.should contain ".execute("
    output.should_not contain ".exec("
  end

  it "transforms db.scalar to execute.fetchone[0]" do
    code = %{db.scalar("SELECT COUNT(*) FROM articles")}
    ast = parse_crystal(code)
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "execute"
    output.should contain "fetchone"
  end

  it "transforms Time.utc to datetime.now" do
    code = %{Time.utc}
    ast = parse_crystal(code)
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "datetime"
    output.should contain "now"
  end

  it "transforms Log.for to logging.getLogger" do
    code = %{Log.for("sql")}
    ast = parse_crystal(code)
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "logging"
    output.should contain "getLogger"
  end
end

describe "Cr2Py::PyAstDunderFilter" do
  filter = Cr2Py::PyAstDunderFilter.new
  serializer = PyAST::Serializer.new

  it "adds __bool__ when class has is_any method and __init__" do
    cls = PyAST::Class.new("Errors", nil, [
      PyAST::Func.new("__init__", ["self"], [
        PyAST::Statement.new("self.data = {}"),
      ] of PyAST::Node),
      PyAST::Func.new("is_any", ["self"], [
        PyAST::Return.new("bool(self.data)"),
      ] of PyAST::Node, "bool"),
    ] of PyAST::Node)
    result = filter.transform([cls] of PyAST::Node)
    mod = PyAST::Module.new(result)
    output = serializer.serialize(mod)
    output.should contain "__bool__"
    output.should contain "bool(self.data)"
  end

  it "adds __len__ when class has size method" do
    cls = PyAST::Class.new("Collection", nil, [
      PyAST::Func.new("size", ["self"], [
        PyAST::Return.new("len(self.items)"),
      ] of PyAST::Node, "int"),
    ] of PyAST::Node)
    result = filter.transform([cls] of PyAST::Node)
    mod = PyAST::Module.new(result)
    output = serializer.serialize(mod)
    output.should contain "__len__"
    output.should contain "self.size()"
  end

  it "does not add __bool__ if already defined" do
    cls = PyAST::Class.new("MyClass", nil, [
      PyAST::Func.new("is_any", ["self"], [
        PyAST::Return.new("True"),
      ] of PyAST::Node),
      PyAST::Func.new("__bool__", ["self"], [
        PyAST::Return.new("False"),
      ] of PyAST::Node),
    ] of PyAST::Node)
    result = filter.transform([cls] of PyAST::Node)
    mod = PyAST::Module.new(result)
    output = serializer.serialize(mod)
    # Should have exactly one __bool__
    output.scan(/__bool__/).size.should eq 1
  end

  it "leaves non-class nodes unchanged" do
    func = PyAST::Func.new("standalone", [] of String, [
      PyAST::Return.new("42"),
    ] of PyAST::Node)
    result = filter.transform([func] of PyAST::Node)
    result.size.should eq 1
    result[0].should be_a(PyAST::Func)
  end
end

describe "Cr2Py::Emitter" do
  # Build a typed program from the runtime for emitter tests
  _emitter_location = Crystal::Location.new("src/app.cr", 1, 1)
  _emitter_runtime_path = File.join(File.dirname(__FILE__), "..", "src", "runtime", "python", "base.cr")
  _emitter_runtime_source = File.read(_emitter_runtime_path)
  _emitter_source = String.build do |io|
    io << "module DB\n"
    io << "  alias Any = Bool | Float32 | Float64 | Int32 | Int64 | String | Nil\n"
    io << "  class Database\n"
    io << "    def exec(sql : String, *args) end\n"
    io << "    def exec(sql : String, args : Array) end\n"
    io << "    def scalar(sql : String, *args) : Int64; 0_i64; end\n"
    io << "  end\n"
    io << "end\n\n"
    _emitter_runtime_source.lines.each do |line|
      next if line.strip.starts_with?("require ")
      io << line << "\n"
    end
  end
  _emitter_synthetic = <<-CR
    _ar = Railcar::ApplicationRecord.new
    _ar.id
    _ar.persisted?
    _ar.attributes
    _ar.errors
    _ar.save
  CR
  _emitter_nodes = Crystal::Expressions.new([
    Crystal::Require.new("prelude").at(_emitter_location),
    Crystal::Parser.parse(_emitter_source),
    Crystal::Parser.parse(_emitter_synthetic),
  ] of Crystal::ASTNode)
  _emitter_program = Crystal::Program.new
  _emitter_compiler = Crystal::Compiler.new
  _emitter_compiler.no_codegen = true
  _emitter_program.compiler = _emitter_compiler
  _emitter_normalized = _emitter_program.normalize(_emitter_nodes)
  _emitter_program.semantic(_emitter_normalized)

  emitter = Cr2Py::Emitter.new(_emitter_program)
  serializer = PyAST::Serializer.new

    # Helper to set up class context for property tests
    ar_type = _emitter_program.types["Railcar"].types["ApplicationRecord"]

    it "emits property access without parens" do
      # record.attributes → record.attributes (not record.attributes())
      record_var = Crystal::Var.new("record")
      record_var.set_type(ar_type)
      call = Crystal::Call.new(record_var, "attributes")
      emitter.in_class = true
      expr = emitter.to_expr(call)
      emitter.in_class = false
      expr.should eq "record.attributes"
    end

    it "emits method call with parens" do
      record_var = Crystal::Var.new("record")
      record_var.set_type(ar_type)
      call = Crystal::Call.new(record_var, "save")
      emitter.in_class = true
      expr = emitter.to_expr(call)
      emitter.in_class = false
      expr.should contain "save()"
    end

    it "adds self parameter inside class" do
      # Non-trivial method (not a simple ivar getter)
      defn = Crystal::Def.new("validate", body: Crystal::Call.new(nil, "check"))
      emitter.in_class = true
      emitter.current_class_type = ar_type
      emitter.current_class_name = ar_type.to_s
      nodes = emitter.to_nodes(defn)
      emitter.in_class = false
      emitter.current_class_type = nil
      emitter.current_class_name = nil
      func = nodes.first.as(PyAST::Func)
      func.args.first.should eq "self"
    end

    it "adds @classmethod for class methods" do
      defn = Crystal::Def.new("find",
        [Crystal::Arg.new("id")] of Crystal::Arg,
        Crystal::Nop.new)
      defn.receiver = Crystal::Var.new("self")
      emitter.in_class = true
      nodes = emitter.to_nodes(defn)
      emitter.in_class = false
      func = nodes.first.as(PyAST::Func)
      func.decorators.should contain "classmethod"
      func.args.first.should eq "cls"
    end

    it "skips trivial getter methods for known ivars" do
      defn = Crystal::Def.new("attributes", body: Crystal::InstanceVar.new("@attributes"))
      emitter.in_class = true
      nodes = emitter.to_nodes(defn)
      emitter.in_class = false
      nodes.should be_empty
    end

    it "emits bare ivar access as self.name without parens" do
      call = Crystal::Call.new(nil, "attributes")
      emitter.in_class = true
      emitter.in_method = true
      emitter.current_class_type = ar_type
      emitter.current_class_name = ar_type.to_s
      expr = emitter.to_expr(call)
      emitter.in_class = false
      emitter.in_method = false
      emitter.current_class_type = nil
      emitter.current_class_name = nil
      expr.should eq "self.attributes"
    end

    it "emits << as .append() for non-IO" do
      call = Crystal::Call.new(
        Crystal::Var.new("results"), "<<",
        [Crystal::Var.new("item")] of Crystal::ASTNode)
      expr = emitter.to_expr(call)
      expr.should eq "results.append(item)"
    end

    it "strips Railcar:: namespace" do
      path = Crystal::Path.new(["Railcar", "Article"])
      expr = emitter.to_expr(path)
      expr.should eq "Article"
    end

    it "emits bare new() as cls() inside class" do
      call = Crystal::Call.new(nil, "new",
        [Crystal::Var.new("attrs")] of Crystal::ASTNode)
      emitter.in_class = true
      expr = emitter.to_expr(call)
      emitter.in_class = false
      expr.should eq "cls(attrs)"
    end

    it "emits assert as statement not function" do
      call = Crystal::Call.new(nil, "assert",
        [Crystal::BoolLiteral.new(true)] of Crystal::ASTNode)
      nodes = emitter.to_nodes(call)
      func = nodes.first.as(PyAST::Statement)
      func.code.should eq "assert True"
    end

    it "maps Crystal types to Python" do
      nodes = emitter.to_nodes(
        Crystal::Def.new("foo",
          [Crystal::Arg.new("x", restriction: Crystal::Path.new("Int64")),
           Crystal::Arg.new("y", restriction: Crystal::Path.new("String"))] of Crystal::Arg,
          Crystal::Nop.new,
          return_type: Crystal::Path.new("Bool"))
      )
      func = nodes.first.as(PyAST::Func)
      func.args.should contain "x: int"
      func.args.should contain "y: str"
      func.return_type.should eq "bool"
    end

end

describe "Python runtime emission" do
  runtime_path = File.join(File.dirname(__FILE__), "..", "src", "runtime", "python", "base.cr")

  unless File.exists?(runtime_path)
    pending "requires runtime/python/base.cr" { }
    next
  end

  # Compile the runtime and emit Python
  location = Crystal::Location.new("src/app.cr", 1, 1)
  runtime_source = File.read(runtime_path)
  source = String.build do |io|
    io << "module DB\n"
    io << "  alias Any = Bool | Float32 | Float64 | Int32 | Int64 | String | Nil\n"
    io << "  class Database\n"
    io << "    def exec(sql : String, *args) end\n"
    io << "    def exec(sql : String, args : Array) end\n"
    io << "    def scalar(sql : String, *args) : Int64; 0_i64; end\n"
    io << "  end\n"
    io << "end\n\n"
    runtime_source.lines.each do |line|
      next if line.strip.starts_with?("require ")
      io << line << "\n"
    end
  end

  # Synthetic calls to force typing of all methods
  synthetic = <<-CR
    _ve = Railcar::ValidationErrors.new
    _ve.add("field", "message")
    _ve.any?
    _ve.empty?
    _ve.full_messages
    _ve["field"]
    _ve.clear
    _ar = Railcar::ApplicationRecord.new
    _ar.id
    _ar.persisted?
    _ar.new_record?
    _ar.attributes
    _ar.errors
    _ar.valid?
    _ar.save
    _ar.run_validations
    Railcar::ApplicationRecord.table_name
    Railcar::ApplicationRecord.count
  CR

  nodes = Crystal::Expressions.new([
    Crystal::Require.new("prelude").at(location),
    Crystal::Parser.parse(source),
    Crystal::Parser.parse(synthetic),
  ] of Crystal::ASTNode)

  program = Crystal::Program.new
  compiler = Crystal::Compiler.new
  compiler.no_codegen = true
  program.compiler = compiler
  normalized = program.normalize(nodes)
  typed = program.semantic(normalized)

  emitter = Cr2Py::Emitter.new(program)
  serializer = PyAST::Serializer.new
  db_filter = Cr2Py::DbFilter.new
  dunder_filter = Cr2Py::PyAstDunderFilter.new

  # Extract Railcar nodes and emit
  railcar_nodes = [] of Crystal::ASTNode
  case typed
  when Crystal::Expressions
    typed.expressions.each do |expr|
      if expr.is_a?(Crystal::ModuleDef) && expr.name.names.includes?("Railcar")
        case expr.body
        when Crystal::Expressions
          railcar_nodes.concat(expr.body.as(Crystal::Expressions).expressions)
        else
          railcar_nodes << expr.body
        end
      end
    end
  end

  py_nodes = [] of PyAST::Node
  railcar_nodes.each do |node|
    next unless node.is_a?(Crystal::ClassDef)
    transformed = node.transform(db_filter)
    py_nodes.concat(emitter.to_nodes(transformed))
  end
  py_nodes = dunder_filter.transform(py_nodes)
  mod = PyAST::Module.new(py_nodes)
  output = serializer.serialize(mod)

  it "has program types for property detection" do
    # Verify program types are available for smart lookups
    # (we use program.types instead of node.type? for property detection)
    ar_type = program.types["Railcar"]?.try(&.types["ApplicationRecord"]?)
    ar_type.should_not be_nil
    if ar_type
      ar_type.all_instance_vars.has_key?("@attributes").should be_true
      ar_type.all_instance_vars.has_key?("@persisted").should be_true
      ar_type.all_instance_vars.has_key?("@errors").should be_true
    end
  end

  it "produces valid Python syntax" do
    # Use Crystal's string matching — can't call python3 from spec
    output.should_not contain "  el        if"
    output.should contain "class ValidationErrors"
    output.should contain "class ApplicationRecord"
  end

  it "has ValidationErrors with add and is_any" do
    output.should contain "def add(self, field: str, message: str)"
    output.should contain "def is_any(self)"
  end

  it "has ApplicationRecord with __init__, save, destroy" do
    output.should contain "def __init__(self"
    output.should contain "def save(self)"
    output.should contain "def destroy(self)"
  end

  it "has classmethods for find, count, create, table_name" do
    output.should contain "@classmethod"
    output.should contain "def find(cls"
    output.should contain "def count(cls"
    output.should contain "def create(cls"
    output.should contain "def table_name(cls"
  end

  it "has do_insert and do_update" do
    output.should contain "def do_insert(self)"
    output.should contain "def do_update(self)"
  end

  it "uses sqlite3 patterns from DbFilter" do
    output.should contain "execute("
    output.should contain "fetchone()"
    output.should contain "datetime.now()"
  end

  it "adds __bool__ via PyAstDunderFilter" do
    output.should contain "__bool__"
  end

  it "has type annotations" do
    output.should contain "-> bool"
    output.should contain "-> str"
    output.should contain "field: str"
  end
end
