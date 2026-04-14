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
  .rb files: Prism FFI → PrismTranslator → Crystal AST
  .cr files: Crystal::Parser → Crystal AST
       |
       v
   Shared filter chain (Rails normalization)
       |
       +---> Crystal filters → .to_s → Crystal.format → .cr/.ecr output
       |
       +---> Python filters → PythonEmitter → .py output
```

Crystal AST (`Crystal::ASTNode`) is the canonical intermediate representation. All filters operate on it, regardless of whether the source was Ruby or Crystal, and regardless of the target language.

The shared filters normalize Rails conventions into a target-neutral form. Target-specific filters then handle language differences (constructor syntax, error handling, property vs method access). The emitter serializes the final AST to the target language's source code.

### Semantic analysis

Railcar can optionally run Crystal's type inference engine on the translated AST. This is used by the RBS generator to determine method return types and instance variable types without executing the code.

The semantic phase requires Crystal's standard library (prelude) but **not** LLVM. Railcar provides LLVM stubs (`stubs/llvm/`) that shadow the standard library's LLVM bindings, allowing semantic analysis to run with no LLVM dependency. This reduces binary size from ~100MB+ to ~28MB.

The pipeline for semantic analysis:

```
Ruby source
    |
    v
PrismTranslator → Crystal AST (with source locations)
    |
    v
Filter chain (RespondToHTML, etc.) → valid Crystal AST
    |
    v
Combine: prelude + model stubs + controller AST
    |
    v
Crystal semantic analysis → typed AST
    |
    v
