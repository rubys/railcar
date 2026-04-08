# Extracts associations, validations, and other model declarations
# from Rails model files using Prism.

require "../prism/bindings"
require "../prism/deserializer"

module Ruby2CR
  record Association,
    kind : Symbol,          # :has_many, :belongs_to, :has_one
    name : String,          # :comments, :article
    options : Hash(String, String) = {} of String => String

  record Validation,
    field : String,
    kind : String,          # "presence", "length", etc.
    options : Hash(String, String) = {} of String => String

  record ModelInfo,
    name : String,
    superclass : String,
    associations : Array(Association),
    validations : Array(Validation)

  class ModelExtractor
    def self.extract(source : String) : ModelInfo?
      ast = Prism.parse(source)
      stmts = ast.statements
      return nil unless stmts.is_a?(Prism::StatementsNode)

      find_class(stmts)
    end

    def self.extract_file(path : String) : ModelInfo?
      extract(File.read(path))
    end

    private def self.find_class(node : Prism::Node) : ModelInfo?
      case node
      when Prism::StatementsNode
        node.body.each do |child|
          result = find_class(child)
          return result if result
        end
      when Prism::ClassNode
        return parse_class(node)
      end
      nil
    end

    private def self.parse_class(klass : Prism::ClassNode) : ModelInfo
      name = klass.name

      superclass = case sc = klass.superclass
                   when Prism::ConstantReadNode then sc.name
                   when Prism::ConstantPathNode then sc.full_path
                   else "ApplicationRecord"
                   end

      associations = [] of Association
      validations = [] of Validation

      if body = klass.body
        stmts = body.is_a?(Prism::StatementsNode) ? body.body : [body]

        stmts.each do |stmt|
          next unless stmt.is_a?(Prism::CallNode)

          case stmt.name
          when "has_many"
            assoc = parse_association(:has_many, stmt)
            associations << assoc if assoc
          when "has_one"
            assoc = parse_association(:has_one, stmt)
            associations << assoc if assoc
          when "belongs_to"
            assoc = parse_association(:belongs_to, stmt)
            associations << assoc if assoc
          when "validates"
            parse_validates(stmt, validations)
          end
        end
      end

      ModelInfo.new(name, superclass, associations, validations)
    end

    private def self.parse_association(kind : Symbol, call : Prism::CallNode) : Association?
      args = call.arg_nodes
      return nil if args.empty?

      name = case arg = args[0]
             when Prism::SymbolNode then arg.value
             else return nil
             end

      options = {} of String => String
      args[1..]?.try &.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)
        arg.elements.each do |el|
          next unless el.is_a?(Prism::AssocNode)
          key = case k = el.key
                when Prism::SymbolNode then k.value
                else next
                end
          val = case v = el.value_node
                when Prism::SymbolNode  then v.value
                when Prism::StringNode  then v.value
                when Prism::TrueNode   then "true"
                when Prism::FalseNode  then "false"
                else next
                end
          options[key] = val
        end
      end

      Association.new(kind, name, options)
    end

    private def self.parse_validates(call : Prism::CallNode, validations : Array(Validation))
      args = call.arg_nodes
      return if args.empty?

      field = case arg = args[0]
              when Prism::SymbolNode then arg.value
              else return
              end

      # Remaining args are keyword options specifying validation types
      args[1..]?.try &.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)
        arg.elements.each do |el|
          next unless el.is_a?(Prism::AssocNode)
          key = case k = el.key
                when Prism::SymbolNode then k.value
                else next
                end

          case key
          when "presence"
            if el.value_node.is_a?(Prism::TrueNode)
              validations << Validation.new(field, "presence")
            end
          when "length"
            opts = extract_hash_options(el.value_node)
            validations << Validation.new(field, "length", opts)
          when "format"
            validations << Validation.new(field, "format")
          when "uniqueness"
            validations << Validation.new(field, "uniqueness")
          when "numericality"
            validations << Validation.new(field, "numericality")
          when "inclusion"
            validations << Validation.new(field, "inclusion")
          end
        end
      end
    end

    private def self.extract_hash_options(node : Prism::Node) : Hash(String, String)
      options = {} of String => String
      case node
      when Prism::HashNode
        node.elements.each do |el|
          next unless el.is_a?(Prism::AssocNode)
          key = case k = el.key
                when Prism::SymbolNode then k.value
                else next
                end
          val = case v = el.value_node
                when Prism::IntegerNode then v.value.to_s
                when Prism::TrueNode   then "true"
                when Prism::FalseNode  then "false"
                when Prism::StringNode  then v.value
                when Prism::SymbolNode  then v.value
                else next
                end
          options[key] = val
        end
      end
      options
    end
  end
end
