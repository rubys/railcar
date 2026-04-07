module Ruby2CR
  # Proxy for has_many associations. Wraps a Relation scoped to the
  # owner's foreign key. Mirrors ActiveRecord::Associations::CollectionProxy.
  class CollectionProxy(T)
    @owner : ApplicationRecord
    @foreign_key : String
    @cached_records : Array(T)? = nil

    def initialize(@owner, @foreign_key)
    end

    private def scope : Relation(T)
      T.where(@foreign_key, @owner.id.not_nil!)
    end

    private def scoped_where : Relation(T)
      Relation(T).new.where("\"#{@foreign_key}\" = ?", @owner.id.not_nil!)
    end

    def to_a : Array(T)
      @cached_records ||= scoped_where.to_a
    end

    def reload : self
      @cached_records = nil
      self
    end

    def each(&block : T -> _)
      to_a.each { |r| yield r }
    end

    def map(&block : T -> U) forall U
      to_a.map { |r| yield r }
    end

    def select(&block : T -> Bool) : Array(T)
      to_a.select { |r| yield r }
    end

    def size : Int32
      to_a.size
    end

    def count : Int64
      scoped_where.count
    end

    def empty? : Bool
      size == 0
    end

    def any? : Bool
      size > 0
    end

    def first : T?
      to_a.first?
    end

    def last : T?
      to_a.last?
    end

    def find(id : Int64) : T
      record = scoped_where.where(id: id).to_a.first?
      raise RecordNotFound.new("#{T.name} with id=#{id} not found in association") unless record
      record
    end

    def build(**attrs) : T
      hash = {} of String => DB::Any
      attrs.each { |k, v| hash[k.to_s] = v.as(DB::Any) }
      hash[@foreign_key] = @owner.id.as(DB::Any)
      T.new(hash)
    end

    def create(**attrs) : T
      record = build(**attrs)
      record.save
      @cached_records = nil # invalidate cache
      record
    end

    def create!(**attrs) : T
      record = create(**attrs)
      raise ValidationError.new(record.errors) unless record.persisted?
      record
    end

    def destroy_all
      to_a.each(&.destroy)
      @cached_records = nil
    end

    def where(**conditions) : Relation(T)
      scoped_where.where(**conditions)
    end

    def order(clause : String) : Relation(T)
      scoped_where.order(clause)
    end

    def order(**columns) : Relation(T)
      scoped_where.order(**columns)
    end

    def includes(*names : Symbol) : Relation(T)
      scoped_where.includes(*names)
    end
  end
end
