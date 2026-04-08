# ruby2cr

A Rails-to-Crystal transpiler. Converts a Ruby on Rails application into an equivalent Crystal web application.

**Status:** Early proof of concept.

## What it does

Given a Rails app directory, ruby2cr extracts migrations, models, controllers, routes, views, fixtures, and tests, then generates a complete Crystal application that compiles and runs.

```
Rails App (Ruby)
    |
    v
Extractors (Prism parser via FFI)
    |
    v
Crystal App (models, controllers, views, routes, tests)
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

Downloads a sample Rails blog app and runs the spec suite against it.

## How it works

- **Schema extraction** -- parses Rails migrations to derive table schemas and column types
- **Model extraction** -- parses model files for associations, validations
- **Controller extraction** -- parses controllers for actions, before_actions, strong params
- **Route extraction** -- parses `config/routes.rb` for resources, nested resources, root
- **ERB conversion** -- converts ERB templates to Crystal ECR via AST transformation
- **Test conversion** -- converts Minitest to Crystal spec format
- **Runtime** -- a Crystal ORM that mirrors ActiveRecord using macros (validations, associations, query chaining)

## Limitations

This is a proof of concept. It handles conventional Rails patterns (CRUD controllers, standard associations, form helpers) but does not support:

- Runtime metaprogramming (`eval`, `method_missing`, dynamic `send`)
- Most gems (Devise, Pundit, etc.)
- ActionCable / WebSockets
- ActiveStorage, ActionMailer
- Background jobs

## License

MIT
