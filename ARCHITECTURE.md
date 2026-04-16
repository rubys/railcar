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
       +---> Elixir filters -> Cr2Ex -> .ex output
       |                           -> EexConverter -> .eex templates
       |
       +---> Go filters -> Cr2Go -> .go models/controllers
       |                -> GoViewEmitter -> .go view functions
       |
       +---> Python filters -> Cr2Py -> PyAST -> .py output
       |
       +---> Rust filters -> Cr2Rs -> .rs models/controllers
       |                  -> RustViewEmitter -> .rs view functions
       |
       +---> TypeScript filters -> Cr2Ts -> .ts output
       |                       -> EjsConverter -> .ejs templates
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
| `ModelBoilerplatePython` | Produces macro-free Crystal AST with TABLE, COLUMNS, property declarations (Python, TypeScript, Go) |
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

### Rust Emitter (`src/emitter/rust/`)

**Cr2Rs Emitter** (`cr2rs.cr`) -- walks Crystal AST and emits Rust model source. Generates `#[derive(Debug, Clone, Default)]` structs, `impl Model` trait (table_name, from_row, run_validations), concrete `save`/`update`/`delete` methods with cloned values for borrow checker compliance, association methods (has_many via where_eq, belongs_to via find), and `impl Broadcaster` with after_save/after_delete callbacks. Each model generates its own SQL to avoid `Box<dyn ToSql>` complexity.

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

### Go Emitter (`src/emitter/go/`)

**Cr2Go Emitter** (`cr2go.cr`) -- walks Crystal AST and emits Go model source. Generates struct definitions, Model interface methods (TableName, Columns, ScanRow, ColumnValues, RunValidations), association methods (has_many via Where, belongs_to via Find), and static functions (Find, All, Create). Extracts broadcast callbacks from pre-filtered AST and generates AfterSave/AfterDelete methods implementing the Broadcaster interface.

**GoViewEmitter** (`src/generator/go_view_emitter.cr`) -- converts view AST (after ViewCleanup) to Go functions that return strings via `strings.Builder`. No template engine -- method calls, loops, and conditionals are plain Go code (same approach as Python). Handles helper function calls, path helpers, partial rendering, and association method calls with `(value, error)` handling.

### Generators

**AppGenerator** (`src/generator/app_generator.cr`) -- orchestrates Crystal output.

**Python2Generator** (`src/generator/python2_generator.cr`) -- orchestrates Python output.

**TypeScriptGenerator** (`src/generator/typescript_generator.cr`) -- orchestrates TypeScript output, delegating to:
- `TypeScriptViewGenerator` -- ERB -> EJS templates via EjsConverter
- `TypeScriptControllerGenerator` -- Ruby source -> AST -> filters -> Express handlers
- `TypeScriptTestGenerator` -- Minitest -> node:test via Prism AST walking

**ElixirGenerator** (`src/generator/elixir_generator.cr`) -- orchestrates Elixir output. Models and controllers use the AST pipeline: `SourceParser.parse` -> `BroadcastsTo` / `SharedControllerFilters` -> `ModelBoilerplateElixir` / `ControllerBoilerplateElixir` -> `Cr2Ex` emitter. Views use EexConverter. Tests use Prism AST walking. Infrastructure (Mix project, router, database init, seeds) is generated structurally from AppModel metadata. Target: Plug + Bandit server with WebSock for ActionCable.

**GoGenerator** (`src/generator/go_generator.cr`) -- orchestrates Go output. Models use the AST pipeline: `SourceParser.parse` -> `BroadcastsTo` -> `ModelBoilerplatePython` -> `Cr2Go` emitter (broadcast callbacks extracted from pre-filtered AST). Views use GoViewEmitter: ERB -> ErbCompiler -> shared view filters -> ViewCleanup -> Go functions returning strings (no template engine). Controllers and tests are generated structurally from AppModel metadata. Target: net/http + database/sql + modernc.org/sqlite + nhooyr.io/websocket.

**RustGenerator** (`src/generator/rust_generator.cr`) -- orchestrates Rust output. Models use the AST pipeline: `SourceParser.parse` -> `BroadcastsTo` -> `ModelBoilerplatePython` -> `Cr2Rs` emitter (broadcast callbacks extracted from pre-filtered AST). Views use string-building functions (same approach as Go). Controllers are Axum async handlers. Tests use cargo test with axum-test. Target: Axum + rusqlite (bundled) + tokio + Axum WebSocket.

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

**Go** (`src/runtime/go/`):
- `base.cr` -- Crystal source used only for `program.semantic()` type checking (not emitted)
- `railcar.go` -- hand-written Go runtime: Model interface, generic CRUD (Find, All, Where, Save, Delete) with database/sql, Broadcaster interface with AfterSave/AfterDelete callbacks, CableServer (in-memory pub/sub), CableHandler (Action Cable WebSocket with `actioncable-v1-json` subprotocol), turbo-stream HTML generation, partial renderer registry, configurable logging via LOG_LEVEL env var

