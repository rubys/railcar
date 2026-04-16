# Filter: Table-driven Ruby-to-native method mapping.
#
# Maps Ruby method calls to target-language equivalents at the AST level,
# following the same approach as Ruby2JS's functions filter. Methods are
# mapped to native types (String, Array, Hash) rather than runtime wrappers,
# minimizing impedance mismatch with the target ecosystem.
#
# Usage:
#   ast = ast.transform(MethodMapper.new(:go))
#   ast = ast.transform(MethodMapper.new(:rust))
#
# The mapper rewrites Crystal::Call nodes whose method name appears in
# the target's mapping table. Each entry specifies how to rewrite the call.

require "compiler/crystal/syntax"

module Railcar
  # Method mapping entry: describes how to rewrite a Ruby method call
  record MethodMapping,
    # The target method/expression pattern
    # Simple patterns: ".to_lowercase()" ".len()" ".is_empty()"
    # With receiver transform: "len(RECV)" "strings.ToLower(RECV)"
    # Special markers: RECV = receiver, ARG0 = first arg, BLOCK = block body
    target : String,
    # Whether this is a property access (no parens) vs method call
    property : Bool = false

  # Tables of Ruby method → target method for each language
  METHODS = {
    # ── Go ──
    :go => {
      # String methods
      {"String", "downcase"}    => MethodMapping.new("strings.ToLower(RECV)"),
      {"String", "upcase"}      => MethodMapping.new("strings.ToUpper(RECV)"),
      {"String", "strip"}       => MethodMapping.new("strings.TrimSpace(RECV)"),
      {"String", "lstrip"}      => MethodMapping.new("strings.TrimLeft(RECV, \" \\t\\n\")"),
      {"String", "rstrip"}      => MethodMapping.new("strings.TrimRight(RECV, \" \\t\\n\")"),
      {"String", "include?"}    => MethodMapping.new("strings.Contains(RECV, ARG0)"),
      {"String", "start_with?"} => MethodMapping.new("strings.HasPrefix(RECV, ARG0)"),
      {"String", "end_with?"}   => MethodMapping.new("strings.HasSuffix(RECV, ARG0)"),
      {"String", "gsub"}        => MethodMapping.new("strings.ReplaceAll(RECV, ARG0, ARG1)"),
      {"String", "sub"}         => MethodMapping.new("strings.Replace(RECV, ARG0, ARG1, 1)"),
      {"String", "split"}       => MethodMapping.new("strings.Split(RECV, ARG0)"),
      {"String", "to_i"}        => MethodMapping.new("strconv.Atoi(RECV)"),
      {"String", "to_f"}        => MethodMapping.new("strconv.ParseFloat(RECV, 64)"),
      {"String", "empty?"}      => MethodMapping.new("RECV == \"\""),

      # Numeric methods
      {"Numeric", "to_s"}  => MethodMapping.new("fmt.Sprintf(\"%v\", RECV)"),
      {"Numeric", "to_f"}  => MethodMapping.new("float64(RECV)"),
      {"Numeric", "abs"}   => MethodMapping.new("math.Abs(float64(RECV))"),
      {"Numeric", "zero?"} => MethodMapping.new("RECV == 0"),

      # Array/Slice methods
      {"Array", "size"}      => MethodMapping.new("len(RECV)"),
      {"Array", "length"}    => MethodMapping.new("len(RECV)"),
      {"Array", "count"}     => MethodMapping.new("len(RECV)"),
      {"Array", "empty?"}    => MethodMapping.new("len(RECV) == 0"),
      {"Array", "any?"}      => MethodMapping.new("len(RECV) > 0"),
      {"Array", "first"}     => MethodMapping.new("RECV[0]"),
      {"Array", "last"}      => MethodMapping.new("RECV[len(RECV)-1]"),
      {"Array", "join"}      => MethodMapping.new("strings.Join(RECV, ARG0)"),
      {"Array", "include?"}  => MethodMapping.new("slices.Contains(RECV, ARG0)"),
      {"Array", "flatten"}   => MethodMapping.new("slices.Concat(RECV...)"),
      {"Array", "compact"}   => MethodMapping.new("RECV"), # Go slices don't have nil elements

      # Hash/Map methods
      {"Hash", "keys"}       => MethodMapping.new("maps.Keys(RECV)"),
      {"Hash", "values"}     => MethodMapping.new("maps.Values(RECV)"),
      {"Hash", "has_key?"}   => MethodMapping.new("_, ok := RECV[ARG0]; ok"),
      {"Hash", "merge"}      => MethodMapping.new("maps.Clone(RECV)"), # simplified

      # General
      {"Any", "nil?"}    => MethodMapping.new("RECV == nil"),
      {"Any", "to_s"}    => MethodMapping.new("fmt.Sprintf(\"%v\", RECV)"),
      {"Any", "size"}    => MethodMapping.new("len(RECV)"),
      {"Any", "length"}  => MethodMapping.new("len(RECV)"),
      {"Any", "count"}   => MethodMapping.new("len(RECV)"),
      {"Any", "empty?"}  => MethodMapping.new("len(RECV) == 0"),
      {"Any", "any?"}    => MethodMapping.new("len(RECV) > 0"),
      {"Any", "freeze"}  => MethodMapping.new("RECV"), # no-op in Go
    },

    # ── Rust ──
    :rust => {
      # String methods
      {"String", "downcase"}    => MethodMapping.new(".to_lowercase()"),
      {"String", "upcase"}      => MethodMapping.new(".to_uppercase()"),
      {"String", "strip"}       => MethodMapping.new(".trim().to_string()"),
      {"String", "lstrip"}      => MethodMapping.new(".trim_start().to_string()"),
      {"String", "rstrip"}      => MethodMapping.new(".trim_end().to_string()"),
      {"String", "include?"}    => MethodMapping.new(".contains(ARG0)"),
      {"String", "start_with?"} => MethodMapping.new(".starts_with(ARG0)"),
      {"String", "end_with?"}   => MethodMapping.new(".ends_with(ARG0)"),
      {"String", "gsub"}        => MethodMapping.new(".replace(ARG0, ARG1)"),
      {"String", "sub"}         => MethodMapping.new(".replacen(ARG0, ARG1, 1)"),
      {"String", "split"}       => MethodMapping.new(".split(ARG0).collect::<Vec<_>>()"),
      {"String", "to_i"}        => MethodMapping.new(".parse::<i64>().unwrap_or(0)"),
      {"String", "to_f"}        => MethodMapping.new(".parse::<f64>().unwrap_or(0.0)"),
      {"String", "empty?"}      => MethodMapping.new(".is_empty()"),
      {"String", "chars"}       => MethodMapping.new(".chars().collect::<Vec<_>>()"),

      # Numeric methods
      {"Numeric", "to_s"}  => MethodMapping.new(".to_string()"),
      {"Numeric", "to_f"}  => MethodMapping.new(" as f64"),
      {"Numeric", "abs"}   => MethodMapping.new(".abs()"),
      {"Numeric", "zero?"} => MethodMapping.new(" == 0"),

      # Array/Vec methods
      {"Array", "size"}      => MethodMapping.new(".len()"),
      {"Array", "length"}    => MethodMapping.new(".len()"),
      {"Array", "count"}     => MethodMapping.new(".len()"),
      {"Array", "empty?"}    => MethodMapping.new(".is_empty()"),
      {"Array", "any?"}      => MethodMapping.new("!RECV.is_empty()"),
      {"Array", "first"}     => MethodMapping.new(".first()"),
      {"Array", "last"}      => MethodMapping.new(".last()"),
      {"Array", "join"}      => MethodMapping.new(".join(ARG0)"),
      {"Array", "include?"}  => MethodMapping.new(".contains(ARG0)"),
      {"Array", "flatten"}   => MethodMapping.new(".into_iter().flatten().collect::<Vec<_>>()"),
      {"Array", "compact"}   => MethodMapping.new(".into_iter().flatten().collect::<Vec<_>>()"),
      {"Array", "reverse"}   => MethodMapping.new(".iter().rev().cloned().collect::<Vec<_>>()"),

      # Hash/HashMap methods
      {"Hash", "keys"}     => MethodMapping.new(".keys().collect::<Vec<_>>()"),
      {"Hash", "values"}   => MethodMapping.new(".values().collect::<Vec<_>>()"),
      {"Hash", "has_key?"} => MethodMapping.new(".contains_key(ARG0)"),
      {"Hash", "merge"}    => MethodMapping.new(".clone()"), # simplified

      # General
      {"Any", "nil?"}    => MethodMapping.new("RECV.is_none()"), # Option types
      {"Any", "to_s"}    => MethodMapping.new(".to_string()"),
      {"Any", "size"}    => MethodMapping.new(".len()"),
      {"Any", "length"}  => MethodMapping.new(".len()"),
      {"Any", "count"}   => MethodMapping.new(".len()"),
      {"Any", "empty?"}  => MethodMapping.new(".is_empty()"),
      {"Any", "any?"}    => MethodMapping.new("!RECV.is_empty()"),
      {"Any", "freeze"}  => MethodMapping.new("RECV"), # no-op
    },

    # ── Python ──
    :python => {
      {"String", "downcase"}    => MethodMapping.new(".lower()"),
      {"String", "upcase"}      => MethodMapping.new(".upper()"),
      {"String", "strip"}       => MethodMapping.new(".strip()"),
      {"String", "include?"}    => MethodMapping.new("ARG0 in RECV"),
      {"String", "start_with?"} => MethodMapping.new(".startswith(ARG0)"),
      {"String", "end_with?"}   => MethodMapping.new(".endswith(ARG0)"),
      {"String", "gsub"}        => MethodMapping.new(".replace(ARG0, ARG1)"),
      {"String", "split"}       => MethodMapping.new(".split(ARG0)"),
      {"String", "to_i"}        => MethodMapping.new("int(RECV)"),
      {"String", "to_f"}        => MethodMapping.new("float(RECV)"),
      {"String", "empty?"}      => MethodMapping.new("len(RECV) == 0"),

      {"Array", "size"}      => MethodMapping.new("len(RECV)"),
      {"Array", "length"}    => MethodMapping.new("len(RECV)"),
      {"Array", "empty?"}    => MethodMapping.new("len(RECV) == 0"),
      {"Array", "any?"}      => MethodMapping.new("len(RECV) > 0"),
      {"Array", "first"}     => MethodMapping.new("RECV[0]"),
      {"Array", "last"}      => MethodMapping.new("RECV[-1]"),
      {"Array", "join"}      => MethodMapping.new("ARG0.join(RECV)"),
      {"Array", "include?"}  => MethodMapping.new("ARG0 in RECV"),
      {"Array", "flatten"}   => MethodMapping.new("[x for sub in RECV for x in sub]"),
      {"Array", "compact"}   => MethodMapping.new("[x for x in RECV if x is not None]"),
      {"Array", "reverse"}   => MethodMapping.new("list(reversed(RECV))"),

      {"Hash", "keys"}     => MethodMapping.new("list(RECV.keys())"),
      {"Hash", "values"}   => MethodMapping.new("list(RECV.values())"),
      {"Hash", "has_key?"} => MethodMapping.new("ARG0 in RECV"),
      {"Hash", "merge"}    => MethodMapping.new("{**RECV, **ARG0}"),

      {"Any", "nil?"}   => MethodMapping.new("RECV is None"),
      {"Any", "to_s"}   => MethodMapping.new("str(RECV)"),
      {"Any", "freeze"} => MethodMapping.new("RECV"),
    },

    # ── Elixir ──
    :elixir => {
      {"String", "downcase"}    => MethodMapping.new("String.downcase(RECV)"),
      {"String", "upcase"}      => MethodMapping.new("String.upcase(RECV)"),
      {"String", "strip"}       => MethodMapping.new("String.trim(RECV)"),
      {"String", "include?"}    => MethodMapping.new("String.contains?(RECV, ARG0)"),
      {"String", "start_with?"} => MethodMapping.new("String.starts_with?(RECV, ARG0)"),
      {"String", "end_with?"}   => MethodMapping.new("String.ends_with?(RECV, ARG0)"),
      {"String", "gsub"}        => MethodMapping.new("String.replace(RECV, ARG0, ARG1)"),
      {"String", "split"}       => MethodMapping.new("String.split(RECV, ARG0)"),
      {"String", "to_i"}        => MethodMapping.new("String.to_integer(RECV)"),
      {"String", "empty?"}      => MethodMapping.new("RECV == \"\""),

      {"Array", "size"}      => MethodMapping.new("length(RECV)"),
      {"Array", "length"}    => MethodMapping.new("length(RECV)"),
      {"Array", "empty?"}    => MethodMapping.new("Enum.empty?(RECV)"),
      {"Array", "any?"}      => MethodMapping.new("Enum.any?(RECV)"),
      {"Array", "first"}     => MethodMapping.new("List.first(RECV)"),
      {"Array", "last"}      => MethodMapping.new("List.last(RECV)"),
      {"Array", "join"}      => MethodMapping.new("Enum.join(RECV, ARG0)"),
      {"Array", "include?"}  => MethodMapping.new("Enum.member?(RECV, ARG0)"),
      {"Array", "flatten"}   => MethodMapping.new("List.flatten(RECV)"),
      {"Array", "compact"}   => MethodMapping.new("Enum.reject(RECV, &is_nil/1)"),
      {"Array", "reverse"}   => MethodMapping.new("Enum.reverse(RECV)"),

      {"Hash", "keys"}     => MethodMapping.new("Map.keys(RECV)"),
      {"Hash", "values"}   => MethodMapping.new("Map.values(RECV)"),
      {"Hash", "has_key?"} => MethodMapping.new("Map.has_key?(RECV, ARG0)"),
      {"Hash", "merge"}    => MethodMapping.new("Map.merge(RECV, ARG0)"),

      {"Any", "nil?"}   => MethodMapping.new("is_nil(RECV)"),
      {"Any", "to_s"}   => MethodMapping.new("to_string(RECV)"),
      {"Any", "freeze"} => MethodMapping.new("RECV"),
    },

    # ── TypeScript ──
    :typescript => {
      {"String", "downcase"}    => MethodMapping.new(".toLowerCase()"),
      {"String", "upcase"}      => MethodMapping.new(".toUpperCase()"),
      {"String", "strip"}       => MethodMapping.new(".trim()"),
      {"String", "include?"}    => MethodMapping.new(".includes(ARG0)"),
      {"String", "start_with?"} => MethodMapping.new(".startsWith(ARG0)"),
      {"String", "end_with?"}   => MethodMapping.new(".endsWith(ARG0)"),
      {"String", "gsub"}        => MethodMapping.new(".replaceAll(ARG0, ARG1)"),
      {"String", "sub"}         => MethodMapping.new(".replace(ARG0, ARG1)"),
      {"String", "split"}       => MethodMapping.new(".split(ARG0)"),
      {"String", "to_i"}        => MethodMapping.new("parseInt(RECV)"),
      {"String", "to_f"}        => MethodMapping.new("parseFloat(RECV)"),
      {"String", "empty?"}      => MethodMapping.new("RECV.length === 0"),
      {"String", "chars"}       => MethodMapping.new("Array.from(RECV)"),

      {"Array", "size"}      => MethodMapping.new(".length", property: true),
      {"Array", "length"}    => MethodMapping.new(".length", property: true),
      {"Array", "empty?"}    => MethodMapping.new("RECV.length === 0"),
      {"Array", "any?"}      => MethodMapping.new("RECV.length > 0"),
      {"Array", "first"}     => MethodMapping.new("[0]"),
      {"Array", "last"}      => MethodMapping.new("[RECV.length - 1]"),
      {"Array", "join"}      => MethodMapping.new(".join(ARG0)"),
      {"Array", "include?"}  => MethodMapping.new(".includes(ARG0)"),
      {"Array", "flatten"}   => MethodMapping.new(".flat()"),
      {"Array", "compact"}   => MethodMapping.new(".filter(x => x != null)"),
      {"Array", "reverse"}   => MethodMapping.new(".slice().reverse()"),

      {"Hash", "keys"}     => MethodMapping.new("Object.keys(RECV)"),
      {"Hash", "values"}   => MethodMapping.new("Object.values(RECV)"),
      {"Hash", "has_key?"} => MethodMapping.new("ARG0 in RECV"),
      {"Hash", "merge"}    => MethodMapping.new("Object.assign({}, RECV, ARG0)"),

      {"Any", "nil?"}   => MethodMapping.new("RECV == null"),
      {"Any", "to_s"}   => MethodMapping.new("String(RECV)"),
      {"Any", "freeze"} => MethodMapping.new("Object.freeze(RECV)"),
    },
  }

  # Look up a method mapping for a target language.
  # Checks specific type first, then falls back to "Any".
  def self.lookup_method(target : Symbol, receiver_type : String, method_name : String) : MethodMapping?
    table = METHODS[target]?
    return nil unless table

    # Try specific type first
    table[{receiver_type, method_name}]? ||
      # Fall back to "Any"
      table[{"Any", method_name}]?
  end

  # Apply a mapping's substitution pattern, given the emitted receiver
  # and already-emitted argument strings. RECV, ARG0, ARG1 placeholders
  # are substituted; a leading "." in the pattern is treated as method
  # access on the receiver (prepends the receiver automatically).
  def self.apply_mapping(mapping : MethodMapping, recv : String, args : Array(String)) : String
    result = mapping.target
    result = result.gsub("RECV", recv)
    result = result.gsub("ARG0", args[0]? || "")
    result = result.gsub("ARG1", args[1]? || "")
    if result.starts_with?(".")
      "#{recv}#{result}"
    else
      result
    end
  end
end
