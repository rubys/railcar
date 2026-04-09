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
   Filter chain (Crystal::Transformer subclasses)
       |
       v
   Serialization (.to_s or ERBConverter for templates)
       |
       v
   Crystal.format (validation + normalization)
       |
       v
   Output file (.cr or .ecr)
```

Crystal AST (`Crystal::ASTNode`) is the canonical intermediate representation. All filters operate on it, regardless of whether the source was Ruby or Crystal.

## Key components

### PrismTranslator (`src/generator/prism_translator.cr`)

Mechanical translation from Prism AST nodes to Crystal AST nodes. This is a dumb syntax mapper -- it knows nothing about Rails. `Prism::CallNode` becomes `Crystal::Call`, `Prism::DefNode` becomes `Crystal::Def`, and so on.

### SourceParser (`src/generator/source_parser.cr`)

Routes `.rb` files through PrismTranslator and `.cr` files through Crystal's own parser. Both produce `Crystal::ASTNode`. The rest of the pipeline doesn't know or care which parser was used.

### Filters (`src/filters/`)

Each filter is a `Crystal::Transformer` subclass that pattern-matches on AST nodes and rewrites them. Filters are composable -- they run in sequence, each receiving the output of the previous one.

**Controller filters** (applied in this order):

| Filter | What it does |
|--------|-------------|
| `InstanceVarToLocal` | `@article` → `article` |
| `ParamsExpect` | `params.expect(:id)` → `id` |
| `RespondToHTML` | Extracts `format.html { ... }` from `respond_to` blocks |
| `StrongParams` | `Article.new(article_params)` → `Article.new(extract_model_params(...))` |
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

**View filters** (applied to template AST before ERBConverter):

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

### AppGenerator (`src/generator/app_generator.cr`)

Orchestrates the full generation pipeline. For each file type (model, controller, template, route, test), it:
1. Parses the source
2. Applies the appropriate filter chain
3. Wraps in module/require structure
4. Serializes and writes the output

### Runtime (`src/runtime/`)

A Crystal ORM that mirrors ActiveRecord, used by the generated application:

- **ApplicationRecord** -- base model class with CRUD, validations, associations via macros
- **Relation** -- chainable query builder (where, order, limit, includes)
- **CollectionProxy** -- has_many association proxy (build, create, destroy_all)
- **Helpers** -- route path helpers, view helpers (link_to, form tags), parameter parsing

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

## Testing

```bash
make test     # runs all 240 specs
crystal spec spec/filters_spec.cr   # run a specific spec file
```

Tests are organized by component:

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

The `make test` target downloads a sample Rails blog app to `build/demo/blog/` for integration testing.
