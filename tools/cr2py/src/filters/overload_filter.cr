# OverloadFilter — merges Crystal method overloads into single Python methods.
#
# Crystal supports multiple methods with the same name but different signatures.
# Python doesn't. This filter merges them into a single method that dispatches
# based on argument types, similar to how Elixir compiles function clauses.
#
# Strategy: use the positional version's body as primary logic. When kwargs
# are provided instead, convert them to a dict and run the same body.
# isinstance() dispatch on the first arg's type restriction.
#
# Bodies are pulled from the typed call graph when available, so all
# expressions inside carry their resolved types.

module Cr2Py
  class OverloadFilter < Crystal::Transformer
    getter program : Crystal::Program
    getter typed_defs : Hash(String, Array(Crystal::Def))

    def initialize(@program, @typed_defs = {} of String => Array(Crystal::Def))
    end

    def transform(node : Crystal::ClassDef) : Crystal::ASTNode
      body = node.body

      stmts = case body
              when Crystal::Expressions then body.expressions.dup
              else [body.as(Crystal::ASTNode)]
              end

      # Group Defs by Crystal name
      owner = node.name.names.join("::")
      groups = {} of String => Array(Crystal::Def)
      stmts.each do |stmt|
        if stmt.is_a?(Crystal::Def)
          key = "#{stmt.receiver ? "self." : ""}#{stmt.name}"
          groups[key] ||= [] of Crystal::Def
          groups[key] << stmt
        end
      end

      # Merge overloaded groups
      merged = {} of String => Crystal::Def
      groups.each do |key, defs|
        next if defs.size < 2
        merged[key] = merge_overloads(defs, owner)
      end

      return node if merged.empty?

      # Rebuild the body
      seen = Set(String).new
      new_stmts = [] of Crystal::ASTNode
      stmts.each do |stmt|
        if stmt.is_a?(Crystal::Def)
          key = "#{stmt.receiver ? "self." : ""}#{stmt.name}"
          if m = merged[key]?
            unless seen.includes?(key)
              new_stmts << m
              seen << key
            end
          else
            new_stmts << stmt.transform(self)
          end
        else
          new_stmts << stmt.transform(self)
        end
      end

      new_body = Crystal::Expressions.new(new_stmts)
      new_node = Crystal::ClassDef.new(node.name, new_body, node.superclass,
        node.type_vars, node.abstract?, node.struct?)
      new_node.location = node.location
      new_node
    end

    def transform(node : Crystal::ASTNode) : Crystal::ASTNode
      super
    end

    private def merge_overloads(defs : Array(Crystal::Def), owner : String) : Crystal::Def
      # If all defs have identical signatures (same arg count, no kwargs), keep first
      if defs.all?(&.double_splat.nil?) && defs.map(&.args.size).uniq.size == 1
        return defs[0]
      end

      kwargs_defs = defs.select(&.double_splat)
      positional_defs = defs.reject(&.double_splat)
      first = defs[0]

      # Pick primary def (positional version has the real logic)
      primary = positional_defs.first? || kwargs_defs.first.not_nil!
      has_kwargs = !kwargs_defs.empty?
      max_args = defs.map(&.args.size).max

      # Try to get the typed body from the call graph
      primary_body = lookup_typed_body(primary, owner) || primary.body

      # Build merged parameter list: _ov_arg0=None, ..., **_ov_kwargs
      merged_args = [] of Crystal::Arg
      max_args.times do |i|
        arg = Crystal::Arg.new("_ov_arg#{i}")
        arg.default_value = Crystal::NilLiteral.new
        merged_args << arg
      end

      # Build body with dispatch
      body_stmts = [] of Crystal::ASTNode

      if has_kwargs && primary.args.size > 0
        # Dispatch: if isinstance(_ov_arg0, <type>), use it; else use kwargs
        first_arg_name = primary.args[0].name
        cond = build_type_check(primary.args[0])

        # Both branches assign a typed variable
        then_var = Crystal::Var.new(first_arg_name)
        if arg_type = resolve_arg_type(primary.args[0])
          then_var.set_type(arg_type)
        end
        then_body = Crystal::Assign.new(
          then_var,
          Crystal::Var.new("_ov_arg0")
        )

        # kwargs → dict via .copy()
        kwargs_var = Crystal::Var.new("_ov_kwargs")
        kwargs_var.set_type(hash_type)
        else_var = Crystal::Var.new(first_arg_name)
        else_var.set_type(hash_type)
        else_body = Crystal::Assign.new(
          else_var,
          Crystal::Call.new(kwargs_var, "copy")
        )

        body_stmts << Crystal::If.new(cond, then_body, else_body)

        # Assign remaining positional args
        primary.args.each_with_index do |arg, i|
          next if i == 0
          body_stmts << Crystal::Assign.new(
            Crystal::Var.new(arg.name),
            Crystal::Var.new("_ov_arg#{i}")
          )
        end
      elsif positional_defs.size > 1 && positional_defs.map(&.args.size).uniq.size > 1
        # Multiple positional overloads with different arg counts
        primary = positional_defs.max_by(&.args.size)
        primary_body = lookup_typed_body(primary, owner) || primary.body
        cond = build_type_check(primary.args[0])

        then_stmts = primary.args.map_with_index { |arg, i|
          Crystal::Assign.new(
            Crystal::Var.new(arg.name),
            Crystal::Var.new("_ov_arg#{i}")
          ).as(Crystal::ASTNode)
        }
        then_stmts << primary_body
        then_body = Crystal::Expressions.new(then_stmts)

        shorter = positional_defs.min_by(&.args.size)
        shorter_body = lookup_typed_body(shorter, owner) || shorter.body
        else_stmts = shorter.args.map_with_index { |arg, i|
          Crystal::Assign.new(
            Crystal::Var.new(arg.name),
            Crystal::Var.new("_ov_arg#{i}")
          ).as(Crystal::ASTNode)
        }
        else_stmts << shorter_body
        else_body = Crystal::Expressions.new(else_stmts)

        body_stmts << Crystal::If.new(cond, then_body, else_body)

        merged = Crystal::Def.new(first.name, merged_args, Crystal::Expressions.new(body_stmts))
        merged.receiver = first.receiver
        merged.return_type = first.return_type
        merged.location = first.location
        return merged
      else
        # Just assign positional args
        primary.args.each_with_index do |arg, i|
          body_stmts << Crystal::Assign.new(
            Crystal::Var.new(arg.name),
            Crystal::Var.new("_ov_arg#{i}")
          )
        end
      end

      body_stmts << primary_body
      final_body = Crystal::Expressions.new(body_stmts)

      merged = Crystal::Def.new(first.name, merged_args, final_body)
      merged.receiver = first.receiver
      merged.return_type = first.return_type
      merged.location = first.location
      if has_kwargs
        merged.double_splat = Crystal::Arg.new("_ov_kwargs")
      end
      merged
    end

    # Look up the typed body for a Def from the call graph
    private def lookup_typed_body(d : Crystal::Def, owner : String) : Crystal::ASTNode?
      # Try instance method key, then class method key
      key = "Railcar::#{owner}##{d.name}"
      class_key = "Railcar::#{owner}.class##{d.name}"

      candidates = @typed_defs[key]? || @typed_defs[class_key]?
      return nil unless candidates

      # Match by arity
      typed = candidates.find { |td| td.args.size == d.args.size }
      typed.try(&.body)
    end

    private def build_type_check(arg : Crystal::Arg) : Crystal::ASTNode
      python_type = if restriction = arg.restriction
                      case restriction.to_s
                      when /Hash/   then "dict"
                      when /String/ then "str"
                      when /Int/    then "int"
                      when /Float/  then "float"
                      when /Bool/   then "bool"
                      when /Array/  then "list"
                      else "dict"
                      end
                    else
                      "dict"
                    end

      Crystal::Call.new(nil, "isinstance",
        [Crystal::Var.new("_ov_arg0"),
         Crystal::Path.new(python_type)] of Crystal::ASTNode)
    end

    private def hash_type : Crystal::Type
      @program.types["Hash"]
    end

    private def resolve_arg_type(arg : Crystal::Arg) : Crystal::Type?
      if restriction = arg.restriction
        case restriction.to_s
        when /Hash/  then @program.types["Hash"]
        when /Array/ then @program.types["Array"]
        else nil
        end
      else
        nil
      end
    end
  end
end
