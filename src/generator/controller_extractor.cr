# Extracts controller structure from Rails controller files using Prism.
#
# Extracts:
#   - before_action declarations with :only constraints
#   - public action methods (index, show, new, edit, create, update, destroy)
#   - private methods (set_article, article_params)
#   - Method bodies as Prism AST nodes for transformation

require "../prism/bindings"
require "../prism/deserializer"

module Ruby2CR
  record BeforeAction, method_name : String, only : Array(String)?

  record ControllerAction,
    name : String,
    body : Prism::Node?,
    is_private : Bool = false

  record ControllerInfo,
    name : String,
    superclass : String,
    before_actions : Array(BeforeAction),
    actions : Array(ControllerAction)

  class ControllerExtractor
    def self.extract(source : String) : ControllerInfo?
      ast = Prism.parse(source)
      stmts = ast.statements
      return nil unless stmts.is_a?(Prism::StatementsNode)
      find_class(stmts)
    end

    def self.extract_file(path : String) : ControllerInfo?
      extract(File.read(path))
    end

    private def self.find_class(node : Prism::Node) : ControllerInfo?
      case node
      when Prism::StatementsNode
        node.body.each do |child|
          result = find_class(child)
          return result if result
        end
      when Prism::ClassNode
        return parse_controller(node)
      end
      nil
    end

    private def self.parse_controller(klass : Prism::ClassNode) : ControllerInfo
      name = klass.name
      superclass = case sc = klass.superclass
                   when Prism::ConstantReadNode then sc.name
                   when Prism::ConstantPathNode then sc.full_path
                   else "ApplicationController"
                   end

      before_actions = [] of BeforeAction
      actions = [] of ControllerAction
      is_private = false

      if body = klass.body
        stmts = body.is_a?(Prism::StatementsNode) ? body.body : [body]

        stmts.each do |stmt|
          case stmt
          when Prism::CallNode
            case stmt.name
            when "before_action"
              ba = parse_before_action(stmt)
              before_actions << ba if ba
            when "private"
              is_private = true
            end
          when Prism::DefNode
            actions << ControllerAction.new(
              name: stmt.name,
              body: stmt.body,
              is_private: is_private
            )
          end
        end
      end

      ControllerInfo.new(name, superclass, before_actions, actions)
    end

    private def self.parse_before_action(call : Prism::CallNode) : BeforeAction?
      args = call.arg_nodes
      return nil if args.empty?

      method_name = case arg = args[0]
                    when Prism::SymbolNode then arg.value
                    else return nil
                    end

      only = nil
      args[1..]?.try &.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)
        arg.elements.each do |el|
          next unless el.is_a?(Prism::AssocNode)
          key = el.key
          next unless key.is_a?(Prism::SymbolNode) && key.value == "only"
          val = el.value_node
          if val.is_a?(Prism::ArrayNode)
            only = val.elements.compact_map { |e|
              e.is_a?(Prism::SymbolNode) ? e.value : nil
            }
          end
        end
      end

      BeforeAction.new(method_name, only)
    end
  end
end
