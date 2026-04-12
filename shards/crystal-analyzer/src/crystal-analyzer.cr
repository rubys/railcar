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
    getter program : Crystal::Program

    def initialize(@files, @views, @program)
    end
  end

  # Analyze a Crystal application. Returns typed AST grouped by source file.
  def self.analyze(entry_path : String) : Result
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

    # --- Collect expanded ECR method bodies ---
    body_collector = TypedBodyCollector.new
    result2.node.accept(body_collector)

    ecr_methods = {} of String => Crystal::ASTNode
    ecr_views = {} of String => Crystal::ASTNode

    finder.found.each do |ecr|
      key = "#{ecr.type_name}##{ecr.def_node.name}"
      if body = body_collector.bodies[key]?
        ecr_methods[key] = body
        # Map ECR filename → expanded body (deduplicated)
        ecr_views[ecr.ecr_filename] ||= body
      end
    end

    # --- Collect files from pass 2 AST ---
    raw_files = {} of String => Array(Crystal::ASTNode)
    collect_files(result2.node, raw_files)

    # --- Build import/export info per file ---
    files = {} of String => FileInfo
    expander = ExpandTransformer.new(ecr_methods)

    raw_files.each do |filename, nodes|
      next unless app_sources.includes?(filename)

      # Transform to expand macros
      expanded_nodes = nodes.map { |n| n.transform(expander) }

      exports = [] of String
      imports = [] of String
      extract_exports_imports(expanded_nodes, exports, imports)

      files[filename] = FileInfo.new(expanded_nodes, exports, imports)
    end

    Dir.cd(saved_dir)

    Result.new(files, ecr_views, result2.program)
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

  # --- Typed body collector (pass 2) ---

  class TypedBodyCollector < Crystal::Visitor
    getter bodies = {} of String => Crystal::ASTNode

    def visit(node : Crystal::Call)
      node.target_defs.try &.each do |d|
        key = "#{d.owner}##{d.name}"
        @bodies[key] ||= d.body
      end
      true
    end

    def visit(node)
      true
    end
  end

  # --- File collector ---

  private def self.source_file(node : Crystal::ASTNode) : String?
    if loc = node.location
      fn = loc.original_filename || loc.filename
      if fn.is_a?(String) && fn.starts_with?("src/") && !fn.includes?("/crystal/src/")
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
      if fn.starts_with?("src/") || fn.includes?("/src/")
        rel = fn.includes?("/src/") ? "src/" + fn.split("/src/").last : fn
        if rel.starts_with?("src/") && !rel.includes?("crystal/src/") && !rel.includes?("/lib/")
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
