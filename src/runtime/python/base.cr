# Crystal source for the Python runtime base classes.
#
# This file serves two purposes:
#   1. program.semantic() types it (so models inheriting from it get type info)
#   2. cr2py emits it as working Python (the ORM base for every app)
#
# Written in Crystal style that translates cleanly to Python.
# No macros. Avoids patterns that emit poorly (unless, ||=, double negation).

module Railcar
  MODEL_REGISTRY = {} of String => ApplicationRecord.class

  # Helper modules (included by models for broadcast partials)
  module RouteHelpers
  end

  module ViewHelpers
  end

  module Broadcasts
  end

  class CollectionProxy
    @owner : ApplicationRecord
    @foreign_key : String
    @model_name : String

    def initialize(@owner, @foreign_key, @model_name)
    end

    def model_class
      return MODEL_REGISTRY[@model_name]
    end

    def build(**attrs)
      hash = {} of String => DB::Any
      attrs.each { |k, v| hash[k.to_s] = v }
      hash[@foreign_key] = @owner.id
      return model_class.new(hash)
    end

    def create(**attrs)
      record = build(**attrs)
      record.save
      return record
    end

    def destroy_all
      @owner.class.db!.exec(
        "DELETE FROM #{model_class.table_name} WHERE #{@foreign_key} = ?",
        @owner.id
      )
    end

    def size : Int32
      0
    end
  end

  class ValidationErrors
    @errors : Hash(String, Array(String))

    def initialize
      @errors = {} of String => Array(String)
    end

    def add(field : String, message : String)
      if !@errors.has_key?(field)
        @errors[field] = [] of String
      end
      @errors[field] << message
    end

    def any? : Bool
      @errors.size > 0
    end

    def empty? : Bool
      @errors.size == 0
    end

    def full_messages : Array(String)
      result = [] of String
      @errors.each do |field, messages|
        messages.each do |msg|
          result << "#{field.capitalize} #{msg}"
        end
      end
      result
    end

    def [](field : String) : Array(String)
      if @errors.has_key?(field)
        @errors[field]
      else
        [] of String
      end
    end

    def clear
      @errors.clear
    end
  end

  class ApplicationRecord
    @@db : DB::Database? = nil

    def self.__init_subclass__(**kwargs)
      MODEL_REGISTRY[self.name] = self
    end

    def self.db
      @@db
    end

    def self.db=(v : DB::Database)
      @@db = v
    end

    def self.db! : DB::Database
      @@db.not_nil!
    end

    @attributes : Hash(String, DB::Any)
    @persisted : Bool
    @errors : ValidationErrors

    def initialize(@attributes = {} of String => DB::Any, @persisted = false, **kwargs)
      if kwargs.size > 0
        kwargs.each { |k, v| @attributes[k.to_s] = v }
      end
      @errors = ValidationErrors.new
    end

    def attributes
      @attributes
    end

    def persisted? : Bool
      @persisted
    end

    def errors
      @errors
    end

    def update(attrs : Hash(String, DB::Any)) : Bool
      attrs.each { |k, v| @attributes[k] = v }
      save
    end

    @id : Int64? = nil

    def id : Int64?
      @id
    end

    def new_record? : Bool
      !persisted?
    end

    def valid? : Bool
      @errors = ValidationErrors.new
      run_validations
      !errors.any?
    end

    def save : Bool
      @errors = ValidationErrors.new
      run_validations
      if errors.any?
        return false
      end
      if persisted?
        do_update
      else
        do_insert
      end
      !errors.any?
    end

    def destroy : Bool
      if !persisted?
        return false
      end
      self.class.db!.exec("DELETE FROM #{self.class.table_name} WHERE id = ?", id)
      @persisted = false
      true
    end

    def reload
      fresh = self.class.find(id.not_nil!)
      @attributes = fresh.attributes
      self
    end

    def run_validations
    end

    # Callback stubs — the Python runtime has a real callback system.
    # These exist only so program.semantic() can resolve the calls.
    def self.after_save(&block)
    end

    def self.after_create_commit(&block)
    end

    def self.after_destroy(&block)
    end

    def self.after_destroy_commit(&block)
    end

    def broadcast_replace_to(channel : String, target : String? = nil)
    end

    def broadcast_append_to(channel : String, target : String? = nil)
    end

    def broadcast_prepend_to(channel : String, target : String? = nil)
    end

    def broadcast_remove_to(channel : String, target : String? = nil)
    end

    def self.table_name : String
      ""
    end

    def self.find(id : Int64) : self
      row = db!.query_one("SELECT * FROM #{table_name} WHERE id = ?", id)
      if !row
        raise "#{self.name} not found: #{id}"
      end
      from_row(row)
    end

    def self.all : Array(self)
      rows = db!.query_all("SELECT * FROM #{table_name} ORDER BY id")
      rows.map { |row| from_row(row) }
    end

    def self.count : Int64
      db!.scalar("SELECT COUNT(*) FROM #{table_name}").as(Int64)
    end

    def self.from_row(row) : self
      hash = {} of String => DB::Any
      row.keys.each do |key|
        hash[key] = row[key]
      end
      new(hash, persisted: true)
    end

    def self.create(**attrs) : self
      hash = {} of String => DB::Any
      attrs.each { |k, v| hash[k.to_s] = v }
      record = new(hash)
      record.save
      record
    end

    private def do_insert
      cols = attributes.keys.reject { |k| k == "id" }
      vals = cols.map { |c| attributes[c] }
      now = Time.utc.to_s("%F %T.%6N")

      if !attributes.has_key?("created_at")
        cols << "created_at"
        vals << now
      end
      if !attributes.has_key?("updated_at")
        cols << "updated_at"
        vals << now
      end

      placeholders = cols.map { "?" }.join(", ")
      col_names = cols.join(", ")

      self.class.db!.exec(
        "INSERT INTO #{self.class.table_name} (#{col_names}) VALUES (#{placeholders})",
        args: vals
      )
      result = self.class.db!.scalar("SELECT last_insert_rowid()").as(Int64)
      attributes["id"] = result
      @persisted = true
    end

    private def do_update
      cols = attributes.keys.reject { |k| k == "id" }
      now = Time.utc.to_s("%F %T.%6N")
      attributes["updated_at"] = now

      set_clause = cols.map { |c| "#{c} = ?" }.join(", ")
      vals = cols.map { |c| attributes[c] }
      vals << id

      self.class.db!.exec(
        "UPDATE #{self.class.table_name} SET #{set_clause} WHERE id = ?",
        args: vals
      )
    end
  end
end
