# Railcar

Three things in one:

1. **Transpiler** -- converts a Ruby on Rails application into a Crystal web application
2. **Framework** -- a Rails-compatible runtime for Crystal, currently covering ActiveRecord and Hotwire, with more to come
3. **RBS generator** -- produces RBS type signatures for existing Rails apps (prototype; planned to leverage Crystal's semantic type inference alongside Rails conventions for comprehensive coverage)

These mix and match. Both Ruby and Crystal input files are supported in the same project, so you can start with a Rails app, generate the Crystal version, then gradually rewrite individual files in Crystal. The pipeline handles both seamlessly.

**Status:** Early proof of concept -- see [Status](#status) below.

## What it does

Given a Rails app directory, Railcar parses the source code, applies a chain of AST transformations, and generates a Crystal application that compiles and runs.

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
2. Compile the `railcar` binary to `build/railcar`

## Usage

```bash
# Generate a Crystal app
build/railcar /path/to/rails/app /path/to/output
cd /path/to/output
shards install
crystal build src/app.cr

# Generate RBS type signatures
build/railcar --rbs /path/to/rails/app /path/to/output
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

## Status

The architecture is solid: a clean pipeline from Prism parse through composable AST filters to Crystal output, with a language-agnostic intermediate representation that separates concerns well. The filter chain is the right abstraction -- each new Rails pattern is a small, testable transformer.

The implementation, however, is held together with bailing wire and chewing gum. A non-exhaustive list:

- **Hard-coded database** -- SQLite only, connection string baked into the generated app
- **Hard-coded layout** -- a single inline HTML template rather than converting the Rails layout
- **Hard-coded import map** -- Turbo JS served as a static file, no asset pipeline
- **Hard-coded port** -- always binds to 0.0.0.0:3000
- **Flash as a global hash** -- `FLASH_STORE` is a process-global `Hash`, not per-request
- **Form builder in the ERB converter** -- ~150 lines of Rails form semantics embedded in what should be a structural pass
- **`content_for` silently dropped** -- stripped inside the Turbo Stream filter because it was convenient
- **Duplicate `model_to_path` logic** -- copy-pasted between `LinkToPathHelper` and `ButtonToPathHelper`

These shortcuts are in place not because the problems are hard, but because they are known to be solvable -- each has a clear path to a proper implementation. The goal at this stage was to prove the pipeline works end to end.

Despite all of this, the proof of concept produces real, observable results: a Rails blog app with models, controllers, views, nested resources, validations, and tests compiles to Crystal and runs.

## What needs work

Many common Rails patterns are not yet implemented:

- **Models** -- scopes, enums, callbacks (beyond stripping), polymorphic associations, `has_one :through`, custom validators
- **Controllers** -- filters beyond `before_action`, rescue_from, streaming, multi-format responses
- **Views** -- Turbo Streams (currently stripped), Action Text, complex form builders, content_for
- **Gems** -- Devise, Pundit, Sidekiq, and other common gems each need their own filters
- **Infrastructure** -- ActionCable/WebSockets, ActiveStorage, ActionMailer, background jobs
- **Runtime metaprogramming** -- `eval`, `method_missing`, dynamic `send` cannot be transpiled

The filter architecture is designed so each of these can be added incrementally. See [ARCHITECTURE.md](ARCHITECTURE.md) for how to contribute.

## Relationship to ruby2js

Railcar is a sibling project to [ruby2js](https://www.ruby2js.com/), which transpiles Ruby to JavaScript. They share the same Prism parser, the same inflector, and the same architectural philosophy: parse source, transform an AST through composable filters, serialize the result. Knowledge from one project transfers to the other.

## License

MIT
