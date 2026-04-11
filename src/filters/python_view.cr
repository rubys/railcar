# Filter: Transform view AST for Python output.
#
# Handles view-specific patterns:
# - _buf = ::String.new → _buf = ""
# - _buf.append= expr.to_s → _buf += str(expr)
# - _buf.to_s → return _buf
# - Convert bare calls to variable refs for known locals
# - .size → len()
# - .to_s → str()
# - turbo_stream_from → function call
# - model path references (article → article_path(article))

require "compiler/crystal/syntax"
require "../generator/inflector"

module Railcar
  class PythonView < Crystal::Transformer
    # Names that should be treated as local variables, not method calls
    getter locals : Array(String)

    def initialize(@locals : Array(String) = [] of String)
    end

    # Convert bare calls to Var when the name matches a known local
    def transform(node : Crystal::Call) : Crystal::ASTNode
      # Bare call with no receiver and no args → local variable
      if node.obj.nil? && node.args.empty? && node.named_args.nil? && node.block.nil?
        if @locals.includes?(node.name)
          return Crystal::Var.new(node.name)
        end
      end

      # .to_s → remove (Python str() will be added at _buf level)
      if node.name == "to_s" && node.args.empty? && node.obj
        return node.obj.not_nil!.transform(self)
      end

      # .size → len(obj)
      if node.name == "size" && node.args.empty? && node.obj
        obj = node.obj.not_nil!.transform(self)
        return Crystal::Call.new(nil, "len", [obj] of Crystal::ASTNode)
      end

      # .count (no args) → len(obj)
      if node.name == "count" && node.args.empty? && node.obj
        obj = node.obj.not_nil!.transform(self)
        return Crystal::Call.new(nil, "len", [obj] of Crystal::ASTNode)
      end

      # button_to: flatten data: { turbo_confirm: "..." } into data_turbo_confirm="..."
      if node.name == "button_to" && node.obj.nil?
        return transform_button_to(node)
      end

      # truncate(text, length: N) → keep as function call (registered as global)
      # link_to, dom_id, pluralize, turbo_stream_from → keep as function calls

      # Transform children
      node.obj = node.obj.try(&.transform(self))
      node.args = node.args.map { |a| a.transform(self) }
      if named = node.named_args
        node.named_args = named.map { |na|
          Crystal::NamedArgument.new(na.name, na.value.transform(self))
        }
      end
      if block = node.block
        node.block = block.transform(self).as(Crystal::Block)
      end
      node
    end

    # _buf = ::String.new → _buf = ""
    def transform(node : Crystal::Assign) : Crystal::ASTNode
      target = node.target.transform(self)
      value = node.value.transform(self)

      # ::String.new → ""
      if target.is_a?(Crystal::Var) && target.name == "_buf"
        if value.is_a?(Crystal::Call) && value.name == "new"
          return Crystal::Assign.new(target, Crystal::StringLiteral.new(""))
        end
        # Also handle String() from PythonConstructor
        if value.is_a?(Crystal::Call) && value.name == "String"
          return Crystal::Assign.new(target, Crystal::StringLiteral.new(""))
        end
      end

      Crystal::Assign.new(target, value)
    end

    # _buf.append= expr → _buf += str(expr)
    def transform(node : Crystal::OpAssign) : Crystal::ASTNode
      target = node.target.transform(self)
      value = node.value.transform(self)

      Crystal::OpAssign.new(target, node.op, value)
    end

    private def transform_button_to(node : Crystal::Call) : Crystal::Call
      args = node.args.map { |a| a.transform(self) }
      new_named = [] of Crystal::NamedArgument

      if named = node.named_args
        named.each do |na|
          if na.name == "data" && na.value.is_a?(Crystal::HashLiteral)
            # Flatten: data: { turbo_confirm: "..." } → data_turbo_confirm="..."
            na.value.as(Crystal::HashLiteral).entries.each do |entry|
              key = case entry.key
                    when Crystal::SymbolLiteral then entry.key.as(Crystal::SymbolLiteral).value
                    when Crystal::StringLiteral then entry.key.as(Crystal::StringLiteral).value
                    else                             entry.key.to_s
                    end
              new_named << Crystal::NamedArgument.new("data_#{key}", entry.value.transform(self))
            end
          elsif na.name == "method"
            # :delete → "delete"
            val = case na.value
                  when Crystal::SymbolLiteral
                    Crystal::StringLiteral.new(na.value.as(Crystal::SymbolLiteral).value)
                  else
                    na.value.transform(self)
                  end
            new_named << Crystal::NamedArgument.new(na.name, val)
          else
            new_named << Crystal::NamedArgument.new(na.name, na.value.transform(self))
          end
        end
      end

      Crystal::Call.new(nil, "button_to", args,
        named_args: new_named.empty? ? nil : new_named)
    end
  end
end
