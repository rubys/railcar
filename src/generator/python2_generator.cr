# Python2Generator — generates Python from typed Crystal AST via PyAST.
#
# Pipeline:
#   1. AppModel.extract() — Rails metadata
#   2. SemanticAnalyzer — builds clean Crystal AST, runs program.semantic()
#   3. This generator — walks typed AST, applies filters, emits Python via PyAST
#
# Unlike the original PythonGenerator which re-parses from Prism and ignores
# types, this uses the typed AST directly. The Cr2Py emitter handles
# Crystal→Python translation with type-aware property detection.

require "./app_model"
require "./schema_extractor"
require "./semantic_analyzer"
require "./inflector"
require "../../tools/cr2py/src/py_ast"
require "../../tools/cr2py/src/cr2py"
require "../../tools/cr2py/src/filters/spec_filter"
require "../../tools/cr2py/src/filters/db_filter"
require "../../tools/cr2py/src/filters/overload_filter"
require "../../tools/cr2py/src/filters/pyast_dunder_filter"

module Railcar
  class Python2Generator
    getter app : AppModel
    getter rails_dir : String

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      puts "Generating Python (v2) from #{rails_dir}..."

      # Run semantic analysis — builds Crystal AST and types it
      semantic = SemanticAnalyzer.new(app, rails_dir)
      semantic.analyze

      program = semantic.program
      typed_ast = semantic.typed_ast

      unless program && typed_ast
        STDERR.puts "Semantic analysis failed — no typed AST"
        exit 1
      end

      # Set up cr2py emitter and filters
      emitter = Cr2Py::Emitter.new(program)
      serializer = PyAST::Serializer.new
      db_filter = Cr2Py::DbFilter.new
      overload_filter = Cr2Py::OverloadFilter.new(program)
      dunder_filter = Cr2Py::PyAstDunderFilter.new

      # Create output directories
      Dir.mkdir_p(output_dir)
      %w[models controllers views runtime tests].each do |dir|
        Dir.mkdir_p(File.join(output_dir, dir))
      end

      # Walk the typed AST and emit Python files
      # The typed AST has: prelude requires, model stubs, controller ASTs, call sites
      # We need to extract the Railcar module contents and emit per-file

      emit_from_typed_ast(typed_ast, output_dir, emitter, serializer,
        db_filter, overload_filter, dunder_filter)

      puts "Done! Output in #{output_dir}/"
    end

    private def emit_from_typed_ast(ast : Crystal::ASTNode, output_dir : String,
                                     emitter : Cr2Py::Emitter,
                                     serializer : PyAST::Serializer,
                                     db_filter : Cr2Py::DbFilter,
                                     overload_filter : Cr2Py::OverloadFilter,
                                     dunder_filter : Cr2Py::PyAstDunderFilter)
      # Collect all top-level nodes from the Railcar module
      railcar_nodes = extract_railcar_nodes(ast)

      # Group by type: models, controllers, etc.
      railcar_nodes.each do |node|
        case node
        when Crystal::ClassDef
          class_name = node.name.names.last
          if class_name.ends_with?("Controller")
            emit_file(node, "controllers/#{Inflector.underscore(class_name)}.py",
              output_dir, emitter, serializer, db_filter, overload_filter, dunder_filter)
          elsif class_name == "ApplicationRecord" || class_name == "Router"
            emit_file(node, "runtime/#{Inflector.underscore(class_name)}.py",
              output_dir, emitter, serializer, db_filter, overload_filter, dunder_filter)
          else
            # Model or runtime class
            emit_file(node, "models/#{Inflector.underscore(class_name)}.py",
              output_dir, emitter, serializer, db_filter, overload_filter, dunder_filter)
          end
        when Crystal::Def
          # Top-level functions (helpers, etc.)
          # Collect and emit later
        when Crystal::ModuleDef
          # Nested module — recurse
          mod_name = node.name.names.last
          body_stmts = case node.body
                       when Crystal::Expressions then node.body.as(Crystal::Expressions).expressions
                       else [node.body]
                       end
          body_stmts.each do |s|
            next unless s.is_a?(Crystal::ClassDef) || s.is_a?(Crystal::Def)
            railcar_nodes << s
          end
        end
      end
    end

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

    private def emit_file(node : Crystal::ASTNode, py_path : String,
                          output_dir : String,
                          emitter : Cr2Py::Emitter,
                          serializer : PyAST::Serializer,
                          db_filter : Cr2Py::DbFilter,
                          overload_filter : Cr2Py::OverloadFilter,
                          dunder_filter : Cr2Py::PyAstDunderFilter)
      transformed = node.transform(overload_filter).transform(db_filter)
      py_nodes = emitter.to_nodes(transformed)
      py_nodes = dunder_filter.transform(py_nodes)

      mod = PyAST::Module.new(py_nodes)
      content = serializer.serialize(mod)

      # Generate imports
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
      imports << "from typing import Self" if content.includes?("Self")
      imports << "import sqlite3" if content.includes?("sqlite3.")
      imports << "import logging" if content.includes?("logging.")
      imports << "from datetime import datetime" if content.includes?("datetime.")

      if imports.empty?
        ""
      else
        imports.join("\n") + "\n\n"
      end
    end
  end
end
