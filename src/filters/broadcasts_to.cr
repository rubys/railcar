# Filter: Convert broadcasts_to into after_save/after_destroy callbacks.
#
# Rails:
#   broadcasts_to ->(article) { "articles" }, inserts_by: :prepend
#
# Generates:
#   after_save { broadcast_replace_to("articles") }
#   after_destroy { broadcast_remove_to("articles") }
#
# Also converts explicit callback declarations:
#   after_create_commit { article.broadcast_replace_to("articles") }
# Into:
#   after_save { broadcast_replace_to("articles") }  (simplified)
#
# The channel name comes from the broadcasts_to lambda or string.
# For the blog demo:
#   Article: broadcasts_to ->(_article) { "articles" }
#     → channel is "articles"
#   Comment: broadcasts_to ->(comment) { "article_#{comment.article_id}_comments" }
#     → channel is dynamic, uses string interpolation

require "compiler/crystal/syntax"

module Railcar
  class BroadcastsTo < Crystal::Transformer
    def transform(node : Crystal::Call) : Crystal::ASTNode
      case node.name
      when "broadcasts_to"
        convert_broadcasts_to(node)
      when "after_create_commit", "after_update_commit", "after_save_commit"
        # Convert to after_save with broadcast call
        convert_after_commit(node, "after_save")
      when "after_destroy_commit"
        convert_after_commit(node, "after_destroy")
      else
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

    private def convert_broadcasts_to(node : Crystal::Call) : Crystal::ASTNode
      # Extract channel name from the first argument
      # Could be a lambda (proc literal) or a string
      # If we can't extract a clean channel name, strip the declaration
      channel_expr = extract_channel(node)
      return Crystal::Nop.new unless channel_expr

      # Extract inserts_by option (prepend, append, or default replace)
      insert_action = extract_insert_action(node)

      # Extract target override
      target_expr = extract_target(node)

      stmts = [] of Crystal::ASTNode

      # after_save { broadcast_replace_to(channel) } or broadcast_prepend_to/append_to
      save_action = insert_action || "replace"
      save_args = [channel_expr.clone] of Crystal::ASTNode
      save_args << target_expr.clone if target_expr
      save_broadcast = Crystal::Call.new(nil, "broadcast_#{save_action}_to", save_args)

      stmts << Crystal::Call.new(nil, "after_save",
        block: Crystal::Block.new(body: save_broadcast))

      # after_destroy { broadcast_remove_to(channel) }
      destroy_args = [channel_expr.clone] of Crystal::ASTNode
      destroy_args << target_expr.clone if target_expr
      destroy_broadcast = Crystal::Call.new(nil, "broadcast_remove_to", destroy_args)

      stmts << Crystal::Call.new(nil, "after_destroy",
        block: Crystal::Block.new(body: destroy_broadcast))

      Crystal::Expressions.new(stmts)
    end

    private def convert_after_commit(node : Crystal::Call, callback_name : String) : Crystal::ASTNode
      block = node.block
      return Crystal::Nop.new unless block

      # Transform the block body — broadcast calls pass through
      Crystal::Call.new(nil, callback_name,
        block: block.transform(self).as(Crystal::Block))
    end

    private def extract_channel(node : Crystal::Call) : Crystal::ASTNode?
      args = node.args
      return nil if args.empty?

      first = args[0]
      case first
      when Crystal::StringLiteral
        first
      when Crystal::StringInterpolation
        # Rewrite lambda param references to self
        rewrite_self_refs(first)
      when Crystal::ProcLiteral
        # Lambda: ->(comment) { "article_#{comment.article_id}_comments" }
        extract_from_proc(first)
      else
        # Try to find a string or interpolation in the tree
        extract_string_from_tree(first)
      end
    end

    # Extract channel expression from a proc/lambda literal
    private def extract_from_proc(proc_lit : Crystal::ProcLiteral) : Crystal::ASTNode?
      body = proc_lit.def.body
      case body
      when Crystal::StringLiteral
        body
      when Crystal::StringInterpolation
        # Rewrite parameter references to self
        param_names = proc_lit.def.args.map(&.name)
        rewrite_param_to_self(body, param_names)
      when Crystal::Expressions
        body.expressions.each do |expr|
          case expr
          when Crystal::StringLiteral
            return expr
          when Crystal::StringInterpolation
            param_names = proc_lit.def.args.map(&.name)
            return rewrite_param_to_self(expr, param_names)
          end
        end
        nil
      else
        nil
      end
    end

    # Replace references to lambda params with self
    # e.g., comment.article_id → self.article_id
    private def rewrite_param_to_self(node : Crystal::StringInterpolation, param_names : Array(String)) : Crystal::StringInterpolation
      parts = node.expressions.map do |part|
        case part
        when Crystal::Call
          obj = part.obj
          obj_name = case obj
                     when Crystal::Call then obj.name
                     when Crystal::Var then obj.name
                     else nil
                     end
          if obj_name && param_names.includes?(obj_name)
            # comment.article_id → article_id (call on self)
            Crystal::Call.new(nil, part.name).as(Crystal::ASTNode)
          else
            part.as(Crystal::ASTNode)
          end
        else
          part.as(Crystal::ASTNode)
        end
      end
      Crystal::StringInterpolation.new(parts)
    end

    private def rewrite_self_refs(node : Crystal::StringInterpolation) : Crystal::StringInterpolation
      node  # Already uses self references — pass through
    end

    private def extract_string_from_tree(node : Crystal::ASTNode) : Crystal::ASTNode?
      case node
      when Crystal::StringLiteral
        node
      when Crystal::StringInterpolation
        node
      when Crystal::ProcLiteral
        extract_from_proc(node)
      when Crystal::Block
        extract_string_from_tree(node.body)
      when Crystal::Expressions
        node.expressions.each do |expr|
          result = extract_string_from_tree(expr)
          return result if result
        end
        nil
      when Crystal::Call
        if block = node.block
          extract_string_from_tree(block)
        else
          nil
        end
      else
        nil
      end
    end

    private def extract_insert_action(node : Crystal::Call) : String?
      node.named_args.try do |named|
        named.each do |na|
          if na.name == "inserts_by" && na.value.is_a?(Crystal::SymbolLiteral)
            return na.value.as(Crystal::SymbolLiteral).value
          end
        end
      end
      nil
    end

    private def extract_target(node : Crystal::Call) : Crystal::ASTNode?
      node.named_args.try do |named|
        named.each do |na|
          if na.name == "target"
            return na.value
          end
        end
      end
      nil
    end
  end
end
