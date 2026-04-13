# Crystal Analyzer — compile a Crystal application and return typed AST
# grouped by source file, with expanded ECR views and import/export info.
#
# Two-pass compilation:
#   Pass 1: no_codegen to find ECR.embed calls and method signatures
#   Pass 2: recompile with synthetic calls to force ECR macro expansion
#
# Usage:
#   require "crystal-analyzer"
#
#   result = CrystalAnalyzer.analyze("path/to/src/app.cr")
#   result.files.each { |name, info| ... }
#   result.views.each { |name, ast| ... }

# The semantic module (LLVM stubs + Crystal compiler phases) must be
# loaded by the consuming application. This shard assumes it's available.
#
# In railcar:   require "../src/semantic"
# Standalone:   require the equivalent setup

module CrystalAnalyzer
  # Info about a single source file
  class FileInfo
    getter nodes : Array(Crystal::ASTNode)
    getter exports : Array(String)
    getter imports : Array(String)

    def initialize(@nodes, @exports = [] of String, @imports = [] of String)
    end
  end

  # Result of analyzing a Crystal application
  class Result
    getter files : Hash(String, FileInfo)
    getter views : Hash(String, Crystal::ASTNode)
    getter tests : Hash(String, FileInfo)
    getter program : Crystal::Program
    getter typed_defs : Hash(String, Array(Crystal::Def))

    def initialize(@files, @views, @program,
                   @tests = {} of String => FileInfo,
                   @typed_defs = {} of String => Array(Crystal::Def))
    end
  end

  # Analyze a Crystal application. Returns typed AST grouped by source file.
  # When include_specs is true, also compiles spec files and returns them
  # in result.tests.
  def self.analyze(entry_path : String, include_specs : Bool = false) : Result
    full_path = File.expand_path(entry_path)
    app_dir = File.dirname(File.dirname(full_path))
    source_text = File.read(full_path)
    relative_entry = "src/" + File.basename(full_path)

    saved_dir = Dir.current
    Dir.cd(app_dir)

    # Scan original app directory for source files
    app_sources = Set(String).new
    Dir.glob(File.join(app_dir, "src/**/*.cr")).each do |path|
      app_sources << path.sub(app_dir + "/", "")
    end

    # Scan spec files if requested
    spec_sources = Set(String).new
    if include_specs
      Dir.glob(File.join(app_dir, "spec/**/*.cr")).each do |path|
        spec_sources << path.sub(app_dir + "/", "")
      end
    end

    # --- Pass 1: find ECR.embed calls ---
    compiler = Crystal::Compiler.new
    compiler.no_codegen = true
    source = Crystal::Compiler::Source.new(relative_entry, source_text)
    result = compiler.compile(source, "analyzer_pass1")

    finder = EcrFinder.new
    result.node.accept(finder)

    # --- Build synthetic calls for pass 2 ---
    seen = Set(String).new
    idx = 0
    synthetic = String.build do |s|
      finder.found.each do |ecr|
        key = "#{ecr.type_name}##{ecr.def_node.name}"
        next if seen.includes?(key)
        seen << key
        idx += 1

        ecr.def_node.args.each_with_index do |arg, ai|
          if r = arg.restriction
            s << "_ca_#{idx}_a#{ai}_ = uninitialized #{r}\n"
          else
            s << "_ca_#{idx}_a#{ai}_ = nil\n"
          end
        end

        arg_names = ecr.def_node.args.map_with_index { |_, ai| "_ca_#{idx}_a#{ai}_" }
        has_block = ecr.def_node.block_arg || ecr.def_node.block_arity

        s << "_ca_#{idx}_ = uninitialized #{ecr.type_name}\n"
        if has_block
          s << "_ca_#{idx}_.#{ecr.def_node.name}(#{arg_names.join(", ")}) { \"\" }\n"
        else
          s << "_ca_#{idx}_.#{ecr.def_node.name}(#{arg_names.join(", ")})\n"
        end
      end
    end

    # --- Pass 2: recompile with forced ECR expansion ---
    compiler2 = Crystal::Compiler.new
    compiler2.no_codegen = true
    source2 = Crystal::Compiler::Source.new(relative_entry, source_text + synthetic)
    result2 = compiler2.compile(source2, "analyzer_pass2")

    # --- Collect files from pass 2 AST ---
    raw_files = {} of String => Array(Crystal::ASTNode)
    collect_files(result2.node, raw_files)

    # --- Collect typed Defs from call graph ---
    typed_defs = collect_typed_defs(result2.node)

    # --- Collect expanded ECR view bodies from typed defs ---
    ecr_methods = {} of String => Crystal::ASTNode
    ecr_views = {} of String => Crystal::ASTNode

    finder.found.each do |ecr|
      key = "#{ecr.type_name}##{ecr.def_node.name}"
      if candidates = typed_defs[key]?
        body = candidates.first.body
        ecr_methods[key] = body
        ecr_views[ecr.ecr_filename] ||= body
      end
    end

    # --- Build import/export info per file ---
    files = {} of String => FileInfo
    tests = {} of String => FileInfo
    expander = ExpandTransformer.new(ecr_methods)
    substituter = TypedDefSubstituter.new(typed_defs)

    raw_files.each do |filename, nodes|
      is_source = app_sources.includes?(filename)
      is_spec = spec_sources.includes?(filename)
      next unless is_source || is_spec

      # Substitute typed Defs, then expand macros
      expanded_nodes = nodes.map { |n| n.transform(substituter).transform(expander) }

      exports = [] of String
      imports = [] of String
      extract_exports_imports(expanded_nodes, exports, imports)

      info = FileInfo.new(expanded_nodes, exports, imports)
      if is_spec
        tests[filename] = info
      else
        files[filename] = info
      end
    end

    # --- Optional: compile spec files separately ---
    if include_specs && !spec_sources.empty?
      begin
        # Build a synthetic spec runner that requires all spec files
        spec_entry = String.build do |s|
          spec_sources.to_a.sort.each do |spec_path|
            req = spec_path.sub(/\.cr$/, "")
            s << "require \"./" << req << "\"\n"
          end
        end

        spec_compiler = Crystal::Compiler.new
        spec_compiler.no_codegen = true
        # Use a virtual entry at the app root
        spec_source = Crystal::Compiler::Source.new("_spec_runner_.cr", spec_entry)
        spec_result = spec_compiler.compile(spec_source, "analyzer_specs")

        # Collect spec files from the AST
        spec_raw_files = {} of String => Array(Crystal::ASTNode)
        collect_files(spec_result.node, spec_raw_files)

        spec_raw_files.each do |filename, nodes|
          next unless spec_sources.includes?(filename)

          expanded_nodes = nodes.map { |n| n.transform(expander) }

          exports = [] of String
          imports = [] of String
          extract_exports_imports(expanded_nodes, exports, imports)

          tests[filename] = FileInfo.new(expanded_nodes, exports, imports)
        end
      rescue ex
        msg = ex.message || "unknown error"
        STDERR.puts "Warning: spec compilation failed:\n#{msg}"
      end
    end

    Dir.cd(saved_dir)

    Result.new(files, ecr_views, result2.program, tests, typed_defs)
  end

  # --- ECR Finder (pass 1) ---

  class EcrFinder < Crystal::Visitor
    record EcrCall,
      ecr_filename : String,
      def_node : Crystal::Def,
      type_name : String

    getter found = [] of EcrCall
    @type_stack = [] of String
    @def_stack = [] of Crystal::Def

    def visit(node : Crystal::ClassDef)
      @type_stack.push(node.name.names.join("::"))
      true
    end

    def end_visit(node : Crystal::ClassDef)
      @type_stack.pop
    end

    def visit(node : Crystal::ModuleDef)
      @type_stack.push(node.name.names.join("::"))
      true
    end

    def end_visit(node : Crystal::ModuleDef)
      @type_stack.pop
    end

    def visit(node : Crystal::Def)
      @def_stack.push(node)
      true
    end

    def end_visit(node : Crystal::Def)
      @def_stack.pop
    end

    def visit(node : Crystal::Call)
      if node.name == "embed" &&
         (obj = node.obj).is_a?(Crystal::Path) &&
         obj.names.last == "ECR" &&
         (d = @def_stack.last?)
        if (first_arg = node.args[0]?) && first_arg.is_a?(Crystal::StringLiteral)
          ecr_file = first_arg.value
          if ecr_file.starts_with?("src/")
            @found << EcrCall.new(
              ecr_filename: ecr_file,
              def_node: d,
              type_name: @type_stack.join("::")
            )
          end
        end
      end
      true
    end

    def visit(node)
      true
    end
  end

  # --- File collector ---

  private def self.app_file?(fn : String) : Bool
    return false unless fn.is_a?(String)
    return false if fn.includes?("/crystal/src/") || fn.includes?("/lib/")
    fn.starts_with?("src/") || fn.starts_with?("spec/")
  end

  private def self.source_file(node : Crystal::ASTNode) : String?
    if loc = node.location
      fn = loc.original_filename || loc.filename
      if fn.is_a?(String) && app_file?(fn)
        return fn
      end
    end
    nil
  end

  private def self.collect_files(node : Crystal::ASTNode, files : Hash(String, Array(Crystal::ASTNode)))
    case node
    when Crystal::Expressions
      node.expressions.each { |e| collect_files(e, files) }
    when Crystal::FileNode
      fn = node.filename
      # Normalize: extract relative path from src/ or spec/
      rel = if fn.starts_with?("src/") || fn.starts_with?("spec/")
              fn
            elsif fn.includes?("/src/")
              "src/" + fn.split("/src/").last
            elsif fn.includes?("/spec/")
              "spec/" + fn.split("/spec/").last
            else
              nil
            end
      if rel && app_file?(rel)
        files[rel] ||= [] of Crystal::ASTNode
        inner = node.node
        case inner
        when Crystal::Expressions
          inner.expressions.each do |e|
            case e
            when Crystal::FileNode then collect_files(e, files)
            when Crystal::Nop then nil
            else files[rel] << e
            end
          end
        else
          files[rel] << inner unless inner.is_a?(Crystal::Nop)
        end
      else
        collect_files(node.node, files)
      end
    when Crystal::Require
      if expanded = node.expanded
        collect_files(expanded, files)
      end
    when Crystal::ModuleDef
      if fn = source_file(node)
        files[fn] ||= [] of Crystal::ASTNode
        files[fn] << node
      else
        collect_files(node.body, files)
      end
    when Crystal::MacroExpression, Crystal::MacroIf, Crystal::MacroFor, Crystal::MacroVerbatim
      if expanded = node.expanded
        collect_files(expanded, files)
      end
    when Crystal::ClassDef, Crystal::Def, Crystal::Assign, Crystal::Call, Crystal::If
      if fn = source_file(node)
        files[fn] ||= [] of Crystal::ASTNode
        files[fn] << node
      end
    end
  end

  # --- Expand macros transformer ---

  class ExpandTransformer < Crystal::Transformer
    getter ecr_methods : Hash(String, Crystal::ASTNode)
    @type_stack = [] of String
    @def_stack = [] of String

    def initialize(@ecr_methods)
    end

    def transform(node : Crystal::ModuleDef)
      @type_stack.push(node.name.names.join("::"))
      result = super
      @type_stack.pop
      result
    end

    def transform(node : Crystal::ClassDef)
      @type_stack.push(node.name.names.join("::"))
      result = super
      @type_stack.pop
      result
    end

    def transform(node : Crystal::Def)
      @def_stack.push(node.name)
      result = super
      @def_stack.pop
      result
    end

    def transform(node : Crystal::Call)
      if node.name == "embed" &&
         (obj = node.obj).is_a?(Crystal::Path) &&
         obj.names.last == "ECR"
        type = @type_stack.join("::")
        method = @def_stack.last?
        if method
          key = "#{type}##{method}"
          if body = @ecr_methods[key]?
            return body
          end
        end
      end

      if node.expanded_macro && (expanded = node.expanded)
        return expanded.transform(self)
      end

      super
    end

    def transform(node : Crystal::MacroExpression)
      if expanded = node.expanded
        expanded.transform(self)
      else
        node
      end
    end

    def transform(node : Crystal::MacroIf)
      if expanded = node.expanded
        expanded.transform(self)
      else
        node
      end
    end

    def transform(node : Crystal::MacroFor)
      if expanded = node.expanded
        expanded.transform(self)
      else
        node
      end
    end

    def transform(node : Crystal::MacroVerbatim)
      if expanded = node.expanded
        expanded.transform(self)
      else
        node
      end
    end
  end

  # --- Typed Def collection from call graph ---

  # Walk the call graph starting from the top-level AST to collect typed
  # Defs.  Unlike program.types (which holds untyped definitions), the
  # call graph's target_defs have fully typed bodies — the compiler
  # instantiates inherited methods per-type, so `Article#save` appears
  # with owner `Railcar::Article` and a typed body, even though the
  # source definition lives in `ApplicationRecord`.
  private def self.collect_typed_defs(node : Crystal::ASTNode) : Hash(String, Array(Crystal::Def))
    typed = {} of String => Array(Crystal::Def)
    visited = Set(UInt64).new

    # Seed: collect target_defs from top-level calls
    queue = [] of Crystal::Def
    seed = CallGraphWalker.new
    node.accept(seed)
    queue.concat(seed.defs)

    # Walk the call graph recursively
    while d = queue.pop?
      next if visited.includes?(d.object_id)
      visited << d.object_id

      if loc = d.location
        fn = loc.original_filename || loc.filename
        if fn.is_a?(String)
          # Normalize absolute paths to relative (e.g. /abs/path/src/foo.cr → src/foo.cr)
          if !fn.starts_with?("src/") && !fn.starts_with?("spec/")
            if idx = fn.index("/src/")
              fn = fn[(idx + 1)..]
            elsif idx = fn.index("/spec/")
              fn = fn[(idx + 1)..]
            end
          end
          if app_file?(fn)
            key = "#{d.owner}##{d.name}"
            list = typed[key] ||= [] of Crystal::Def
            list << d unless list.any? { |existing| existing.object_id == d.object_id }
          end
        end
      end

      walker = CallGraphWalker.new
      d.body.accept(walker)
      queue.concat(walker.defs)
    end

    typed
  end

  private class CallGraphWalker < Crystal::Visitor
    getter defs = [] of Crystal::Def

    def visit(node : Crystal::Call)
      node.target_defs.try &.each { |d| @defs << d }
      true
    end

    def visit(node)
      true
    end
  end

  # --- Typed Def substituter ---

  # Replaces untyped Def nodes from the parse tree with their typed
  # counterparts from the call graph.
  class TypedDefSubstituter < Crystal::Transformer
    getter typed_defs : Hash(String, Array(Crystal::Def))
    @type_stack = [] of String

    def initialize(@typed_defs)
    end

    def transform(node : Crystal::ModuleDef)
      @type_stack.push(node.name.names.join("::"))
      result = super
      @type_stack.pop
      result
    end

    def transform(node : Crystal::ClassDef)
      @type_stack.push(node.name.names.join("::"))
      result = super
      @type_stack.pop
      result
    end

    def transform(node : Crystal::Def)
      owner = @type_stack.join("::")
      key = "#{owner}##{node.name}"
      # Try instance method key, then class method key (.class suffix)
      candidates = @typed_defs[key]? || @typed_defs["#{owner}.class##{node.name}"]?
      if candidates
        # Match by exact arity — don't fall back to first, as that would
        # replace a kwargs overload with a positional one
        if typed = candidates.find { |d| d.args.size == node.args.size }
          typed
        else
          super  # keep original (untyped) if no arity match
        end
      else
        super
      end
    end
  end

  # --- Import/Export extraction ---

  private def self.extract_exports_imports(nodes : Array(Crystal::ASTNode),
                                            exports : Array(String),
                                            imports : Array(String))
    nodes.each do |node|
      extract_node_exports(node, exports, [] of String)
      extract_node_imports(node, imports)
    end
    exports.uniq!
    imports.uniq!
    # Remove self-references
    imports.reject! { |i| exports.includes?(i) }
  end

  private def self.extract_node_exports(node : Crystal::ASTNode, exports : Array(String), scope : Array(String))
    case node
    when Crystal::ModuleDef
      name = scope.empty? ? node.name.to_s : "#{scope.join("::")}::#{node.name}"
      exports << name
      extract_node_exports(node.body, exports, scope + [node.name.to_s])
    when Crystal::ClassDef
      name = scope.empty? ? node.name.to_s : "#{scope.join("::")}::#{node.name}"
      exports << name
      extract_node_exports(node.body, exports, scope + [node.name.to_s])
    when Crystal::Def
      # Top-level defs are exports
      if scope.empty?
        exports << node.name
      end
    when Crystal::Assign
      target = node.target
      if target.is_a?(Crystal::Path)
        exports << target.to_s
      end
    when Crystal::Expressions
      node.expressions.each { |e| extract_node_exports(e, exports, scope) }
    end
  end

  private def self.extract_node_imports(node : Crystal::ASTNode, imports : Array(String))
    case node
    when Crystal::Path
      imports << node.names.join("::")
    when Crystal::Call
      if obj = node.obj
        if obj.is_a?(Crystal::Path)
          imports << obj.names.join("::")
        else
          extract_node_imports(obj, imports)
        end
      end
      node.args.each { |a| extract_node_imports(a, imports) }
      if block = node.block
        extract_node_imports(block.body, imports)
      end
    when Crystal::Assign
      extract_node_imports(node.value, imports)
    when Crystal::If
      extract_node_imports(node.cond, imports)
      extract_node_imports(node.then, imports)
      extract_node_imports(node.else, imports) if node.else
    when Crystal::Expressions
      node.expressions.each { |e| extract_node_imports(e, imports) }
    when Crystal::ModuleDef
      extract_node_imports(node.body, imports)
    when Crystal::ClassDef
      extract_node_imports(node.body, imports)
    when Crystal::Def
      extract_node_imports(node.body, imports) if node.body
    when Crystal::Include
      extract_node_imports(node.name, imports)
    end
  end
end
