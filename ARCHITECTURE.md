# Architecture

This document explains how railcar works, for contributors who want to understand the codebase or add new Rails pattern support.

## Pipeline overview

Every file -- model, controller, or template -- flows through the same pipeline:

```
Source file (.rb or .cr)
       |
       v
   SourceParser
       |
  .rb files: Prism FFI -> PrismTranslator -> Crystal AST
  .cr files: Crystal::Parser -> Crystal AST
       |
       v
   Shared filter chain (Rails normalization)
       |
       +---> Crystal filters -> .to_s -> Crystal.format -> .cr/.ecr output
       |
       +---> Python filters -> Cr2Py -> PyAST -> .py output
       |
       +---> TypeScript filters -> Cr2Ts -> .ts output
       |                       -> EjsConverter -> .ejs templates
       |
       +---> Elixir filters -> Cr2Ex -> .ex output
       |                           -> EexConverter -> .eex templates
```

Crystal AST (`Crystal::ASTNode`) is the canonical intermediate representation. All filters operate on it, regardless of whether the source was Ruby or Crystal, and regardless of the target language.

The shared filters normalize Rails conventions into a target-neutral form. Target-specific filters then handle language differences (constructor syntax, error handling, property vs method access). The emitter serializes the final AST to the target language's source code.

### Semantic analysis

Railcar can optionally run Crystal's type inference engine on the translated AST. This is used by the RBS generator, the Python emitter, and the TypeScript emitter to determine method return types and instance variable types without executing the code.

The semantic phase requires Crystal's standard library (prelude) but **not** LLVM. Railcar provides LLVM stubs (`stubs/llvm/`) that shadow the standard library's LLVM bindings, allowing semantic analysis to run with no LLVM dependency. This reduces binary size from ~100MB+ to ~28MB.

The pipeline for semantic analysis:

```
Ruby source
    |
    v
PrismTranslator -> Crystal AST (with source locations)
    |
    v
Filter chain (RespondToHTML, etc.) -> valid Crystal AST
    |
    v
Combine: prelude + model stubs + controller AST
    |
    v
Crystal semantic analysis -> typed AST
    |
    v
Read inferred types (method returns, instance variables)
```

Model stubs are generated from AppModel metadata (schemas, associations) and provide typed signatures so Crystal can infer types through method calls like `Article.find(id)` -> `Article`.

## Key components

### PrismTranslator (`src/generator/prism_translator.cr`)

Mechanical translation from Prism AST nodes to Crystal AST nodes. This is a dumb syntax mapper -- it knows nothing about Rails. `Prism::CallNode` becomes `Crystal::Call`, `Prism::DefNode` becomes `Crystal::Def`, and so on.

### SourceParser (`src/generator/source_parser.cr`)

Routes `.rb` files through PrismTranslator and `.cr` files through Crystal's own parser. Both produce `Crystal::ASTNode`. The rest of the pipeline doesn't know or care which parser was used.

### Filters (`src/filters/`)

Each filter is a `Crystal::Transformer` subclass that pattern-matches on AST nodes and rewrites them. Filters are composable -- they run in sequence, each receiving the output of the previous one.

**Shared controller filters** (used by all targets, via `SharedControllerFilters.apply`):

| Filter | What it does |
|--------|-------------|
| `InstanceVarToLocal` | `@article` -> `article` |
| `ParamsExpect` | `params.expect(:id)` -> `id` |
| `RespondToHTML` | Extracts `format.html { ... }` from `respond_to` blocks |
| `StrongParams` | `Article.new(article_params)` -> `Article.new(extract_model_params(...))` |

**Crystal-specific controller filters** (applied after shared filters):

| Filter | What it does |
|--------|-------------|
| `RedirectToResponse` | `redirect_to @article` -> status 302 + Location header + flash |
| `RenderToECR` | `render :new` -> `response.print(layout { ECR.embed(...) })` |
| `ControllerSignature` | Adds typed parameters, inlines `before_action`, appends view rendering |
| `ControllerBoilerplate` | Injects `include` statements, helper methods, partial renderers |
| `ModelNamespace` | `Article` -> `Railcar::Article` |

**Python controller filter:**

| Filter | What it does |
|--------|-------------|
| `ControllerBoilerplatePython` | Transforms Rails controller class into async handler functions: inlines before_actions, transforms redirects to `web.HTTPFound`, renders to `web.Response` |

**TypeScript controller filter:**

| Filter | What it does |
|--------|-------------|
| `ControllerBoilerplateTypeScript` | Transforms Rails controller class into Express handler functions: inlines before_actions, transforms redirects to `res.redirect()`, renders to `helpers.renderView()` |

**Elixir controller filter:**

| Filter | What it does |
|--------|-------------|
| `ControllerBoilerplateElixir` | Transforms Rails controller class into Plug handler functions: inlines before_actions, converts `if article.save` to `case Model.create(params) do {:ok,} / {:error,}`, transforms redirects to `conn \|> put_resp_header \|> send_resp`, resolves association chains for nested resources |