**Rust** (`src/runtime/rust/`):
- `base.cr` -- Crystal source used only for `program.semantic()` type checking (not emitted)
- `railcar.rs` -- hand-written Rust runtime: Model trait, generic CRUD (find, all, where_eq) with rusqlite, Broadcaster trait with after_save/after_delete callbacks, CableServer (RwLock + mpsc channels), cable_handler (Axum WebSocket with `actioncable-v1-json` subprotocol), turbo-stream HTML generation, partial renderer registry, configurable logging via LOG_LEVEL env var

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

CI generates and tests all six targets:

| Target | What CI runs |
|--------|-------------|
| Crystal | `crystal spec` on generated blog (compiled binary) |
| Elixir | `mix test --no-start` on generated blog (21 tests) |
| Go | `go test ./...` on generated blog (21 tests) |
| Python | `pytest tests/ -v` on generated blog (21 tests) |
| Rust | `cargo test -- --test-threads=1` on generated blog (21 tests) |
| TypeScript | `npx tsx --test tests/*.test.ts` on generated blog (21 tests) |

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

| `method_map_spec.cr` | Ruby-to-native method mapping tables |

The `make test` target downloads a sample Rails blog app to `build/demo/blog/` for integration testing.

## MethodMap: Ruby-to-native method mapping

`src/filters/method_map.cr` provides a table-driven mapping from Ruby method calls to target-language equivalents, following the same approach as [Ruby2JS's functions filter](https://www.ruby2js.com/docs/filters/functions). Methods map to native types (String, Array, Hash) rather than runtime wrappers, minimizing impedance mismatch with the target ecosystem.

Each target has a table of `{receiver_type, method_name}` → replacement pattern. Lookup tries the specific type first, then falls back to `"Any"`. Patterns use `RECV`, `ARG0`, `ARG1` placeholders that are substituted at emit time.

Adding a new Ruby method across all targets means adding one row per target to the tables — no emitter changes needed.

## Design direction

Three areas of work extend the current architecture:

### Broader Rails pattern coverage (shared filters)

Layout transpilation, ActionMailer, ActiveStorage, concerns, more complex form builders. Each is a `Crystal::Transformer` that rewrites AST nodes — write once, all backends benefit. The filter architecture is designed for this: each new Rails pattern is a small, testable transformer added to the shared chain.

### Broader Ruby language coverage (MethodMap + emitters)

The blog demo uses a narrow slice of Ruby. Real Rails applications use `String#parameterize`, `Array#group_by`, `Hash#transform_values`, and hundreds of other standard library methods. These are handled through MethodMap entries that rewrite Ruby method calls to target-native equivalents at transpile time — the same approach Ruby2JS uses for JavaScript. The emitters also need to handle more Crystal AST node types (case/when, ranges, regular expressions, multiple return values).

### Semantic analysis for controllers and views

Currently only models get Crystal's type inference (`program.semantic()`). Extending this to controllers and views would provide exact receiver types for MethodMap lookups — knowing that `@article` is an `Article` (not just "Any") means the mapper can choose the right translation for `@article.comments.size` vs `@article.title.size`. The infrastructure exists (Crystal's semantic engine, the model stubs); extending it to controllers means including controller ASTs in the semantic analysis phase.

### Generated runtime

Each target has a hand-written runtime that re-implements Rails semantics: CollectionProxy, ValidationErrors, query building, callback chains. These are pure business logic with no platform dependency — they could be written once in Crystal and transpiled to each target, the same way application code is. Platform glue (database drivers, WebSocket handlers, HTTP servers) stays hand-written per target. This separation — generated Rails semantics, hand-written platform glue — makes adding new Rails features work across all targets without N implementations.

### Framework targets

The current targets all generate the same architecture: routes → controller functions → model calls → view rendering → HTTP response. But different frameworks organize the request lifecycle differently. Phoenix uses contexts and changesets, Django uses class-based views and its own ORM, Next.js uses file-based routing and server components.

Railcar's analysis phase is framework-agnostic — `AppModel.extract` understands routes, controllers, models, and views as abstract concepts. The full request lifecycle is known at transpile time: which route selects which controller action, which models that action queries, which view it renders. A framework-specific emitter would reorganize these same pieces into the target framework's conventions. The analysis stays the same; the emission changes.

### Single-File Component (SFC) targets

SFC frameworks like Svelte, Vue, and LiveView collapse the controller/view/route separation into a single file. The component IS the route, the data fetching, and the template. This is roughly comparable in effort to adding a new language target — despite sharing underlying language characteristics (e.g., Svelte with TypeScript), the entire rendering model changes:

- String concatenation becomes reactive template syntax (`{expression}`, `{#if}`, `{#each}`)
- Explicit render calls become implicit reactivity
- Partials become components with props
- Server-side HTML patching (Turbo Streams) becomes client-side reactive DOM updates
- Layout wrapping becomes layout components with slots

The AppModel already has the connections needed: which controller action renders which view, which route maps to which action, which variables flow from controller to template. For SFC generation, the emitter follows those connections and merges what were three separate outputs (route, controller, view) into one component file. The first SFC target establishes the patterns; subsequent ones (Svelte → Vue, or → LiveView) reuse them with different syntax.
