# PyAST Return Filter — adds implicit returns to function bodies.
#
# Crystal and Ruby use implicit returns (last expression is the return value).
# Python requires explicit return statements. This filter walks every Func
# node and recursively adds return to terminal expressions in all branches.
#
# Rules:
#   Statement as last node    → return expr
#   If/else as last node      → recurse into both branches
#   Try/except as last node   → recurse into both branches
#   Assign as last node       → add return of target after
#   Return already present    → leave as-is
#   For/While/Class/Func/Raw  → don't add return

module Cr2Py
  class PyAstReturnFilter
    def transform(nodes : Array(PyAST::Node)) : Array(PyAST::Node)
      nodes.each do |node|
        transform_node(node)
      end
      nodes
    end

    private def transform_node(node : PyAST::Node)
      case node
      when PyAST::Class
        node.body.each { |n| transform_node(n) }
      when PyAST::Func
        if node.return_type && node.return_type != "None"
          add_returns(node.body)
        end
      end
    end

    private def add_returns(body : Array(PyAST::Node))
      return if body.empty?
      last = body.last

      case last
      when PyAST::Return
        # Already has return
      when PyAST::Statement
        code = last.code
        # Don't return assignments, raise statements, or pass
        unless (code.includes?(" = ") && !code.includes?(" == ")) ||
               code.starts_with?("raise ") || code == "pass"
          body[-1] = PyAST::Return.new(code)
        end
      when PyAST::If
        add_returns(last.body)
        if else_body = last.else_body
          add_returns(else_body)
        end
      when PyAST::Try
        add_returns(last.body)
        add_returns(last.rescue_body)
      when PyAST::Assign
        # x = expr → keep assignment, add return x
        body << PyAST::Return.new(last.target)
      when PyAST::For, PyAST::While, PyAST::Func, PyAST::Class,
           PyAST::Blank, PyAST::Raw, PyAST::BufLiteral, PyAST::BufAppend
        # Don't add return to these
      end
    end
  end
end
