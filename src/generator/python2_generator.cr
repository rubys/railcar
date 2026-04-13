# Python2Generator — generates Python from typed Crystal AST via PyAST.
#
# Pipeline:
#   1. Parse Crystal-for-Python runtime (src/runtime/python/base.cr)
#   2. Feed to program.semantic() → typed AST
#   3. Emit Python via cr2py's emitter/PyAST pipeline
#
# Built layer by layer:
#   Layer 1: Runtime (ApplicationRecord, ValidationErrors)
#   Layer 2: Models (Article, Comment — from Rails metadata + filters)
#   Layer 3: Tests
#   Layer 4: Controllers
#   Layer 5: Views
#   Layer 6: App (server, routing, static files)

require "./app_model"
require "./schema_extractor"
require "./inflector"
require "../semantic"
require "../../tools/cr2py/src/py_ast"
require "../../tools/cr2py/src/cr2py"
require "../../tools/cr2py/src/filters/db_filter"
require "../../tools/cr2py/src/filters/pyast_dunder_filter"
require "../../tools/cr2py/src/filters/pyast_return_filter"

module Railcar
  class Python2Generator
    getter app : AppModel
    getter rails_dir : String

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      puts "Generating Python (v2) from #{rails_dir}..."
      Dir.mkdir_p(output_dir)

      # Layer 1: Runtime
      program, typed_ast = compile_layer1
      unless program && typed_ast
        STDERR.puts "Cannot generate Python without typed AST"
        return
      end

      emitter = Cr2Py::Emitter.new(program)
      serializer = PyAST::Serializer.new
      db_filter = Cr2Py::DbFilter.new
      dunder_filter = Cr2Py::PyAstDunderFilter.new
      return_filter = Cr2Py::PyAstReturnFilter.new

      emit_runtime(typed_ast, output_dir, emitter, serializer, db_filter, dunder_filter, return_filter)

      puts "Done! Output in #{output_dir}/"
    end

    # ── Layer 1: Compile runtime ──

    private def compile_layer1 : {Crystal::Program?, Crystal::ASTNode?}
      location = Crystal::Location.new("src/app.cr", 1, 1)

      # Read the Crystal-for-Python runtime
      runtime_path = File.join(File.dirname(__FILE__), "..", "runtime", "python", "base.cr")
      runtime_source = File.read(runtime_path)

      # Strip require lines, add DB stub
      source = String.build do |io|
        io << "module DB\n"
        io << "  alias Any = Bool | Float32 | Float64 | Int32 | Int64 | String | Nil\n"
        io << "  class Database\n"
        io << "    def exec(sql : String, *args)\n    end\n"
        io << "    def exec(sql : String, args : Array)\n    end\n"
        io << "    def scalar(sql : String, *args) : Int64\n      0_i64\n    end\n"
        io << "    def query_one?(sql : String, *args, &) : Hash(String, DB::Any)?\n      nil\n    end\n"
        io << "  end\n"
        io << "end\n\n"
        runtime_source.lines.each do |line|
          next if line.strip.starts_with?("require ")
          io << line << "\n"
        end
      end

      all_nodes = [
        Crystal::Require.new("prelude").at(location),
        Crystal::Parser.parse(source),
      ] of Crystal::ASTNode

      # Append synthetic calls to force the MainVisitor through all methods.
      # This ensures types are set on every expression in method bodies.
      all_nodes.concat(build_synthetic_calls)

      nodes = Crystal::Expressions.new(all_nodes)

      program = Crystal::Program.new
      compiler = Crystal::Compiler.new
      compiler.no_codegen = true
      program.compiler = compiler

      normalized = program.normalize(nodes)
      typed = program.semantic(normalized)

      puts "  layer 1 (runtime): OK"
      {program, typed}
    rescue ex
      STDERR.puts "  layer 1 failed: #{ex.message}"
      {nil, nil}
    end

    # Build synthetic calls to exercise every runtime method
    private def build_synthetic_calls : Array(Crystal::ASTNode)
      calls = [] of Crystal::ASTNode

      # ValidationErrors: initialize, add, any?, empty?, full_messages, [], clear
      calls << Crystal::Parser.parse(<<-CR)
        _ve = Railcar::ValidationErrors.new
        _ve.add("field", "message")
        _ve.any?
        _ve.empty?
        _ve.full_messages
        _ve["field"]
        _ve.clear
      CR

      # ApplicationRecord: initialize, id, persisted?, new_record?, valid?, save,
      # destroy, reload, run_validations, find, count, create, do_insert, do_update
      calls << Crystal::Parser.parse(<<-CR)
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

      calls
    end

    # ── Emit runtime Python files ──

    private def emit_runtime(typed_ast : Crystal::ASTNode, output_dir : String,
                             emitter : Cr2Py::Emitter,
                             serializer : PyAST::Serializer,
                             db_filter : Cr2Py::DbFilter,
                             dunder_filter : Cr2Py::PyAstDunderFilter,
                             return_filter : Cr2Py::PyAstReturnFilter)
      runtime_dir = File.join(output_dir, "runtime")
      Dir.mkdir_p(runtime_dir)

      file_map = {
        "ValidationErrors"  => "base",
        "ApplicationRecord" => "base",
      }

      # Collect nodes grouped by output file
      file_nodes = {} of String => Array(Crystal::ASTNode)
      extract_railcar_nodes(typed_ast).each do |node|
        name = case node
               when Crystal::ClassDef then node.name.names.last
               else nil
               end
        next unless name
        if file = file_map[name]?
          file_nodes[file] ||= [] of Crystal::ASTNode
          file_nodes[file] << node
        end
      end

      file_nodes.each do |file, nodes|
        emit_file(nodes, "runtime/#{file}.py", output_dir,
          emitter, serializer, db_filter, dunder_filter, return_filter)
      end

      File.write(File.join(runtime_dir, "__init__.py"), "")
    end

    # ── Shared helpers ──

    private def extract_railcar_nodes(ast : Crystal::ASTNode) : Array(Crystal::ASTNode)
      nodes = [] of Crystal::ASTNode
      case ast
      when Crystal::Expressions
        ast.expressions.each do |expr|
          case expr
          when Crystal::ModuleDef
            if expr.name.names.includes?("Railcar")
              case expr.body
              when Crystal::Expressions
                nodes.concat(expr.body.as(Crystal::Expressions).expressions)
              else
                nodes << expr.body
              end
            end
          end
        end
      end
      nodes
    end

    private def emit_file(nodes : Array(Crystal::ASTNode), py_path : String,
                          output_dir : String,
                          emitter : Cr2Py::Emitter,
                          serializer : PyAST::Serializer,
                          db_filter : Cr2Py::DbFilter,
                          dunder_filter : Cr2Py::PyAstDunderFilter,
                          return_filter : Cr2Py::PyAstReturnFilter)
      py_nodes = [] of PyAST::Node
      nodes.each do |node|
        transformed = node.transform(db_filter)
        py_nodes.concat(emitter.to_nodes(transformed))
      end
      py_nodes = dunder_filter.transform(py_nodes)
      py_nodes = return_filter.transform(py_nodes)

      mod = PyAST::Module.new(py_nodes)
      content = serializer.serialize(mod)
      imports = generate_imports(content)

      out_path = File.join(output_dir, py_path)
      Dir.mkdir_p(File.dirname(out_path))
      File.write(out_path, imports + content)
      puts "  #{py_path}"
    end

    private def generate_imports(content : String) : String
      imports = [] of String
      imports << "from __future__ import annotations" if content.includes?("->") || content.includes?(": ")
      imports << "from typing import Any" if content.includes?("Any")
      imports << "import sqlite3" if content.includes?("sqlite3.")
      imports << "import logging" if content.includes?("logging.")
      imports << "from datetime import datetime" if content.includes?("datetime.")
      imports.empty? ? "" : imports.join("\n") + "\n\n"
    end
  end
end
