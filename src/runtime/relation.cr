module Ruby2CR
  # Chainable query builder, mirrors ActiveRecord::Relation.
  # Each method returns a new Relation (immutable chaining).
  class Relation(T)
    getter conditions : Array(String) = [] of String
    getter params : Array(DB::Any) = [] of DB::Any
    getter order_clause : String? = nil
    getter limit_value : Int32? = nil
    getter offset_value : Int32? = nil
    getter include_names : Array(Symbol) = [] of Symbol

    def initialize
    end

    # Deep copy for immutable chaining
    private def clone : self
      rel = Relation(T).new
      rel.conditions.concat(@conditions)
      rel.params.concat(@params)
      rel.order_clause = @order_clause
      rel.limit_value = @limit_value
      rel.offset_value = @offset_value
      rel.include_names.concat(@include_names)
      rel
    end

    protected setter order_clause
    protected setter limit_value
    protected setter offset_value

    def where(**conditions) : self
      rel = clone
      conditions.each do |key, value|
        rel.conditions << "\"#{key}\" = ?"
        rel.params << value.as(DB::Any)
      end
      rel
    end

    def where(sql : String, *bind_params) : self
      rel = clone
      rel.conditions << sql
      bind_params.each { |p| rel.params << p.as(DB::Any) }
      rel
    end

    def order(clause : String) : self
      rel = clone
      rel.order_clause = clause
      rel
    end

    def order(**columns) : self
      rel = clone
      parts = columns.map { |k, v| "\"#{k}\" #{v}" }
      rel.order_clause = parts.join(", ")
      rel
    end

    def limit(n : Int32) : self
      rel = clone
      rel.limit_value = n
      rel
    end

    def offset(n : Int32) : self
      rel = clone
      rel.offset_value = n
      rel
    end

    def includes(*names : Symbol) : self
      rel = clone
      names.each { |n| rel.include_names << n }
      rel
    end

    def first : T?
      order("id ASC").limit(1).to_a.first?
    end

    def last : T?
      order("id DESC").limit(1).to_a.first?
    end

    def count : Int64
      sql = "SELECT COUNT(*) FROM #{T.table_name}"
      sql += " WHERE #{conditions.join(" AND ")}" unless conditions.empty?
      T.db!.scalar(sql, args: params).as(Int64)
    end

    def exists? : Bool
      count > 0
    end

    def any? : Bool
      exists?
    end

    def empty? : Bool
      !exists?
    end

    def to_a : Array(T)
      sql = "SELECT * FROM #{T.table_name}"
      sql += " WHERE #{conditions.join(" AND ")}" unless conditions.empty?
      sql += " ORDER BY #{order_clause}" if order_clause
      sql += " LIMIT #{limit_value}" if limit_value
      sql += " OFFSET #{offset_value}" if offset_value

      results = T.db!.query(sql, args: params) { |rs| T.from_rows(rs) }

      # Eager load associations
      load_includes(results) unless include_names.empty?

      results
    end

    def each(&block : T -> _)
      to_a.each { |record| yield record }
    end

    def map(&block : T -> U) forall U
      to_a.map { |record| yield record }
    end

    def size : Int64
      count
    end

    # Subclasses/models implement eager loading by overriding this
    private def load_includes(records : Array(T))
      # Default: no-op. Models with associations override via macro.
    end
  end
end
