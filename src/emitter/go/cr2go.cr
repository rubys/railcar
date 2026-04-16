# Emitter: Crystal AST → Go source code.
#
# Walks typed Crystal AST nodes and emits Go.
# Handles model emission: struct definitions, receiver methods,
# validations, associations, interface implementation.

require "compiler/crystal/syntax"

module Railcar
  module Cr2Go
    class Emitter
      CRYSTAL_TO_GO = {
        "String"  => "string",
        "Int32"   => "int",
        "Int64"   => "int64",
        "Float32" => "float32",
        "Float64" => "float64",
        "Bool"    => "bool",
        "Nil"     => "nil",
      }

      def emit_model(node : Crystal::ClassDef, class_name : String, schema : TableSchema, app_name : String,
                     broadcast_ast : Crystal::ASTNode? = nil) : String
        io = IO::Memory.new
        singular = Inflector.underscore(class_name)
        table_name = Inflector.pluralize(singular)

        io << "package models\n\n"
        io << "import (\n"
        io << "\t\"database/sql\"\n"
        io << "\t\"fmt\"\n"
        io << "\t\"#{app_name}/railcar\"\n"
        io << ")\n\n"

        # Struct
        io << "type #{class_name} struct {\n"
        io << "\tId        int64\n"
        schema.columns.each do |col|
          next if col.name == "id"
          go_type = map_type(col.type)
          go_name = go_field_name(col.name)
          io << "\t#{go_name}  #{go_type}\n"
        end
        io << "\tpersisted bool\n"
        io << "\terrors    []railcar.ValidationError\n"
        io << "}\n\n"

        # Factory
        io << "func New#{class_name}() *#{class_name} { return &#{class_name}{} }\n\n"

        # Interface methods
        io << "func (m *#{class_name}) TableName() string { return #{table_name.inspect} }\n"
        io << "func (m *#{class_name}) ID() int64 { return m.Id }\n"
        io << "func (m *#{class_name}) SetID(id int64) { m.Id = id }\n"
        io << "func (m *#{class_name}) Persisted() bool { return m.persisted }\n"
        io << "func (m *#{class_name}) SetPersisted(v bool) { m.persisted = v }\n"
        io << "func (m *#{class_name}) Errors() []railcar.ValidationError { return m.errors }\n"
        io << "func (m *#{class_name}) SetErrors(e []railcar.ValidationError) { m.errors = e }\n\n"

        # Columns
        cols = schema.columns.reject { |c| c.name == "id" }.map { |c| c.name }
        io << "func (m *#{class_name}) Columns() []string {\n"
        io << "\treturn []string{#{cols.map(&.inspect).join(", ")}}\n"
        io << "}\n\n"

        # ScanRow
        scan_fields = ["&m.Id"] + schema.columns.reject { |c| c.name == "id" }.map { |c| "&m.#{go_field_name(c.name)}" }
        io << "func (m *#{class_name}) ScanRow(rows *sql.Rows) error {\n"
        io << "\treturn rows.Scan(#{scan_fields.join(", ")})\n"
        io << "}\n\n"

        # ColumnValues (for insert, excludes timestamps)
        val_cols = schema.columns.reject { |c| {"id", "created_at", "updated_at"}.includes?(c.name) }
        io << "func (m *#{class_name}) ColumnValues() []any {\n"
        io << "\treturn []any{#{val_cols.map { |c| "m.#{go_field_name(c.name)}" }.join(", ")}}\n"
        io << "}\n\n"

        # ColumnValuesForUpdate
        update_cols = schema.columns.reject { |c| c.name == "id" }
        io << "func (m *#{class_name}) ColumnValuesForUpdate() []any {\n"
        io << "\treturn []any{#{update_cols.map { |c| "m.#{go_field_name(c.name)}" }.join(", ")}}\n"
        io << "}\n\n"

        # Now walk the filtered AST for methods
        body = case node.body
               when Crystal::Expressions then node.body.as(Crystal::Expressions).expressions
               else [node.body]
               end

        has_destroy = false
        body.each do |expr|
          case expr
          when Crystal::Def
            has_destroy = true if expr.as(Crystal::Def).name == "destroy"
            emit_method(expr, io, class_name, singular, table_name, app_name)
          end
        end

        # Default Delete if no destroy override was generated
        unless has_destroy
          io << "func (m *#{class_name}) Delete() error { return railcar.Delete(m) }\n\n"
        end

        # Extract broadcast callbacks from the pre-filtered AST
        after_save_stmts = [] of Crystal::ASTNode
        after_delete_stmts = [] of Crystal::ASTNode
        if broadcast_ast
          broadcast_body = case broadcast_ast
                          when Crystal::ClassDef
                            case broadcast_ast.as(Crystal::ClassDef).body
                            when Crystal::Expressions then broadcast_ast.as(Crystal::ClassDef).body.as(Crystal::Expressions).expressions
                            else [broadcast_ast.as(Crystal::ClassDef).body]
                            end
                          else [] of Crystal::ASTNode
                          end
          broadcast_body.each do |expr|
            # after_save/after_destroy are Call nodes, but BroadcastsTo returns
            # Expressions containing them, so also check Expressions
            collect_callbacks(expr, after_save_stmts, after_delete_stmts)
          end
        end

        # After save/delete callbacks → AfterSave/AfterDelete methods (Broadcaster interface)
        unless after_save_stmts.empty? && after_delete_stmts.empty?
          io << "func (m *#{class_name}) AfterSave() {\n"
          after_save_stmts.each { |stmt| emit_callback_body(stmt, io, class_name) }
          io << "}\n\n"
          io << "func (m *#{class_name}) AfterDelete() {\n"
          after_delete_stmts.each { |stmt| emit_callback_body(stmt, io, class_name) }
          io << "}\n\n"
        end

        # Static functions: Find, All, Count, Last, Create
        emit_static_functions(io, class_name, table_name, schema, app_name)

        # Convenience: Save, Update
        io << "func (m *#{class_name}) Save() error { return railcar.Save(m) }\n\n"
        io << "func (m *#{class_name}) Update(attrs map[string]any) error {\n"
        schema.columns.each do |col|
          next if {"id", "created_at", "updated_at"}.includes?(col.name)
          go_name = go_field_name(col.name)
          go_t = map_type(col.type)
          cast = go_t == "int64" ? "v.(int64)" : "v.(string)"
          io << "\tif v, ok := attrs[#{col.name.inspect}]; ok { m.#{go_name} = #{cast} }\n"
        end
        io << "\tm.SetPersisted(true)\n"
        io << "\treturn railcar.Save(m)\n"
        io << "}\n\n"

        io << "var _ = fmt.Sprintf\n"

        io.to_s
      end

      private def emit_method(defn : Crystal::Def, io : IO, class_name : String,
                               singular : String, table_name : String, app_name : String)
        name = defn.name

        case name
        when "run_validations"
          emit_validations(defn, io, class_name)
        when "destroy"
          emit_destroy_override(defn, io, class_name)
        else
          # Association methods (comments, article)
          ret_type = defn.return_type
          if ret_type
            type_name = ret_type.to_s
            if type_name == "CollectionProxy"
              emit_has_many(defn, io, class_name, app_name)
            elsif type_name == "ApplicationRecord"
              emit_belongs_to(defn, io, class_name, app_name)
            end
          end
        end
      end

      private def emit_validations(defn : Crystal::Def, io : IO, class_name : String)
        io << "func (m *#{class_name}) RunValidations() []railcar.ValidationError {\n"
        io << "\tvar errors []railcar.ValidationError\n"

        walk_validation_body(defn.body, io, class_name)

        io << "\treturn errors\n"
        io << "}\n\n"
      end

      private def walk_validation_body(node : Crystal::ASTNode, io : IO, class_name : String)
        case node
        when Crystal::Expressions
          node.expressions.each { |e| walk_validation_body(e, io, class_name) }
        when Crystal::If
          emit_validation_if(node, io, class_name)
        when Crystal::Call
          if node.name == "add" && node.obj
            # errors.add("field", "message")
            field = node.args[0]?.try(&.to_s.strip('"')) || ""
            message = node.args[1]?.try(&.to_s.strip('"')) || ""
            io << "\terrors = append(errors, railcar.ValidationError{Field: #{field.inspect}, Message: #{message.inspect}})\n"
          end
        end
      end

      private def emit_validation_if(node : Crystal::If, io : IO, class_name : String)
        cond = emit_go_condition(node.cond)
        io << "\tif #{cond} {\n"
        walk_validation_body_inner(node.then, io, class_name)
        if node.else && !node.else.is_a?(Crystal::Nop)
          io << "\t} else {\n"
          walk_validation_body_inner(node.else, io, class_name)
        end
        io << "\t}\n"
      end

      private def walk_validation_body_inner(node : Crystal::ASTNode, io : IO, class_name : String)
        case node
        when Crystal::Expressions
          node.expressions.each { |e| walk_validation_body_inner(e, io, class_name) }
        when Crystal::If
          emit_validation_if(node, io, class_name)
        when Crystal::Call
          if node.name == "add" && node.obj
            field = node.args[0]?.try(&.to_s.strip('"')) || ""
            message = node.args[1]?.try(&.to_s.strip('"')) || ""
            io << "\t\terrors = append(errors, railcar.ValidationError{Field: #{field.inspect}, Message: #{message.inspect}})\n"
          end
        when Crystal::ExceptionHandler
          # begin/rescue for belongs_to validation → extract find target from body
          find_target = class_name
          find_field = "article_id"
          body = node.body
          if body.is_a?(Crystal::Call) && body.name == "find"
            if body.obj.is_a?(Crystal::Call) && body.obj.as(Crystal::Call).name == "[]"
              target_arg = body.obj.as(Crystal::Call).args.first?
              find_target = target_arg.to_s.strip('"') if target_arg
            end
            if body.args.first?
              fk = body.args.first
              fk = fk.as(Crystal::Cast).obj if fk.is_a?(Crystal::Cast)
              find_field = case fk
                           when Crystal::InstanceVar then fk.name.lchop("@")
                           else "article_id"
                           end
            end
          end
          io << "\t\tif _, err := Find#{find_target}(m.#{go_field_name(find_field)}); err != nil {\n"
          if node.rescues && !node.rescues.not_nil!.empty?
            walk_validation_body_inner(node.rescues.not_nil!.first.body, io, class_name)
          end
          io << "\t\t}\n"
        end
      end

      private def emit_go_condition(node : Crystal::ASTNode) : String
        case node
        when Crystal::IsA
          obj = emit_go_expr(node.obj)
          type_name = node.const.to_s.lstrip(":")
          if type_name == "Nil" || type_name == "NilClass"
            # Check zero value based on inferred type
            if obj.ends_with?("Id") || obj.ends_with?("ID")
              "#{obj} == 0"
            else
              "#{obj} == \"\""
            end
          elsif type_name == "String"
            "true" # Always string in Go
          else
            "true"
          end
        when Crystal::Call
          if node.name == "nil?"
            obj = node.obj ? emit_go_expr(node.obj.not_nil!) : "m"
            if obj.ends_with?("Id") || obj.ends_with?("ID")
              "#{obj} == 0"
            else
              "#{obj} == \"\""
            end
          elsif node.name == "empty?"
            obj = node.obj ? emit_go_expr(node.obj.not_nil!) : "m"
            "#{obj} == \"\""
          elsif node.name == "size" || node.name == "length"
            obj = node.obj ? emit_go_expr(node.obj.not_nil!) : "m"
            "len(#{obj})"
          elsif node.name == "<"
            left = node.obj ? emit_go_expr(node.obj.not_nil!) : ""
            right = node.args.first? ? emit_go_expr(node.args.first) : "0"
            "#{left} < #{right}"
          else
            emit_go_expr(node)
          end
        when Crystal::And
          left = emit_go_condition(node.left)
          right = emit_go_condition(node.right)
          "#{left} && #{right}"
        when Crystal::Or
          left = emit_go_condition(node.left)
          right = emit_go_condition(node.right)
          "(#{left} || #{right})"
        when Crystal::Not
          "!(#{emit_go_condition(node.exp)})"
        when Crystal::Expressions
          # Multi-expression condition — emit last expression
          if node.expressions.size > 0
            emit_go_condition(node.expressions.last)
          else
            "true"
          end
        when Crystal::Cast
          # .as(Type) — just emit the inner expression
          emit_go_condition(node.obj)
        else
          emit_go_expr(node)
        end
      end

      def emit_go_expr(node : Crystal::ASTNode) : String
        case node
        when Crystal::StringLiteral then node.value.inspect
        when Crystal::NumberLiteral then node.value.to_s.gsub(/_i64|_i32/, "")
        when Crystal::BoolLiteral then node.value.to_s
        when Crystal::NilLiteral then "nil"
        when Crystal::Var
          node.name == "self" ? "m" : node.name
        when Crystal::InstanceVar
          "m.#{go_field_name(node.name.lchop("@"))}"
        when Crystal::Path then node.names.join(".")
        when Crystal::Call
          obj = node.obj
          name = node.name
          if name == "size" || name == "length"
            obj_str = obj ? emit_go_expr(obj) : "m"
            "len(#{obj_str})"
          elsif obj
            obj_str = emit_go_expr(obj)
            "#{obj_str}.#{go_field_name(name)}"
          else
            name
          end
        when Crystal::Cast then emit_go_expr(node.obj)
        when Crystal::Expressions
          node.expressions.map { |e| emit_go_expr(e) }.last? || ""
        else "/* TODO: #{node.class.name} */"
        end
      end

      private def emit_has_many(defn : Crystal::Def, io : IO, class_name : String, app_name : String)
        # Extract CollectionProxy.new(self, "fk", "Target") from body
        body = defn.body
        if body.is_a?(Crystal::Call) && body.name == "new"
          args = body.args
          if args.size >= 3
            fk = args[1].to_s.strip('"')
            target = args[2].to_s.strip('"')
            target_table = Inflector.pluralize(Inflector.underscore(target))
            io << "func (m *#{class_name}) #{go_field_name(defn.name)}() ([]*#{target}, error) {\n"
            io << "\treturn railcar.Where(func() *#{target} { return New#{target}() }, #{target_table.inspect}, map[string]any{#{fk.inspect}: m.Id})\n"
            io << "}\n\n"
          end
        end
      end

      private def emit_belongs_to(defn : Crystal::Def, io : IO, class_name : String, app_name : String)
        # Extract MODEL_REGISTRY["Target"].find(@fk) from body
        body = defn.body
        target = ""
        fk = ""
        case body
        when Crystal::Call
          if body.name == "find" && body.obj
            # The obj is MODEL_REGISTRY["Target"] — extract target name
            if body.obj.is_a?(Crystal::Call) && body.obj.as(Crystal::Call).name == "[]"
              target_arg = body.obj.as(Crystal::Call).args.first?
              target = target_arg.to_s.strip('"') if target_arg
            end
            # The arg is the FK
            if body.args.first?
              fk_node = body.args.first
              if fk_node.is_a?(Crystal::Cast)
                fk_node = fk_node.obj
              end
              fk = case fk_node
                   when Crystal::InstanceVar then fk_node.name.lchop("@")
                   else fk_node.to_s
                   end
            end
          end
        end

        unless target.empty?
          io << "func (m *#{class_name}) #{go_field_name(defn.name)}() (*#{target}, error) {\n"
          io << "\treturn Find#{target}(m.#{go_field_name(fk)})\n"
          io << "}\n\n"
        end
      end

      private def emit_destroy_override(defn : Crystal::Def, io : IO, class_name : String)
        io << "func (m *#{class_name}) Delete() error {\n"
        # Walk body for destroy_all calls
        body = case defn.body
               when Crystal::Expressions then defn.body.as(Crystal::Expressions).expressions
               else [defn.body]
               end
        body.each do |expr|
          if expr.is_a?(Crystal::Call) && expr.name == "destroy_all"
            if obj = expr.obj
              assoc_name = go_field_name(obj.to_s)
              io << "\tchildren, _ := m.#{assoc_name}()\n"
              io << "\tfor _, child := range children {\n"
              io << "\t\tchild.Delete()\n"
              io << "\t}\n"
            end
          end
        end
        io << "\treturn railcar.Delete(m)\n"
        io << "}\n\n"
      end

      private def emit_static_functions(io : IO, class_name : String, table_name : String,
                                         schema : TableSchema, app_name : String)
        io << "func Find#{class_name}(id int64) (*#{class_name}, error) {\n"
        io << "\tm := New#{class_name}()\n"
        io << "\terr := railcar.Find(m, id)\n"
        io << "\tif err != nil { return nil, err }\n"
        io << "\treturn m, nil\n"
        io << "}\n\n"

        io << "func All#{class_name}s(orderBy string) ([]*#{class_name}, error) {\n"
        io << "\treturn railcar.All(func() *#{class_name} { return New#{class_name}() }, #{table_name.inspect}, orderBy)\n"
        io << "}\n\n"

        io << "func #{class_name}Count() (int, error) {\n"
        io << "\treturn railcar.Count(#{table_name.inspect})\n"
        io << "}\n\n"

        io << "func #{class_name}Last() (*#{class_name}, error) {\n"
        io << "\tresults, err := All#{class_name}s(\"id\")\n"
        io << "\tif err != nil || len(results) == 0 { return nil, err }\n"
        io << "\treturn results[len(results)-1], nil\n"
        io << "}\n\n"

        io << "func Create#{class_name}(attrs map[string]any) (*#{class_name}, error) {\n"
        io << "\tm := New#{class_name}()\n"
        schema.columns.each do |col|
          next if {"id", "created_at", "updated_at"}.includes?(col.name)
          go_name = go_field_name(col.name)
          go_t = map_type(col.type)
          cast = go_t == "int64" ? "v.(int64)" : "v.(string)"
          io << "\tif v, ok := attrs[#{col.name.inspect}]; ok { m.#{go_name} = #{cast} }\n"
        end
        io << "\terr := railcar.Save(m)\n"
        io << "\tif err != nil { return m, err }\n"
        io << "\treturn m, nil\n"
        io << "}\n\n"
      end

      # --- Type mapping ---

      private def map_type(crystal_type : String) : String
        case crystal_type.downcase
        when "string", "text" then "string"
        when "integer", "references" then "int64"
        when "boolean" then "bool"
        when "float", "real", "double" then "float64"
        when "datetime", "date", "time" then "string"
        else "string"
        end
      end

      def go_field_name(name : String) : String
        name.split("_").map(&.capitalize).join("")
      end

      private def collect_callbacks(node : Crystal::ASTNode,
                                    save_stmts : Array(Crystal::ASTNode),
                                    delete_stmts : Array(Crystal::ASTNode))
        case node
        when Crystal::Call
          if node.name == "after_save" && node.block
            save_stmts << node.block.not_nil!.body
          elsif node.name == "after_destroy" && node.block
            delete_stmts << node.block.not_nil!.body
          end
        when Crystal::Expressions
          node.expressions.each { |e| collect_callbacks(e, save_stmts, delete_stmts) }
        end
      end

      private def emit_callback_body(node : Crystal::ASTNode, io : IO, class_name : String)
        case node
        when Crystal::Expressions
          node.expressions.each { |e| emit_callback_body(e, io, class_name) }
        when Crystal::Call
          name = node.name
          case name
          when "broadcast_replace_to", "broadcast_append_to", "broadcast_prepend_to", "broadcast_remove_to"
            func = case name
                   when "broadcast_replace_to" then "railcar.BroadcastReplaceTo"
                   when "broadcast_append_to"  then "railcar.BroadcastAppendTo"
                   when "broadcast_prepend_to" then "railcar.BroadcastPrependTo"
                   when "broadcast_remove_to"  then "railcar.BroadcastRemoveTo"
                   else "railcar.BroadcastReplaceTo"
                   end
            # First arg is channel expression, second (optional) is target
            channel = node.args.first? ? emit_callback_expr(node.args.first, class_name) : "\"\""
            target = node.args[1]? ? emit_callback_expr(node.args[1], class_name) : "\"\""
            # Also check named arg "target"
            if target == "\"\"" && (named = node.named_args)
              if target_arg = named.find { |na| na.name == "target" }
                target = emit_callback_expr(target_arg.value, class_name)
              end
            end
            # If called on an object (e.g., article.broadcast_replace_to), use that object
            if obj = node.obj
              if obj.is_a?(Crystal::Call)
                # Association method call (e.g., article → m.Article()) returns (value, error)
                assoc_name = obj.as(Crystal::Call).name
                go_method = "m.#{go_field_name(assoc_name)}()"
                io << "\tif #{assoc_name}, err := #{go_method}; err == nil {\n"
                io << "\t\t#{func}(#{assoc_name}, #{channel}, #{target})\n"
                io << "\t}\n"
              else
                obj_expr = emit_callback_expr(obj, class_name)
                io << "\t#{func}(#{obj_expr}, #{channel}, #{target})\n"
              end
            else
              io << "\t#{func}(m, #{channel}, #{target})\n"
            end
          else
            # Other calls in callbacks (e.g., article method calls)
            if node.obj
              io << "\t#{emit_callback_expr(node, class_name)}\n"
            end
          end
        when Crystal::ExceptionHandler
          # rescue nil → just emit the body, ignore errors
          emit_callback_body(node.body, io, class_name)
        end
      end

      private def emit_callback_expr(node : Crystal::ASTNode, class_name : String) : String
        case node
        when Crystal::StringLiteral
          node.value.inspect
        when Crystal::StringInterpolation
          # "article_#{article_id}_comments" → fmt.Sprintf("article_%d_comments", m.ArticleId)
          format_parts = [] of String
          go_args = [] of String
          node.expressions.each do |part|
            case part
            when Crystal::StringLiteral
              format_parts << part.value.gsub("%", "%%")
            when Crystal::Call
              if part.name.ends_with?("_id") || part.name == "id"
                format_parts << "%d"
              else
                format_parts << "%v"
              end
              go_args << emit_callback_expr(part, class_name)
            else
              format_parts << "%v"
              go_args << emit_callback_expr(part, class_name)
            end
          end
          if go_args.empty?
            format_parts.join.inspect
          else
            "fmt.Sprintf(#{format_parts.join.inspect}, #{go_args.join(", ")})"
          end
        when Crystal::Call
          obj = node.obj
          if obj
            obj_str = emit_callback_expr(obj, class_name)
            "#{obj_str}.#{go_field_name(node.name)}()"
          else
            # Bare method call → receiver method on m
            "m.#{go_field_name(node.name)}"
          end
        when Crystal::InstanceVar
          "m.#{go_field_name(node.name.lchop("@"))}"
        when Crystal::Var
          node.name == "self" ? "m" : node.name
        else
          emit_go_expr(node)
        end
      end
    end
  end
end
