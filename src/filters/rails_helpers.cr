# Filter: Convert Rails-specific helper patterns to Crystal equivalents.
#
# Handles miscellaneous Rails → Crystal conversions that don't warrant
# their own filter:
#
#   object.present?          → object (truthy check)
#   collection.count (no args) → collection.size
#   dom_id(record, :prefix)  → dom_id(record, "prefix") (symbol → string)

require "compiler/crystal/syntax"

module Railcar
  class RailsHelpers < Crystal::Transformer
    def transform(node : Crystal::Call) : Crystal::ASTNode
      case node.name
      when "present?"
        # obj.present? → obj (Crystal truthy check)
        if obj = node.obj
          return obj.transform(self)
        end
      when "count"
        # collection.count with no args → collection.size
        if node.obj && node.args.empty? && (node.named_args.nil? || node.named_args.try(&.empty?))
          return Crystal::Call.new(node.obj.not_nil!.transform(self), "size")
        end
      when "dom_id"
        # Convert symbol args to strings
        node.args = node.args.map do |a|
          if a.is_a?(Crystal::SymbolLiteral)
            Crystal::StringLiteral.new(a.value).as(Crystal::ASTNode)
          else
            a
          end
        end
      end

      # Recurse into children
      node.obj = node.obj.try(&.transform(self))
      node.args = node.args.map(&.transform(self).as(Crystal::ASTNode))
      node.named_args = node.named_args.try(&.map { |na|
        Crystal::NamedArgument.new(na.name, na.value.transform(self)).as(Crystal::NamedArgument)
      })
      node.block = node.block.try(&.transform(self).as(Crystal::Block))
      node
    end
  end
end
