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

- **symbols** — a zoomable *altitude browser*: `l` (or `<CR>`) descends, `h`
  ascends — sideways is free in a linear list, so it becomes altitude.
  Top level is the **file tree** (one row per file, with usage-classification
  gutter signs). Inside a file, runs of top-level statements between function
  definitions roll up into **blocks** (`≡`, named by their first source line
  — a constants preamble reads as one row); a block descends into its
  declarations. `<Tab>` toggles the top level between the flat list and the
  **include tree** — files nested under whoever requires them, roots being
  the entry points nothing requires; a file already shown appears dim with
  `…` instead of expanding again (require-cycle safe). **Entry points** are
  first-class: files matching `setup{ entrypoints = {...} }` patterns
  (defaults cover the Factorio lifecycle — `control.lua`, `data.lua`,
  `settings.lua`, the `-updates`/`-final-fixes` variants — plus `main.lua`)
  get a `▶` sign instead of the `○` orphan warning, and sort first among
  the tree's roots; a file opens into **all its definitions** in source order —
  functions, methods, *and* module-level vars/fields, so the whole file is
  navigable; a function opens into its **statement-level locals** (from the
  data flow), where hovering a row highlights the real line in the source
  pane. At the file level the cursor row is the focus, and staging lives here.

  Below the fn level, descend keeps going **into the graph**, acting on the
  name under the cursor: statement rows name their calls (`→ callee`) and
  the module vars / globals they read (`· var`), so `l` on a callee follows
  the call into that function (recorded in the jumplist — `<C-o>` walks
  back), and on a var it opens that var's usage sites; on a **parameter**
  it opens the origin trace; on a **local** it jumps to the defining
  statement; with no name targeted it follows the statement's only
  resolvable call. A **var** row
  descends into its usage sites (every function that reads it, from the
  extractor's `use` edges) — hovering a site shows the read in the
  source pane, and descending enters the reading function. A var holding a
  **literal table** descends into the data itself: entries as rows (scalars
  show their value, nested tables keep descending, a `→ name` reference
  follows to that var), hover highlighting the entry's line in the
  declaring table. Non-literal elements (`unpack(...)`, calls, functions)
  stay visible as honest text rows instead of silently vanishing.

  Inside a function, the `↖ callers (N)` row descends into the **call
  sites**: one row per call, hover shows the caller's code with the call
  highlighted in the source pane, descend enters the caller. **Self
  references are distinct** in every sites view: external sites first, then
  an inert `── self ──` separator, then the entity's own sites with the
  class prefix stripped (`.get`, `:trigger`) — position carries the
  meaning, so nothing is dimmed. The header shows the split
  (`used by (2 + 140 self)`), and recursion is marked `⟳`. Edges vm-typed resolution
  can't see — a method called on an instance fetched out of a storage table
  (the Factorio pattern) — are recovered by **unique method name** and
  marked `~`: honest, but name-matched rather than type-proven. Ambiguous
  names refuse to link rather than guess.
- **source** — the real code, taking the full width and height beside the
  browser. It shows the focused body; hovering a call site / var read /
  trace origin **temporarily takes over the pane** (the site's function,
  its line highlighted, auto-scrolled) and the focused body returns when
  the hover clears. One window, two moments.
`<Tab>` in the code pane toggles the **flow lens**: statements are grouped by
independent concern (from the statement-level local def-use) and the source
lines are **coloured by concern**, with the tangle metrics on the header line.
Comprehension only — locals, not control/aliasing, so it reveals tangle and
makes no safety/reorder claim.

### Configuration

Every binding is remappable (defaults assume qwerty; dvorak/colemak users can
rebind anything without touching pane code):

```lua
require('cartograph').setup {
    keys = { jump = '<C-j>', back = '<C-h>' },  -- names in lua/cartograph/config.lua
}
```

### Navigation

All standard vim idioms — no new keys to learn:

- `<C-]>` — **in the source pane**, jump to the definition of the call under
  the cursor (resolved from the graph's recorded call sites, with a
  word-match fallback). In the tree pane it pivots like `<CR>`.
- `<C-o>` / `<C-t>` — go **back** to where the last pivot happened; `<C-i>`
  goes forward again. Vim-jumplist semantics: deliberate pivots record,
  scrolling the symbol list doesn't. (`<C-i>` is bound only where `<Tab>`
  isn't the lens toggle, since most terminals can't tell them apart.)
- `gf` — **leave the cockpit**: open the real file at the corresponding line
  (in a reused tab), from the source, symbols, or tree pane.
