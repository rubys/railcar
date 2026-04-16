# Emitter: Crystal AST → Rust source code.
#
# Walks typed Crystal AST nodes and emits Rust.
# Handles model emission: struct definitions, trait implementations,
# validations, associations, CRUD methods.

require "compiler/crystal/syntax"

module Railcar
  module Cr2Rs
    class Emitter
      CRYSTAL_TO_RUST = {
        "String"  => "String",
        "Int32"   => "i32",
        "Int64"   => "i64",
        "Float32" => "f32",
        "Float64" => "f64",
        "Bool"    => "bool",
        "Nil"     => "()",
      }

      def emit_model(node : Crystal::ClassDef, class_name : String, schema : TableSchema,
                     app_name : String, broadcast_ast : Crystal::ASTNode? = nil) : String
        io = IO::Memory.new
        singular = Inflector.underscore(class_name)
        table_name = Inflector.pluralize(singular)

        io << "use crate::railcar;\n"
        io << "use rusqlite::{params, Row};\n"
        io << "use std::collections::HashMap;\n"

        # Import associated model modules by scanning for association methods in AST
        assoc_body = case node.body
                     when Crystal::Expressions then node.body.as(Crystal::Expressions).expressions
                     else [node.body]
                     end
        assoc_body.each do |expr|
          next unless expr.is_a?(Crystal::Def)
          ret = expr.as(Crystal::Def).return_type
          next unless ret
          type_name = ret.to_s
          if type_name == "CollectionProxy" && expr.as(Crystal::Def).body.is_a?(Crystal::Call)
            args = expr.as(Crystal::Def).body.as(Crystal::Call).args
            if args.size >= 3
              target = args[2].to_s.strip('"')
              if target != class_name
                io << "use crate::#{Inflector.underscore(target)}::*;\n"
              end
            end
          elsif type_name == "ApplicationRecord" && expr.as(Crystal::Def).body.is_a?(Crystal::Call)
            body_call = expr.as(Crystal::Def).body.as(Crystal::Call)
            if body_call.name == "find" && body_call.obj.is_a?(Crystal::Call)
              target_arg = body_call.obj.as(Crystal::Call).args.first?
              target = target_arg.to_s.strip('"') if target_arg
              if target && target != class_name
                io << "use crate::#{Inflector.underscore(target)}::*;\n"
              end
            end
          end
        end
        io << "\n"

        # Struct
        io << "#[derive(Debug, Clone, Default)]\n"
        io << "pub struct #{class_name} {\n"
        io << "    pub id: i64,\n"
        schema.columns.each do |col|
          next if col.name == "id"
          rust_type = map_type(col.type)
          io << "    pub #{col.name}: #{rust_type},\n"
        end
        io << "    pub persisted: bool,\n"
        io << "    pub errors: Vec<railcar::ValidationError>,\n"
        io << "}\n\n"

        # Default / new
        io << "impl #{class_name} {\n"
        io << "    pub fn new() -> Self {\n"
        io << "        Self {\n"
        io << "            id: 0,\n"
        schema.columns.each do |col|
          next if col.name == "id"
          default = case col.type.downcase
                    when "integer", "references" then "0"
                    when "boolean"               then "false"
                    when "float", "real", "double" then "0.0"
                    else                          "String::new()"
                    end
          io << "            #{col.name}: #{default},\n"
        end
        io << "            persisted: false,\n"
        io << "            errors: vec![],\n"
        io << "        }\n"
        io << "    }\n\n"

        # Save (insert or update)
        emit_save(io, class_name, schema)

        # Update from attrs
        emit_update(io, class_name, schema)

        # Delete
        io << "    pub fn delete(&self) -> Result<(), String> {\n"
        io << "        railcar::delete_by_id(\"#{table_name}\", self.id)\n"
        io << "    }\n\n"

        # Associations
        body = case node.body
               when Crystal::Expressions then node.body.as(Crystal::Expressions).expressions
               else [node.body]
               end

        has_destroy = false
        body.each do |expr|
          case expr
          when Crystal::Def
            defn = expr.as(Crystal::Def)
            case defn.name
            when "destroy"
              has_destroy = true
              emit_destroy_override(io, defn, class_name)
            else
              ret_type = defn.return_type
              if ret_type
                type_name = ret_type.to_s
                if type_name == "CollectionProxy"
                  emit_has_many(io, defn, class_name)
                elsif type_name == "ApplicationRecord"
                  emit_belongs_to(io, defn, class_name)
                end
              end
            end
          end
        end

        # Override delete with destroy if present
        if has_destroy
          # destroy_override already emitted above
        end

        io << "}\n\n"  # close impl

        # Model trait implementation
        emit_model_trait(io, class_name, schema)

        # Validations
        emit_validations(io, class_name, body)

        # Static functions
        emit_static_functions(io, class_name, table_name, schema)

        # Broadcast callbacks
        emit_broadcast_callbacks(io, class_name, broadcast_ast)

        io.to_s
      end

      private def emit_save(io : IO, class_name : String, schema : TableSchema)
        table_name = Inflector.pluralize(Inflector.underscore(class_name))
        insert_cols = schema.columns.reject { |c| {"id", "created_at", "updated_at"}.includes?(c.name) }
        has_times = schema.columns.any? { |c| c.name == "created_at" }

        io << "    pub fn save(&mut self) -> Result<(), String> {\n"
        io << "        let errors = self.validate();\n"
        io << "        if !errors.is_empty() {\n"
        io << "            self.errors = errors;\n"
        io << "            return Err(\"validation failed\".to_string());\n"
        io << "        }\n"
        io << "        self.errors = vec![];\n"
        io << "        let now = railcar::now();\n"
        io << "        if self.persisted {\n"

        # Update — clone values to avoid borrow issues
        update_cols = schema.columns.reject { |c| {"id", "created_at"}.includes?(c.name) }
        set_clauses = update_cols.map { |c| "#{c.name} = ?" }
        update_cols.each do |c|
          next if c.name == "updated_at"
          rust_type = map_type(c.type)
          if rust_type == "String"
            io << "            let #{c.name}_val = self.#{c.name}.clone();\n"
          else
            io << "            let #{c.name}_val = self.#{c.name};\n"
          end
        end
        io << "            let id_val = self.id;\n"
        param_names = update_cols.map { |c| c.name == "updated_at" ? "now" : "#{c.name}_val" }
        param_names << "id_val"
        io << "            railcar::with_db(|conn| {\n"
        io << "                conn.execute(\n"
        io << "                    \"UPDATE #{table_name} SET #{set_clauses.join(", ")} WHERE id = ?\",\n"
        io << "                    params![#{param_names.join(", ")}],\n"
        io << "                ).map(|_| ())\n"
        io << "            })\n"
        io << "        } else {\n"

        # Insert — clone values to avoid borrow issues
        all_insert_cols = insert_cols.map(&.name)
        if has_times
          all_insert_cols += ["created_at", "updated_at"]
        end
        placeholders = all_insert_cols.map { |_| "?" }
        insert_cols.each do |c|
          rust_type = map_type(c.type)
          if rust_type == "String"
            io << "            let #{c.name}_val = self.#{c.name}.clone();\n"
          else
            io << "            let #{c.name}_val = self.#{c.name};\n"
          end
        end
        param_names_insert = insert_cols.map { |c| "#{c.name}_val" }
        if has_times
          param_names_insert += ["now.clone()", "now"]
        end
        io << "            let id = railcar::with_db(|conn| {\n"
        io << "                conn.execute(\n"
        io << "                    \"INSERT INTO #{table_name} (#{all_insert_cols.join(", ")}) VALUES (#{placeholders.join(", ")})\",\n"
        io << "                    params![#{param_names_insert.join(", ")}],\n"
        io << "                )?;\n"
        io << "                Ok(conn.last_insert_rowid())\n"
        io << "            })?;\n"
        io << "            self.id = id;\n"
        io << "            self.persisted = true;\n"
        io << "            Ok(())\n"
        io << "        }\n"
        io << "    }\n\n"
      end

      private def emit_update(io : IO, class_name : String, schema : TableSchema)
        io << "    pub fn update(&mut self, attrs: &HashMap<String, String>) -> Result<(), String> {\n"
        schema.columns.each do |col|
          next if {"id", "created_at", "updated_at"}.includes?(col.name)
          if col.type.downcase == "integer" || col.type.downcase == "references"
            io << "        if let Some(v) = attrs.get(\"#{col.name}\") { self.#{col.name} = v.parse().unwrap_or(0); }\n"
          else
            io << "        if let Some(v) = attrs.get(\"#{col.name}\") { self.#{col.name} = v.clone(); }\n"
          end
        end
        io << "        self.persisted = true;\n"
        io << "        self.save()\n"
        io << "    }\n\n"
      end

      private def emit_model_trait(io : IO, class_name : String, schema : TableSchema)
        table_name = Inflector.pluralize(Inflector.underscore(class_name))

        io << "impl railcar::Model for #{class_name} {\n"
        io << "    fn table_name() -> &'static str { \"#{table_name}\" }\n"
        io << "    fn id(&self) -> i64 { self.id }\n"
        io << "    fn set_id(&mut self, id: i64) { self.id = id; }\n"
        io << "    fn persisted(&self) -> bool { self.persisted }\n"
        io << "    fn set_persisted(&mut self, p: bool) { self.persisted = p; }\n"
        io << "    fn errors(&self) -> &[railcar::ValidationError] { &self.errors }\n"
        io << "    fn set_errors(&mut self, e: Vec<railcar::ValidationError>) { self.errors = e; }\n\n"

        # run_validations — delegates to generated validation logic
        io << "    fn run_validations(&self) -> Vec<railcar::ValidationError> {\n"
        io << "        self.validate()\n"
        io << "    }\n\n"

        # from_row
        io << "    fn from_row(row: &Row) -> Result<Self, rusqlite::Error> {\n"
        io << "        Ok(Self {\n"
        io << "            id: row.get(0)?,\n"
        schema.columns.each_with_index do |col, i|
          next if col.name == "id"
          io << "            #{col.name}: row.get(#{i + 1})?,\n"
        end
        io << "            persisted: true,\n"
        io << "            errors: vec![],\n"
        io << "        })\n"
        io << "    }\n"
        io << "}\n\n"
      end

      private def emit_validations(io : IO, class_name : String, body : Array(Crystal::ASTNode))
        # Find run_validations def in the body
        validations_def = body.find { |e| e.is_a?(Crystal::Def) && e.as(Crystal::Def).name == "run_validations" }
        return unless validations_def

        io << "impl #{class_name} {\n"
        io << "    pub fn validate(&self) -> Vec<railcar::ValidationError> {\n"
        io << "        let mut errors = Vec::new();\n"

        walk_validation_body(validations_def.as(Crystal::Def).body, io, class_name)

        io << "        errors\n"
        io << "    }\n"
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
            field = node.args[0]?.try(&.to_s.strip('"')) || ""
            message = node.args[1]?.try(&.to_s.strip('"')) || ""
            io << "        errors.push(railcar::ValidationError::new(\"#{field}\", \"#{message}\"));\n"
          end
        end
      end

      private def emit_validation_if(node : Crystal::If, io : IO, class_name : String)
        cond = emit_rust_condition(node.cond)
        return if cond == "true"  # skip always-true type checks
        io << "        if #{cond} {\n"
        walk_validation_body_inner(node.then, io, class_name)
        if node.else && !node.else.is_a?(Crystal::Nop)
          io << "        } else {\n"
          walk_validation_body_inner(node.else, io, class_name)
        end
        io << "        }\n"
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
            io << "            errors.push(railcar::ValidationError::new(\"#{field}\", \"#{message}\"));\n"
          end
        when Crystal::ExceptionHandler
          # belongs_to validation: try find, on error add validation error
          body = node.body
          if body.is_a?(Crystal::Call) && body.name == "find" && body.obj
            find_target = ""
            if body.obj.is_a?(Crystal::Call) && body.obj.as(Crystal::Call).name == "[]"
              target_arg = body.obj.as(Crystal::Call).args.first?
              find_target = target_arg.to_s.strip('"') if target_arg
            end
            find_field = ""
            if body.args.first?
              fk_node = body.args.first
              fk_node = fk_node.as(Crystal::Cast).obj if fk_node.is_a?(Crystal::Cast)
              find_field = case fk_node
                           when Crystal::InstanceVar then fk_node.name.lchop("@")
                           else fk_node.to_s
                           end
            end
            singular = Inflector.underscore(find_target)
            io << "            if find_#{singular}(self.#{find_field}).is_err() {\n"
            if node.rescues && !node.rescues.not_nil!.empty?
              walk_validation_body_inner(node.rescues.not_nil!.first.body, io, class_name)
            end
            io << "            }\n"
          end
        end
      end

      private def emit_rust_condition(node : Crystal::ASTNode) : String
        case node
        when Crystal::IsA
          type_name = node.const.to_s.lstrip(":")
          if type_name == "Nil" || type_name == "NilClass"
            obj = emit_rust_expr(node.obj)
            if obj.ends_with?("_id")
              "#{obj} == 0"
            else
              "#{obj}.is_empty()"
            end
          else
            "true"
          end
        when Crystal::Expressions
          # Multi-expression: emit last
          if node.expressions.size > 0
            emit_rust_condition(node.expressions.last)
          else
            "true"
          end
        when Crystal::Cast
          emit_rust_condition(node.obj)
        when Crystal::Call
          if node.name == "nil?"
            obj = node.obj ? emit_rust_expr(node.obj.not_nil!) : "self"
            if obj.ends_with?("_id")
              "#{obj} == 0"
            else
              "#{obj}.is_empty()"
            end
          elsif node.name == "empty?"
            obj = node.obj ? emit_rust_expr(node.obj.not_nil!) : "self"
            "#{obj}.is_empty()"
          elsif node.name == "<"
            left = node.obj ? emit_rust_expr(node.obj.not_nil!) : ""
            right = node.args.first? ? emit_rust_expr(node.args.first) : "0"
            "#{left} < #{right}"
          elsif node.name == "size" || node.name == "length"
            obj = node.obj ? emit_rust_expr(node.obj.not_nil!) : ""
            "#{obj}.len()"
          else
            emit_rust_expr(node)
          end
        when Crystal::And
          left = emit_rust_condition(node.left)
          right = emit_rust_condition(node.right)
          return right if left == "true"
          return left if right == "true"
          "#{left} && #{right}"
        when Crystal::Or
          left = emit_rust_condition(node.left)
          right = emit_rust_condition(node.right)
          return left if left == right
          "(#{left} || #{right})"
        when Crystal::Not
          "!(#{emit_rust_condition(node.exp)})"
        else
          emit_rust_expr(node)
        end
      end

      private def emit_rust_expr(node : Crystal::ASTNode) : String
        case node
        when Crystal::StringLiteral then node.value.inspect
        when Crystal::NumberLiteral then node.value.to_s.gsub(/_i64|_i32/, "")
        when Crystal::BoolLiteral then node.value.to_s
        when Crystal::Var then node.name == "self" ? "self" : node.name
        when Crystal::InstanceVar then "self.#{node.name.lchop("@")}"
        when Crystal::Path then node.names.join("::")
        when Crystal::Call
          obj = node.obj
          name = node.name
          if name == "size" || name == "length"
            obj_str = obj ? emit_rust_expr(obj) : "self"
            "#{obj_str}.len()"
          elsif obj
            "#{emit_rust_expr(obj)}.#{name}"
          else
            name
          end
        when Crystal::Cast then emit_rust_expr(node.obj)
        else "/* TODO: #{node.class.name} */"
        end
      end

      private def emit_has_many(io : IO, defn : Crystal::Def, class_name : String)
        body = defn.body
        if body.is_a?(Crystal::Call) && body.name == "new"
          args = body.args
          if args.size >= 3
            fk = args[1].to_s.strip('"')
            target = args[2].to_s.strip('"')
            singular = Inflector.underscore(target)
            io << "    pub fn #{defn.name}(&self) -> Result<Vec<#{target}>, String> {\n"
            io << "        railcar::where_eq::<#{target}>(\"#{fk}\", self.id)\n"
            io << "    }\n\n"
          end
        end
      end

      private def emit_belongs_to(io : IO, defn : Crystal::Def, class_name : String)
        body = defn.body
        target = ""
        fk = ""
        case body
        when Crystal::Call
          if body.name == "find" && body.obj
            if body.obj.is_a?(Crystal::Call) && body.obj.as(Crystal::Call).name == "[]"
              target_arg = body.obj.as(Crystal::Call).args.first?
              target = target_arg.to_s.strip('"') if target_arg
            end
            if body.args.first?
              fk_node = body.args.first
              fk_node = fk_node.as(Crystal::Cast).obj if fk_node.is_a?(Crystal::Cast)
              fk = case fk_node
                   when Crystal::InstanceVar then fk_node.name.lchop("@")
                   else fk_node.to_s
                   end
            end
          end
        end

        unless target.empty?
          singular = Inflector.underscore(target)
          io << "    pub fn #{defn.name}(&self) -> Result<#{target}, String> {\n"
          io << "        find_#{singular}(self.#{fk})\n"
          io << "    }\n\n"
        end
      end

      private def emit_destroy_override(io : IO, defn : Crystal::Def, class_name : String)
        io << "    pub fn destroy(&self) -> Result<(), String> {\n"
        body = case defn.body
               when Crystal::Expressions then defn.body.as(Crystal::Expressions).expressions
               else [defn.body]
               end
        body.each do |expr|
          if expr.is_a?(Crystal::Call) && expr.name == "destroy_all"
            if obj = expr.obj
              assoc_name = case obj
                           when Crystal::Call then obj.name
                           else "items"
                           end
              io << "        if let Ok(children) = self.#{assoc_name}() {\n"
              io << "            for child in &children {\n"
              io << "                child.delete()?;\n"
              io << "            }\n"
              io << "        }\n"
            end
          end
        end
        io << "        railcar::delete_by_id(\"#{Inflector.pluralize(Inflector.underscore(class_name))}\", self.id)\n"
        io << "    }\n\n"
      end

      private def emit_static_functions(io : IO, class_name : String, table_name : String, schema : TableSchema)
        singular = Inflector.underscore(class_name)

        io << "pub fn find_#{singular}(id: i64) -> Result<#{class_name}, String> {\n"
        io << "    railcar::find::<#{class_name}>(id)\n"
        io << "}\n\n"

        io << "pub fn all_#{singular}s(order_by: &str) -> Result<Vec<#{class_name}>, String> {\n"
        io << "    railcar::all::<#{class_name}>(order_by)\n"
        io << "}\n\n"

        io << "pub fn #{singular}_count() -> Result<i64, String> {\n"
        io << "    railcar::count(\"#{table_name}\")\n"
        io << "}\n\n"

        io << "pub fn #{singular}_last() -> Result<#{class_name}, String> {\n"
        io << "    let mut all = railcar::all::<#{class_name}>(\"id\")?;\n"
        io << "    all.pop().ok_or(\"no records\".to_string())\n"
        io << "}\n\n"

        io << "pub fn create_#{singular}(attrs: &HashMap<String, String>) -> Result<#{class_name}, String> {\n"
        io << "    let mut m = #{class_name}::new();\n"
        schema.columns.each do |col|
          next if {"id", "created_at", "updated_at"}.includes?(col.name)
          if col.type.downcase == "integer" || col.type.downcase == "references"
            io << "    if let Some(v) = attrs.get(\"#{col.name}\") { m.#{col.name} = v.parse().unwrap_or(0); }\n"
          else
            io << "    if let Some(v) = attrs.get(\"#{col.name}\") { m.#{col.name} = v.clone(); }\n"
          end
        end
        io << "    m.save()?;\n"
        io << "    Ok(m)\n"
        io << "}\n\n"

      end

      private def emit_broadcast_callbacks(io : IO, class_name : String, broadcast_ast : Crystal::ASTNode?)
        # For now, empty implementations — will be filled in when WebSocket is added
        io << "impl railcar::Broadcaster for #{class_name} {\n"
        io << "    fn after_save(&self) {}\n"
        io << "    fn after_delete(&self) {}\n"
        io << "}\n"
      end

      private def map_type(crystal_type : String) : String
        case crystal_type.downcase
        when "string", "text"               then "String"
        when "integer", "references"        then "i64"
        when "boolean"                      then "bool"
        when "float", "real", "double"      then "f64"
        when "datetime", "date", "time"     then "String"
        else "String"
        end
      end

      def rust_field_name(name : String) : String
        name  # Rust uses snake_case, same as Ruby
      end
    end
  end
end
