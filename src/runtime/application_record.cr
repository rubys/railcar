require "db"
require "sqlite3"
require "log"
require "./errors"
require "./turbo_broadcast"
require "./broadcasts"

module Ruby2CR
  Log = ::Log.for("sql")

  def self.log_sql(sql : String, params = nil)
    if params
      Log.debug { "  #{sql}  #{params}" }
    else
      Log.debug { "  #{sql}" }
    end
  end
  # Validation error with per-field messages
  class ValidationError < Exception
    getter errors : Errors

    def initialize(@errors)
      messages = [] of String
      errors.data.each { |k, v| messages << "#{k} #{v.join(", ")}" }
      super("Validation failed: #{messages.join(", ")}")
    end
  end

  # Record not found
  class RecordNotFound < Exception
  end

  # Base class for all models. Provides CRUD, validations, associations,
  # and query building. Mirrors the subset of ActiveRecord used by the
  # blog demo.
  abstract class ApplicationRecord
    include Broadcasts

    # Class-level database connection
    class_property db : DB::Database?

    # Instance state
    getter attributes : Hash(String, DB::Any)
    getter? persisted : Bool = false
    getter? destroyed : Bool = false
    property errors : Errors = Errors.new

    def initialize(@attributes = {} of String => DB::Any, @persisted = false)
    end

    def id : Int64?
      attributes["id"]?.try &.as(Int64)
    end

    def new_record? : Bool
      !persisted?
    end

    # ----- Class methods implemented via macros in subclasses -----

    # Subclasses use the `model` macro which generates:
    #   - table_name
    #   - column accessors (typed getters/setters)
    #   - .create, .find, .all, .where, .order, .first, .last, .count
    #   - .includes (eager loading)
    #   - validation runners
    #   - association loaders

    macro model(table, &block)
      COLUMNS = {} of String => String
      VALIDATIONS = [] of Proc(self, Nil)
      HAS_MANY = {} of String => NamedTuple(model: String, foreign_key: String, dependent: Symbol?)
      BELONGS_TO = {} of String => NamedTuple(model: String, foreign_key: String)

      {{block.body}}

      def self.table_name : String
        {{table}}
      end

      def self.db! : DB::Database
        @@db || raise "Database not connected. Call #{self}.db = DB.open(...)"
      end

      # ----- Finders -----

      def self.find(id : Int64) : self
        Ruby2CR.log_sql("SELECT * FROM #{table_name} WHERE id = ?", [id])
        row = db!.query_one?(
          "SELECT * FROM #{table_name} WHERE id = ?", id
        ) { |rs| row_to_hash(rs) }
        raise RecordNotFound.new("#{name} with id=#{id} not found") unless row
        new(row, persisted: true)
      end

      def self.find_by(**conditions) : self?
        rel = where(**conditions).limit(1)
        rel.to_a.first?
      end

      def self.all : Relation(self)
        Relation(self).new
      end

      def self.where(**conditions) : Relation(self)
        Relation(self).new.where(**conditions)
      end

      def self.where(sql : String, *params) : Relation(self)
        Relation(self).new.where(sql, *params)
      end

      def self.order(clause : String) : Relation(self)
        Relation(self).new.order(clause)
      end

      def self.order(**columns) : Relation(self)
        Relation(self).new.order(**columns)
      end

      def self.limit(n : Int32) : Relation(self)
        Relation(self).new.limit(n)
      end

      def self.includes(*names : Symbol) : Relation(self)
        Relation(self).new.includes(*names)
      end

      def self.first : self?
        all.order("id ASC").limit(1).to_a.first?
      end

      def self.last : self?
        all.order("id DESC").limit(1).to_a.first?
      end

      def self.count : Int64
        Ruby2CR.log_sql("SELECT COUNT(*) FROM #{table_name}")
        db!.scalar("SELECT COUNT(*) FROM #{table_name}").as(Int64)
      end

      def self.exists?(id : Int64) : Bool
        db!.scalar("SELECT COUNT(*) FROM #{table_name} WHERE id = ?", id).as(Int64) > 0
      end

      def self.destroy_all
        db!.exec("DELETE FROM #{table_name}")
      end

      # ----- Row mapping -----

      def self.row_to_hash(rs : DB::ResultSet) : Hash(String, DB::Any)
        hash = {} of String => DB::Any
        rs.column_count.times do |i|
          col = rs.column_name(i)
          hash[col] = rs.read(DB::Any)
        end
        hash
      end

      def self.from_rows(rs : DB::ResultSet) : Array(self)
        results = [] of self
        rs.each do
          results << new(row_to_hash(rs), persisted: true)
        end
        results
      end

      # ----- Create -----

      def self.create(attrs : Hash(String, DB::Any)) : self
        record = new(attrs)
        record.save
        record
      end

      def self.create(**attrs) : self
        hash = {} of String => DB::Any
        attrs.each { |k, v| hash[k.to_s] = v.as(DB::Any) }
        create(hash)
      end

      def self.create!(attrs : Hash(String, DB::Any)) : self
        record = create(attrs)
        raise ValidationError.new(record.errors) unless record.persisted?
        record
      end

      def self.create!(**attrs) : self
        hash = {} of String => DB::Any
        attrs.each { |k, v| hash[k.to_s] = v.as(DB::Any) }
        create!(hash)
      end

    end

    macro finished
      def run_after_save_callbacks
        {% for method in @type.methods %}
          {% if method.name.starts_with?("_after_save_") %}
            {{method.name}}
          {% end %}
        {% end %}
      end

      def run_after_destroy_callbacks
        {% for method in @type.methods %}
          {% if method.name.starts_with?("_after_destroy_") %}
            {{method.name}}
          {% end %}
        {% end %}
      end
    end

    # ----- Column macro -----

    macro column(name, type, **options)
      {% COLUMNS[name.id.stringify] = type.stringify %}

      def {{name.id}} : {{type}}
        {% if type.stringify == "String" %}
          (attributes[{{name.id.stringify}}]? || {{options[:default]}} || "").to_s
        {% elsif type.stringify == "Int64" %}
          val = attributes[{{name.id.stringify}}]?
          val ? val.as(Int64) : {{options[:default] || 0_i64}}
        {% elsif type.stringify == "Float64" %}
          val = attributes[{{name.id.stringify}}]?
          val ? val.as(Float64) : {{options[:default] || 0.0}}
        {% elsif type.stringify == "Bool" %}
          val = attributes[{{name.id.stringify}}]?
          val ? (val == 1_i64 || val == true) : {{options[:default] || false}}
        {% elsif type.stringify == "Time" %}
          val = attributes[{{name.id.stringify}}]?
          case val
          when Time then val
          when String then Time.parse_utc(val, val.includes?('.') ? "%F %T.%6N" : "%F %T")
          else Time.utc
          end
        {% elsif type.stringify == "Time?" %}
          val = attributes[{{name.id.stringify}}]?
          case val
          when Time then val
          when String then Time.parse_utc(val, val.includes?('.') ? "%F %T.%6N" : "%F %T")
          else nil
          end
        {% else %}
          attributes[{{name.id.stringify}}]?.as({{type}})
        {% end %}
      end

      def {{name.id}}=(value : {{type}})
        attributes[{{name.id.stringify}}] = value.as(DB::Any)
      end
    end

    # ----- Validation macros -----

    macro validates(field, **options)
      {% if options[:presence] %}
        {% VALIDATIONS << "proc_presence_#{field.id}".id %}
        def self.validate_presence_{{field.id}}(record : self)
          val = record.attributes[{{field.id.stringify}}]?
          if val.nil? || (val.is_a?(String) && val.empty?)
            
            record.errors.add({{field.id.stringify}}, "can't be blank")
          end
        end
      {% end %}

      {% if options[:length] %}
        {% VALIDATIONS << "proc_length_#{field.id}".id %}
        def self.validate_length_{{field.id}}(record : self)
          val = record.attributes[{{field.id.stringify}}]?
          if val.is_a?(String)
            {% if options[:length][:minimum] %}
              if val.size < {{options[:length][:minimum]}}
                
                record.errors.add({{field.id.stringify}}, "is too short (minimum is {{options[:length][:minimum]}} characters)")
              end
            {% end %}
          end
        end
      {% end %}
    end

    # ----- Association macros -----

    macro has_many(name, model, foreign_key = nil, dependent = nil)
      {% fk = foreign_key || ((@type.name.split("::").last.underscore + "_id").id) %}
      {% HAS_MANY[name.id.stringify] = {model: model.stringify, foreign_key: fk.id.stringify, dependent: dependent} %}

      def {{name.id}} : CollectionProxy({{model}})
        CollectionProxy({{model}}).new(self, {{fk.id.stringify}})
      end
    end

    # ----- Callback macros -----

    macro after_save(&block)
      def _after_save_{{block.body.stringify.size}}
        {{block.body}}
      end
    end

    macro after_destroy(&block)
      def _after_destroy_{{block.body.stringify.size}}
        {{block.body}}
      end
    end

    macro belongs_to(name, model, foreign_key = nil)
      {% fk = foreign_key || (name.id.stringify + "_id") %}
      {% BELONGS_TO[name.id.stringify] = {model: model.stringify, foreign_key: fk} %}

      # Implicit belongs_to presence validation (Rails 5+ behavior)
      {% VALIDATIONS << "proc_belongs_to_#{name.id}".id %}
      def self.validate_belongs_to_{{name.id}}(record : self)
        fk_val = record.attributes[{{fk}}]?
        if fk_val.nil?
          
          record.errors.add({{name.id.stringify}}, "must exist")
        end
      end

      def {{name.id}} : {{model}}
        fk_val = attributes[{{fk}}]?
        raise RecordNotFound.new("No #{{{name.id.stringify}}} foreign key set") unless fk_val
        {{model}}.find(fk_val.as(Int64))
      end

      def {{name.id}}=(record : {{model}})
        attributes[{{fk}}] = record.id.as(DB::Any)
      end

      def {{(name.id.stringify + "_id").id}} : Int64?
        attributes[{{fk}}]?.try &.as(Int64)
      end

      def {{(name.id.stringify + "_id").id}}=(value : Int64)
        attributes[{{fk}}] = value.as(DB::Any)
      end
    end

    # ----- Instance methods -----

    def valid? : Bool
      @errors = Errors.new
      run_validations
      errors.empty?
    end

    def save : Bool
      return false unless valid?

      if persisted?
        do_update
      else
        do_insert
      end
      # do_insert may have added errors (e.g., FK constraint failure)
      if errors.empty?
        run_after_save_callbacks
        true
      else
        false
      end
    end

    # Callback runners are generated at end of model() macro
    # using the AFTER_SAVE_METHODS/AFTER_DESTROY_METHODS arrays

    def save! : Bool
      raise ValidationError.new(errors) unless save
      true
    end

    def update(attrs : Hash(String, DB::Any)) : Bool
      attrs.each { |k, v| attributes[k] = v }
      save
    end

    def update(**attrs) : Bool
      attrs.each { |k, v| attributes[k.to_s] = v.as(DB::Any) }
      save
    end

    def destroy : Bool
      return false unless persisted?
      self.class.db!.exec("DELETE FROM #{self.class.table_name} WHERE id = ?", id)
      @destroyed = true
      @persisted = false
      run_after_destroy_callbacks
      true
    end

    def destroy! : Bool
      raise "Failed to destroy" unless destroy
      true
    end

    def reload : self
      raise "Can't reload a new record" unless persisted? && id
      fresh = self.class.find(id.not_nil!)
      @attributes = fresh.attributes
      self
    end

    # Subclasses override via macro-generated code
    private def run_validations
    end

    def run_after_save_callbacks
    end

    def run_after_destroy_callbacks
    end


    private def do_insert
      cols = attributes.keys.reject { |k| k == "id" }
      vals = cols.map { |c| attributes[c] }
      placeholders = cols.map { "?" }.join(", ")
      col_names = cols.map { |c| "\"#{c}\"" }.join(", ")

      now = Time.utc.to_s("%F %T.%6N")
      if !attributes.has_key?("created_at")
        cols << "created_at"
        vals << now.as(DB::Any)
        col_names += ", \"created_at\""
        placeholders += ", ?"
      end
      if !attributes.has_key?("updated_at")
        cols << "updated_at"
        vals << now.as(DB::Any)
        col_names += ", \"updated_at\""
        placeholders += ", ?"
      end

      begin
        self.class.db!.exec(
          "INSERT INTO #{self.class.table_name} (#{col_names}) VALUES (#{placeholders})",
          args: vals
        )
      rescue ex : SQLite3::Exception
        if ex.message.try(&.includes?("FOREIGN KEY constraint failed"))
          @errors.add("base", "Foreign key constraint failed")
          @persisted = false
          return
        end
        raise ex
      end

      # Get the last inserted ID
      result = self.class.db!.scalar("SELECT last_insert_rowid()").as(Int64)
      attributes["id"] = result.as(DB::Any)
      attributes["created_at"] = now.as(DB::Any) unless attributes.has_key?("created_at")
      attributes["updated_at"] = now.as(DB::Any) unless attributes.has_key?("updated_at")
      @persisted = true
    end

    private def do_update
      cols = attributes.keys.reject { |k| k == "id" || k == "created_at" }

      now = Time.utc.to_s("%F %T.%6N")
      attributes["updated_at"] = now.as(DB::Any)
      cols << "updated_at" unless cols.includes?("updated_at")

      set_clause = cols.map { |c| "\"#{c}\" = ?" }.join(", ")
      vals = cols.map { |c| attributes[c] }
      vals << id.as(DB::Any)

      self.class.db!.exec(
        "UPDATE #{self.class.table_name} SET #{set_clause} WHERE id = ?",
        args: vals
      )
    end
  end
end
