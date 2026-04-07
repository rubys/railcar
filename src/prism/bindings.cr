# FFI bindings to libprism — minimal surface for pm_serialize_parse
#
# We use the serialization API rather than walking C structs directly.
# This is the same approach used by Prism's Ruby, JavaScript, Java,
# and Rust bindings.

@[Link(ldflags: "-L/opt/homebrew/lib/ruby/gems/4.0.0/gems/prism-1.9.0/build -lprism")]
lib LibPrism
  struct PmBuffer
    length : LibC::SizeT
    capacity : LibC::SizeT
    value : UInt8*
  end

  fun pm_serialize_parse(buffer : PmBuffer*, source : UInt8*, size : LibC::SizeT, data : UInt8*) : Void
  fun pm_buffer_free(buffer : PmBuffer*) : Void
  fun pm_buffer_init(buffer : PmBuffer*) : Bool
  fun pm_version : UInt8*
  fun pm_parser_init(parser : Void*, source : UInt8*, size : LibC::SizeT, options : Void*) : Void
  fun pm_parse(parser : Void*) : Void*
  fun pm_prettyprint(buffer : PmBuffer*, parser : Void*, node : Void*) : Void
  fun pm_parser_free(parser : Void*) : Void
  fun pm_buffer_sizeof : LibC::SizeT
  fun pm_parser_sizeof : LibC::SizeT
end

module Prism
  def self.version : String
    String.new(LibPrism.pm_version)
  end

  # Parse Ruby source and return the serialized binary representation.
  # The caller is responsible for deserializing (see Prism::Deserializer).
  def self.serialize_parse(source : String) : Bytes
    buffer = LibPrism::PmBuffer.new
    buffer.value = Pointer(UInt8).null
    buffer.length = 0
    buffer.capacity = 0
    LibPrism.pm_serialize_parse(pointerof(buffer), source.to_unsafe, source.bytesize.to_u64, Pointer(UInt8).null)
    len = buffer.length
    bytes = Bytes.new(len)
    bytes.copy_from(buffer.value, len) if len > 0
    LibPrism.pm_buffer_free(pointerof(buffer))
    bytes
  end
end
