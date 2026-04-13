# Crystal source for the Python runtime base classes.
#
# This file serves two purposes:
#   1. program.semantic() types it (so models inheriting from it get type info)
#   2. cr2py emits it as working Python (the ORM base for every app)
#
# Written in Crystal style that translates cleanly to Python.
# No macros, no Crystal-specific patterns.

module Railcar
  class ValidationErrors
    @errors : Hash(String, Array(String))

    def initialize
      @errors = {} of String => Array(String)
    end

    def add(field : String, message : String)
      @errors[field] ||= [] of String
      @errors[field] << message
    end

    def any? : Bool
      !@errors.empty?
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
      @errors[field]? || [] of String
    end

    def clear
      @errors.clear
    end
  end

  class ApplicationRecord
    @@db : Nil = nil

    def self.db
      @@db
    end

    def self.db=(v)
      @@db = v
    end

    getter attributes : Hash(String, DB::Any)
    getter? persisted : Bool
    getter errors : ValidationErrors

    def initialize(@attributes = {} of String => DB::Any, @persisted = false)
      @errors = ValidationErrors.new
    end

    def id : Int64?
      attributes["id"]?.try(&.as(Int64))
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
      return false if errors.any?
      if persisted?
        do_update
      else
        do_insert
      end
      !errors.any?
    end

    def destroy : Bool
      return false unless persisted?
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

    def self.table_name : String
      ""
    end

    def self.find(id : Int64) : self
      row = db!.query_one?("SELECT * FROM #{table_name} WHERE id = ?", id) do |rs|
        row_to_hash(rs)
      end
      raise "#{name} not found: #{id}" unless row
      new(row, persisted: true)
    end

    def self.count : Int64
      db!.scalar("SELECT COUNT(*) FROM #{table_name}").as(Int64)
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

      unless attributes.has_key?("created_at")
        cols << "created_at"
        vals << now
      end
      unless attributes.has_key?("updated_at")
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

    private def self.row_to_hash(rs) : Hash(String, DB::Any)
      hash = {} of String => DB::Any
      rs.column_count.times do |i|
        hash[rs.column_name(i)] = rs.read(DB::Any)
      end
      hash
    end
  end
end