- **The view follows the eye; focus follows intent.** In the browser,
  moving the cursor *tints* relationships (dependencies green, dependents
  amber) and *previews* the row in the source pane (a temporary takeover,
  restored when you move off) — but it never re-roots the cockpit: no
  focus change, no history entry, no re-scoping. `<CR>` pivots (focus
  without changing altitude); `l` descends (and pivots where that means
  entering something). Reading is free; commitment is a keypress.
- **History restores places, not just symbols.** Every pivot snapshots the
  browser's location — level, file, cursor row — so `<C-o>` puts you back
  *where you were standing*, mid-exploration, not merely on the symbol you
  had focused.
- **`h` returns the way you came — and `l` returns the way you left.**
  Descending keeps a trail: entering a caller from the callers list, `h`
  goes back to that list (on the row you left), not to the caller's file.
  And `h` remembers where it came *from*: leave a function body at row 7,
  and `l` on that function drops you back on row 7 — bounce `h`/`l` freely
  without losing your place. Descending somewhere *else* branches, which
  clears the forward memory. Structural ascent (fn → file → files) is the
  fallback for places you *jumped* into (`<C-]>` starts a fresh journey).

### Tracing a parameter

`gr` on a parameter name in the source pane answers *"where does this value
come from?"* — an origin tree with one row per call site, showing what each
site passes: a literal (the answer), another function's parameter, a local, a
call result, a field. `<CR>` expands a row **incrementally**: a param origin
climbs to *its* callers, a call origin traces through the target's `return`
statements, a local origin steps to its defining statements and the locals
*they* read. You steer the fan-out; nothing explodes eagerly.

Frontiers are honest and labelled instead of silently dropped: a table field
(writes can alias from anywhere), a global, varargs, a computed expression, a
dynamically-dispatched function (e.g. an event handler — "no resolved call
sites"). Hovering a row shows the origin's code in the **source pane**
with the origin line highlighted (the same pattern as hovering the dependency
tree); `gf` jumps to its real file; `<C-]>` pivots the cockpit to its
function; the trace opens in its own right-hand split, and `q` closes it.

Powered by extractor-side classification: call arguments (`argv`) and `return`
values are classified (literal / param / local / call / field / …), calls carry
their resolved target, and function nodes carry their parameter lists (implicit
`self` included, so method-call argv positions line up).

`:CartographHeat` (from the symbols pane) toggles a **hub/heat overlay**: each
symbol is annotated with fan-in / fan-out and a role — `hub` (many callers,
load-bearing), `coordinator` (calls many), `leaf`, `api` (exported, no static
caller — public surface, *not* dead), `unused?` (a local with no caller), or
`isolated`. A quick map of where a module's weight sits.
- **plan** — the staged move set and its computed impact (references to
  rewrite, imports to fix) and hazards (scope coupling, load order)

### Extracting a function

In the **source** pane, visually select whole statements and run
`:'<,'>CartographExtract <name>`. The engine computes the new function's
parameters (locals read but defined before the selection) and return values
(locals defined in the selection and used after it) from the data-flow, shows a
**preview** in the source pane, and writes to disk only after you confirm.

It is deliberately conservative: it works on **whole top-level statements** and
**refuses** a selection that cuts a loop/branch body or contains a
`return`/`break`/`goto`. It cannot see non-local (table/global) state, so that
risk is disclosed as a hazard on the preview rather than silently assumed away —
verify those by eye. After applying, regenerate the graph dump to refresh the
cockpit.

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

### Browsing the state machine

`:CartographStates` opens the FSM as an altitude: states as rows (each with
its **reachability cone** size — how many functions can run while the machine
is there), a state descending into its outgoing transitions (`→ finalize ⇒
finalizing`, followable with `l`) and its **active entry points** — the
listeners subscribed in that state and the FSM callbacks its transitions can
fire — each descending into the code.

The domain semantics live in a ~10-line declarative adapter
(`setup{ fsm = { events = { var = 'landing_states', path = {'events'} },
subs = { var = 'state_subs' }, callbacks = { var = 'launch_callbacks' },
register = 'register_listener' } }`): which data table is the transition
spec, which maps state → subscriptions, which table holds the callbacks
(lua-state-machine naming conventions), and the register verb. Everything
else is generic: the extractor captures **literal data tables** (nested
strings/numbers, `{ref='name'}` for named indirections like a shared
ticking spec), names **anonymous functions registered under a string key**
(`register_listener("handle_x", function() … end)` becomes node
`handle_x`, with real call-graph edges), and the reachability cone is a
plain BFS. Unresolvable handlers are honest frontiers, labelled.

### WoW addons: the .toc manifest

When the workspace root holds a `.toc` file, cartograph reads it as what it
is — the addon's **load-order manifest**. The ordered file list (flattened
through the XML `<Script>`/`<Include>` chains, backslashes and case
differences resolved) becomes the project structure:

