# Rails-compatible Errors collection.
#
# Wraps a Hash(String, Array(String)) and provides Rails-like iteration
# where each yields ErrorEntry objects with full_message.
#
# Usage:
#   article.errors.each { |error| puts error.full_message }
#   article.errors.any?
#   article.errors.size   # total error count
#   article.errors[:title] # => ["can't be blank"]

record Railcar::ErrorEntry, field : String, message : String do
  def full_message : String
    "#{field.capitalize} #{message}"
  end
end

class Railcar::Errors
  getter data : Hash(String, Array(String))

  def initialize
    @data = {} of String => Array(String)
  end

  # Add a single error message to a field
  def add(field : String, message : String)
    @data[field] ||= [] of String
    @data[field] << message
  end

  # Set errors for a field
  def []=(field : String, messages : Array(String))
    @data[field] = messages
  end

  # Get errors for a field
  def [](field : String) : Array(String)
    @data[field]? || [] of String
  end

  def []?(field : String) : Array(String)?
    @data[field]?
  end

  # Iterate — yields ErrorEntry objects (Rails compatible)
  def each(&block : ErrorEntry ->)
    @data.each do |field, messages|
      messages.each do |msg|
        yield ErrorEntry.new(field, msg)
      end
    end
  end

  def any? : Bool
    @data.any? { |_, v| !v.empty? }
  end

  def empty? : Bool
    !any?
  end

  # Total number of errors across all fields
  def size : Int32
    @data.sum { |_, v| v.size }
  end

  def count : Int32
    size
  end

  def clear
    @data.clear
  end

  def has_key?(field : String) : Bool
    @data.has_key?(field)
  end

end