**Model filters:**

| Filter | What it does |
|--------|-------------|
| `BroadcastsTo` | Converts `broadcasts_to`/`after_*_commit` to broadcast calls |
| `ModelBoilerplate` | Wraps body in `model("table") { columns + declarations }`, adds validations (Crystal) |
| `ModelBoilerplatePython` | Produces macro-free Crystal AST with TABLE, COLUMNS, property declarations (Python, TypeScript, and Go) |
| `ModelBoilerplateElixir` | Produces Elixir-shaped Crystal AST with module functions taking `record` param, `Railcar.Validation` calls, association methods |

**View filters** (shared, applied to template AST before target-specific emission):

| Filter | What it does |
|--------|-------------|
| `InstanceVarToLocal` | `@article` -> `article` |
| `TurboStreamConnect` | Converts `turbo_stream_from` to `turbo-cable-stream-source` element |
| `RailsHelpers` | `present?` -> truthy, `count` -> `size`, `dom_id` symbols -> strings |
| `LinkToPathHelper` | `link_to("Show", @article)` -> `link_to("Show", article_path(article))` |
| `ButtonToPathHelper` | Same for `button_to`, including nested resource arrays |
| `RenderToPartial` | `render @articles` -> `articles.each { render_article_partial(article) }` |
| `FormToHTML` | `form_with model: @article` -> HTML form tags (used by Python and TypeScript views) |

**Shared utilities:**

| Module | What it does |
|--------|-------------|
| `SharedControllerFilters` | Applies the 4 shared controller filters in the correct order |
| `PathHelperUtils` | `model_to_path` and `extract_resource_name`, shared by LinkTo and ButtonTo filters |

Filter order matters. Each filter's documentation notes its dependencies.

### ERBConverter / EjsConverter / EexConverter

**ERBConverter** (`src/generator/erb_converter.cr`): Converts ERB/ECR templates to Crystal ECR output.

**EjsConverter** (`src/generator/ejs_converter.cr`): Converts ERB templates to EJS output for TypeScript. Handles EJS `include()` for partials and `<%-` for unescaped HTML output.

**EexConverter** (`src/generator/eex_converter.cr`): Converts ERB templates to EEx output for Elixir. Emits Elixir expressions with full module paths (e.g., `Blog.Helpers.link_to`). Uses `app_module` parameter and `known_fields` from schema for property-vs-method detection.

All three converters follow the same pattern: after view filters have normalized the AST, they walk the `_buf`-based AST and emit template tags in the target syntax.

### Python Emitter (`src/emitter/python/`)

A two-stage Crystal AST -> Python pipeline:

1. **Cr2Py Emitter** (`cr2py.cr`) -- walks typed Crystal AST nodes and produces PyAST nodes
2. **PyAST** (`py_ast.cr`) -- minimal Python AST with structural indentation
3. **PyAST Filters** (`filters/`) -- ReturnFilter, DunderFilter, AsyncFilter, DbFilter
4. **TypeIndex** (`type_index.cr`) -- property detection from `program.types`

### TypeScript Emitter (`src/emitter/typescript/`)

**Cr2Ts Emitter** (`cr2ts.cr`) -- walks typed Crystal AST and emits TypeScript directly. Handles model class definitions, typed property declarations, validation methods, and association methods. No intermediate AST -- Crystal-to-TypeScript syntax is close enough for direct emission.

### Elixir Emitter (`src/emitter/elixir/`)

**Cr2Ex Emitter** (`cr2ex.cr`) -- walks Crystal AST (post-filter) and emits Elixir. Two entry points: `emit_model` (ClassDef -> defmodule with module functions) and `emit_controller_function` (Def -> Plug handler). Handles Elixir-specific patterns: `case` result expressions from `if save/update`, pipe chains for redirects, struct literals, property access without parens, keyword list formatting for `render_view`, and `Railcar.Validation` calls in run_validations.

### Generators

**AppGenerator** (`src/generator/app_generator.cr`) -- orchestrates Crystal output.

**Python2Generator** (`src/generator/python2_generator.cr`) -- orchestrates Python output.

**TypeScriptGenerator** (`src/generator/typescript_generator.cr`) -- orchestrates TypeScript output, delegating to:
- `TypeScriptViewGenerator` -- ERB -> EJS templates via EjsConverter
- `TypeScriptControllerGenerator` -- Ruby source -> AST -> filters -> Express handlers
- `TypeScriptTestGenerator` -- Minitest -> node:test via Prism AST walking

