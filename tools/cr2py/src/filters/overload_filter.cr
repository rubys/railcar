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
# Synthetic nodes get proper types set so downstream checks (e.g. is_hash_type?)
# work correctly.

module Cr2Py
  class OverloadFilter < Crystal::Transformer
    getter program : Crystal::Program

    def initialize(@program)
    end

    def transform(node : Crystal::ClassDef) : Crystal::ASTNode
      body = node.body

      stmts = case body
              when Crystal::Expressions then body.expressions.dup
              else [body.as(Crystal::ASTNode)]
              end

      # Group Defs by Crystal name
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
        merged[key] = merge_overloads(defs)
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

    private def merge_overloads(defs : Array(Crystal::Def)) : Crystal::Def
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

        # Both branches assign a typed variable so downstream checks work
        then_var = Crystal::Var.new(first_arg_name)
        if arg_type = resolve_arg_type(primary.args[0])
          then_var.set_type(arg_type)
        end
        then_body = Crystal::Assign.new(
          then_var,
          Crystal::Var.new("_ov_arg0")
        )

        # kwargs → dict via .copy() (kwargs is already a dict in Python)
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
        cond = build_type_check(primary.args[0])

        then_stmts = primary.args.map_with_index { |arg, i|
          Crystal::Assign.new(
            Crystal::Var.new(arg.name),
            Crystal::Var.new("_ov_arg#{i}")
          ).as(Crystal::ASTNode)
        }
        then_stmts << primary.body
        then_body = Crystal::Expressions.new(then_stmts)

        shorter = positional_defs.min_by(&.args.size)
        else_stmts = shorter.args.map_with_index { |arg, i|
          Crystal::Assign.new(
            Crystal::Var.new(arg.name),
            Crystal::Var.new("_ov_arg#{i}")
          ).as(Crystal::ASTNode)
        }
        else_stmts << shorter.body
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

      # Type the body's parameter references so downstream checks work
      typed_body = type_body_vars(primary)
      body_stmts << typed_body
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

    # Walk the body of a Def and set types on Var nodes matching parameter names
    private def type_body_vars(d : Crystal::Def) : Crystal::ASTNode
      param_types = {} of String => Crystal::Type
      d.args.each do |arg|
        if t = resolve_arg_type(arg)
          param_types[arg.name] = t
        end
      end
      return d.body if param_types.empty?
      typer = VarTyper.new(param_types)
      d.body.transform(typer)
    end

    private class VarTyper < Crystal::Transformer
      def initialize(@param_types : Hash(String, Crystal::Type))
      end

      def transform(node : Crystal::Var) : Crystal::ASTNode
        if t = @param_types[node.name]?
          node.set_type(t)
        end
        node
      end

      def transform(node : Crystal::ASTNode) : Crystal::ASTNode
        super
      end
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
