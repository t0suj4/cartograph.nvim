# cartograph.nvim

> A dependency/definition **cockpit** for Neovim — navigate a codebase's symbol
> graph, and stage multi-file **function moves** that respect references and
> load order.

**Status:** early / experimental. Design in flux.

## Why

Editors expose the dependency graph one query at a time — a rename box, a
references popup, a flat symbol outline. None of them give you a *place to see
the structure and stage a change against it*. cartograph is that missing layer:
a focus+context view over the symbol graph, plus a staging surface for
relocations.

The guiding principle: **the unit of attention is one node and its edges, and
navigation is re-rooting.** Never the whole graph (a hairball at any real
scale), never a context-free list.

## Shape

A cockpit of independent panes over a shared state store:

- **symbols** — the current file's definitions, in source order
- **source** — the real code at the focused location (def, or a call site),
  splittable to compare the two
- **dependencies** — the hovered symbol's uses / used-by tree
- **minimap** — its 1-hop neighborhood, cyclable (`<Tab>`) through a few
  perspectives including **data flow**: the statement-level local def-use *inside*
  the focused function (a zoom below the symbol layer), with an **untangle lens** —
  statements are grouped/coloured by independent concern and scored for how
  interleaved those concerns are (`tangle`). Comprehension only — locals, not
  control/aliasing, so it reveals tangle and makes no safety/reorder claim.
- **plan** — the staged move set and its computed impact (references to
  rewrite, imports to fix) and hazards (scope coupling, load order)

### Staging a move

Moving a function is modelled as **cut & paste**, so the keys are the ones you
already know. In the **symbols** list:

- `dd` — cut (stage) the function under the cursor into the move-set; `dd` again
  un-cuts it. In visual mode, `d` cuts the selected functions.
- `p` — paste: set the destination to the file under the cursor.
- `u` — unstage the last cut.

The **plan** bar updates live — staged symbols, call sites to rewrite, requires
to add, and hazards. Nothing is written yet: the plan *describes* the move
(preview-then-apply is the next step, and `p` will become the commit).

## Architecture (three seams)

1. **GraphProvider** — supplies `nodes{id,name,kind,file,range,order}` and
   `edges{from,to,kind}`. First provider is Lua (via lua-language-server);
   a generic-LSP provider makes the navigator language-agnostic.
2. **ImpactEngine** — `(nodeSet, target, op) -> {edits, hazards}`. Move-first,
   Lua-first. Preview the diff before it touches a file — never a silent edit.
3. **Panes/Store** — panes are independent widgets that subscribe to a shared
   store; a *layout* is a composition of panes. Layouts are meant to be
   swappable/customizable.

## Ledger reconstruction

The inverse of the ImpactEngine: instead of predicting a move's edits, recover
what a series of edits *did* to the structure. `reconstruct.run{repo, from, to}`
extracts the symbol graph at each commit in a range and diffs consecutive
snapshots into a per-commit structural ledger — added / removed / renamed
symbols and reference-edge changes, each classified (`extract`, `rename`,
`inline`, `rewire`, `restructure`, `internal`). Graphs are cached by commit sha.

Node identity across snapshots is `(file, name, kind)`, not the node id (which
embeds a line number and shifts as code moves). It sees *structural* change
only: commits that transform code *inside* a function (hoist to upvalue, reorder
args, closure→iterator) show up as `internal` — a real, deliberate limit of the
named-symbol graph.

## Tests

```sh
./tests/run.sh
```

A dependency-free runner (`nvim --headless`, no plenary). `tests/*_spec.lua`
use the globals `test` / `eq` / `ok` / `skip`. The store classifier is covered
with in-memory graphs via `store.ingest`; the extractor's load-time `effects`
detection is covered by a golden test that runs the real `--graph` CLI over
`tests/fixtures/effects` (self-skips if the CLI isn't installed).

## License

TBD
