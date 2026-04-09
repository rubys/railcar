# ERB to Ruby compiler — Crystal port of lib/ruby2js/rails/erb_compiler.rb
#
# Converts ERB templates to Ruby source code that builds a string via
# _buf += and _buf.append=. The output can then be parsed by Prism
# and the AST transformed before emitting ECR.

module Railcar
  class ErbCompiler
    BLOCK_EXPR = /((\s|\))do|\{)(\s*\|[^|]*\|)?\s*$/

    getter position_map : Array(Tuple(Int32, Int32, Int32, Int32))

    def initialize(@template : String)
      @position_map = [] of Tuple(Int32, Int32, Int32, Int32)
    end

    def src : String
      ruby_code = "def render\n_buf = ::String.new;"
      pos = 0

      while pos < @template.size
        erb_start = @template.index("<%", pos)

        unless erb_start
          text = @template[pos..]
          ruby_code += " _buf += #{emit_ruby_string(text)};" if text && !text.empty?
          break
        end

        erb_end = @template.index("%>", erb_start)
        raise "Unclosed ERB tag" unless erb_end

        tag = @template[(erb_start + 2)...erb_end]
        is_code_block = !tag.strip.starts_with?("=") && !tag.strip.starts_with?("-")

        # Add text before ERB tag
        if erb_start > pos
          text = @template[pos...erb_start]
          if is_code_block
            if text.includes?("\n")
              last_newline = text.rindex("\n")
              if last_newline
                after_newline = text[(last_newline + 1)..]
                if after_newline =~ /^\s*$/
                  text = text[0..last_newline]
                end
              end
            end
          end
          ruby_code += " _buf += #{emit_ruby_string(text)};" if !text.empty?
        end

        trim_trailing = tag.ends_with?("-")
        tag = tag[0...-1] if trim_trailing
        is_erb_comment = tag.starts_with?("#")
        tag = tag.strip

        is_output_expr = false

        if tag.starts_with?("=")
          expr = tag[1..].strip
          erb_expr_start = erb_start + 2 + 1 + (tag.size - 1 - expr.size)
          erb_expr_end = erb_expr_start + expr.size

          if expr =~ BLOCK_EXPR
            ruby_expr_start = ruby_code.size + " _buf.append= ".size
            ruby_code += " _buf.append= #{expr}\n"
            ruby_expr_end = ruby_code.size - 1
            @position_map << {ruby_expr_start, ruby_expr_end, erb_expr_start, erb_expr_end}
          else
            ruby_expr_start = ruby_code.size + " _buf.append= ( ".size
            ruby_code += " _buf.append= ( #{expr} ).to_s;"
            ruby_expr_end = ruby_expr_start + expr.size
            @position_map << {ruby_expr_start, ruby_expr_end, erb_expr_start, erb_expr_end}
            is_output_expr = true
          end
        elsif tag.starts_with?("-")
          expr = tag[1..].strip
          erb_expr_start = erb_start + 2 + 1 + (tag.size - 1 - expr.size)
          erb_expr_end = erb_expr_start + expr.size
          ruby_expr_start = ruby_code.size + " _buf.append= ( ".size
          ruby_code += " _buf.append= ( #{expr} ).to_s;"
          ruby_expr_end = ruby_expr_start + expr.size
          @position_map << {ruby_expr_start, ruby_expr_end, erb_expr_start, erb_expr_end}
          is_output_expr = true
        elsif is_erb_comment
          # Skip ERB comments
        else
          code = tag.strip
          erb_code_start = erb_start + 2 + (tag.size - tag.lstrip.size)
          erb_code_end = erb_code_start + code.size
          ruby_code_start = ruby_code.size + 1
          ruby_code += " #{code}\n"
          ruby_code_end = ruby_code.size - 1
          @position_map << {ruby_code_start, ruby_code_end, erb_code_start, erb_code_end}
        end

        pos = erb_end + 2
        if (trim_trailing || is_code_block) && pos < @template.size && @template[pos]? == '\n'
          pos += 1
        end

        if is_output_expr && pos < @template.size && @template[pos]? == '\n'
          ruby_code += " _buf += #{emit_ruby_string("\n")};"
          pos += 1
        end
      end

      ruby_code += "\n_buf.to_s\nend"
      ruby_code
    end

    private def emit_ruby_string(str : String) : String
      escaped = str.gsub("\\", "\\\\").gsub("\"", "\\\"").gsub("\n", "\\n")
      "\"#{escaped}\""
    end
  end
end
