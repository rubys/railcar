# railcar-ast — interactive AST debugger.
#
# Primary audience: developers (and Claude Code sessions) working on
# filters and emitters. Quickly dump the Crystal AST for a snippet of
# Ruby/Crystal code, optionally after running it through the filter
# chain, optionally after running program.semantic() for typed output.
#
# Usage:
#   railcar-ast -e 'puts "hi"'                       # Ruby AST
#   railcar-ast file.rb                              # from file
#   railcar-ast --erb file.html.erb                  # ERB → Crystal AST
#   railcar-ast --filter InstanceVarToLocal -e '@x'  # apply a filter
#   railcar-ast --filter A,B,C --trace -e '@x'       # show each filter's output
#   railcar-ast --semantic --types -e 'x = "hi"'     # post-semantic + type annotations
#   railcar-ast --find Call file.rb                  # find all Call nodes
#   railcar-ast --locations file.rb                  # include source locations

require "../generator/ast_dump"
require "../generator/erb_compiler"
require "../generator/source_parser"
require "../generator/prism_translator"

# Filters (explicit list; keeps dependency surface controlled).
require "../filters/instance_var_to_local"
require "../filters/rails_helpers"
require "../filters/link_to_path_helper"
require "../filters/button_to_path_helper"
require "../filters/render_to_partial"
require "../filters/form_to_html"
require "../filters/turbo_stream_connect"
require "../filters/view_cleanup"
require "../filters/buf_to_interpolation"
require "../filters/strip_turbo_stream"
require "../filters/strip_callbacks"
require "../filters/respond_to_html"
require "../filters/params_expect"
require "../filters/strong_params"
require "../filters/redirect_to_response"
require "../filters/python_constructor"
require "../filters/python_view"
require "../filters/typescript_view"

# Filter registry. Only filters that can be constructed without configuration
# are registered here — filters that need controller/model names, view helper
# sets, etc. are applied by their owning generator and aren't useful standalone.
FILTERS = {
  "InstanceVarToLocal"   => ->{ Railcar::InstanceVarToLocal.new.as(Crystal::Transformer) },
  "RailsHelpers"         => ->{ Railcar::RailsHelpers.new.as(Crystal::Transformer) },
  "LinkToPathHelper"     => ->{ Railcar::LinkToPathHelper.new.as(Crystal::Transformer) },
  "ButtonToPathHelper"   => ->{ Railcar::ButtonToPathHelper.new.as(Crystal::Transformer) },
  "RenderToPartial"      => ->{ Railcar::RenderToPartial.new.as(Crystal::Transformer) },
  "FormToHTML"           => ->{ Railcar::FormToHTML.new.as(Crystal::Transformer) },
  "TurboStreamConnect"   => ->{ Railcar::TurboStreamConnect.new.as(Crystal::Transformer) },
  "ViewCleanup"          => ->{ Railcar::ViewCleanup.new.as(Crystal::Transformer) },
  "BufToInterpolation"   => ->{ Railcar::BufToInterpolation.new.as(Crystal::Transformer) },
  "StripTurboStream"     => ->{ Railcar::StripTurboStream.new.as(Crystal::Transformer) },
  "StripCallbacks"       => ->{ Railcar::StripCallbacks.new.as(Crystal::Transformer) },
  "RespondToHTML"        => ->{ Railcar::RespondToHTML.new.as(Crystal::Transformer) },
  "ParamsExpect"         => ->{ Railcar::ParamsExpect.new.as(Crystal::Transformer) },
  "StrongParams"         => ->{ Railcar::StrongParams.new.as(Crystal::Transformer) },
  "PythonConstructor"    => ->{ Railcar::PythonConstructor.new.as(Crystal::Transformer) },
  "PythonView"           => ->{ Railcar::PythonView.new([] of String).as(Crystal::Transformer) },
  "TypeScriptView"       => ->{ Railcar::TypeScriptView.new.as(Crystal::Transformer) },
} of String => Proc(Crystal::Transformer)

