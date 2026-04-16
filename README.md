# Railcar

Eight things in one:

1. **Crystal transpiler** -- converts a Ruby on Rails application into a Crystal web application
2. **Elixir transpiler** -- converts a Ruby on Rails application into an Elixir web application
3. **Go transpiler** -- converts a Ruby on Rails application into a Go web application
4. **Python transpiler** -- converts a Ruby on Rails application into a Python web application
5. **Rust transpiler** -- converts a Ruby on Rails application into a Rust web application
6. **TypeScript transpiler** -- converts a Ruby on Rails application into a TypeScript web application
7. **Framework** -- a Rails-compatible runtime for Crystal, currently covering ActiveRecord and Hotwire, with more to come
8. **RBS generator** -- produces RBS type signatures for existing Rails apps, using Crystal's semantic type inference to determine method return types and instance variable types

These mix and match. Both Ruby and Crystal input files are supported in the same project, so you can start with a Rails app, generate the Crystal version, then gradually rewrite individual files in Crystal. The pipeline handles both seamlessly.

**Status:** Early proof of concept -- see [Status](#status) below.

## Demo

Railcar transpiles a [Rails blog app](https://ruby2js.github.io/ruby2js/releases/demo-blog.tar.gz) (built by this [creation script](https://github.com/ruby2js/ruby2js/blob/master/test/blog/create-blog)) into Crystal, Elixir, Go, Python, Rust, and TypeScript.

- **[Browse the generated code](https://rubys.github.io/railcar/)** -- compare the original Ruby source side-by-side with each target's output
- **[Run the blog in your browser](https://ruby2js.github.io/ruby2js/blog/)** -- an in-browser version of the same app, powered by ruby2js

## What it does

Given a Rails app directory, Railcar parses the source code, applies a chain of AST transformations, and generates a Crystal, Elixir, Go, Python, Rust, or TypeScript application.

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
    +--> Crystal filters --> Crystal.format --> .cr/.ecr output
    |
    +--> Elixir filters --> EexConverter --> .ex/.eex output
    |
    +--> Go filters --> GoViewEmitter --> .go output
    |
    +--> Python filters --> Cr2Py --> PyAST --> .py output
    |
    +--> Rust filters --> Cr2Rs --> .rs output
    |
    +--> TypeScript filters --> Cr2Ts --> .ts/.ejs output
```

The shared filters normalize Rails conventions (instance variables, params, respond_to, strong params, redirects, render calls) into a target-neutral AST. Target-specific filters and emitters handle the language differences.

## Prerequisites

- [Crystal](https://crystal-lang.org/install/) >= 1.10.0
- Ruby with the [prism](https://rubygems.org/gems/prism) gem installed (`gem install prism`)
- SQLite3 development headers
- Optional: [Elixir](https://elixir-lang.org/install.html) >= 1.17 (for Elixir target)
- Optional: [Go](https://go.dev/dl/) >= 1.21 (for Go target)
- Optional: [Node.js](https://nodejs.org/) >= 18 (for TypeScript target)
- Optional: [Rust](https://www.rust-lang.org/tools/install) >= 1.75 (for Rust target)
- Optional: [uv](https://docs.astral.sh/uv/) (for Python target)
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

# Generate a TypeScript app
build/railcar --typescript /path/to/rails/app /path/to/output
cd /path/to/output
npm install
npx tsx app.ts

# Generate an Elixir app
build/railcar --elixir /path/to/rails/app /path/to/output
cd /path/to/output
mix deps.get
mix run --no-halt

# Generate a Go app
build/railcar --go /path/to/rails/app /path/to/output
cd /path/to/output
go mod tidy
go run .

# Generate a Rust app
build/railcar --rust /path/to/rails/app /path/to/output
cd /path/to/output
cargo run

# Generate RBS type signatures
build/railcar --rbs /path/to/rails/app /path/to/output
```

Target flags also accept short forms: `--cr`, `--ex`, `--go`, `--py`, `--rs`, `--ts`, or `--target=rust`.

## Test

```bash
make test
```

Downloads a sample Rails blog app and runs the spec suite (313 Crystal specs). CI also generates and tests the Crystal blog (compiled + crystal spec), the Elixir blog (21 ExUnit tests), the Go blog (21 go test tests), the Python blog (21 pytest tests), the Rust blog (21 cargo test tests), and the TypeScript blog (21 node:test tests).

## Try it

```bash
git clone https://github.com/rubys/railcar
cd railcar
make
make test
npx github:ruby2js/juntos --demo blog
```

Generate and run each target:

```bash
# Crystal
./build/railcar blog crystal-blog
cd crystal-blog && shards install
crystal build src/app.cr -o blog && crystal spec && ./blog

# Python
./build/railcar --python blog python-blog
cd python-blog
uv run --extra test python -m pytest tests/ -v
uv run python app.py

# TypeScript
./build/railcar --typescript blog ts-blog
cd ts-blog && npm install
npx tsx --test tests/*.test.ts
npx tsx app.ts

# Elixir
./build/railcar --elixir blog ex-blog
cd ex-blog && mix deps.get
mix test --no-start
mix run --no-halt

# Go
./build/railcar --go blog go-blog
cd go-blog && go mod tidy
go test ./...
go run .

# Rust
./build/railcar --rust blog rust-blog
cd rust-blog
cargo test -- --test-threads=1
cargo run
```

Open multiple browser tabs to see real-time Turbo Streams updates.

## What works

The blog demo exercises these patterns across Crystal, Elixir, Go, Python, Rust, and TypeScript targets:

- **Models** -- `has_many`, `belongs_to`, `validates` (presence, length), `dependent: :destroy`
- **Controllers** -- CRUD actions, `before_action`, strong params, `respond_to`, `redirect_to` with flash, `render` with status codes
- **Views** -- ERB to ECR (Crystal), EEx templates (Elixir), Go/Rust view functions, Python string functions, or EJS templates (TypeScript); `link_to`, `button_to`, `form_with`, partials, `render @collection`
- **Routes** -- `resources`, nested resources, `root`
- **Tests** -- Minitest to Crystal spec, ExUnit, go test, pytest, cargo test, or node:test; model and controller tests; fixtures
- **Real-time** -- ActionCable/WebSocket with Turbo Streams broadcasting

**Crystal:** 313 specs passing, compiled binary, full ActiveRecord-like runtime with macros.

**Elixir:** 21 tests passing (9 model + 12 controller), Plug + Bandit server, hand-written ORM runtime with Exqlite, EEx templates, Tailwind CSS, Turbo Streams with ActionCable WebSocket via WebSock.

**Go:** 21 tests passing (9 model + 12 controller), net/http server, hand-written ORM runtime with modernc.org/sqlite, view functions (no template engine), Tailwind CSS, Turbo Streams with ActionCable WebSocket via nhooyr.io/websocket.

**Python:** 21 tests passing (9 model + 12 controller), aiohttp async server, hand-written ORM runtime with direct attribute access, Tailwind CSS, Turbo Streams with ActionCable WebSocket.

**Rust:** 21 tests passing (9 model + 12 controller), Axum async server, hand-written ORM runtime with rusqlite (bundled), view functions (no template engine), Tailwind CSS, Turbo Streams with ActionCable WebSocket via Axum WebSocket.

**TypeScript:** 21 tests passing (9 model + 12 controller), Express server, hand-written ORM runtime with better-sqlite3, EJS templates, Tailwind CSS, Turbo Streams with ActionCable WebSocket via ws.

## Status

The architecture is solid: a clean pipeline from Prism parse through composable AST filters to target output, with a language-agnostic intermediate representation that separates concerns well. The filter chain is the right abstraction -- each new Rails pattern is a small, testable transformer.

The implementation, however, is held together with bailing wire and chewing gum. A non-exhaustive list:

- **Hard-coded database** -- SQLite only, connection string baked into the generated app
- **Hard-coded layout** -- a single inline HTML template rather than converting the Rails layout
- **Hard-coded import map** -- Turbo JS served as a static file, no asset pipeline
- **Hard-coded port** -- always binds to 0.0.0.0:3000
- **Flash as a global hash** -- `FLASH_STORE` is a process-global `Hash`, not per-request (Crystal); flash not yet implemented (Python/TypeScript)

These shortcuts are in place not because the problems are hard, but because they are known to be solvable -- each has a clear path to a proper implementation. The goal at this stage was to prove the pipeline works end to end.

Despite all of this, the proof of concept produces real, observable results: a Rails blog app with models, controllers, views, nested resources, validations, and tests transpiles to six languages and runs.

## What needs work

Many common Rails patterns are not yet implemented:

- **Models** -- scopes, enums, callbacks (beyond stripping), polymorphic associations, `has_one :through`, custom validators
- **Controllers** -- filters beyond `before_action`, rescue_from, streaming, multi-format responses
- **Views** -- Action Text, complex form builders, content_for, layout transpilation
- **Ruby standard library** -- string, array, hash methods beyond the basics. Handled via table-driven `MethodMap` that maps Ruby methods to target-native equivalents (same approach as [Ruby2JS's functions filter](https://www.ruby2js.com/docs/filters/functions))
- **Gems** -- Devise, Pundit, Sidekiq, and other common gems each need their own filters
- **Infrastructure** -- ActiveStorage, ActionMailer, background jobs
- **Runtime metaprogramming** -- `eval`, `method_missing`, dynamic `send` cannot be transpiled

The filter architecture is designed so each of these can be added incrementally. See [ARCHITECTURE.md](ARCHITECTURE.md) for the design direction.

## Adding a new target language

The shared Rails filters handle ~50% of the work for any target. To add a new language:

1. Write a **language emitter** that serializes Crystal AST to the target syntax
2. Write **language-specific filters** (constructor syntax, redirect/render patterns)
3. Write **infrastructure** (HTTP server, routing, ORM, WebSocket)
4. Write a **test adapter** (test framework integration)

See [ARCHITECTURE.md](ARCHITECTURE.md) for the filter pipeline details.

## Relationship to ruby2js

Railcar is a sibling project to [ruby2js](https://www.ruby2js.com/), which transpiles Ruby to JavaScript. They share the same Prism parser, the same inflector, and the same architectural philosophy: parse source, transform an AST through composable filters, serialize the result. Knowledge from one project transfers to the other. The demo blog used as Railcar's test input is built by the [ruby2js CI](https://github.com/ruby2js/ruby2js/blob/master/test/blog/create-blog) and can be [run in the browser](https://ruby2js.github.io/ruby2js/blog/).

## License

MIT
