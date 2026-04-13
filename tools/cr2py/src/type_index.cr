# TypeIndex — a flat lookup table built from Crystal's program.types.
#
# After program.semantic(), walks program.types once and builds
# a simple hash-based index for the emitter to query:
#
#   type_index.instance_vars("CollectionProxy", "@owner") → "ApplicationRecord"
#   type_index.class_vars("ApplicationRecord", "@@db") → "DB::Database"
#   type_index.has_instance_var?("Article", "@attributes") → true
#   type_index.has_class_var?("ApplicationRecord", "@@db") → true

module Cr2Py
  class TypeIndex
    # type_name → {ivar_name → type_string}
    getter instance_vars : Hash(String, Hash(String, String))
    # type_name → {cvar_name → type_string}
    getter class_vars : Hash(String, Hash(String, String))
    # type_name → parent type names
    getter parents : Hash(String, Array(String))

    def initialize
      @instance_vars = {} of String => Hash(String, String)
      @class_vars = {} of String => Hash(String, String)
      @parents = {} of String => Array(String)
    end

    def self.build(program : Crystal::Program) : TypeIndex
      index = new
      index.collect(program.types)
      index
    end

    def collect(types : Hash)
      types.each do |name, type|
        collect_type(type)
        # Recurse into nested types
        begin
          if type.responds_to?(:types)
            collect(type.types)
          end
        rescue
        end
      end
    end

    private def collect_type(type)
      type_name = type.to_s

      # Instance vars (including inherited)
      begin
        ivars = {} of String => String
        type.all_instance_vars.each do |ivar_name, ivar|
          ivars[ivar_name] = ivar.type.to_s
        end
        @instance_vars[type_name] = ivars unless ivars.empty?
      rescue
      end

      # Class vars
      begin
        cvars = {} of String => String
        type.class_vars.each do |cvar_name, cvar|
          cvars[cvar_name] = cvar.type.to_s
        end
        @class_vars[type_name] = cvars unless cvars.empty?
      rescue
      end

      # Parents
      begin
        if type.responds_to?(:parents)
          parent_names = type.parents.try(&.map(&.to_s)) || [] of String
          @parents[type_name] = parent_names unless parent_names.empty?
        end
      rescue
      end
    end

    # Query: does this type have an instance var with this name?
    def has_instance_var?(type_name : String, ivar_name : String) : Bool
      if ivars = @instance_vars[type_name]?
        return true if ivars.has_key?(ivar_name)
      end
      # Check parent types
      if parent_names = @parents[type_name]?
        parent_names.each do |parent|
          return true if has_instance_var?(parent, ivar_name)
        end
      end
      false
    end

    # Query: does this type have a class var with this name?
    def has_class_var?(type_name : String, cvar_name : String) : Bool
      if cvars = @class_vars[type_name]?
        return true if cvars.has_key?(cvar_name)
      end
      if parent_names = @parents[type_name]?
        parent_names.each do |parent|
          return true if has_class_var?(parent, cvar_name)
        end
      end
      false
    end

    # Query: what type is this instance var?
    def ivar_type(type_name : String, ivar_name : String) : String?
      if ivars = @instance_vars[type_name]?
        if t = ivars[ivar_name]?
          return t
        end
      end
      if parent_names = @parents[type_name]?
        parent_names.each do |parent|
          if t = ivar_type(parent, ivar_name)
            return t
          end
        end
      end
      nil
    end

    # Query: what type is this class var?
    def cvar_type(type_name : String, cvar_name : String) : String?
      if cvars = @class_vars[type_name]?
        if t = cvars[cvar_name]?
          return t
        end
      end
      if parent_names = @parents[type_name]?
        parent_names.each do |parent|
          if t = cvar_type(parent, cvar_name)
            return t
          end
        end
      end
      nil
    end

    # Query: is this type a Hash?
    def is_hash_type?(type_str : String) : Bool
      type_str.starts_with?("Hash")
    end
  end
end
