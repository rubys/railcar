# ruby2cr

Converts a Ruby on Rails application into a Crystal web application.

**Status:** Early proof of concept. Tested against a Rails blog demo (articles, comments, nested resources). The architecture is designed for incremental extension -- new Rails patterns are added by writing composable filters.

## What it does

Given a Rails app directory, ruby2cr parses the source code, applies a chain of AST transformations, and generates a Crystal application that compiles and runs.

```
Source (.rb or .cr)
    |
    v
Parse (Prism for Ruby, Crystal parser for Crystal)
    |
    v
Crystal AST (canonical intermediate representation)
    |
    v
Filter chain (composable transformations)
    |
    v
Crystal source output (via Crystal.format)
```

Both Ruby and Crystal input files are supported. This means you can start with a Rails app, generate the Crystal version, then gradually rewrite individual files in Crystal as you learn the language. The pipeline handles both seamlessly.

## Prerequisites

- [Crystal](https://crystal-lang.org/install/) >= 1.10.0
- Ruby with the [prism](https://rubygems.org/gems/prism) gem installed (`gem install prism`)
- SQLite3 development headers

## Build

```bash
make
```

This will:
1. Locate and build `libprism` from the prism gem
2. Compile the `ruby2cr` binary to `build/ruby2cr`

## Usage

```bash
build/ruby2cr /path/to/rails/app /path/to/output
cd /path/to/output
shards install
crystal build src/app.cr
```

## Test

```bash
make test
```

Downloads a sample Rails blog app and runs the 240-test spec suite.

## What works

The blog demo exercises these patterns:

- **Models** -- `has_many`, `belongs_to`, `validates` (presence, length), `dependent: :destroy`
- **Controllers** -- CRUD actions, `before_action`, strong params, `respond_to`, `redirect_to` with flash, `render` with status codes
- **Views** -- ERB to ECR conversion, `link_to`, `button_to`, `form_with`, partials, `render @collection`
- **Routes** -- `resources`, nested resources, `root`
- **Tests** -- Minitest to Crystal spec, model and controller tests, fixtures with dependency ordering
- **Runtime** -- ActiveRecord-like ORM with macros, query chaining, validations, associations

## What needs work

This is a proof of concept. Many common Rails patterns are not yet implemented:

- **Models** -- scopes, enums, callbacks (beyond stripping), polymorphic associations, `has_one :through`, custom validators
- **Controllers** -- filters beyond `before_action`, rescue_from, streaming, multi-format responses
- **Views** -- Turbo Streams (currently stripped), Action Text, complex form builders, content_for
- **Gems** -- Devise, Pundit, Sidekiq, and other common gems each need their own filters
- **Infrastructure** -- ActionCable/WebSockets, ActiveStorage, ActionMailer, background jobs
- **Runtime metaprogramming** -- `eval`, `method_missing`, dynamic `send` cannot be transpiled

The filter architecture is designed so each of these can be added incrementally. See [ARCHITECTURE.md](ARCHITECTURE.md) for how to contribute.

## Relationship to ruby2js

ruby2cr is a sibling project to [ruby2js](https://www.ruby2js.com/), which transpiles Ruby to JavaScript. They share the same Prism parser, the same inflector, and the same architectural philosophy: parse source, transform an AST through composable filters, serialize the result. Knowledge from one project transfers to the other.

## License

MIT
