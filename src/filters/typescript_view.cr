# Filter: Transform view AST for TypeScript output.
#
# Handles view-specific patterns:
# - _buf = ::String.new → _buf = ""
# - _buf.append= expr.to_s → _buf += String(expr)
# - _buf.to_s → return _buf
# - .size → .length
# - .any? → .length > 0
# - .present? → truthy check
# - content_for(:title, "text") → title = "text"
# - Convert bare calls to variable refs for known locals

require "compiler/crystal/syntax"
require "../generator/inflector"

module Railcar
  class TypeScriptView < Crystal::Transformer
    getter locals : Array(String)

    def initialize(@locals : Array(String) = [] of String)
    end

    def transform(node : Crystal::Call) : Crystal::ASTNode
      # Bare call with no receiver and no args → local variable
      if node.obj.nil? && node.args.empty? && node.named_args.nil? && node.block.nil?
        if @locals.includes?(node.name)
          return Crystal::Var.new(node.name)
        end
      end

      # .to_s → remove (TS template literals auto-convert)
      if node.name == "to_s" && node.args.empty? && node.obj
        return node.obj.not_nil!.transform(self)
      end

      # .size → .length
      if node.name == "size" && node.args.empty? && node.obj
        obj = node.obj.not_nil!.transform(self)
        return Crystal::Call.new(obj, "length")
      end

      # .count (no args) → .length
      if node.name == "count" && node.args.empty? && node.obj
        obj = node.obj.not_nil!.transform(self)
        return Crystal::Call.new(obj, "length")
      end

      # .any? → .length > 0 (keep as call, emitter handles)
      if (node.name == "any?" || node.name == "is_any") && node.args.empty? && node.obj
        return node.obj.not_nil!.transform(self)
      end

      # .present? → just the receiver (truthy check)
      if node.name == "present?" && node.args.empty? && node.obj
        return node.obj.not_nil!.transform(self)
      end

      # content_for(:title, "text") → title = "text"
      if node.name == "content_for" && node.obj.nil? && node.args.size == 2
        key = node.args[0]
        value = node.args[1]
        if key.is_a?(Crystal::SymbolLiteral)
          return Crystal::Assign.new(
            Crystal::Var.new(key.value),
            value.transform(self)
          )
        end
      end

      # button_to: flatten data hash
      if node.name == "button_to" && node.obj.nil?
        return transform_button_to(node)
      end

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

      if target.is_a?(Crystal::Var) && target.name == "_buf"
        if value.is_a?(Crystal::Call) && value.name == "new"
          return Crystal::Assign.new(target, Crystal::StringLiteral.new(""))
        end
      end

      Crystal::Assign.new(target, value)
    end

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
            na.value.as(Crystal::HashLiteral).entries.each do |entry|
              key = case entry.key
                    when Crystal::SymbolLiteral then entry.key.as(Crystal::SymbolLiteral).value
                    when Crystal::StringLiteral then entry.key.as(Crystal::StringLiteral).value
                    else                             entry.key.to_s
                    end
              new_named << Crystal::NamedArgument.new("data_#{key}", entry.value.transform(self))
            end
          elsif na.name == "method"
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
