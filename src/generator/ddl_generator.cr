# Generates SQL DDL (CREATE TABLE) from extracted table schemas.
#
# Shared between app entry point and test spec_helper to avoid duplication.

require "./schema_extractor"
require "./inflector"

module Railcar
  class DDLGenerator
    SQL_TYPES = {
      "string"   => "TEXT",
      "text"     => "TEXT",
      "integer"  => "INTEGER",
      "float"    => "REAL",
      "boolean"  => "INTEGER",
      "datetime" => "TEXT",
      "date"     => "TEXT",
      "time"     => "TEXT",
      "decimal"  => "REAL",
      "binary"   => "BLOB",
      "json"     => "TEXT",
      "jsonb"    => "TEXT",
      "uuid"     => "TEXT",
    }

    # Generate DDL statements for the given schemas.
    # if_not_exists: adds IF NOT EXISTS clause (for app entry, not tests)
    def self.generate(schemas : Array(TableSchema), io : IO, indent : String = "", if_not_exists : Bool = false)
      exists_clause = if_not_exists ? "IF NOT EXISTS " : ""
      schemas.each do |schema|
        io << indent << "db.exec <<-SQL\n"
        io << indent << "  CREATE TABLE #{exists_clause}#{schema.name} (\n"
        io << indent << "    id INTEGER PRIMARY KEY AUTOINCREMENT"
        schema.columns.each do |col|
          sql_type = SQL_TYPES[col.type]? || "TEXT"
          not_null = col.options["null"]? == "true" ? "" : " NOT NULL"
          refs = ""
          if col.name.ends_with?("_id")
            ref_table = Inflector.pluralize(col.name.chomp("_id"))
            refs = " REFERENCES #{ref_table}(id)"
          end
          io << ",\n" << indent << "    #{col.name} #{sql_type}#{not_null}#{refs}"
        end
        io << "\n" << indent << "  )\n" << indent << "SQL\n"
      end
    end
  end
end
