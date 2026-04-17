# Developing Railcar

This is the day-to-day reference for working on railcar itself — build commands, debugging tools, recipes. For the bigger picture, see [ARCHITECTURE.md](ARCHITECTURE.md); for user-facing capabilities, see [README.md](README.md).

## Build & test

```bash
make              # builds build/railcar and build/railcar-ast
make test         # runs the full Crystal spec suite
make clean        # removes build/
```

To regenerate a blog target and run its tests:

```bash
# Go
build/railcar --go build/demo/blog /tmp/go-blog
(cd /tmp/go-blog && go mod tidy && go test ./...)

# Python, TypeScript, Elixir, Rust, Crystal — see README "Try it" section
```

The Crystal spec suite runs the full test matrix (parser, translator, filters, emitters, semantic, AstDump) and must pass before any commit. Spec files live in `spec/`; one spec file per major component is the convention.

## Debugging tools

### `railcar-ast` — structural AST dumps

Crystal's standard `to_s` emits re-parseable source (lossy — hides named_args, erases post-semantic types), and `inspect` produces memory addresses. `railcar-ast` is the dev tool that dumps the AST structurally so you can actually see what filters and emitters see.

**Quick examples:**

```bash
# Basic: parse a Ruby snippet, dump the Crystal AST
build/railcar-ast -e '@article.title.downcase'

# After a filter
build/railcar-ast --filter InstanceVarToLocal -e '@article.title'

# Trace a filter chain, one dump per filter
build/railcar-ast --filter InstanceVarToLocal,RailsHelpers --trace -e '@article.title'

# ERB template → Crystal AST (pre-compiles through ErbCompiler)
build/railcar-ast --erb build/demo/blog/app/views/articles/show.html.erb

# Run through program.semantic(), annotate each node with its inferred type
build/railcar-ast --semantic --types -e 'x = "hi"; y = x.size'

# Find all Call nodes in a file
build/railcar-ast --find Call build/demo/blog/app/models/article.rb

# Include source locations (@line:col) on each node
build/railcar-ast --locations -e 'x = 1'
```

**Flag reference:**

| Flag | Purpose |
|------|---------|
| `-e SOURCE` | Inline source to parse (Ruby by default) |
| `path/to/file` | Positional file argument (Ruby .rb or Crystal .cr) |
| `--erb` | Pre-process input through `ErbCompiler` (auto-enabled for `.erb` files) |
| `--parser prism\|crystal` | Override parser choice; default is Prism for Ruby |
| `--filter A,B,C` | Apply a chain of registered filters (comma-separated, in order) |
| `--trace` | With `--filter`, dump the AST after each filter |
| `--semantic` | Wrap in prelude, run through `program.semantic()` |
| `--types` | Annotate each node with `:: TypeName` (requires typed input, e.g. `--semantic`) |
| `--locations` | Annotate each node with `@line:col` |
| `--find CLASSNAME` | Walk the AST and print only nodes of that class (e.g. `Call`, `InstanceVar`) |
| `--help` | Print usage and the list of registered filters |

**Registered filters** (those constructible without configuration — more can be added to `src/cli/ast.cr` as needed):
`InstanceVarToLocal`, `RailsHelpers`, `LinkToPathHelper`, `ButtonToPathHelper`, `RenderToPartial`, `FormToHTML`, `TurboStreamConnect`, `ViewCleanup`, `BufToInterpolation`, `StripTurboStream`, `StripCallbacks`, `RespondToHTML`, `ParamsExpect`, `StrongParams`, `PythonConstructor`, `PythonView`, `TypeScriptView`.

**Common investigation recipes:**

- *"What shape does this ERB template produce after view filters?"*
  `railcar-ast --erb FILE.html.erb --filter InstanceVarToLocal,RailsHelpers,ViewCleanup --trace`

- *"Does semantic analysis type this expression correctly?"*
  `railcar-ast --semantic --types -e 'SNIPPET'`

- *"How many `Call` nodes does this code have, and what do they look like?"*
  `railcar-ast --find Call FILE.rb`

- *"Where exactly does this construct appear in the source?"*
  `railcar-ast --locations FILE.rb`

### `AstDump` from Crystal code

For spec authoring, the same printer is available as `Railcar::AstDump`:

```crystal
require "../src/generator/ast_dump"

dumped = Railcar::AstDump.dump(ast)
dumped = Railcar::AstDump.dump(ast, with_types: true, with_locations: true)
```

Useful when a spec assertion fails and you want to see the actual AST shape rather than squinting at `to_s` output. Typically pair with `puts Railcar::AstDump.dump(ast)` inside a spec during debugging, then remove before committing.

## Adding a new filter

Summary (full detail in [ARCHITECTURE.md](ARCHITECTURE.md#writing-a-new-filter)):

1. Create `src/filters/my_filter.cr` subclassing `Crystal::Transformer`
2. Override `transform` for the node types you care about
3. Add a spec in `spec/filters_spec.cr` or a new file
4. Wire into the appropriate chain in the relevant generator
5. If the filter's constructor takes no arguments, register it in `src/cli/ast.cr`'s `FILTERS` map so `railcar-ast --filter MyFilter` works

## Adding a new spec

One file per component, name-aligned with the source (`my_filter.cr` → `my_filter_spec.cr`). The root `spec/spec_helper.cr` has shared setup. For filter specs, the pattern is:

1. Parse a small Ruby/Crystal snippet via `Railcar::PrismTranslator.translate` or `Crystal::Parser.parse`
2. Apply the filter via `ast.transform(MyFilter.new)`
3. Assert on the result — either via `ast.to_s` for source-level checks, or `Railcar::AstDump.dump(ast)` for structural checks

## Roadmap reference

The planned ordering of architectural work is in the most recent conversation context; high-level shape:

1. Small debt cleanup ✓
2. Extend semantic analysis to views (thesis move)
3. Rails pattern filter breadth (scopes, callbacks, enums, polymorphic)
4. Ruby language breadth (MethodMap rows, more Crystal AST node kinds)
5. Status-section infrastructure (layout transpilation, per-request flash, configurable DB)
6. Generated runtime (write Rails semantics once in Crystal, transpile per target)
7. Framework targets (Phoenix/Django/Next.js) and SFC targets (Svelte/LiveView)

## See also

- [README.md](README.md) — what railcar does and who it's for
- [ARCHITECTURE.md](ARCHITECTURE.md) — pipeline, components, filter pattern
- [ruby2js](https://github.com/ruby2js/ruby2js) — the sibling project this one grew out of
