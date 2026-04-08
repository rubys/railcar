# Extracts table schemas from Rails migration files using Prism.
#
# Parses `create_table` blocks to find column names and types.
# Handles `t.string :name`, `t.references :article`, `t.timestamps`, etc.

require "../prism/bindings"
require "../prism/deserializer"

module Ruby2CR
  # Represents a single column in a table
  record Column, name : String, type : String, options : Hash(String, String) = {} of String => String

  # Represents a table schema extracted from a migration
  record TableSchema, name : String, columns : Array(Column)

  class SchemaExtractor
    # Parse a migration file and extract the table schema
    def self.extract(source : String) : TableSchema?
      ast = Prism.parse(source)
      stmts = ast.statements
      return nil unless stmts.is_a?(Prism::StatementsNode)

      # Walk the tree looking for create_table calls
      find_create_table(stmts)
    end

    def self.extract_file(path : String) : TableSchema?
      extract(File.read(path))
    end

    # Extract all migration files from a directory, sorted by filename
    def self.extract_all(dir : String) : Array(TableSchema)
      schemas = [] of TableSchema
      files = Dir.glob(File.join(dir, "*.rb")).sort
      files.each do |file|
        schema = extract_file(file)
        schemas << schema if schema
      end
      schemas
    end

    private def self.find_create_table(node : Prism::Node) : TableSchema?
      if node.is_a?(Prism::CallNode) && node.name == "create_table"
        return parse_create_table(node)
      end

      node.children.each do |child|
        result = find_create_table(child)
        return result if result
      end
      nil
    end

    private def self.parse_create_table(call : Prism::CallNode) : TableSchema?
      # First arg is the table name (symbol)
      args = call.arg_nodes
      return nil if args.empty?

      table_name = case arg = args[0]
                   when Prism::SymbolNode then arg.value
                   when Prism::StringNode then arg.value
                   else return nil
                   end

      columns = [] of Column

      # The block contains column definitions
      block = call.block
      return TableSchema.new(table_name, columns) unless block.is_a?(Prism::BlockNode)

      body = block.body
      return TableSchema.new(table_name, columns) unless body.is_a?(Prism::StatementsNode)

      body.body.each do |stmt|
        next unless stmt.is_a?(Prism::CallNode)
        col = parse_column(stmt)
        if col
          columns.concat(col)
        end
      end

      TableSchema.new(table_name, columns)
    end

    private def self.parse_column(call : Prism::CallNode) : Array(Column)?
      method = call.name
      args = call.arg_nodes

      case method
      when "timestamps"
        # t.timestamps generates created_at and updated_at
        return [
          Column.new("created_at", "datetime"),
          Column.new("updated_at", "datetime"),
        ]
      when "references"
        # t.references :article → article_id integer column
        return nil if args.empty?
        ref_name = extract_symbol_or_string(args[0])
        return nil unless ref_name
        return [Column.new("#{ref_name}_id", "integer")]
      when "string", "text", "integer", "float", "boolean", "datetime",
           "date", "time", "binary", "decimal", "json", "jsonb", "uuid"
        return nil if args.empty?
        col_name = extract_symbol_or_string(args[0])
        return nil unless col_name

        options = extract_options(args)
        return [Column.new(col_name, method, options)]
      end

      nil
    end

    private def self.extract_symbol_or_string(node : Prism::Node) : String?
      case node
      when Prism::SymbolNode then node.value
      when Prism::StringNode then node.value
      else nil
      end
    end

    private def self.extract_options(args : Array(Prism::Node)) : Hash(String, String)
      options = {} of String => String
      args.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)
        arg.elements.each do |el|
          next unless el.is_a?(Prism::AssocNode)
          key = extract_symbol_or_string(el.key)
          next unless key
          val = case v = el.value_node
                when Prism::TrueNode  then "true"
                when Prism::FalseNode then "false"
                when Prism::NilNode   then "nil"
                when Prism::SymbolNode then v.value
                when Prism::StringNode then v.value
                when Prism::IntegerNode then v.value.to_s
                else "?"
                end
          options[key] = val
        end
      end
      options
    end

    # Map Rails column types to Crystal types
    def self.crystal_type(rail_type : String, nullable : Bool = false) : String
      base = case rail_type
             when "string", "text"     then "String"
             when "integer", "references" then "Int64"
             when "float", "decimal"   then "Float64"
             when "boolean"            then "Bool"
             when "datetime", "date", "time" then "Time"
             when "json", "jsonb"      then "String" # JSON stored as string for now
             when "uuid"               then "String"
             when "binary"             then "Bytes"
             else "String"
             end
      nullable ? "#{base}?" : base
    end
  end
end
