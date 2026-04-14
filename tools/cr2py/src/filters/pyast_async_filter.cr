# PyAST Async Filter — adds async/await to controller and test functions.
#
# Marks functions as async and wraps specific calls with await:
#   client.get/post/patch/delete → await client.get/...
#   response.text() → await response.text()
#   request.read() → await request.read()
#   aiohttp_client(...) → await aiohttp_client(...)
#   parse_form(request.read()) → parse_form(await request.read())

module Cr2Py
  class PyAstAsyncFilter
    AWAIT_METHODS = %w[get post patch put delete text read]
    AWAIT_FUNCTIONS = %w[aiohttp_client create_test_client]

    def transform(nodes : Array(PyAST::Node)) : Array(PyAST::Node)
      nodes.each { |n| transform_node(n) }
      nodes
    end

    private def transform_node(node : PyAST::Node)
      case node
      when PyAST::Func
        # Mark all top-level functions as async (controllers and tests)
        node.is_async = true
        add_awaits(node.body)
      when PyAST::Class
        node.body.each { |n| transform_node(n) }
      end
    end

    private def needs_async?(body : Array(PyAST::Node)) : Bool
      body.any? do |node|
        case node
        when PyAST::Statement
          AWAIT_METHODS.any? { |m| node.code.includes?(".#{m}(") } ||
          AWAIT_FUNCTIONS.any? { |f| node.code.includes?("#{f}(") }
        when PyAST::Assign
          AWAIT_METHODS.any? { |m| node.value.includes?(".#{m}(") } ||
          AWAIT_FUNCTIONS.any? { |f| node.value.includes?("#{f}(") }
        when PyAST::If
          needs_async?(node.body) || (node.else_body.try { |e| needs_async?(e) } || false)
        else
          false
        end
      end
    end

    private def add_awaits(body : Array(PyAST::Node))
      body.each_with_index do |node, i|
        case node
        when PyAST::Assign
          body[i] = PyAST::Assign.new(node.target, add_await_to_expr(node.value))
        when PyAST::Statement
          body[i] = PyAST::Statement.new(add_await_to_expr(node.code))
        when PyAST::Return
          body[i] = PyAST::Return.new(add_await_to_expr(node.expr))
        when PyAST::If
          add_awaits(node.body)
          if else_body = node.else_body
            add_awaits(else_body)
          end
        end
      end
    end

    private def add_await_to_expr(expr : String) : String
      result = expr
      # await client.method(...) calls
      AWAIT_METHODS.each do |method|
        result = result.gsub(/(\w+)\.#{method}\(/) { "await #{$1}.#{method}(" }
      end
      # Add allow_redirects=False to POST/PATCH/PUT/DELETE calls
      # and data= keyword for body data (not for DELETE which has no body)
      %w[post patch put delete].each do |method|
        next unless result.includes?("await client.#{method}(")
        result = result.gsub(/await client\.#{method}\((.+)\)\s*$/) do |match|
          inner = $1
          # Count parens to find the real end of the client call args
          depth = 0
          split_pos = nil
          inner.each_char_with_index do |c, i|
            depth += 1 if c == '('
            depth -= 1 if c == ')'
            if c == ',' && depth == 0 && split_pos.nil?
              split_pos = i
            end
          end
          if split_pos && method != "delete"
            url = inner[0...split_pos]
            body = inner[split_pos + 2..]  # skip ", "
            "await client.#{method}(#{url}, data=#{body}, allow_redirects=False)"
          else
            "await client.#{method}(#{inner}, allow_redirects=False)"
          end
        end
      end
      # response.text (property) → await response.text() (coroutine in aiohttp)
      result = result.gsub(/(\w+)\.text(?!\()/) { "await #{$1}.text()" }
      # await function(...) calls
      AWAIT_FUNCTIONS.each do |func|
        result = result.gsub(/(?<!await )#{func}\(/) { "await #{func}(" }
      end
      # Fix double-await
      result = result.gsub("await await ", "await ")
      result
    end
  end
end
