# OverloadFilter — merges Crystal method overloads into single Python methods.
#
# Crystal supports multiple methods with the same name but different signatures.
# Python doesn't. This filter merges them into a single method with an if/elif
# chain that dispatches based on argument types, similar to how Elixir compiles
# multiple function clauses.
#
# Patterns handled:
#   def foo(x : Hash)  + def foo(**kwargs)  → dispatch on isinstance(dict)
#   def foo(x : String, y) + def foo(**kw)  → dispatch on isinstance(str)
#   def foo() + def foo()                    → keep first (identical)

module Cr2Py
  class OverloadFilter < Crystal::Transformer
    def transform(node : Crystal::ClassDef) : Crystal::ASTNode
      body = node.body

      stmts = case body
              when Crystal::Expressions then body.expressions.dup
              else [body.as(Crystal::ASTNode)]
              end

      # Group Defs by Python-compatible name (strip !, ? suffix collisions)
      groups = {} of String => Array(Crystal::Def)
      stmts.each do |stmt|
        if stmt.is_a?(Crystal::Def)
          # Group by Crystal name (keep ! variants separate since they have
          # different semantics — create vs create! — and only merge
          # positional vs kwargs overloads of the same method)
          key = "#{stmt.receiver ? "self." : ""}#{stmt.name}"
          groups[key] ||= [] of Crystal::Def
          groups[key] << stmt
        end
      end

      # Replace overloaded groups with merged methods
      merged = {} of String => Crystal::Def
      groups.each do |key, defs|
        next if defs.size < 2
        merged[key] = merge_overloads(defs)
      end

      return node if merged.empty?

      # Rebuild the body, replacing overloaded defs with merged versions
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
            # Skip subsequent overloads
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
      # If all defs have identical args, just keep the first
      if defs.all? { |d| d.args.size == defs[0].args.size && d.double_splat.nil? == defs[0].double_splat.nil? }
        if defs.map(&.args.size).uniq.size == 1 && defs.all?(&.double_splat.nil?)
          return defs[0]
        end
      end

      # Separate kwargs versions from positional versions
      kwargs_defs = defs.select(&.double_splat)
      positional_defs = defs.reject(&.double_splat)

      # Build merged parameter list: *args, **kwargs
      # The merged method accepts everything and dispatches internally
      first = defs[0]

      # Build the dispatch body as if/elif chain
      branches = [] of Crystal::ASTNode

      # Positional clauses first (more specific)
      positional_defs.each do |d|
        if d.args.empty? && !d.double_splat
          # No-arg version — this is the fallback
          next
        end
        cond = build_dispatch_condition(d)
        if cond
          # Wrap body with local variable assignments from args
          body = build_dispatched_body(d)
          branches << Crystal::If.new(cond, body)
        end
      end

      # kwargs clause
      if kw = kwargs_defs.first?
        body = build_kwargs_body(kw)
        if branches.empty?
          branches << body
        else
          # Add as else clause to the last if
          branches << body
        end
      end

      # No-arg fallback
      no_arg = positional_defs.find { |d| d.args.empty? && !d.double_splat }

      # Build final body
      final_body = if branches.size == 0 && no_arg
                     no_arg.body
                   elsif branches.size == 1 && !no_arg
                     branches[0]
                   else
                     build_if_chain(branches, no_arg)
                   end

      # Build merged def with generic args
      merged_args = build_merged_args(defs)
      has_kwargs = defs.any?(&.double_splat)
      merged = Crystal::Def.new(first.name, merged_args, final_body)
      merged.receiver = first.receiver
      merged.return_type = first.return_type
      merged.location = first.location
      if has_kwargs
        merged.double_splat = Crystal::Arg.new("_ov_kwargs")
      end
      merged
    end

    private def build_dispatch_condition(d : Crystal::Def) : Crystal::ASTNode?
      return nil if d.args.empty?

      first_arg = d.args[0]
      restriction = first_arg.restriction
      return nil unless restriction

      type_str = restriction.to_s
      python_type = case type_str
                    when /Hash/ then "dict"
                    when /String/ then "str"
                    when /Int/   then "int"
                    when /Float/ then "float"
                    when /Bool/  then "bool"
                    when /Array/ then "list"
                    else nil
                    end

      return nil unless python_type

      # Build: isinstance(args[0], <type>)
      # We use _args as the merged positional args tuple
      Crystal::Call.new(nil, "isinstance",
        [Crystal::Var.new("_ov_arg0"),
         Crystal::Path.new(python_type)] of Crystal::ASTNode)
    end

    private def build_dispatched_body(d : Crystal::Def) : Crystal::ASTNode
      # Assign local vars from positional args, then run the original body
      assigns = [] of Crystal::ASTNode
      d.args.each_with_index do |arg, i|
        assigns << Crystal::Assign.new(
          Crystal::Var.new(arg.name),
          Crystal::Var.new("_ov_arg#{i}")
        )
      end
      assigns << d.body
      Crystal::Expressions.new(assigns)
    end

    private def build_kwargs_body(d : Crystal::Def) : Crystal::ASTNode
      if ds = d.double_splat
        # Assign kwargs to the double_splat name
        assigns = [Crystal::Assign.new(
          Crystal::Var.new(ds.name),
          Crystal::Var.new("_ov_kwargs")
        ).as(Crystal::ASTNode)]
        assigns << d.body
        Crystal::Expressions.new(assigns)
      else
        d.body
      end
    end

    private def build_if_chain(branches : Array(Crystal::ASTNode), fallback : Crystal::Def?) : Crystal::ASTNode
      if branches.size == 1
        if fb = fallback
          if branches[0].is_a?(Crystal::If)
            # Add fallback as else
            if_node = branches[0].as(Crystal::If)
            return Crystal::If.new(if_node.cond, if_node.then, fb.body)
          end
        end
        return branches[0]
      end

      # Build elif chain from bottom up
      result : Crystal::ASTNode = if fb = fallback
                                    fb.body
                                  else
                                    branches.pop
                                  end

      branches.reverse_each do |branch|
        if branch.is_a?(Crystal::If)
          result = Crystal::If.new(branch.cond, branch.then, result)
        else
          result = branch
        end
      end
      result
    end

    private def build_merged_args(defs : Array(Crystal::Def)) : Array(Crystal::Arg)
      # Find max positional args across all overloads
      max_args = defs.map(&.args.size).max
      has_kwargs = defs.any?(&.double_splat)

      args = [] of Crystal::Arg
      max_args.times do |i|
        arg = Crystal::Arg.new("_ov_arg#{i}")
        arg.default_value = Crystal::NilLiteral.new
        args << arg
      end

      args
    end
  end
end
