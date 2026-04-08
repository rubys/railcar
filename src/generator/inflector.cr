# Rails-compatible inflector for singularize/pluralize
# Ported from lib/ruby2js/inflector.rb (shared with juntos)

module Ruby2CR
  module Inflector
    IRREGULARS_SINGULAR = {
      "people" => "person", "men" => "man", "women" => "woman",
      "children" => "child", "sexes" => "sex", "moves" => "move",
      "zombies" => "zombie", "octopi" => "octopus", "viri" => "virus",
      "aliases" => "alias", "statuses" => "status", "axes" => "axis",
      "crises" => "crisis", "testes" => "testis", "oxen" => "ox",
      "quizzes" => "quiz",
    }

    IRREGULARS_PLURAL = {
      "person" => "people", "man" => "men", "woman" => "women",
      "child" => "children", "sex" => "sexes", "move" => "moves",
      "zombie" => "zombies", "octopus" => "octopi", "virus" => "viri",
      "alias" => "aliases", "status" => "statuses", "axis" => "axes",
      "crisis" => "crises", "testis" => "testes", "ox" => "oxen",
      "quiz" => "quizzes",
    }

    UNCOUNTABLES = %w[
      equipment information rice money species series fish sheep jeans police
    ]

    # Order matters - first match wins
    SINGULARS = [
      {/(ss)$/i, "\\1"},
      {/(database)s$/i, "\\1"},
      {/(quiz)zes$/i, "\\1"},
      {/(matr)ices$/i, "\\1ix"},
      {/(vert|ind)ices$/i, "\\1ex"},
      {/^(ox)en/i, "\\1"},
      {/(alias|status)(es)?$/i, "\\1"},
      {/(octop|vir)(us|i)$/i, "\\1us"},
      {/^(a)x[ie]s$/i, "\\1xis"},
      {/(cris|test)(is|es)$/i, "\\1is"},
      {/(shoe)s$/i, "\\1"},
      {/(o)es$/i, "\\1"},
      {/(bus)(es)?$/i, "\\1"},
      {/^(m|l)ice$/i, "\\1ouse"},
      {/(x|ch|ss|sh)es$/i, "\\1"},
      {/(m)ovies$/i, "\\1ovie"},
      {/(s)eries$/i, "\\1eries"},
      {/([^aeiouy]|qu)ies$/i, "\\1y"},
      {/([lr])ves$/i, "\\1f"},
      {/(tive)s$/i, "\\1"},
      {/(hive)s$/i, "\\1"},
      {/([^f])ves$/i, "\\1fe"},
      {/((a)naly|(b)a|(d)iagno|(p)arenthe|(p)rogno|(s)ynop|(t)he)(sis|ses)$/i, "\\1sis"},
      {/(^analy)(sis|ses)$/i, "\\1sis"},
      {/([ti])a$/i, "\\1um"},
      {/(n)ews$/i, "\\1ews"},
      {/s$/i, ""},
    ]

    PLURALS = [
      {/(quiz)$/i, "\\1zes"},
      {/^(oxen)$/i, "\\1"},
      {/^(ox)$/i, "\\1en"},
      {/^(m|l)ice$/i, "\\1ice"},
      {/^(m|l)ouse$/i, "\\1ice"},
      {/(matr|vert|ind)(?:ix|ex)$/i, "\\1ices"},
      {/(x|ch|ss|sh)$/i, "\\1es"},
      {/([^aeiouy]|qu)y$/i, "\\1ies"},
      {/(hive)$/i, "\\1s"},
      {/(?:([^f])fe|([lr])f)$/i, "\\1\\2ves"},
      {/sis$/i, "ses"},
      {/([ti])a$/i, "\\1a"},
      {/([ti])um$/i, "\\1a"},
      {/(buffal|tomat)o$/i, "\\1oes"},
      {/(bu)s$/i, "\\1ses"},
      {/(alias|status)$/i, "\\1es"},
      {/(octop|vir)i$/i, "\\1i"},
      {/(octop|vir)us$/i, "\\1i"},
      {/^(ax|test)is$/i, "\\1es"},
      {/s$/i, "s"},
      {/$/, "s"},
    ]

    def self.singularize(word : String) : String
      lower = word.downcase
      return word if UNCOUNTABLES.includes?(lower)

      if irregular = IRREGULARS_SINGULAR[lower]?
        return preserve_case(word, irregular)
      end

      SINGULARS.each do |(rule, replacement)|
        if word.matches?(rule)
          return word.sub(rule, replacement)
        end
      end

      word
    end

    def self.pluralize(word : String) : String
      lower = word.downcase
      return word if UNCOUNTABLES.includes?(lower)

      if irregular = IRREGULARS_PLURAL[lower]?
        return preserve_case(word, irregular)
      end

      PLURALS.each do |(rule, replacement)|
        if word.matches?(rule)
          return word.sub(rule, replacement)
        end
      end

      word
    end

    # Convert underscored/hyphenated string to PascalCase class name
    def self.classify(word : String) : String
      singularize(word).split(/[_\s]/).map { |s|
        s.empty? ? "" : s[0].upcase + s[1..]
      }.join
    end

    # Convert CamelCase to snake_case
    def self.underscore(word : String) : String
      result = String.build do |io|
        word.each_char_with_index do |ch, i|
          is_upper = ch.uppercase? && ch.lowercase? != ch
          if is_upper
            if i > 0
              prev_upper = word[i - 1].uppercase? && word[i - 1].lowercase? != word[i - 1]
              next_lower = i + 1 < word.size && word[i + 1].lowercase? && word[i + 1].uppercase? != word[i + 1]
              if prev_upper && next_lower
                io << '_'
              elsif !prev_upper
                io << '_'
              end
            end
            io << ch.downcase
          else
            io << ch
          end
        end
      end
      result
    end

    private def self.preserve_case(original : String, replacement : String) : String
      if original[0].uppercase?
        replacement[0].upcase + replacement[1..]
      else
        replacement
      end
    end
  end
end
