# PyAST Dunder Filter — adds Python dunder methods to classes based on
# the methods they define.
#
# Crystal classes use methods like any?, empty?, size, each that map to
# Python's __bool__, __len__, __iter__ protocols. This filter scans
# PyAST::Class nodes and adds the appropriate dunder methods.
#
# Mappings:
#   is_any() defined  → add __bool__(self): return bool(self.data) or delegate
#   is_empty() defined → add __bool__(self): return not self.is_empty()
#   size() defined     → add __len__(self): return self.size()
#   each() with yield  → add __iter__(self): ...

module Cr2Py
  class PyAstDunderFilter
    def transform(nodes : Array(PyAST::Node)) : Array(PyAST::Node)
      nodes.map { |n| transform_node(n) }
    end

    private def transform_node(node : PyAST::Node) : PyAST::Node
      return node unless node.is_a?(PyAST::Class)
      transform_class(node)
    end

    # Find the main data-holding attribute by scanning __init__ for self.x = assignments
    private def find_data_attr(cls : PyAST::Class) : String?
      cls.body.each do |n|
        next unless n.is_a?(PyAST::Func) && n.name == "__init__"
        n.body.each do |stmt|
          case stmt
          when PyAST::Assign
            if stmt.target.starts_with?("self.")
              attr = stmt.target.sub("self.", "")
              return attr unless %w[persisted destroyed errors].includes?(attr)
            end
          when PyAST::Statement
            if stmt.code.starts_with?("self.") && stmt.code.includes?(" = ")
              attr = stmt.code.split(" = ").first.sub("self.", "")
              return attr unless %w[persisted destroyed errors].includes?(attr)
            end
          end
        end
      end
      nil
    end

    private def transform_class(cls : PyAST::Class) : PyAST::Class
      methods = {} of String => PyAST::Func
      cls.body.each do |n|
        if n.is_a?(PyAST::Func)
          methods[n.name] = n
        end
      end

      additions = [] of PyAST::Node

      # is_any()/is_empty() → __bool__: look for a data-bearing attribute
      # and delegate to bool(self.data) or similar
      if (methods.has_key?("is_any") || methods.has_key?("is_empty")) && !methods.has_key?("__bool__")
        # Find the likely data attribute by looking at __init__ assignments
        data_attr = find_data_attr(cls)
        if data_attr
          additions << PyAST::Func.new("__bool__", ["self"], [
            PyAST::Return.new("bool(self.#{data_attr})"),
          ] of PyAST::Node, "bool")
        end
      end

      # size() → __len__
      if methods.has_key?("size") && !methods.has_key?("__len__")
        additions << PyAST::Func.new("__len__", ["self"], [
          PyAST::Return.new("self.size()"),
        ] of PyAST::Node, "int")
      end

      return cls if additions.empty?

      new_body = cls.body + additions
      PyAST::Class.new(cls.name, cls.superclass, new_body)
    end
  end
end
