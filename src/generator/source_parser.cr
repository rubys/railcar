# Unified source parser: reads .rb or .cr files into Crystal AST.
#
# The rest of the pipeline operates on Crystal::ASTNode regardless
# of whether the source was Ruby or Crystal.

require "compiler/crystal/syntax"
require "./prism_translator"

module Ruby2CR
  module SourceParser
    def self.parse(path : String) : Crystal::ASTNode
      parse_source(File.read(path), path)
    end

    def self.parse_source(source : String, filename : String = "") : Crystal::ASTNode
      if filename.ends_with?(".rb")
        PrismTranslator.translate(source)
      else
        Crystal::Parser.parse(source)
      end
    end
  end
end