Read inferred types (method returns, instance variables)
```

Model stubs are generated from AppModel metadata (schemas, associations) and provide typed signatures so Crystal can infer types through method calls like `Article.find(id)` → `Article`.

## Key components

### PrismTranslator (`src/generator/prism_translator.cr`)

Mechanical translation from Prism AST nodes to Crystal AST nodes. This is a dumb syntax mapper -- it knows nothing about Rails. `Prism::CallNode` becomes `Crystal::Call`, `Prism::DefNode` becomes `Crystal::Def`, and so on.

### SourceParser (`src/generator/source_parser.cr`)

Routes `.rb` files through PrismTranslator and `.cr` files through Crystal's own parser. Both produce `Crystal::ASTNode`. The rest of the pipeline doesn't know or care which parser was used.

### Filters (`src/filters/`)

Each filter is a `Crystal::Transformer` subclass that pattern-matches on AST nodes and rewrites them. Filters are composable -- they run in sequence, each receiving the output of the previous one.

**Shared controller filters** (used by both Crystal and Python targets):

| Filter | What it does |
|--------|-------------|
| `InstanceVarToLocal` | `@article` → `article` |
| `ParamsExpect` | `params.expect(:id)` → `id` |
| `RespondToHTML` | Extracts `format.html { ... }` from `respond_to` blocks |
| `StrongParams` | `Article.new(article_params)` → `Article.new(extract_model_params(...))` |

**Crystal-specific controller filters** (applied after shared filters):

| Filter | What it does |
|--------|-------------|
| `RedirectToResponse` | `redirect_to @article` → status 302 + Location header + flash |
| `RenderToECR` | `render :new` → `response.print(layout { ECR.embed(...) })` |
| `ControllerSignature` | Adds typed parameters, inlines `before_action`, appends view rendering |
| `ControllerBoilerplate` | Injects `include` statements, helper methods, partial renderers |
| `ModelNamespace` | `Article` → `Railcar::Article` |

**Model filters:**

| Filter | What it does |
|--------|-------------|
| `BroadcastsTo` | Converts `broadcasts_to`/`after_*_commit` to broadcast calls |
| `ModelBoilerplate` | Wraps body in `model("table") { columns + declarations }`, adds validations |

**Python controller filter** (applied after shared filters instead of Crystal-specific ones):

| Filter | What it does |
|--------|-------------|
| `ControllerBoilerplatePython` | Transforms Rails controller class into async handler functions: inlines before_actions (using shared `ControllerExtractor` records), transforms redirects to `web.HTTPFound`, renders to `web.Response`, handles nested resources |

**Python view filters** (applied to ERB-compiled AST):

| Filter | What it does |
|--------|-------------|
| `FormToHTML` | `form_with model: @article` → HTML form tags with `_buf` operations |
| `PythonConstructor` | `Article.new(...)` → `Article(...)` |
| `PythonView` | Bare calls → vars, `.size` → `len()`, `.any?`/`.present?` → truthy, `content_for` → assignment, `button_to` data hash flattening |
| `ViewCleanup` | `_buf.append= expr.to_s` → `_buf += str(expr)`, extracts `.each` blocks from `_buf` wrappers |
| `BufToInterpolation` | Consolidates consecutive `_buf +=` into f-string interpolation, strips redundant `str()` |

**Python test filter:**

| Filter | What it does |
|--------|-------------|
| `MinitestToPytest` | Rails Minitest → pytest: `test "name"` → `def test_name`, `assert_equal` → `assert ==`, integration test patterns (aiohttp client) |

**View filters** (shared, applied to template AST before ERBConverter or PythonEmitter):

| Filter | What it does |
|--------|-------------|
| `InstanceVarToLocal` | `@article` → `article` |
| `TurboStreamConnect` | Converts `turbo_stream_from` to `turbo-cable-stream-source` element |
| `RailsHelpers` | `present?` → truthy, `count` → `size`, `dom_id` symbols → strings |
| `LinkToPathHelper` | `link_to("Show", @article)` → `link_to("Show", article_path(article))` |
| `ButtonToPathHelper` | Same for `button_to`, including nested resource arrays |
| `RenderToPartial` | `render @articles` → `articles.each { render_article_partial(article) }` |

Filter order matters. Each filter's documentation notes its dependencies.

### ERBConverter (`src/generator/erb_converter.cr`)

Converts ERB/ECR templates to Crystal ECR output. After view filters have transformed the AST, the converter handles only structural concerns: walking the `_buf`-based AST from ErbCompiler and emitting `<% %>` and `<%= %>` tags. It has no Rails-specific knowledge.

The `ErbCompiler` extracts code from `<% %>` tags into Ruby/Crystal source. This works identically for `.erb` and `.ecr` input since the tag syntax is the same.

### Python Emitter (`src/emitter/python/`)

A two-stage Crystal AST → Python pipeline:

1. **Cr2Py Emitter** (`cr2py.cr`) -- walks typed Crystal AST nodes and produces PyAST nodes. Two-method approach: `to_nodes()` for statement context, `to_expr()` for expression context. Uses TypeIndex for property detection (method vs attribute access) and `model_columns` for untyped variable fallback.

2. **PyAST** (`py_ast.cr`) -- minimal Python AST with structural indentation: `Func`, `Class`, `If`, `For`, `While`, `Try`, `BufLiteral`, `BufAppend`, `Assign`, `Statement`, `Return`. The serializer handles Python-correct indentation without `end` keywords.

3. **PyAST Filters** (`filters/`) -- post-emission transforms:
   - `ReturnFilter` -- adds implicit returns to function bodies
   - `DunderFilter` -- adds `__bool__`/`__len__` methods
   - `AsyncFilter` -- marks controller/test functions as `async`, adds `await`
   - `DbFilter` -- Crystal DB API → Python sqlite3 patterns

4. **TypeIndex** (`type_index.cr`) -- flat lookup table built from `program.types` after semantic analysis, providing instance var and class var resolution with inheritance.

### AppGenerator / Python2Generator

**AppGenerator** (`src/generator/app_generator.cr`) orchestrates Crystal output.

**Python2Generator** (`src/generator/python2_generator.cr`) orchestrates Python output layer by layer:
1. **Build** -- parse Rails models, apply ModelBoilerplatePython filter
2. **Compile** -- combine Crystal runtime + models, run `program.semantic()` for type info
3. **Emit** -- extract typed nodes, emit each layer through Cr2Py emitter + PyAST filters:
   - Runtime (hand-written Python, not transpiled)
   - Helpers (transpiled Crystal + hand-written route/form helpers)
   - Models (transpiled with COLUMNS/TABLE constants)
   - Controllers (Crystal AST filters → emitter → async filter)
   - Views (ERB → Crystal AST → view filter chain → emitter)
   - Tests (MinitestToPytest → emitter → async filter)
   - App entry point, static assets (hand-written)

### Runtime

**Crystal** (`src/runtime/`): A Crystal ORM mirroring ActiveRecord -- base model class with macros, Relation query builder, CollectionProxy, view helpers.

**Python** (`src/runtime/python/`):
- `base.cr` -- Crystal source used only for `program.semantic()` type checking (not emitted)
- `base_runtime.py` -- hand-written Python runtime using COLUMNS + `setattr` for direct attribute access. Includes ApplicationRecord, ValidationErrors, CollectionProxy, MODEL_REGISTRY.
- `helpers.cr` -- Crystal source for helper functions, transpiled to Python via emitter

### RBS Generator (`src/generator/rbs_generator.cr`)

Generates RBS type signature files for Rails apps. Uses Crystal's semantic analysis to infer:
- Method return types (e.g., `def set_article: Article`)
- Instance variable types (e.g., `@article: Article?`)
- Nullable types from union inference (e.g., `Article | Nil` → `Article?`)

Generates Crystal stub classes from AppModel metadata (schema column types, model associations, controller methods) and feeds them alongside Prism-translated controller bodies to Crystal's type inference engine.

### LLVM Stubs (`stubs/llvm/`)

A local shard that shadows Crystal's standard library LLVM bindings. Provides type declarations for `LLVM::CallConvention`, `LLVM::TargetMachine`, and other types that Crystal's semantic phase references at compile time but never exercises at runtime. Installed via `shards install` as a path dependency.

### Extractors (`src/generator/*_extractor.cr`)

Parse Rails source files to extract metadata used by the pipeline:

- **SchemaExtractor** -- migrations → table schemas and column types
- **ModelExtractor** -- model files → associations, validations
- **ControllerExtractor** -- controllers → actions, before_actions
- **RouteExtractor** -- config/routes.rb → route definitions

This metadata is collected into `AppModel`, a language-agnostic intermediate representation that filters can reference.

### Inflector (`src/generator/inflector.cr`)

Rails-compatible singularize/pluralize/classify, ported from the shared ruby2js/juntos inflector. Includes irregular words (person/people, child/children) and uncountable nouns (sheep, equipment).

## Writing a new filter

To add support for a new Rails pattern:

1. Create a file in `src/filters/`, e.g., `src/filters/my_filter.cr`
2. Subclass `Crystal::Transformer` and override `transform` for the node types you need
3. Add tests in `spec/filters_spec.cr` or a new spec file
4. Wire it into the appropriate chain in `AppGenerator`

Here's a minimal example:

```crystal
require "compiler/crystal/syntax"

module Railcar
  class MyFilter < Crystal::Transformer
    def transform(node : Crystal::Call) : Crystal::ASTNode
      if node.name == "old_pattern"
        # Return a new AST node
        Crystal::Call.new(node.obj, "new_pattern", node.args)
      else
        # Recurse into children for non-matching nodes
        node.obj = node.obj.try(&.transform(self))
        node.args = node.args.map(&.transform(self).as(Crystal::ASTNode))
        node.block = node.block.try(&.transform(self).as(Crystal::Block))
        node
      end
    end
  end
end
```

The existing filters in `src/filters/` range from 33 to 196 lines. Most are under 100 lines. Start with a small, focused transformation and add complexity as needed.

## Crystal AST serialization

Crystal's `ToSVisitor` uses method overloading, which requires concrete types at compile time. Programmatically constructed AST trees store children as abstract `Crystal::ASTNode`, which the visitor can't dispatch on.

We patch this with a single overload in `src/generator/crystal_expr.cr`:

```crystal
class Crystal::ToSVisitor
  def visit(node : Crystal::ASTNode)
    node.accept(self)
    false
  end
end
```

This enables runtime dispatch for abstract-typed children. It's a minimal, non-breaking change. The patch could be contributed upstream to make programmatic AST construction a supported use case.

## Adding a new target language

To add a new target (e.g., TypeScript, Go):

1. **Write an emitter** (`src/emitter/typescript/`) -- serialize Crystal AST to the target syntax (optionally via an intermediate AST like PyAST)
2. **Write language-specific filters** (`src/filters/typescript_*.cr`) -- handle constructor syntax, error handling, redirect/render patterns
3. **Write a generator** (`src/generator/typescript_generator.cr`) -- orchestrate the pipeline: parse → shared filters → language filters → emitter → output
4. **Write a hand-written runtime** -- HTTP server, ORM, WebSocket (the Crystal runtime provides types for semantic analysis; each target gets its own idiomatic runtime)
5. **Write a test adapter** -- convert Minitest assertions to the target test framework

The shared infrastructure:
- **9 Crystal AST filters** (InstanceVarToLocal, ParamsExpect, RespondToHTML, StrongParams, RailsHelpers, LinkToPathHelper, ButtonToPathHelper, RenderToPartial, BroadcastsTo) handle Rails normalization and are reusable across all targets
- **Rails DSL detection** (`src/filters/rails_dsl.cr`) -- shared set of Rails model/controller DSL call names
- **ControllerExtractor** -- extracts BeforeAction records, consumed by both Crystal and Python controller filters
- **AppModel** -- language-agnostic IR (schemas, models, controllers, routes, fixtures)

Semantic type information from Crystal's type checker can inform the emitter (see `spec/python_semantic_spec.cr` for the proven approach).

## Testing

```bash
make test     # runs all Crystal specs (321)
crystal spec spec/filters_spec.cr   # run a specific spec file
```

CI also generates the Python blog and runs its 21 pytest tests.

Crystal tests are organized by component:

| File | What it tests |
|------|--------------|
| `inflector_spec.cr` | Pluralization, singularization, classify, underscore |
| `translator_spec.cr` | Prism → Crystal AST translation |
| `filters_spec.cr` | Individual filters and pipeline integration |
| `view_filters_spec.cr` | View-specific filters (link_to, render, etc.) |
| `source_parser_spec.cr` | .rb/.cr routing |
| `erb_spec.cr` | Template conversion |
| `generator_spec.cr` | Schema extraction, model generation |
| `controller_spec.cr` | Controller extraction |
| `route_spec.cr` | Route extraction |
| `models_spec.cr` | Runtime model CRUD and validations |
| `prism_spec.cr` | Prism FFI bindings |
| `semantic_spec.cr` | LLVM stub + Crystal type inference |
| `semantic_prism_spec.cr` | Full pipeline: Ruby → Prism → Crystal AST → semantic → inferred types |
| `python_semantic_spec.cr` | Crystal type inference for Python emission |

Python tests are generated alongside the Python app and run via pytest:

| File | What it tests |
|------|--------------|
| `test_article.py` | Article model CRUD, validations, dependent destroy |
| `test_comment.py` | Comment model, associations, FK validation |
| `test_articles_controller.py` | Articles CRUD endpoints, redirects, form handling |
| `test_comments_controller.py` | Comments create/destroy endpoints |

The `make test` target downloads a sample Rails blog app to `build/demo/blog/` for integration testing.