**ElixirGenerator** (`src/generator/elixir_generator.cr`) -- orchestrates Elixir output. Models and controllers use the AST pipeline: `SourceParser.parse` -> `BroadcastsTo` / `SharedControllerFilters` -> `ModelBoilerplateElixir` / `ControllerBoilerplateElixir` -> `Cr2Ex` emitter. Views use EexConverter. Tests use Prism AST walking. Infrastructure (Mix project, router, database init, seeds) is generated structurally from AppModel metadata. Target: Plug + Bandit server with WebSock for ActionCable.

### Runtime

**Crystal** (`src/runtime/`): A Crystal ORM mirroring ActiveRecord -- base model class with macros, Relation query builder, CollectionProxy, view helpers.

**Python** (`src/runtime/python/`):
- `base.cr` -- Crystal source used only for `program.semantic()` type checking (not emitted)
- `base_runtime.py` -- hand-written Python runtime with ApplicationRecord, ValidationErrors, CollectionProxy

**TypeScript** (`src/runtime/typescript/`):
- `base.cr` -- Crystal source used only for `program.semantic()` type checking (not emitted)
- `base_runtime.ts` -- hand-written TypeScript runtime with ApplicationRecord, ValidationErrors, CollectionProxy, using better-sqlite3
- `base_runtime_test.ts` -- smoke tests (24 assertions)

**Elixir** (`src/runtime/elixir/`):
- `base_runtime.ex` -- hand-written Elixir runtime: `Railcar.Record` macro (CRUD, validations, callbacks), `Railcar.Repo` (SQLite via Exqlite with persistent_term), `Railcar.Validation` helpers, `Railcar.CableServer` (GenServer for WebSocket subscriptions), `Railcar.CableHandler` (WebSock Action Cable protocol), `Railcar.Broadcast` (turbo-stream HTML generation and delivery)

### Shared data models

**RouteSet** (`src/generator/route_extractor.cr`):
- `nested_parent_for(controller_name)` -- finds parent resource for nested controllers
- `helpers` -- computes `Array(RouteHelper)` with name, path, params for each route helper

**AppModel** (`src/generator/app_model.cr`) -- language-agnostic IR: schemas, models, controllers, routes, fixtures.

### Extractors (`src/generator/*_extractor.cr`)

- **SchemaExtractor** -- migrations -> table schemas and column types
- **ModelExtractor** -- model files -> associations, validations
- **ControllerExtractor** -- controllers -> actions, before_actions
- **RouteExtractor** -- config/routes.rb -> route definitions

### Inflector (`src/generator/inflector.cr`)

Rails-compatible singularize/pluralize/classify, ported from the shared ruby2js/juntos inflector.

## Writing a new filter

To add support for a new Rails pattern:

1. Create a file in `src/filters/`, e.g., `src/filters/my_filter.cr`
2. Subclass `Crystal::Transformer` and override `transform` for the node types you need
3. Add tests in `spec/filters_spec.cr` or a new spec file
4. Wire it into the appropriate chain in the generator

Here's a minimal example:

```crystal
require "compiler/crystal/syntax"

module Railcar
  class MyFilter < Crystal::Transformer
    def transform(node : Crystal::Call) : Crystal::ASTNode
      if node.name == "old_pattern"
        Crystal::Call.new(node.obj, "new_pattern", node.args)
      else
        node.obj = node.obj.try(&.transform(self))
        node.args = node.args.map(&.transform(self).as(Crystal::ASTNode))
        node.block = node.block.try(&.transform(self).as(Crystal::Block))
        node
      end
    end
  end
end
```

The existing filters in `src/filters/` range from 33 to 429 lines. Most are under 150 lines.

## Testing

```bash
make test     # runs all Crystal specs (313)
crystal spec spec/filters_spec.cr   # run a specific spec file
```

CI generates and tests all four targets:

| Target | What CI runs |
|--------|-------------|
| Crystal | `crystal spec` on generated blog (compiled binary) |
| Python | `pytest tests/ -v` on generated blog (21 tests) |
| TypeScript | `npx tsx --test tests/*.test.ts` on generated blog (21 tests) |
| Elixir | `mix test --no-start` on generated blog (21 tests) |

Crystal tests are organized by component:

| File | What it tests |
|------|--------------|
| `inflector_spec.cr` | Pluralization, singularization, classify, underscore |
| `translator_spec.cr` | Prism -> Crystal AST translation |
| `filters_spec.cr` | Individual filters and pipeline integration |
| `view_filters_spec.cr` | View-specific filters (link_to, render, etc.) |
| `source_parser_spec.cr` | .rb/.cr routing |
| `erb_spec.cr` | Template conversion |
| `generator_spec.cr` | Schema extraction, model generation |
| `controller_spec.cr` | Controller extraction |
| `route_spec.cr` | Route extraction, RouteHelper data model |
| `models_spec.cr` | Runtime model CRUD and validations |
| `prism_spec.cr` | Prism FFI bindings |
| `semantic_spec.cr` | LLVM stub + Crystal type inference |

The `make test` target downloads a sample Rails blog app to `build/demo/blog/` for integration testing.
