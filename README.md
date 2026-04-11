# Railcar

Four things in one:

1. **Crystal transpiler** -- converts a Ruby on Rails application into a Crystal web application
2. **Python transpiler** -- converts a Ruby on Rails application into a Python web application
3. **Framework** -- a Rails-compatible runtime for Crystal, currently covering ActiveRecord and Hotwire, with more to come
4. **RBS generator** -- produces RBS type signatures for existing Rails apps, using Crystal's semantic type inference to determine method return types and instance variable types

These mix and match. Both Ruby and Crystal input files are supported in the same project, so you can start with a Rails app, generate the Crystal version, then gradually rewrite individual files in Crystal. The pipeline handles both seamlessly.

**Status:** Early proof of concept -- see [Status](#status) below.

## What it does

Given a Rails app directory, Railcar parses the source code, applies a chain of AST transformations, and generates a Crystal or Python application.

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
Shared filter chain (Rails-specific transformations)
    |
    +--> Crystal filters --> Crystal.format --> .cr output
    |
    +--> Python filters --> PythonEmitter --> .py output
```

The shared filters normalize Rails conventions (instance variables, params, respond_to, strong params, redirects, render calls) into a target-neutral AST. Target-specific filters and emitters handle the language differences.

## Prerequisites

- [Crystal](https://crystal-lang.org/install/) >= 1.10.0
- Ruby with the [prism](https://rubygems.org/gems/prism) gem installed (`gem install prism`)
- SQLite3 development headers
- Optional: [tailwindcss](https://tailwindcss.com/docs/installation) or `gem install tailwindcss-rails` for styled output

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

# Generate a Python app
build/railcar --python /path/to/rails/app /path/to/output
cd /path/to/output
uv run python3 app.py

# Run Python tests
uv run --extra test pytest tests/ -v

# Generate RBS type signatures
build/railcar --rbs /path/to/rails/app /path/to/output
```

The RBS generator uses Crystal's type inference engine to produce accurate type signatures. For a blog app's controller, it infers:

```rbs
class ArticlesController < ApplicationController
  @articles: ActiveRecord::Relation[Article]?
  @article: Article?

  def index: ActiveRecord::Relation[Article]
  def new: Article
  def set_article: Article
  def article_params: ActionController::Parameters
end
```

## Test

```bash
make test
```

Downloads a sample Rails blog app and runs the 240-test spec suite.

## What works

The blog demo exercises these patterns across both Crystal and Python targets:

- **Models** -- `has_many`, `belongs_to`, `validates` (presence, length), `dependent: :destroy`
- **Controllers** -- CRUD actions, `before_action`, strong params, `respond_to`, `redirect_to` with flash, `render` with status codes
- **Views** -- ERB to ECR (Crystal) or Python string functions, `link_to`, `button_to`, `form_with`, partials, `render @collection`
- **Routes** -- `resources`, nested resources, `root`
- **Tests** -- Minitest to Crystal spec or pytest, model and controller tests, fixtures
- **Real-time** -- ActionCable/WebSocket with Turbo Streams broadcasting

**Crystal:** 243 specs passing, compiled binary, full ActiveRecord-like runtime with macros.

**Python:** 20 tests passing (4 model + 5 model + 8 controller + 3 controller), aiohttp async server, SQLite ORM with validations.

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

## Adding a new target language

The shared Rails filters handle ~50% of the work for any target. To add a new language:

1. Write a **language emitter** that serializes Crystal AST to the target syntax
2. Write **language-specific filters** (constructor syntax, redirect/render patterns)
3. Write **infrastructure** (HTTP server, routing, ORM, WebSocket)
4. Write a **test adapter** (test framework integration)

See [ARCHITECTURE.md](ARCHITECTURE.md) for the filter pipeline details.

## Relationship to ruby2js

Railcar is a sibling project to [ruby2js](https://www.ruby2js.com/), which transpiles Ruby to JavaScript. They share the same Prism parser, the same inflector, and the same architectural philosophy: parse source, transform an AST through composable filters, serialize the result. Knowledge from one project transfers to the other.

## License

MIT
