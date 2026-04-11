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

**Python controller filters** (applied after shared filters instead of Crystal-specific ones):

| Filter | What it does |
|--------|-------------|
| `PythonConstructor` | `Article.new(...)` → `Article(...)` |
| `PythonRedirect` | `redirect_to @article` → `raise web.HTTPFound(article_path(article))` |
| `PythonRender` | `render :new` → `return web.Response(text=layout(render_new(...)))` |

**Python view filter:**

| Filter | What it does |
|--------|-------------|
| `PythonView` | Converts `_buf` patterns, bare calls → vars, `.size` → `len()`, `.any?`/`.present?` → truthy, `content_for` → assignment, `button_to` data hash flattening |

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

### PythonEmitter (`src/generator/python_emitter.cr`)

Serializes Crystal AST to Python source. The Python counterpart of Crystal's built-in `.to_s()`. Handles:
- Indentation-based blocks (no `end`)
- `_buf` string-building patterns for views (`_buf.append=` → `_buf += str(...)`)
- Property vs method access (type-aware: uses semantic analysis `.type?` or AppModel metadata)
- Python reserved word handling (`class` → `class_`)
- f-strings for string interpolation
- `raise` as statement (not function)

### AppGenerator / PythonGenerator

**AppGenerator** (`src/generator/app_generator.cr`) orchestrates Crystal output. **PythonGenerator** (`src/generator/python_generator.cr`) orchestrates Python output, delegating to:
- **PythonControllerGenerator** -- transpiles controllers through shared + Python filters, handles structural transformation (class → async functions, routing, before_action inlining)
- **PythonViewGenerator** -- transpiles ERB through ErbCompiler → shared filters → PythonView filter → PythonEmitter, producing string-building functions
- **PythonTestGenerator** -- converts Minitest to pytest (fixtures, assertions, async HTTP client)

For each file type, the generator:
1. Parses the source
2. Applies the appropriate filter chain
3. Wraps in target-specific structure
4. Serializes and writes the output

### Runtime (`src/runtime/`)

A Crystal ORM that mirrors ActiveRecord, used by the generated application:

- **ApplicationRecord** -- base model class with CRUD, validations, associations via macros
- **Relation** -- chainable query builder (where, order, limit, includes)
- **CollectionProxy** -- has_many association proxy (build, create, destroy_all)
- **Helpers** -- route path helpers, view helpers (link_to, form tags), parameter parsing

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

To add a new target (e.g., Go, Elixir):

1. **Write an emitter** (`src/generator/go_emitter.cr`) -- serialize Crystal AST to the target syntax
2. **Write language-specific filters** (`src/filters/go_*.cr`) -- handle constructor syntax, error handling, redirect/render patterns
3. **Write a generator** (`src/generator/go_generator.cr`) -- orchestrate the pipeline: parse → shared filters → language filters → emitter → output
4. **Write infrastructure generators** -- HTTP server, routing, ORM, WebSocket support
5. **Write a test adapter** -- convert Minitest assertions to the target test framework

The shared filters (InstanceVarToLocal, ParamsExpect, RespondToHTML, StrongParams, RenderToPartial, LinkToPathHelper, ButtonToPathHelper) handle Rails-specific normalization and are reusable across all targets. They provide ~50% of the transformation work.

Semantic type information from Crystal's type checker can inform the emitter (see `spec/python_semantic_spec.cr` for the proven approach).

## Testing

```bash
make test     # runs all Crystal specs (~247)
crystal spec spec/filters_spec.cr   # run a specific spec file
```

CI also generates the Python blog and runs its 20 pytest tests.

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