- the files view shows each file's **load position**; `<Tab>`'s tree is the
  load order itself (XML includes indented), closed by a
  `── never loaded ──` section for Lua files no manifest path reaches;
- classification is exact: listed files are quiet, unlisted files are
  genuine orphans — they never load (on a shipped addon this found two
  localization files missing from the manifest);
- **load-order lint**: a load-time call into a file that loads *later* hits
  nil — the classic addon bug — plus listed-but-missing files;
- XML handler references (`function="X"` attributes, inline
  `<OnClick>Foo()</OnClick>` bodies) are engine entry points, exempted from
  dead-function.

**Cross-addon ordering.** When the addon sits in an AddOns folder, the
folder is modelled too: every sibling manifest's `## Dependencies` /
`## OptionalDeps` builds the client's real load order (alphabetical with
dependencies promoted, LoadOnDemand addons held back). The lint then knows
things one addon can't: a **required dependency that isn't installed**
(the addon will not load), a **dependency cycle** (the client disables
both), and — where sibling addons have extracted dumps to testify — a
**load-time call into an undeclared sibling**: nothing guarantees who
loads first, so it works or nils by alphabet. Honest scope: no sibling
dump, no claim.

## Lint

`:CartographLint` runs graph-aware, whole-program checks and drops the findings
into the quickfix list. Not a luacheck replacement — it makes the *cross-file*
checks luacheck can't:

- **dead-function** — a *local* function with no caller anywhere (exported
  functions and metamethods are excluded — public/dynamically-dispatched surface
  isn't dead).
- **redundant-require** — a pure module `require`d only for effect, but it has
  none, so the require does nothing.
- **call-cycle** — mutual recursion / cyclic call clusters (plain self-recursion
  is not flagged). Structural, and a load-order signal.
- **swallowed-type** — every `~` (name-inferred) call betrays a receiver whose
  class was laundered to `unknown`, usually through an untyped container.
  Findings point at the **root cause**: when the receiver comes from a getter
  of the same class, one finding says `---@return CLASS` *on the getter* —
  fixing every caller at once (on a real mod: 32 name-only calls → one
  finding). `:CartographLintFix` on the quickfix entry inserts the annotation.
- **listener-audit** — for a wiretap-style paired API (`register_listener` /
  `subscribe` / `unsubscribe`, keyed by a listener-name argument): flags
  subscribe/unsubscribe to an unregistered name (a runtime error), a listener
  registered but never subscribed, one subscribed but never unsubscribed
  (leak-prone), and registration inside a function rather than at load
  (register-after-init risk). Honest: a *dynamic* subscribe/unsubscribe (name
  from a variable) suppresses the dead/leak checks, since it could cover any
  name. Configurable via `lint.listener_config`; generalises to lock/unlock,
  open/close — any argument-keyed acquire/release.

Structural smells, not proofs — dynamically-invoked functions (event handlers,
test cases run by a harness) can still read as "no caller". Rules live in
`lint.lua` and are pure/testable.

## Offline: history archaeology

A sibling tool that lives under `cartograph.history` and runs *outside* the live
cockpit — it reads git history rather than the current buffer, and produces
reports rather than driving panes. It shares the cockpit's graph extractor (one
dump per commit, cached by sha) but nothing else, so it stands on its own:

```lua
local history = require 'cartograph.history'
history.reconstruct.run{ repo = '…', from = 'HEAD~50', to = 'HEAD' }
history.couplingmine.run{ repo = '…', from = 'HEAD~50', to = 'HEAD' }
```

### Ledger reconstruction

The inverse of the ImpactEngine: instead of predicting a move's edits, recover
what a series of edits *did* to the structure. `history.reconstruct.run{repo, from, to}`
extracts the symbol graph at each commit in a range and diffs consecutive
snapshots into a per-commit structural ledger — added / removed / renamed
symbols and reference-edge changes, each classified (`extract`, `rename`,
`inline`, `rewire`, `restructure`, `internal`). Graphs are cached by commit sha.

Node identity across snapshots is `(file, name, kind)`, not the node id (which
embeds a line number and shifts as code moves). It sees *structural* change
only: commits that transform code *inside* a function (hoist to upvalue, reorder
args, closure→iterator) show up as `internal` — a real, deliberate limit of the
named-symbol graph.

### Temporal coupling

`history.couplingmine.run{repo, from, to}` attributes each commit's changed lines to the
functions whose ranges they fell in (at *that* commit), then accumulates
co-occurrence across the range. The output is **change coupling**: functions
that keep changing together even when no static reference edge links them —
hidden coupling the symbol graph alone can't see. Validated on the LuaLS
`script/vm` history, where it surfaced compiler↔sign/generic-resolution coupling
that is architecturally real but statically invisible.

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