module RailcarAst
  class Options
    property source : String? = nil
    property file : String? = nil
    property erb : Bool = false
    property parser : String = "prism" # "prism" or "crystal"
    property filter_names : Array(String) = [] of String
    property trace : Bool = false
    property semantic : Bool = false
    property show_types : Bool = false
    property show_locations : Bool = false
    property find_class : String? = nil
    property help : Bool = false
  end

  def self.parse_args(argv : Array(String)) : Options
    opts = Options.new
    i = 0
    while i < argv.size
      arg = argv[i]
      case arg
      when "-h", "--help"
        opts.help = true
      when "-e"
        opts.source = argv[i + 1]; i += 1
      when "-f"
        opts.file = argv[i + 1]; i += 1
      when "--erb"
        opts.erb = true
      when "--parser"
        opts.parser = argv[i + 1]; i += 1
      when "--filter"
        opts.filter_names = argv[i + 1].split(",").map(&.strip); i += 1
      when "--trace"
        opts.trace = true
      when "--semantic"
        opts.semantic = true
      when "--types"
        opts.show_types = true
      when "--locations"
        opts.show_locations = true
      when "--find"
        opts.find_class = argv[i + 1]; i += 1
      else
        # Positional: treat as file
        if opts.file.nil? && opts.source.nil?
          opts.file = arg
        end
      end
      i += 1
    end
    opts
  end

  def self.print_help
    puts <<-HELP
    railcar-ast — dump Crystal AST structure for debugging

    Usage:
      railcar-ast -e 'ruby code'                     inline Ruby source
      railcar-ast file.rb                            read a file
      railcar-ast --erb file.html.erb                ERB template (pre-compiles via ErbCompiler)

    Transformation:
      --filter A,B,C        apply one or more filters in order
      --trace               when used with --filter, dump after each filter
      --semantic            run through program.semantic() with a minimal prelude

    Output:
      --types               annotate each node with :: Type (requires --semantic)
      --locations           annotate each node with @line:col
      --find CLASSNAME      walk the result and print only nodes of that class

    Input:
      --parser prism|crystal   override parser choice (default: prism)

    Available filters:
    #{FILTERS.keys.sort.map { |k| "  " + k }.join("\n")}
    HELP
  end

  def self.run(argv : Array(String)) : Int32
    opts = parse_args(argv)
    if opts.help
      print_help
      return 0
    end

    source = read_source(opts)
    return 1 unless source

    ast = parse_source(source, opts)
    return 1 unless ast

    # Optional filter chain
    if opts.filter_names.empty?
      dump_result(ast, opts)
    elsif opts.trace
      dump_trace(ast, opts)
    else
      ast = apply_filters(ast, opts.filter_names)
      return 1 unless ast
      dump_result(ast, opts)
    end

    0
  end

  private def self.read_source(opts : Options) : String?
    if src = opts.source
      src
    elsif path = opts.file
      unless File.exists?(path)
        STDERR.puts "File not found: #{path}"
        return nil
      end
      raw = File.read(path)
      if opts.erb || path.ends_with?(".erb")
        Railcar::ErbCompiler.new(raw).src
      else
        raw
      end
    else
      STDERR.puts "No input: pass -e 'code' or a filename (or --help)"
      nil
    end
  end

  private def self.parse_source(source : String, opts : Options) : Crystal::ASTNode?
    # ERB pre-processing already happened in read_source when the input was
    # a file. For inline -e snippets, apply it here.
    source = Railcar::ErbCompiler.new(source).src if opts.erb && opts.file.nil?

    # ErbCompiler produces Crystal syntax (_buf = ::String.new; ...), so use
    # the Crystal parser for that path regardless of the --parser flag.
    if opts.erb
      Crystal::Parser.parse(source)
    elsif opts.parser == "crystal"
      Crystal::Parser.parse(source)
    else
      # prism: Ruby source → Crystal AST
      Railcar::PrismTranslator.translate(source)
    end
  rescue ex
    STDERR.puts "Parse error: #{ex.message}"
    nil
  end

  private def self.apply_filters(ast : Crystal::ASTNode,
                                  names : Array(String)) : Crystal::ASTNode?
    names.each do |name|
      factory = FILTERS[name]?
      unless factory
        STDERR.puts "Unknown filter: #{name} (use --help to list)"
        return nil
      end
      ast = ast.transform(factory.call)
    end
    ast
  end

  private def self.dump_trace(ast : Crystal::ASTNode, opts : Options) : Nil
    puts "── initial ──"
    dump_result(ast, opts)
    opts.filter_names.each do |name|
      puts
      puts "── after #{name} ──"
      factory = FILTERS[name]?
      unless factory
        STDERR.puts "Unknown filter: #{name}"
        next
      end
      ast = ast.transform(factory.call)
      dump_result(ast, opts)
    end
  end

  private def self.dump_result(ast : Crystal::ASTNode, opts : Options) : Nil
    if opts.semantic
      ast = run_semantic(ast)
    end
    if klass = opts.find_class
      print_matches(ast, klass, opts)
    else
      puts Railcar::AstDump.dump(ast,
        with_types: opts.show_types,
        with_locations: opts.show_locations)
    end
  end

  # Wraps the AST in a program with prelude, runs semantic(), returns the
  # typed AST. Intended for standalone snippets — code that references
  # external types will fail.
  private def self.run_semantic(ast : Crystal::ASTNode) : Crystal::ASTNode
    program = Crystal::Program.new
    compiler = Crystal::Compiler.new
    compiler.no_codegen = true
    program.compiler = compiler

    location = Crystal::Location.new("snippet.cr", 1, 1)
    nodes = Crystal::Expressions.new([
      Crystal::Require.new("prelude").at(location),
      ast,
    ] of Crystal::ASTNode)

    normalized = program.normalize(nodes)
    program.semantic(normalized)
  rescue ex
    STDERR.puts "Semantic failed: #{ex.message}"
    ast
  end

  # Walks the AST and prints each node whose class name matches.
  private def self.print_matches(ast : Crystal::ASTNode, klass : String,
                                  opts : Options) : Nil
    count = 0
    walk(ast) do |node|
      short = node.class.name.split("::").last
      if short == klass
        count += 1
        puts "── match ##{count} ──"
        puts Railcar::AstDump.dump(node,
          with_types: opts.show_types,
          with_locations: opts.show_locations)
      end
    end
    puts "(#{count} match#{count == 1 ? "" : "es"})"
  end

  # Depth-first walk over every node in the AST. Uses a simple visitor
  # that yields each node then recurses into well-known child fields.
  private def self.walk(node : Crystal::ASTNode, &block : Crystal::ASTNode ->) : Nil
    yield node
    children_of(node).each { |child| walk(child, &block) }
  end

  private def self.children_of(node : Crystal::ASTNode) : Array(Crystal::ASTNode)
    result = [] of Crystal::ASTNode
    case node
    when Crystal::Expressions
      result.concat(node.expressions)
    when Crystal::Call
      result << node.obj.not_nil! if node.obj
      result.concat(node.args)
      if named = node.named_args
        result.concat(named.map(&.value.as(Crystal::ASTNode)))
      end
      result << node.block.not_nil! if node.block
    when Crystal::Block
      result << node.body
    when Crystal::Def
      result.concat(node.args.map(&.as(Crystal::ASTNode)))
      result << node.body
      if rt = node.return_type
        result << rt
      end
    when Crystal::Arg
      if r = node.restriction
        result << r
      end
      if dv = node.default_value
        result << dv
      end
    when Crystal::Assign
      result << node.target
      result << node.value
    when Crystal::OpAssign
      result << node.target
      result << node.value
    when Crystal::If
      result << node.cond << node.then << node.else
    when Crystal::Unless
      result << node.cond << node.then << node.else
    when Crystal::While
      result << node.cond << node.body
    when Crystal::StringInterpolation
      result.concat(node.expressions)
    when Crystal::ArrayLiteral
      result.concat(node.elements)
    when Crystal::HashLiteral
      node.entries.each do |e|
        result << e.key << e.value
      end
    when Crystal::ClassDef
      if sc = node.superclass
        result << sc
      end
      result << node.body
    when Crystal::ModuleDef
      result << node.body
    when Crystal::Cast
      result << node.obj << node.to
    when Crystal::IsA
      result << node.obj << node.const
    when Crystal::Not
      result << node.exp
    when Crystal::And
      result << node.left << node.right
    when Crystal::Or
      result << node.left << node.right
    when Crystal::Return
      if e = node.exp
        result << e
      end
    when Crystal::Yield
      result.concat(node.exps)
    end
    result
  end
end

exit RailcarAst.run(ARGV)
