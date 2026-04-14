# DbFilter — transforms Crystal DB API calls to Python sqlite3 equivalents.
#
# Crystal pattern → Python equivalent:
#   DB.open("sqlite3::memory:")     → sqlite3.connect(":memory:")
#   DB.open("sqlite3:./blog.db")    → sqlite3.connect("blog.db")
#   db.exec(sql)                    → db.execute(sql); db.commit()
#   db.exec(sql, arg1, arg2)        → db.execute(sql, [arg1, arg2])
#   db.scalar(sql)                  → db.execute(sql).fetchone()[0]
#   db.scalar(sql, arg)             → db.execute(sql, [arg]).fetchone()[0]
#   Time.utc.to_s(fmt)              → datetime.now().strftime(fmt)

module Cr2Py
  class DbFilter < Crystal::Transformer
    def transform(node : Crystal::Call) : Crystal::ASTNode
      obj = node.obj
      name = node.name
      args = node.args

      # DB.open("sqlite3:...") → sqlite3.connect("...")
      if name == "open" && obj.is_a?(Crystal::Path) && obj.names.last == "DB" && args.size == 1
        if arg = args[0].as?(Crystal::StringLiteral)
          # Extract path from "sqlite3::memory:" or "sqlite3:./blog.db"
          connstr = arg.value
          path = if connstr == "sqlite3::memory:"
                   ":memory:"
                 else
                   connstr.sub(/^sqlite3:\.?\/?\/?/, "")
                 end
          return Crystal::Call.new(
            Crystal::Path.new(["sqlite3"]),
            "connect",
            [Crystal::StringLiteral.new(path)] of Crystal::ASTNode
          )
        end
      end

      # db.exec(sql, ...) → db.execute(sql, [...])
      if name == "exec" && obj
        new_args = if args.size > 1
                     # Multiple args → wrap params in array
                     [args[0].transform(self), Crystal::ArrayLiteral.new(args[1..].map { |a| a.transform(self).as(Crystal::ASTNode) })] of Crystal::ASTNode
                   else
                     args.map { |a| a.transform(self).as(Crystal::ASTNode) }
                   end
        # Convert named "args:" to positional (sqlite3.execute takes positional params)
        if named = node.named_args
          named.each do |na|
            if na.name == "args"
              new_args << na.value.transform(self)
            end
          end
        end
        return Crystal::Call.new(obj.transform(self), "execute", new_args)
      end

      # db.query_one(sql, ...) → db.execute(sql, [...]).fetchone()
      if name == "query_one" && obj
        execute_args = if args.size > 1
                         [args[0].transform(self), Crystal::ArrayLiteral.new(args[1..].map { |a| a.transform(self).as(Crystal::ASTNode) })] of Crystal::ASTNode
                       else
                         args.map { |a| a.transform(self).as(Crystal::ASTNode) }
                       end
        execute_call = Crystal::Call.new(obj.transform(self), "execute", execute_args)
        return Crystal::Call.new(execute_call, "fetchone")
      end

      # db.query_all(sql, ...) → db.execute(sql, [...]).fetchall()
      if name == "query_all" && obj
        execute_args = if args.size > 1
                         [args[0].transform(self), Crystal::ArrayLiteral.new(args[1..].map { |a| a.transform(self).as(Crystal::ASTNode) })] of Crystal::ASTNode
                       else
                         args.map { |a| a.transform(self).as(Crystal::ASTNode) }
                       end
        execute_call = Crystal::Call.new(obj.transform(self), "execute", execute_args)
        return Crystal::Call.new(execute_call, "fetchall")
      end

      # db.scalar(sql, ...) → db.execute(sql, [...]).fetchone()[0]
      if name == "scalar" && obj
        execute_args = if args.size > 1
                         [args[0].transform(self), Crystal::ArrayLiteral.new(args[1..].map { |a| a.transform(self).as(Crystal::ASTNode) })] of Crystal::ASTNode
                       else
                         args.map { |a| a.transform(self).as(Crystal::ASTNode) }
                       end
        execute_call = Crystal::Call.new(obj.transform(self), "execute", execute_args)
        fetchone = Crystal::Call.new(execute_call, "fetchone")
        return Crystal::Call.new(fetchone, "[]", [Crystal::NumberLiteral.new("0")] of Crystal::ASTNode)
      end

      # db.query_one?(sql, ...) { |rs| ... } → db.execute(sql, [...]).fetchone()
      if (name == "query_one?" || name == "query_one") && obj
        execute_args = if args.size > 1
                         [args[0].transform(self), Crystal::ArrayLiteral.new(args[1..].map { |a| a.transform(self).as(Crystal::ASTNode) })] of Crystal::ASTNode
                       else
                         args.map { |a| a.transform(self).as(Crystal::ASTNode) }
                       end
        execute_call = Crystal::Call.new(obj.transform(self), "execute", execute_args)
        return Crystal::Call.new(execute_call, "fetchone")
      end

      # Time.utc → datetime.now()
      if name == "utc" && obj.is_a?(Crystal::Path) && obj.names.last == "Time"
        return Crystal::Call.new(
          Crystal::Path.new(["datetime"]),
          "now"
        )
      end

      # .to_s("%F %T.%6N") on datetime → .strftime(...)
      if name == "to_s" && obj && args.size == 1 && args[0].is_a?(Crystal::StringLiteral)
        # Check if obj is likely a Time/datetime
        fmt = args[0].as(Crystal::StringLiteral).value
        if fmt.includes?("%F") || fmt.includes?("%T")
          py_fmt = fmt
            .gsub("%F", "%Y-%m-%d")
            .gsub("%T", "%H:%M:%S")
            .gsub("%6N", "%f")
          return Crystal::Call.new(
            obj.transform(self),
            "strftime",
            [Crystal::StringLiteral.new(py_fmt)] of Crystal::ASTNode
          )
        end
      end

      # Log.for("name") → logging.getLogger("name")
      if name == "for" && obj.is_a?(Crystal::Path) && obj.names.last == "Log"
        return Crystal::Call.new(
          Crystal::Path.new(["logging"]),
          "getLogger",
          args.map { |a| a.transform(self).as(Crystal::ASTNode) }
        )
      end

      # log.debug { msg } → log.debug(msg) (strip block, inline)
      if name == "debug" && obj && node.block
        block_body = node.block.not_nil!.body
        return Crystal::Call.new(
          obj.transform(self),
          "debug",
          [block_body.transform(self)] of Crystal::ASTNode
        )
      end

      super
    end

    def transform(node : Crystal::ASTNode) : Crystal::ASTNode
      super
    end
  end
end
