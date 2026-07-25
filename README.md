# cartograph.nvim

> Maps you can edit. A keyboard-driven Smalltalk-style browser over your
> codebase's symbol graph — plus **transactions**: merge clones, move
> functions, extract modules, previewed as diffs, applied through a journal,
> undone byte-exact.

**Status:** experimental. Working and tested (166-test suite, validated on
corpora from WordPress to GitLab), but the design is still moving — commands,
keys and APIs may change without notice. The edit verbs are journaled with
byte-exact undo, so mistakes are recoverable; still, treat it accordingly.

## Install

```lua
-- lazy.nvim
{
  't0suj4/cartograph.nvim',
  dependencies = { 'nvim-treesitter/nvim-treesitter' }, -- parsers + injections
}
```

No `setup()` required — every command exists at startup and nothing loads
until one runs. Optional configuration:

```lua
require('cartograph').setup {
  keys = { descend = '<Right>' },  -- every binding is remappable
}
```

## Quickstart

```
:Cartograph              " open the cockpit on the current directory
```

`l`/`h` zoom in/out (files → file → function → statements), `<CR>` pivots,
`<C-]>` jumps to the callee under the cursor, `<C-o>` goes back. To move a
function: `dd` cuts it, `p` on a file row sets the destination, then
`:CartographMove` → `:CartographDiff` → `:CartographApply` →
(`:CartographUndo` if you change your mind).

`:h cartograph` for everything else; `:checkhealth cartograph` to verify
the wiring (parsers, injections, cache codec, optional oracles). Project-
specific adapters — framework entry points, FSM browsing, the live oracle,
database links — are plain `setup{}` blocks; [`examples/`](examples/) has
complete wirings to copy from.

Fourteen languages (lua, c, cpp, python, js, ts, php, ruby, java, go, rust,
haskell, scheme, zig, odin) plus vue/svelte single-file components. Everything
cross-file is name-matched and marked `~` unless an oracle proved it;
ambiguity refuses to link rather than guess.

## Why

Editors expose the dependency graph one query at a time — a rename box, a
references popup, a flat symbol outline. None of them give you a *place to see
the structure and stage a change against it*. cartograph is that missing layer:
a focus+context view over the symbol graph, plus a staging surface for
relocations.

The guiding principle: **the unit of attention is one node and its edges, and
navigation is re-rooting.** Never the whole graph (a hairball at any real
scale), never a context-free list.

## Terminology

Three layers, one vocabulary.

**The graph** — the data:
- **node** — a symbol. Kinds: `function`, `method`, `var`, `module`, `region`
  (a run of top-level statements between function definitions, shown `≡`).
- **edge** — a directed relationship between nodes: `ref` (call / reference),
  `import` (require / include), `use` (variable read), `reg` (registration by
  a dispatch table or annotation).
- **call** — a call-site record; becomes a `ref` edge once resolved (or stays
  a *refusal* when the name is ambiguous).
- **occurrence** — one *site* of an edge (a source range); an edge can have
  several.

**Views** — what the **browser** (the symbols pane) shows, one **altitude** at
a time; `l`/`h` change altitude:
`files → file → fn → block`, plus side-views `region` (a region's
declarations), `callers` / `used-by` / `sites`, `table`, `refused`,
`registrations`, `states`, `working set`.
- **block** — the view you descend a compound statement (`if`/`for`, a nested
  lisp call) or a function body into; derived on demand from the source.
- **form** — one nested statement or call, a row in a block view (not a graph
  node).
- **lens** — a way of reading the current altitude's rows, cycled with
  `<Tab>`/`<S-Tab>`. fn/block/region offer `statements` (default) and `detail`
  (arguments, conditions, var/field reads). The lens rides the trail.

**Navigation**:
- **focus** — the node the cockpit is rooted on (shown in the source pane),
  set by a **pivot** (`<CR>`, or `l` where descending enters something).
- **context** — the transient hover preview that takes over the source pane,
  restored when you move off. *The view follows the eye; focus follows intent.*
- **descend** (`l`) / **ascend** (`h`) change altitude; **step** (`j`/`k`)
  moves within a view and **steps out** at a block edge.
- **peek** — after an ascend the source pane lingers on where you were until
  you move (deferred re-sync); immediate for same-location moves.
- **trail** — the `h`/`l` structural path (return the way you came), distinct
  from the **jumplist** (`<C-o>`/`<C-i>`, which records pivots).
- **cockpit** — the whole tab: the **browser**, the **source pane**, the
  **plan bar**.

## Shape

A cockpit of independent panes over a shared state store:

- **symbols** — a zoomable *altitude browser*: `l` (or `<CR>`) descends, `h`
  ascends — sideways is free in a linear list, so it becomes altitude.
  Top level is the **file tree** (one row per file, with usage-classification
  gutter signs). Inside a file, runs of top-level statements between function
  definitions roll up into **regions** (`≡`, named by their first source line
  — a constants preamble reads as one row); a region descends into its
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

  Below the fn level, descend keeps going **into the graph**. A **compound
  statement** (an `if`/`for`/`while`, a nested lisp call) descends into the
  **block** view — its immediate **forms**, one level down, derived on demand
  from the source; a `▸` form descends deeper, a leaf call descends into the
  callee. `j`/`k` walk this tree depth-first: within a block they move among
  its forms, and at the first/last form they **step out** to the parent
  (chaining up until there's somewhere to go, never leaving the function).
  Otherwise `l` acts on the name under the cursor — statement rows name their
  calls (`→ callee`) and the module vars / globals they read (`· var`), so `l`
  on a callee follows the call into that function (recorded in the jumplist —
  `<C-o>` walks back), on a var opens that var's usage sites, on a
  **parameter** opens the origin trace, on a **local** jumps to the defining
  statement. A **var** row
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

**Lenses.** `<Tab>`/`<S-Tab>` cycle the current altitude's **lens** — the way
its rows are read. At the files altitude that's the flat list vs the include
tree. At fn/block/region the lenses are `statements` (the default view) and
`detail`: the code's fine-grained descendable elements, indented under each
statement — a call's **arguments** and a conditional's **condition** (`l`
descends into that element's forms), and the **module vars/fields** the
statement reads (`l` opens the var's usage sites). The lens rides the `h`/`l`
trail (ascend restores the lens you had), but not the `<C-o>` jumplist.

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
  word-match fallback). In the browser it pivots like `<CR>`.
- `<C-o>` / `<C-t>` — go **back** to where the last pivot happened; `<C-i>`
  goes forward again. Vim-jumplist semantics: deliberate pivots record,
  scrolling the symbol list doesn't. (`<C-i>` is unbound in the browser, since
  `<Tab>` cycles the lens there and most terminals can't tell them apart.)
- `gf` — **leave the cockpit**: open the real file at the corresponding line
  (in a reused tab), from the source, symbols, or plan pane.
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

### Tracing (planned)

Variable tracing — *where does this value come from, and where does it flow?* —
is being re-homed into the browser as two on-demand **axes**: `sources`
(backward: assignments, params ← callers' args, callees' returns) and `sinks`
(forward: reads, args passed onward, returns), with the path you walk kept in a
walkable, filterable history. The extractor-side origin engine
(`cartograph.trace`: argument/return classification, recursive `origins` /
`origins_local`) is in place and covered by `trace_spec`; the earlier separate
trace *pane* has been retired in favour of the axis model. (Refusal pinning —
`p` on a candidate in the refused view — is unaffected.)

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

### The first transaction: clone-merge

`:CartographMerge` on a function finds its **witness twins** — same
data-flow shape, params and callee set, the identity the reference
layer already trusts — and stages a merge: delete the copies, rewrite
their call sites to the survivor's name. The plan bar shows exactly
what will happen (removals with line ranges, rewrite count, hazards:
data-referenced clones, non-bare call forms, cross-file visibility);
**nothing is written** until `:CartographApply` survives verification:

- the graph generation must match the plan's (nothing re-ingested);
- survivor and clones must still resolve by **ref, witness-clean** — a
  transaction never follows drift silently;
- every touched file's stamp must match plan time (CAS), with no dirty
  buffers.

Any failure refuses with its reason and costs a re-plan, never a
corrupted write. The apply itself is journaled — full before-content
per file, `pending → write → applied` (a crash leaves evidence, not
mystery) — and the touched files splice back through the same refresh
every save uses. `:CartographUndo` restores **byte-exact**, refusing if
files moved on since; `:CartographTxnClear` abandons a staged plan.
The journal (`state dir`, human-readable JSON) is the substrate every
future verb — move, extract-module, remote edits — reuses.

`:CartographMerge` needs you to *find* a clone first. `:CartographClones`
is the finder: it groups every function by an **exact-structural** key —
the per-statement shape read from the same expression IR that powers
`:CartographExpr`, made **alpha-invariant** by renaming a function's own
locals (its params and dataflow-defined names) to positional slots, while
keeping callees, globals, operators, field names, and literals verbatim.
So a copy that only renamed its variables is one group (`sorted` and
`sorted_keys` collapse), but a copy that calls a different function or uses
a different operator is *not* — the discriminating tokens stay in the key,
so it needs no "shared-callee" heuristic to suppress coincidences. Focus a
group member, `:CartographMerge`, and the duplication is gone. Run it
repo-wide (including tests, where copy-pasted fixtures live) headless with
`nvim -l tools/clones.lua`.

`:CartographBlockClones` is the second tier: a clone need not be a whole
function. It finds **contiguous statement runs** duplicated across — or
within — functions, which the whole-function tier is blind to. It seeds on a
window of statements, extends each match maximally so a long shared run is
reported once at its true length, and alpha-canonicalizes each window
*locally* (slots renumbered per window) so a block matches regardless of what
locals its surrounding function happened to introduce first. On this very
codebase it surfaces a 67-statement block shared between the extractor's and
the relinker's name-resolution loops — a copy that a text diff misses because
the two have drifted in comments and whitespace, but whose *statement shape*
is identical. Run it with `nvim -l tools/clones.lua --blocks`.

`:CartographNearClones` is the third tier — for copies that are *almost*
identical. It finds functions whose statement sequences differ by only a few
edits, aligning the two with an edit-distance backtrace: the matched rows are
the shared **template**, and each substituted, inserted, or deleted row is a
**hole** — a parameter of the helper the two copies could factor into. It's
the anti-unifier read as a refactoring: the report points at each hole's source
line, so `find_bin` in the clangd and lua-ls providers shows up as one edit —
the config key `clangd_bin` vs `luals_bin` — which is exactly the argument the
merged helper would take. Candidates come from a shared-distinctive-statement
index, so the pairwise alignment runs only on real leads, not every pair of
functions. Run it with `nvim -l tools/clones.lua --near`. Exact, block, and
near are the three tiers of the clone ladder; all three key off the same
expression IR, differing only in how much divergence they tolerate.

A near-clone's holes are described at statement granularity, but whether they
are a *clean parameter* is a finer question, and `:CartographExtractHelper`
answers it by **anti-unifying** the differing rows — descending both
expression trees in lockstep to the divergent leaf. If every divergence is a
leaf value — a callee name, a literal, a field — the pair is
*value-parameterizable*: the report proposes the helper the two copies factor
into, with each varying leaf named as a parameter (the `find_bin` pair in the
clangd and lua-ls providers reduces to one field parameter, `clangd_bin` vs
`luals_bin`). If a divergence is a shape difference — a different arity, an
inserted statement, a local where the other has a field access — the pair is
flagged *structural* and left to a human, because a value parameter can't
capture it. And if anti-unification finds no real divergence at all (the
edit-distance came from renamed locals the function-global pass couldn't see
through), the pair is really an exact clone and `:CartographMerge` applies
directly. And for the cleanest case — a same-file, value-parameterizable pair
whose bodies are both safe to lift — `:CartographExtractHelperApply` does the
write: it synthesizes the shared helper (the template with each varying leaf as
a parameter), rewrites both bodies to *tail-call* it passing their own filling,
and stages it as a transaction you review with `:CartographDiff` and commit with
`:CartographApply`. The tail call is what makes it sound — the whole body moves
into the helper, so every return (count, values, early exits) is preserved
exactly. It rides the same journal-and-verify contract as the move and merge
refactors, and adds a synthesis gate of its own: the result must parse cleanly
and actually contain the helper and both call sites, or the apply refuses. When
the two copies live in **different files**, pass a destination module path and it
does the cross-file version: the helper becomes a member of a new shared module,
and each copy's file gains a `require` of it and a delegating body. That last
step needs one thing the tool can't be sure of — that the require path it writes
actually resolves under your project's package layout — so it rides as a hazard
to verify rather than a silent claim. A cross-file move also has to check the
body reads only globals, never a local of its old file (which wouldn't follow it
across), and refuses if it would. What stays out of the safe subset — a differing
statement rather than a differing leaf, a nested or vararg or recursive body, a
body that depends on file-locals it can't take along — is refused with a reason,
leaving the reviewable scaffold as the fallback. Only the *synthesis* is
language-specific (the helper's declaration, the delegating call, the parse
check): the analysis and every gate are language-agnostic, so the transaction
works for Lua and — same-file — JavaScript, and a new language is a small table
of syntax rather than a new implementation.

`:CartographClonesSigns` lands all of this *on the code* rather than in a
report: exact clones and near-clone functions become in-buffer signs, and each
value hole becomes a sign at its **exact substitution column** — so `]d` walks
you from one rewrite site to the next, and the quickfix list is the work queue.
The costly per-function index behind every tier is built once and cached by
graph generation, so a focused query (`:CartographExtractHelper` on the function
under the cursor) is instant after the first scan rather than re-reading the
whole graph. Both clone reports are honest about their own confidence: the block
tier marks short runs as likely-coincidental, and the near-clone count is stated
as a lower bound, since a copy that inserts a local can drift past the matcher.

### The working set

Mark what you're working on; dive freely; come back. In the symbols list:

- `m` — toggle the symbol under the cursor in the **working set** (● in
  the gutter; files containing members carry ● at the files level).
- `M` — the working-set altitude: your members grouped by file, with the
  cursor on the **last-visited member** — the way back from a code dive.
  `l` dives back in, `h` returns the way you came.
- `]w` / `[w` — cycle through members (conscious pivots: `<C-o>` undoes).

Membership is held as **refs**, not ids: it survives refresh (a member
follows its function through line shifts, and renames with a note),
persists per project in the state dir across sessions, and members whose
symbol vanished stay visible as honest `? pending` rows until they
return. On a parallel cold open, working-set files jump to the **head of
the extraction queue** — your declared attention outranks everything but
the buffer you're in.

The index also **orients you**: at any function, a ghost line under the
title says how to get back — `↩ ● beta is 3×<C-o> back` (the return
path through the jumplist) — and how to get *there* — `● →alpha ↖beta`
(the closest graph route: `→` descend into that callee, `↖` up through
callers). Ariadne's thread, in text.

## Architecture (three seams)

1. **GraphProvider** — supplies `nodes{id,name,kind,file,range,order}` and
   `edges{from,to,kind}`. Three providers exist:
   - **MCP** (`:Cartograph mcp://name`): any MCP server tool that returns
     the neutral schema is a provider — a database introspector, a
     running game, a debugger, a remote index. Configure under
     `setup{ mcp = { name = { cmd = {...}, tool = 'graph' } } }`; the
     client is a ~150-line stdio JSON-RPC speaker built on uv, and the
     same client serves future **oracles** (live systems answering
     enrichment questions, the clangd pattern over a different wire).
     A server that **stamps** its keys (e.g. a Postgres introspector
     fingerprinting each table's definition) is *substrate*: its scan
     caches like a source tree — table ⇔ shard — and a warm open makes
     one cheap `stamps` call, re-fetching only keys whose fingerprint
     changed. A server that can't stamp gives an honestly-dated sample,
     re-fetched per open. What a source *can do* is the dispatch surface
     (`lua/cartograph/source.lua`): persistable ⇔ stamps, warm-openable
     ⇔ diff + slice re-fetch, reconcilable ⇔ id-pass + names.
     **Recipes** adapt servers that only speak generic SQL — no
     cartograph-specific tool needed. Validated against a real Postgres
     through [postgres-mcp](https://github.com/crystaldba/postgres-mcp)
     in restricted (read-only) mode:
     ```lua
     setup{ mcp = { pg = {
       cmd = { 'postgres-mcp', '--access-mode=restricted',
               'postgresql://user:pass@localhost/db' },
       recipe = 'postgres',
     } } }        -- then :Cartograph mcp://pg
     ```
     Tables become entities (columns as literal data, `l` descends),
     foreign keys become edges, definition fingerprints make the scan
     cacheable: `ALTER TABLE` one table and the next open re-introspects
     that table alone.
   - **lua-ls CLI** (the reference): vm-typed resolution, full `df`
     data-flow, effects — the deep option for Lua. Extract once, open the
     dump.
   - **tree-sitter** (in-editor, any language with a parser + a spec):
     `:Cartograph` on a directory — or with no argument, the cwd — parses
     the tree and opens instantly (~200ms for a mod, ~4s for 100-file
     projects; 40× faster than the CLI). No type resolution, so cross-file
     links are name-matched and wear the honest `~`; ambiguous names refuse
     to link. Emits calls, literal data, imports (`require`/`#include`,
     with a unique-basename fallback for `-I` paths) and a df-lite, so the
     fn altitude, the lit altitude and the graph lints all work. Specs ship
     for **Lua, C, C++, Haskell, Scheme, PHP, JavaScript/TypeScript (incl.
     React `.jsx`/`.tsx`), Python, Ruby, Java, Go, Rust, Zig, Odin** — a new
     language is one spec table (queries + a few hooks); the two newest slot in
     with no new machinery — Zig into the procedural+struct+method family (a
     `fn` is free or a struct member, keyed `Type.method`), Odin into the
     C/procedural family (package + `proc` + struct, no methods). Odin resolves
     **package-qualified** calls: a proc in `package P` gains a `P.proc` key
     (while keeping its bare key for same-package calls), and a `strings.to_lower()`
     call keys `<package>.proc` through the import alias (the import path's last
     segment) — so a call into another package's proc resolves to that package,
     not a same-named proc elsewhere. Zig also
     carries **receiver typing**: a `recv.method()` call is keyed by the
     receiver's declared type — a PascalCase receiver *is* the type (`Foo.init`),
     and a lowercase receiver is typed from the enclosing fn's pointer parameter
     (`fn f(sema: *Sema)` → `sema.x()` links to `Sema.x`). The definition side
     mirrors it: a top-level `fn` with a pointer receiver (`fn fail(func: *Func)`)
     keys `Func.fail` by that param's type — not the filename — so the
     `const Self = @This()` aliasing idiom keys consistently on both sides,
     and a bare-name fallback is refused for a typed key (an honest frontier,
     never a promiscuous tail guess). Zig **`@import` module binding** completes
     the picture: `const Foo = @import("foo.zig")` binds `Foo` to that file, so a
     `Foo.member()` call resolves to `foo.zig`'s export — binding beats
     name-match, which also *corrects* the residual cross-module mis-picks (a
     `name()` call that tail-matched an unrelated module now binds to the
     imported one). A value-receiver method (`fn setExtra(symbol: Symbol)`) is
     **dual-keyed**: it keeps its bare same-file reach *and* gains a
     `Symbol.setExtra` key, so a pointer-typed caller (`p.setExtra()`, `p: *Symbol`)
     — which refuses rather than fall back to a bare guess — finds its own
     value-receiver method (unique cross-file → resolves; same-named across
     modules → honest ambiguous-refuse). The receiver signal (param named `self`
     or the lowercased type) dodges the constructor trap (`init(gpa: Allocator)`
     is not a method of `Allocator`). A multi-level chain
     `root.Type.method()` (`link.File.open`, `Mir.Memory.encode`) resolves through
     its PascalCase penultimate segment — the method's type namespace — via an
     additive post-pass that fills only the cross-file chains the same-file tail
     path left unresolved. An *instance* chain `root.field.method()` (lowercase
     penultimate) resolves through **struct field typing**: the root's type (a
     parameter type) → the field's declared type → the method. The field type is
     **file-bound** — an `@import` alias in the field's file, else a same-file
     local `const T = struct` — and the method is resolved *in that file*, never
     by bare name (same-named types collide across subsystems, so `MachO`'s
     `StringTable` binds to `link/StringTable.zig`, not an unrelated one). One hop
     of **local type inference** extends this: a local `const s = self.field; s.m()`
     is typed through the field and resolved as if it were `self.field.m()` (the
     per-file local map is built once and cached — the dominant `const sema = …;
     sema.typeOf()` idiom). Deeper local typing (call-return chains) stays open.
     TypeScript parses under its own tree-sitter grammar (a JS superset) for
     both extraction *and* the on-demand analysis lenses, but resolves under
     the JavaScript spec — so `.ts` and `.js` are one language family (the way
     TS imports JS under `allowJs`), while TS syntax (annotations, generics,
     interfaces) never errors a re-parse the way it would under the JS grammar.
     ES6 class methods carry their class (`class C { m(){} }` → `C.m`, the JS
     analog of Lua `C:m` / PHP `C::m`), so a `C.m()` reference links exactly and
     the module-function namespace stops colliding with same-named methods —
     object-literal methods stay bare (they belong to no class). TypeScript
     `interface` and `enum` declarations extract as browse-only type nodes with
     their members (`Opts.run`, `Color.Red`) — faithful to the source, but kept
     out of value resolution (an interface method signature is a declaration,
     not a callable), so they enrich the graph without inventing links. Type
     aliases (`type Id = …`) and namespaces are captured the same browse-only
     way, and `import type { … }` links to its module like any import. React
     `.tsx` parses under the tsx grammar and `.jsx` under the JS grammar (both
     JSX-capable); the whole OOP treatment above applies to components unchanged,
     since `.js`/`.jsx`/`.ts`/`.tsx` all resolve as one language family.
     `class C extends B` records the inheritance edge, so `super.method()` and
     inherited static calls resolve to the nearest ancestor that defines the
     method (walking the chain, unique-or-refuse) — the same superclass
     machinery PHP and Java use. And a `this.method()` call inside a class
     method resolves to that class's member (own, or inherited via the chain),
     typed lexically from the enclosing method — the JS/TS analog of Lua's
     `self:method`. It wears the honest `~` (JS `this` can be rebound, and a
     subclass can override), and only fires for a genuine object (a class with
     ≥2 methods) with a unique hit; a `this` inside a nested plain function
     isn't the class instance, so it's left unresolved rather than guessed.
     Pre-ES6 prototype methods (`X.prototype.method = function`) are captured
     too and keyed `X.method`, so a prototype "class" gets the same treatment as
     an ES6 one — `this.method()` inside resolves the same way. Extending a
     built-in prototype (`Function.prototype.overload = …`, MooTools-style) works
     the same; a member assignment that isn't on a `.prototype.` is left alone.
     A local built by a constructor — `const o = new C(); o.method()` — is typed
     to `C`, so its method calls resolve to `C`'s members (own or inherited);
     rebinding the local (`o = new D()`) makes its type ambiguous, so it hedges.
     A callee bound by an in-function `const`/`let`/`var` (including a
     destructured `const [x, setX] = useState()` hook setter) shadows any
     same-named global: with no same-file definition of its own it refuses
     rather than link to an unrelated cross-file function — while a
     `const f = () => …` still resolves to its own binding. Class field-arrows
     (`onClick = () => …`, `private load = async () => …`) are keyed like methods,
     so `this.onClick()` resolves the same way. And `this` is followed with real
     scope semantics: inside a nested arrow it's the class instance (arrows
     inherit `this`), but inside a nested `function () {}` it is rebound, so a
     `this.method()` there is left unresolved rather than mis-typed.
     **Ruby** resolves class-method calls by their constant receiver:
     `Foo.bar` / `A::B.baz` key to the singleton method `Foo.bar` and
     exact-match the definition (`def self.bar`, or a `def bar` inside
     `class << self` — both keyed `Foo.bar`, not the instance `Foo#bar`).
     Because a constant names the class explicitly, the link crosses files
     (Ruby classes reopen corpus-wide), but the receiver evidence is
     exact-or-nothing: `Foo.bar` with no such definition stays an honest
     frontier — inherited via a mixin/superclass, or external — and never
     collides onto an unrelated `X#bar`. A bare call (or `self.m`) inside a
     method dispatches on `self` → the enclosing class: in an instance method
     it keys `Owner#m`, in a class method (`def self.x` / `class << self`) it
     keys `Owner.m`, and it resolves corpus-wide since classes reopen. These
     wear `~` (a subclass can override the method) and are exact-or-nothing —
     but when the method isn't defined on the class itself, its **ancestors**
     are walked: the superclass chain, `include`/`prepend` modules (as instance
     methods), and `extend` modules (as singleton methods), for the nearest
     unique definition (`class Dog < Animal; def act; breathe; end` resolves
     `breathe` to `Animal#breathe`; `include Comparable`-style mixins resolve
     the same way), and a bare `super` (or `super(args)`) resolves to that same
     inherited method one level up. When a local is built by a constructor —
     `x = Account.new; x.freeze!` — its calls resolve to that class's method
     (own or inherited), which disambiguates a name shared by several classes;
     rebinding the local drops the type, so it stays honest — and the same
     applies to an instance variable set from a constructor (`@engine =
     Engine.new` makes `@engine.rev` resolve to `Engine#rev`). Bare
     calls with no parentheses (`save`, an attribute read) — which parse as a
     plain identifier, not a call — are recovered by applying Ruby's own
     var-vs-call rule: a bare name is a method call unless a local of that name
     is bound in the enclosing method (a parameter, block/rescue/for/pattern
     variable, or assignment target), in which case it's a variable read and
     left alone. And `attr_accessor`/`attr_reader`/`attr_writer` are read as
     method definitions: `attr_accessor :name` defines `Owner#name` and
     `Owner#name=` (singleton accessors inside `class << self`), so a read of
     the attribute resolves like any method — while an explicit `def name`
     overrides the generated accessor. `@ivar`-receiver calls remain
     file-scoped for now (constructor typing is a later step). Framework
     knowledge lives in **overlay packs** that compose onto the base language,
     not in it: the `rails` pack adds the ActiveRecord/ActionController
     vocabulary (`save`/`where`/`find`/…, which a *non*-Rails project would
     resolve to its own methods) and reads `has_many`/`belongs_to`/`has_one`/
     `delegate` as method definitions (`has_many :comments` → `Model#comments`).
     It **activates automatically** from the project's shape — a Rails app marker
     (`config/application.rb`) switches the pack on with no configuration, while a
     pure-Ruby project (or the Rails framework's own source, which has no app
     marker) stays pure; an explicit `setup{}` always overrides. The pack also extends
     constructor typing to ActiveRecord **finders** that return a model
     instance — `user = User.find_by(email: e); user.suspend!` types `user` as
     `User` (→ `User#suspend!`), just as `.new` does — while relation-returning
     verbs (`where`/`all`/`order`) are left untyped (they yield a `Relation`,
     not an instance). This is a pack input: only ActiveRecord makes `find_by`
     instance-returning, so pure Ruby never assumes it. Packs compose: an `rspec`
     pack (RSpec + factory_bot verbs — `describe`/`it`/`let`/`expect`/…) stacks
     on top of `rails` for a test suite, so framework DSL reads as framework and
     a project method that happens to share a DSL name isn't mistaken for it.
     Framework calls with no project definition (`where`, `present?`,
     `belongs_to`, …) are recovered as external framework nodes (an
     `ActiveRecord::Relation#where` you can hover and jump to) by the matching
     **environment profile**, which activates from the same project shape as the
     pack — and the shape is found even when you open a *sub-directory* of the
     app (analyzing `app/models/` alone still sees the Rails marker two levels
     up, bounded by the repository root), so the same enrichment applies whether
     you open the whole app or one folder.
     A **localized parse error** doesn't blind the rest of a file: a def is
     dropped from the name index only when the error sits inside its *own*
     subtree (Lua/bash, whose def names are self-contained), not merely because
     an earlier line failed — one invalid-escape string in a 4k-line library
     otherwise cost ~2000 downstream defs their resolvability. (Languages whose
     defs inherit an enclosing qualifier — a PHP/C `class{}` block a parse error
     can truncate — keep the conservative "everything after the error" rule.)
     Dependency trees (`node_modules/`, `vendor/`, `dist/`) are excluded
     by default — built artifacts poison navigation. Minified bundles
     (`*.min.js`) become **opaque frontiers** instead: visible in the
     files view as `lib.min.js (unparsed)`, contributing no parsed nodes,
     but reachable — descending an unresolved call whose name lives in a
     bundle lands inside it by lazy text search, at the definition
     (`ƒ myfun … (unparsed source — landed by text search)`).
     `setup{ unparsed = false }` makes them invisible entirely. Dispatch stays honest per idiom:
     C dispatch-table references, C++ methods, Haskell instance methods
     and Lua registry fields are dynamically dispatched (not dead);
     `main` is an entry point; stdlib vocabularies (`string.format`,
     `.size()`, scheme's `apply`) never name-match a project definition.
   - **self** (`:Cartograph self://loaded`): the RUNNING nvim as a graph.
     `nvim_list_runtime_paths()` is the loaded-plugin roster — a plugin
     joins the runtimepath exactly when it loads, so this is
     manager-agnostic (lazy, packer, native `packadd` all qualify) — and
     every loaded root (your config, each loaded plugin, cartograph itself)
     is unioned into ONE corpus under a synthetic `self://loaded` root, so
     a `require` from your config into a plugin, or one plugin into
     another, resolves in a single graph. Streams like the cold path
     (~5s for a whole ~30-plugin session, 4k+ files, 18 languages, on 8
     workers). A session-scoped **sample** — not cached, since the next
     launch may load a different set. `$VIMRUNTIME` is held back as a lazy
     node (huge, rarely what you're exploring; present so edges into it
     resolve, extracted only when descended). On top of this base graph a
     **self oracle** — the live process answering what IS, the way
     clangd/lua-ls answer for on-disk projects, but in-process — adds a
     **`live` lens** at the file altitude (`<Tab>`): where the static graph
     shows what a module's source *declares* (a `local M = {} … return M`
     reads as an EMPTY table), the live lens shows what it *concretely
     holds right now* — the assembled export table, a dispatch table's
     actual entries — and resolves every runtime function value back to the
     def it dispatches to (via `debug.getinfo`), closing a `⊘` frontier the
     source left dynamic. Descending a live **closure** (`⇡N`) shows its
     **upvalues** (`debug.getupvalue`) — the state it captured, which is real
     coupling that's invisible to require/call analysis because it's *closed
     over*, not called; captured functions resolve to their defs, captured
     tables are walkable. And a live table's **metatable `__index`**
     (`getmetatable`) is surfaced as `↑ __index` — so a value's methods and
     its inheritance chain resolve through the metatable the source can't
     follow (the ubiquitous `M.__index = M` self-idiom is collapsed, not
     recursed). A live read is stamped `live @ now` (a sample, never
     cached). The oracle also marks the files view: `⚡` on every file
     that actually **ran this session** (a required module or sourced
     script) — the unmarked rest of a loaded plugin's tree is
     present-but-never-loaded, the honest "dead this session" signal. And it
     **builds the import graph**: the static path-match can't resolve a
     `require` in a self graph (its file keys are plugin-labelled), but the
     loader knows exactly which file each module is — so every
     `require(<literal>)` the loader resolved becomes a PROVEN import edge
     (19 → 85 on cartograph's own tree). And `:CartographSelf` reports
     **declared-vs-registered**: the user commands and keymaps the source
     spells out (literal names — dynamic ones honestly skipped) diffed
     against what this instance actually registered, flagging a command
     declared but missing now (its module never ran, or a guard fired).
   - **clangd oracle** (C/C++, automatic when a `clangd` binary exists;
     `setup{ clangd = false }` disables): the tree-sitter skeleton stays,
     but a headless clangd session answers `callHierarchy/incomingCalls`
     per function and REBUILDS those ref edges as semantically proven —
     upgrading correct `~` hypotheses and refuting wrong ones (on pkgit:
     87 name-matched edges → 0, one false dead-function cleared, one
     false survivor exposed — a local variable had been mistaken for a
     dispatch-table reference). Functions clangd can't see keep their
     honest `~`. A `compile_commands.json`/`compile_flags.txt` gives it
     full cross-file eyes.

### The reference layer

Node ids embed line numbers and never leave the session. Anything
durable — pins, staged plans, journals — holds a **ref** instead:
`{ file, kind, name, ordinal?, witness? }`, resolved at use time via
`store.resolve_ref`. The witness is the clone detector's hash reused as
identity evidence (df shape + params + callees): insensitive to renames
and moves, sensitive to behavior. Resolution policy, edit by edit —
edits elsewhere survive; body edits survive with a drift note (a
transaction's stale-plan check); renames recover by witness *with a
note*, offered never assumed; reordered same-named siblings are
disambiguated by witness (true clones fall to the ordinal, with the
caveat stated); deletion is `missing`, which is the truth. Refs are
provider-portable — a ref minted on a tree-sitter graph resolves
against a lua-ls dump of the same tree.

### Live refresh

The graph follows saves. Writing a file under the project root
re-extracts just that file (imports resolved against the whole project),
splices it into the store, and **relinks in both directions**: node ids
embed line numbers, so inbound edges survive edits through a
(kind, name) remap, and calls elsewhere that named a function you just
created resolve to it. Navigation state — focus, history, trails, the
browser's exact location — carries across. Staged changes **freeze**
refresh (a transaction pins the graph it was planned against);
`:CartographRefresh` forces one file, `:CartographRefresh!` the whole
project; `setup{ refresh = false }` disables. Dump-based graphs (lua-ls)
say so instead of silently staling.

### LSP read surface

`:CartographLspAttach` starts an **in-process LSP server** on the current
buffer, served from the open graph — a real client, so `gd` (definition),
`gr` (references), `K` (hover), document symbols and workspace symbols all
answer from the common core, across languages, with no extra process
(`:CartographLspDetach` stops it). It is **read-only** — writes stay with the
transaction family (`:CartographMove`/`Merge`/`Apply`).

What makes it different is **honesty on hover**: every answer carries its
epistemic tier. Definition is exact when the graph is sure (one location),
offers the **candidate set** when a name is a navigable fork, and returns
**nothing** — never a fabricated guess — at a frontier. Hover then says *why*:
the tier (`matched` / `typed` / `proven` / `stdlib` / …), or for the
unresolved, the refusal rule and how many candidates it saw. No per-language
server explains what it doesn't know, or follows a call across a language
boundary; this one does both because the graph already did.

Beyond the basics it also serves **call hierarchy** (incoming/outgoing — which
crosses languages, since the call graph does), **go-to-implementation** (an
interface's concrete impls) and **go-to-type-definition** (the value's type
node), **semantic tokens that tint each call by its resolution tier** (the
honesty made visible — name-matched `~` calls shade differently from proven
ones), and — for tools and agents — the namespaced `cartograph/why` (the full
resolution record) and `cartograph/graphInfo`. Over the stdio host
(`tools/lspserve.lua`) the same surface runs under any editor, and pushes the
graph-aware lint as diagnostics on save. Measured against lua-ls on the same
corpus it agrees **99.6–100%** where both resolve, and resolves more.

`:CartographDogfood` turns all of this on the open project at once — a one-screen
dashboard (resolution by tier, the LSP answering its own graph, the lint) with
the read surface attached. Run headless, `nvim --headless -l tools/dogfood.lua`
is a CI/pre-commit **fence**: it fails if any code reads the wide graph indexes
raw instead of through the query seam.

### Multiple projects at once

`:Cartograph <root>` **adds** a band rather than replacing the current graph, so
several projects — or `self://loaded` alongside a work corpus — stay resident
together. The store is a lens on the *active* band; opening a new root freezes
the current one into its record, and re-opening a known root switches back to it
(no re-extraction). `:CartographBands` lists what's open, `:CartographSwitch
<name>` flips the active band. A single-project session behaves exactly as
before.

Navigation is **one continuous trail across bands**: `<C-o>` walks the current
project's jump history and, when it runs out, crosses back into the project you
came from — landing exactly where you left it. So `self://loaded` alongside a
work corpus is `<C-o>`-navigable as a single session. (Following a call across a
language or engine boundary *into* another band is the next step, once bands are
linked.)

### Cross-language linking

Engine boundaries dispatch by **string key**, and the key is the edge:
`chrome.send('getThing')` in TypeScript runs whatever C++ registered
`RegisterMessageCallback("getThing", …)`; `scm_c_define_gsubr("apply", …)`
makes a C function callable from Scheme by name. `cartograph.xlang` links
these as a pure post-pass over any provider's graph: export calls resolve
their handler (through `base::BindRepeating(&Class::Method, …)` and
friends, bounded to the call's own extent), and every import site gets a
real edge — descending a TS proxy method's statement row lands in the C++
handler, whose callers view lists the TS side back. One hook can fan out to
many handlers (WordPress `add_action`/`do_action`: string-named callables
resolve, closures stay honest frontiers; a single-handler key becomes a
descend target). Ships with bindings for chromium WebUI
(`chrome.send`/`sendWithPromise`), WordPress hooks, guile's gsubr and
`lua_register`; one config entry adds a boundary
(`setup{ bindings = { { export = { verb = …, name = argN },
import = { verb = … } | { any_call = true } } } }`). Unresolvable
handlers stay honest frontiers.
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

### String-embedded SQL

Query strings carry real structure: the **tables** they touch. Each
table found in embedded SQL becomes a first-class entity — a var node
anchored at its first query, with use edges from every function that
queries it — so "who touches `posts`" is an ordinary sites view, and the
`sql` lint reports each table's read/write footprint. Parsing is
case-strict (code SQL capitalizes; an email template's
`<table cellspacing=…>` corroborates nothing), patterns are chosen per
verb (`ON DUPLICATE KEY UPDATE col=` donates no tables), and the
interpolation idioms resolve — `{$wpdb->posts}` names `posts`,
`{$this->getTable('sales/order')}` names its argument. On WordPress: 311
queries over 23 tables (`posts`: 67 reads, 13 writes); on Magento: 92
tables. Interpolated names beyond those idioms stay honest misses.

### Incremental open

Extraction is a pure function of file contents and node ids are
deterministic — so an unchanged file's entire contribution to the
graph, including edges between two unchanged files, is still valid
tomorrow. The raw graph is cached per project root; the next
`:Cartograph` stats every file stamp, re-extracts only the diff,
remaps and relinks. The cache is SHARDED PER FILE (binary: LuaJIT
string.buffer, mpack fallback) under a manifest that doubles as the
stamps sidecar — the warm/cold decision costs a few KB, and a save
rewrites only the shards a change actually dirtied (the splice reports
every file whose contribution it touched: remaps, relinks,
reconciliation — verified disk == memory in tests). Wordpress: 47s
cold, **0.8s warm** (2,096 files unchanged), ~3.4s with one file edited
(25 shards rewritten, 2,071 untouched). Deletion is a tombstone —
omission from the manifest — so nothing is unlinked on the hot path; a
background gc reclaims unreferenced shards later. Full saves (cold
open) encode synchronously (immutable bytes, safe against post-pass
mutation) and write in the background, manifest last as the commit
point: a cancelled or crashed save leaves the old manifest standing and
any skew simply re-splices at the next diff. Post-passes (xlang, SQL, clangd
oracle) re-run on every open — oracle verdicts are session-live by
design. Subtree slices (`subdirs`) bypass the cache; `setup{ cache =
false }` opts out.

Globals reconcile exactly, in both directions: the id pass records each
file's identifier **mention index** (it iterates every identifier
anyway), so when an edit flips a global name's uniqueness — a new
global appears, or a second definition makes one ambiguous — only the
files that actually mention that name get their links re-derived, at
global scope. Cost scales with churn, not corpus size. Per-language
opt-out: `name_index = false` in a language spec, for languages where a
bare identifier mention does not imply potential global use.

### Parallel cold open

The first open of a big tree doesn't block: above ~300 files the
browser opens **immediately** on the file list and worker processes
parse slices in the background — the graph fills in as chunks land,
with an honest `extracting… k/n slices (links partial)` header until
it's complete. The result is **identical to sequential extraction by
construction**: workers parse, but every cross-file *hypothesis* a
slice makes is discarded (unique-in-slice is not unique-globally) and
re-derived by the global relink; the identifier pass runs against
parent-built global indexes. Wordpress: 47s → **13s** on 8 workers,
browsable from second 6. `setup{ workers = n, parallel = false,
parallel_threshold = n }` to tune.

### The live oracle

The running system is the top rung of the epistemics ladder.
`:CartographLive` queries it over MCP — which listeners are *actually*
subscribed, which FSM state each force *actually* occupies — and diffs
runtime against the static model: **missing** (the occupied state
demands it, the game lacks it), **leaked** (live, but no occupied state
explains it — the subscription-leak bug class the wiretap discipline
exists to prevent), **unknown** (live, absent from the graph). The
states view marks occupied states with `◉ live`. The whole picture is
taken as **one atomic snapshot query** stamped with the game tick — a
live system moves between calls, so separate reads can tear, and a
sample is evidence about a moment, not an invariant (contrast a paused
debugger, which stops the world at a causal point and can answer *who*
subscribed, not just *that* it is). The query is config
(`setup{ live = { snapshot = … } }`), defaulting to the wiretap/bnw
shapes; permanent load-time subscriptions form the baseline. On its
first run against a running game it reported six flight-state handlers
still subscribed in `inactive`.

### Greenspun detection

Per Greenspun's tenth rule, every sufficiently complicated codebase
contains an ad-hoc implementation of half of Common Lisp — and those
halves are the navigation obstacles. cartograph **discovers** them: a
verb called repeatedly with a string key and a callable is an ad-hoc
symbol table (`add_action`, `register_listener`, `RegisterMessageCallback`
— all found from call shape alone, no configuration); verbs whose literal
keys overlap a registry's keys are its dispatch side, and discovered
pairs are linked automatically like any xlang binding
(`setup{ discover = false }` disables). Literal data tables mapping to
functions are surfaced as funcall tables, `eval`/`load`/`dlsym` as the
interpreter itself — all in the `greenspun` lint rule, counted and
jumpable. And once a registry is known, it gets the **consistency
audit** for free (`registry-audit`): keys dispatched but never
registered, keys registered but never dispatched — each direction
suppressed when its side has dynamic keys — and when an unmatched key
sits one slip from a real one, the finding names it:
`'on_tikc' is dispatched but never registered — did you mean 'on_tick'?`
(transpositions count as one slip; they are THE registry typo).

Two more halves are found the same way. **Ad-hoc RAII**
(`pair-audit`): acquire/release verb pairs detected by name morphology
(`unX`, `remove_X`, `open`/`close`) and confirmed by shared keys — then
the imbalance audit runs itself: keys released but never acquired get a
typo suggestion, keys acquired but never released are leak-prone
(suppressed when the release side is dynamic). **Schema mirrors**
(`schema-mirror`): literal data tables sharing a vocabulary — keys,
values, or a list column — are mirrors of one schema, clustered into
**families** (four tables sharing the state names is one finding naming
each member's divergence from the common core, not six pairwise
reports; pairwise-linked sets with no common core are labelled chains).
Candidates come from an inverted index over member strings, so the
comparison scales with actual sharing, not vocabulary count. On a real
mod this surfaced two FSM states missing from the validation table's
vocabulary. Scope notes, honestly: pairing is receiver-blind (two
different objects' `lock('x')`/`unlock('x')` cross-link), and a
released-key warning without a typo suggestion only fires when the
acquire side is fully literal.

The rest of the detector family, all self-configuring: **vtables** —
C/C++ initializer arrays carry litdata, so `struct cmd cmds[] = { {
"build", cmd_build } }` browses in the lit altitude and reports as a
funcall table; **FSM autodetect** — any `{name, from, to}` list opens
with `:CartographStates`, no adapter config; **access points**
(`access-point`) — a trivial function everyone calls is marked as
plumbing, in the lint and in its fn-altitude header; **clones**
(`clone`) — functions with identical data-flow shape and callee sets,
names normalized away (on pkgit this found `remove_tree` duplicated
verbatim across two files); **layering** (`layering`) — imports running
against a directory pair's dominant direction, each stray named.

When discovery *doesn't* find a registry you know is there,
`:CartographDiscover` explains why: with no argument, one verdict line
per candidate verb (`EXPORT (key = arg 1, 3 sites)` /
`IMPORT of 'register_listener'` / `rejected as export: callables at
0/2 sites, 2 needed — other args classify as lit ×2`); with a verb,
every gate's numbers — site count, per-position literal coverage,
callable classification, and the key-overlap arithmetic against each
discovered export. A misspelled verb gets pointed at the real one.

Array callables (`[$obj, 'method']`, `&Class::method` — even inside
Bind-style wrappers) and concatenated keys (**prefix families**:
`'save_' . $type` covers every `save_*` key) are classified at parse
time, where they're free — the default tier handles them, and the audit
uses families to lift its blanket dynamic suppression and flag only
genuinely uncovered keys. `:CartographDiscover!` is the **deep tier**:
a per-site source-scan fallback for graphs whose provider didn't emit
argument kinds (lua-ls dumps, older extractions). The bang applies what
it finds beyond the bindings in force — links, live — and restores your
exact location; the explainer's rejection lines tell you when the
button would change the verdict
(`… — would PASS with deep heuristics (:CartographDiscover!)`).

## Lint

`:CartographLint` runs graph-aware, whole-program checks and drops the findings
into the quickfix list. Not a luacheck replacement — it makes the *cross-file*
checks luacheck can't:

- **dead-function** — a *local* function with no caller anywhere (exported
  functions and metamethods are excluded — public/dynamically-dispatched surface
  isn't dead).
- **silent-drop** — a *bare* call whose callee is a **local or param** of the
  enclosing function, yet resolved to nothing **and** was not refused: resolution
  silently gave up on a callable it can see the binding for (the function-value /
  forward-declared-local class — `local g = f; g()`). The engine's contract is to
  resolve it *or* speak a refusal; silence is a uniform-honesty violation. Local-
  and bare-only (a free external name resolving to nil is an honest "not ours"; a
  qualified `obj.method` drop is receiver-typing, a separate concern). The
  resolver itself now enforces this — a param callee refuses as *higher-order*, a
  local one resolves to a unique same-file def or refuses as *fn-value* — so the
  lint is a regression detector: it gates on **boundedness, not name length** (a
  short bound name like `go` is still a gap), and in practice reports nothing.
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
- **resource-leak** (C++, `~`) — a raw pointer allocated with `new` and then
  **reassigned** without a release (`->drop()` / `delete`) in between: the first
  allocation leaks. Sound without escape analysis — a reassignment *definitively*
  kills the old reference, so (unlike a plain never-freed local) it can't have
  escaped via return or store. Manual-refcount / raw-pointer code only: a
  `unique_ptr` reassignment has no raw `new`, so RAII is skipped for free. The
  `~` is honest — a macro or an aliased pointer can fool the per-line source
  match. (Member leaks whose release belongs in a destructor are a separate,
  object-graph concern, not flagged.)
- **member-leak** (C++, `~`) — the class-lifetime sibling: a pointer **member**
  `m_x = new T()` acquired somewhere but **never released** (`delete m_x` /
  `m_x->drop()`) anywhere in the program — a leak for the object's lifetime (the
  release belongs in the destructor or a cleanup). Whole-program, and *sound on
  the free side*: a member name freed in any class is excluded (a name collision
  costs a missed report, never a false one). The `~` is honest about the other
  side — **ownership transfer** isn't modelled, so a member handed to another
  object that takes ownership can be a false positive; the finding is a review
  candidate. (`m_` member convention; raw `= new` only — a `unique_ptr` member
  auto-releases.)
- **null-deref** (C++, `~`) — a pointer assigned from a **nullable-returning**
  call (the irrlicht/luanti `…NoEx` / `emergeBlock` convention) and then
  dereferenced (`p->x`) with no null-guard in between: it can crash if the call
  returned null. The guard can be an `if (p)`, an early-exit `if (!p) return;`
  (even braceless), or an `assert(p)` — all recognized via the CFG's dominating-
  guard walk run *in reverse* (a guard proves *safe*; its absence flags *danger*).
  The nullness is tracked **per assignment**, so a plain `MeshBlock *p` parameter
  — which was never assigned a nullable return — is never flagged. The `~` is
  honest: the nullable-returning set is a name heuristic.

- **dead-state** — a module var written (from functions) but never read: dead
  weight, or dynamic access the graph can't see — the hedge is in the message.
- **seam-guard** — raw reads of a *folded representation*. Declare your seams
  (`config.seams = { { name, patterns, owners } }`) and any source line
  matching a pattern outside the owner files is a violation: the
  representation behind an accessor seam may change at any time, and a raw
  read is a latent break. cartograph's own at/df/argv seams are declared in
  `tools/guards.lua` — the migration that built them is an invariant now.
- **truncation** — `local a, b = x and f() or y`: `and`/`or` ADJUSTS a call to
  one value, so the extra targets are silently nil. Three real bugs in one
  day of this repo's own development earned the rule.
- **require-cycle** — SCCs over the *import* edges (call-cycle covers calls).
  Hedged in the message itself: import edges don't record load-time vs lazy,
  and a lazy require breaks the cycle at runtime.
- **sink-concat** (PHP) — a *divergent* SQL-injection smell: one function
  string-concatenates a param into a query-shaped sink **without** sanitizing
  it, while a *sibling* concatenates the same shape into the same sink and
  **does** — "you defended the peer, not this one". The sanitizing peer is
  *required*: it's the evidence. Sanitizers recognised are coercion (a scalar
  type hint `int $id`, an inline cast `(int)$id`) and **parameterization /
  escaping** (`param()`/`db_param()`, PDO `bindValue`, the escape family) — a
  param bound through one of those is the safe channel, not raw. The sink is a
  `~` **hypothesis**, never confirmed (a `query`/`where`/`exec…` method, a
  concat ending on a dangling `… id = `, or a DB receiver), so every finding
  says "sink unconfirmed". Because the divergence is required, it stays silent
  on uniformly-parameterised code (mantis, sylius: 0) and fires on the genuine
  article — it found a real (since-fixed) injection in grocy's
  `GetProductStockLocations` the moment it was pointed at the repo. Lone
  offenders with no divergent peer are reachability's job, not this rule's.
- **sink-source** (PHP) — the classic shape: a *request source*
  (`$_GET`/`$_POST`/`$_REQUEST`/`$_COOKIE`/`$_SERVER`/`$_FILES`) reaching a SQL
  sink, unsanitized. No peer needed — a superglobal is definitionally tainted.
  Scope-aware forward taint (top-level scripts *and* functions) tracks the
  value from `$id = $_GET['id']` through `"… '$id'"` (interpolation) or `.`
  concatenation to `mysqli_query`/`->query`/`->prepare`. Crucially it fires only
  when the taint is **embedded in SQL-carrying string text** — a bare value
  passed standalone (a bound parameter, `where('col', $v)`) is *not* injection,
  which keeps it silent on parameterised/ORM code (mantis, sylius, grocy: 0).
  Sanitisers: casts/coercion, parameterisation (`bindValue`, prepared
  placeholders), escapes. On DVWA the low/impossible gradient falls out cleanly
  — low fires, impossible (prepared + `bindParam`) stays silent. Sources are
  superglobals **plus framework request inputs** (a controller action — one
  `Request`-typed param — has its `Request` and route-`array` params treated as
  external). And a value **validated by a guard** (`IsIsoDate`, `filter_var`,
  `is_numeric`, …) is sanitised — so grocy's `Spendings` fires on its
  *unguarded* `product_group` concat while its `IsIsoDate`-guarded date path
  stays silent, in the same method. Still `~`: the sink is a hypothesis, and a
  same-scope tracer misses session/cross-page flows (cross-*function* flows are
  `sink-reach`, next).
- **sink-reach** (PHP) — taint rung 2: the *inter-procedural* shape a same-scope
  tracer can't see — a request source flows across ≥1 resolved call hop into a
  callee parameter that reaches a SQL sink. It rides the **resolved call graph**
  (`c.to` + an SCC pass, callees-first) rather than re-matching names: per
  function it computes which *parameters* reach an embedded sink, then
  propagates that backward — a caller passing its own param inherits the
  reachability, a caller passing a source is flagged. The sanitiser that
  matters here is the **coercion** one, and it's a per-language fact: a PHP
  scalar type hint (`int $x`) rewrites the value at runtime so it clears taint,
  but a TypeScript annotation is erased and clears nothing — so the coercion set
  is declared per language, defaulting to *none* (sound: a type never silently
  drops taint). Validated on grocy: it fires on exactly the one real SQLi
  (`GetProductStockLocations`, an untyped `$productId` reaching `->where`) and
  stays silent on the `int $productId` sibling; mantis/sylius/DVWA: 0.

Structural smells, not proofs — dynamically-invoked functions (event handlers,
test cases run by a harness) can still read as "no caller". Rules live in
`lint.lua` and are pure/testable.

## Escalation (confirm the `~` hotspots against lua-ls)

`:CartographEscalate` spends the expensive oracle *only where the cheap
resolvers gave up*. A **hedge-saturated** function — one whose resolved calls
are *all* `~` (name-matched), none proven — is the signal that lua-ls will pay
off; those hedges are the work-list. cartograph runs a headless lua-ls over just
that work-list and **reconciles** each hedge against what the oracle says:

- **confirmed** — the oracle agreed; the `~` is promoted to proven.
- **conflict** — static resolved to *B*, lua-ls to *C* ≠ *B*: a real bug on
  **one** side (ours or theirs). This is the point — a disagreement is a lead.
- **refuted** — lua-ls found no such target; our name-match over-reached.
- **recovered** — lua-ls resolved a call static had *refused* (a free win).

It runs **async** — lua-ls's workspace load never freezes the editor — and is
idempotent within a generation: a hedge the oracle can't settle is marked so it
never re-fires, so a second run drains only what's left (on this repo, the
second pass asks ~13× fewer questions). `:CartographEscalate!` widens past the
saturated set to the whole graph.

Conflicts and refutations land as **in-buffer diagnostics** (`diag.lua`) — a
conflict is an error sign, a refutation a warning — right on the offending call,
not only in a report. The confirmations upgrade the live graph in place, so the
symbols pane shows `~`→proven the moment the oracle speaks.

Not every disagreement is *ours* to fix. Two conflict classes are lua-ls
following a **reassignment** of the called name that cartograph correctly did
not — it kept the name's own top-level, load-time def. `wraptriage.lua` **names
them** in the offline disagreement harvest (`tools/harvest_scan.lua`), splitting
the roster into *unexplained* (the real leads) and *attributed-to-lua-ls*:

- **wrap-passthrough** — `local function f() … end; f = wrap(f, …)`: lua-ls
  follows value-flow to the *factory* (`wrap`); since `wrap` is identity in the
  production path (a delegating profiler otherwise), cartograph's original is the
  correct target and lua-ls's `→factory` is imprecise.
- **nested-patch** — `X.m = function … end` *inside a function body* (Skada's
  one-shot `Skada.ReloadSettings` monkey-patch inside `:ImportProfile`): lua-ls
  resolves to the nested runtime patch; cartograph keeps the top-level binding
  where the call actually dispatches at load time.

On the WoW corpus, 72 of 144 conflicts are attributed (68 wrap-passthrough + 4
nested-patch), leaving a sharper 72 real leads. Pure triage — it changes no
resolution, only the accounting. (The banked *cross-file* override arm was itself
**refuted** by measurement: 0 genuine cases in 60 addons — the candidates are all
per-file-local `private`/`lib` tables sharing a member name, which a cross-file
last-write resolver would wrongly unify.)

## Reorder (statement commutativity)

`:CartographReorder` reports, for the focused function, which statements can
change order and which cannot: local dataflow chains (`#1 → #2  local stack`),
same-state conflicts (two *set-once* writes to the same key are excused — they
commute), world-order conflicts (two `io` effects — external order is
observable), and **opaque** statements whose effects didn't resolve — certified
for nothing, with the hedge named. The report's header carries its own
disclaimer: reads through calls are not modeled. Built entirely from the write
axis (`rw`/`gw`/`gp`), the effect summaries, and the signature packs.

`:CartographReorderApply <from> [<through>] <to>` is the write side: it moves the
statement at one line — or the contiguous **block** `<from>..<through>` — to
before another, **only when the verdict certifies it**. Moving a statement (or
block) inverts its order with each one it crosses, so it is behavior-preserving
exactly when *every* moved statement has no modeled relationship — dataflow
dependency or state/world conflict — with any crossed statement, and crosses
nothing opaque (an unresolved effect it can't reason about). A block moves as a
unit, so its internal order is preserved automatically and only the block↔crossed
relationships are checked. It refuses with the
specific barrier named (*"the move would cross #3, which has a dataflow dep
(local a) with it"*), and otherwise stages the one-line move as a transaction
you review with `:CartographDiff` and commit with `:CartographApply` — journaled,
span-checked, and re-parsed before it lands. This is the one analysis in the
cockpit that had stayed read-only; now the commute verdict has an editor.

`:CartographHoistClosure` is the decomposition verb for the other direction —
pulling a nested `local function` *out* of a bloated one to module scope. It is
the exact inverse of the extract-helper's nested check: a closure can be lifted
only when it **captures nothing** from its enclosing function — every name it
reads must resolve to a module-level definition or a global, never an enclosing
local or parameter (which would become nil once the function moves out). A
capture is refused with the variable named (*"captures enclosing local `cap` —
parameterize it first"*), pointing you at the extract-helper as the way to turn
that capture into an argument. When it is clean, the closure is cut, de-indented,
and re-inserted above its former host — its name follows it, so the existing
calls still resolve — staged as a transaction, parse-checked before it lands. A
name that would collide with an existing module-level definition is refused
rather than silently shadowed.

## Untangle (independent concerns + safe-to-split)

`:CartographUntangle` partitions the focused function into independent
**concerns** — connected components over the full **program-dependence graph**:
data (RAW) + output (WAW) + control (a body depends on its guard) + side-effect
ordering (non-commuting impure statements, via the reorder model). Statements in
different concerns share *no* dependency, so they can be reordered or extracted
independently. Each statement is tagged with its concern (A/B/C…), indented by
nesting; the footer gives a **sound safe-to-split verdict**: `CERTIFIED` when the
PDG is complete, or `~ NOT certified` with a breakdown of *why* — the specific
opaque statements (unresolved calls, aliasing) whose hidden effects could couple
concerns across a boundary. Resolve a blocker → re-run → it certifies. Built on
`flow.reaching_cfg`, `cfg.guards_over`, and the reorder effect model; the PDG's
WAW edges ride `reaching_cfg`'s scope-regime reaching, so reused block-locals
don't falsely couple. When a function has more than one concern, the report ends
with **extract candidates**: each contiguous certified concern is handed to
`extract.plan`, which independently validates the mechanics (live-in→params,
live-out→returns, refusing on control-escape or ambiguous returns) — so untangle
picks the boundary and extract.plan checks it. A scattered concern is refused
until a reorder gathers it.

`:CartographUntangleModule` is the same idea one level up — it clusters the
focused *file's functions* into independent groups over call edges + shared
mutable module state (read-only shared consts don't couple), the god-file split
signal. Same sound verdict: a cluster is `CERTIFIED` safe to extract as its own
module only when no unmodeled edge — a silently-unresolved call to an in-scope
name, a `t[k]()` dispatch, dynamic dispatch, or unclassified state — could
secretly connect it to another cluster; otherwise `~`, with the blocking calls
named. Pass a directory (`:CartographUntangleModule <dir>`) to cluster a whole
package across files; a certified cluster hands off to the module extractor
(`moveapply`), whose load-order/cycle hazards are the independent cross-check.
What counts as shared state is a per-ecosystem sharing-model seam (the default
couples any written module var).

Connected components answer *"are these provably independent?"* — a strict
yes/no. But cohesive code is often **one** connected concern with rich internal
structure (a 90-line function, a god-file where everything calls everything).
Both reports then run **community detection** (greedy modularity) over the same
edges: a strict refinement of the components that finds the denser sub-groups
inside a connected blob. In `:CartographUntangle`, refined rows carry a lowercase
sub-group tag (`[a]`, `[b]`); `:CartographUntangleModule` lists the cohesive
sub-modules. This is a *refactoring suggestion, not a safety claim* — communities
share edges across their boundary, so the report always prices the cut (*"breaks
N dependency edges: 15 data, 7 control"*): those are real dependencies a split
would have to sever.

Untangle detects *independent-slice* tangle. The other kind is *linear-pipeline*
decomposition — a big function that's one cohesive concern but wants its nested
loops and branches pulled into helpers. `:CartographExtractBlocks` is the view for
that: it enumerates the focused function's control sub-regions (every loop/branch,
at any nesting depth) as extract-into-helper candidates, in source order and
indented by nesting. Each carries its interface — `(params) -> (returns)`, the
locals live-in and live-out computed over the block's reaching row-set, so it reads
*nested* blocks (where `extract.plan` handles only whole top-level statements) — and
a control-escape verdict: a `return`/`throw`, or a `break`/`goto` whose target sits
outside the block, marks it `~` (moving it would change control flow). A `*` flags
the sweet spots (clean, substantial, small interface). On a 40-line render loop it
surfaces the marker-scan `while` as `local pos = scan_markers(at, line, out, pos)`.

Where untangle and extract-blocks *refactor*, `:CartographOptimize` *optimizes* — it
reads the same PDG to find **loop-invariant computations**: a pure declaration inside
a loop whose inputs are all defined outside it (or are themselves invariant) computes
the same value every iteration, so it can be hoisted above the loop. Each is marked
`*` (unconditionally hoistable) or `~` (invariant but hedged — a table-content read
whose aliasing we can't rule out, or branch-guarded). It is deliberately conservative:
allocations (`{}` — fresh identity each iteration), loop induction variables, and
reassignments (which may be read before the write) are never certified. For the clean
(`*`) ones it prints a **hoist plan** — the exact statements to lift above the header —
gated by an independent capture check (a hoisted `local` is only safe if its name lives
nowhere outside the loop), so a value-invariant row whose *move* would collide is
flagged rather than suggested. The same lens
also reports **redundant computations** (CSE): two statements in one block computing
the same expression over the same operand values, where the earlier already produced
the result — so the later can reuse it (again `~` when a table read might have changed
under it). A suggestion, never a silent transform — the same discipline as the rest.
It also flags **globals to localize**: a module function called inside a loop
(`math.floor`, `table.insert`) is re-resolved through the global table every iteration,
so binding it to a `local` above the loop — `local floor = math.floor` — is a small,
always-safe speedup; the report lists each with its in-loop call count. Underneath, all
of this now reads the shape of each expression from the same intermediate representation
that powers `:CartographExpr`, rather than scanning source text: allocations, table
reads, and the "is this the same computation?" test are answered structurally, so a
brace inside a string or a comment mid-expression can no longer fool them. Redundancy
is found across blocks, not just within one: a computation whose value was already
produced by a statement that *dominates* it — one that runs on every path leading here —
can reuse that result, and a computation performed in *both* arms of an exhaustive
`if`/`else` over inputs fixed before the branch can be lifted **above** it and computed
once (partial-redundancy elimination). Dominance is judged on the control-arm path, so a
value computed in one branch is never mistaken for available in a sibling branch it never
reaches.

These are suggestions until you ask for them to be *applied*. `optapply` is the piece
that acts: it takes the CSE-reuse finding and rewrites the source — `local b = x + y`
becomes `local b = a` where an earlier `local a = x + y` already holds the value — through
the same transaction layer the move and extract refactors ride (journalled, undoable). It
runs headless, so it is something a program can drive rather than a person clicking in a
pane: plan, preview the exact diff, then apply — pointed at a single function, or even a
single line (resolve the spot, rewrite just that redundancy, leave the rest untouched).
Because a common-subexpression rewrite
*deliberately* changes the dataflow (it removes a recomputation, and any call inside it),
it can't lean on the move refactor's "the graph must look identical afterwards" check;
instead it verifies that the text it is about to replace is still exactly what it planned
against, that the result parses cleanly, and — through the transaction layer — that the
file hasn't shifted under it, and it reports the graph change rather than forbidding it.
Only the safe rewrites are offered: never a hedged one, and only when the reused value
lives in a variable that is assigned once and so can't have changed underneath.

The same machinery drives three more rewrites. `optapply` can **localize** a global looked
up inside a loop — insert `local floor = math.floor` above the loop and rewrite the calls
to `floor(x)` — it can **hoist** a loop-invariant computation above its loop, and it can
lift a computation done in *both* arms of an `if`/`else` above the branch so it runs once
(**PRE**). They
apply a discipline worth naming: the *apply* is stricter than the *suggestion*, because
acting on a finding has to consider things a read-only report doesn't. Localizing only
touches a genuinely-always-present global (so the line it lifts out can't raise an error
on a path that never ran the original), never shadows a name already in scope, and stays
out of loops containing nested functions; hoisting only lifts out of a loop that is
guaranteed to run at least once, so a computation that might throw can't be relocated onto
a path — an empty loop — that would have skipped it; PRE is the safest of the three, since
an `if`/`else` always takes exactly one arm, so lifting the shared work above it changes
nothing about what runs.

When a rewrite is refused, the refusal is not silent — it's recorded with its reason
(*"the loop may run zero times"*, *"`myglobal` may be nil"*, *"`a` is reassigned
elsewhere"*), and for the sharper ones the *evidence* behind the verdict (the exact line
`a` is reassigned at). A refusal is a **hedge**: a fact the analysis couldn't establish on
its own. So rather than a blunt override, you *discharge* it by supplying that fact — "this
loop always runs", "`math` is always defined" — chosen from the small menu each refusal
carries; the premise you assert is written into the transaction journal, so the override
is on the record. Some refusals need no assumption at all — a name that would be shadowed
is simply rebound under a fresh one. And the mechanical checks never bend: supplying a
premise waives a judgment, never the guards that stop a corrupt edit.

`:CartographNarrow` is the branch-sensitive counterpart — the type sibling of
constant folding. Where a guard *proves* something about a variable (`if x`,
`x ~= nil`, `if x == nil then return`), it records the refinement in the region the
guard dominates: *in here, `x` is non-nil*. It reuses the same `guards_over` CFG
dominance the taint sanitizers ride, and narrows only where the predicate actually
proves it — an `and`-conjunction narrows every conjunct, but an `or` or a negated
compound narrows nothing. The guard vocabulary is per-language and extensible. Beyond nil and
truthiness it reads **type tests**: `if type(x) == 'string'` narrows `x` to that type in
the region — the seed of devirtualization — which is sound for a local (a call can't
change its type) and, importantly, is only trusted when `type` is the real global and not
a variable that shadows it. It narrows **field paths** too (`if opts.mode`, `self.cache.x`)
and **discriminants** — `if x.kind == 'A'` records that `x.kind` *holds the value* `'A'` in
the region, the tag-dispatch companion of the type-test seed. A field path is sound only
while its container is stable, so the lens drops it where the root is field-written
(`opts.mode = …`), passed to a call, or aliased (any of which could change the field behind
its back) — but a bare local is immune to calls, so it distinguishes the two. On top of
these facts the lens flags **redundant checks** — an `if` re-testing something a dominating
guard already proved (`always true` / `dead branch`), including a re-tested or contradictory
type (`type(x) == 'number'` under a proven `type(x) == 'string'` is dead) or discriminant
(`x.kind == 'B'` under a proven `x.kind == 'A'` is dead) — the type twin of a dead-branch
constant fold. It is careful where control flow is: it distinguishes truthy from
non-nil (a non-nil value can still be `false`) and drops a narrowing once the variable
is reassigned, so it reports a redundancy only when the earlier guard genuinely still
holds.

`:CartographParamNil` turns the same guard analysis outward, onto the function's
*parameters*. For each one it infers a nilability contract from how the body uses it: a
parameter that is dereferenced (`p.x`, `p()`, `#p`, arithmetic on it) without ever being
checked — or that is `assert`ed — is inferred **required** (the code assumes it is
non-nil); one whose every dereference sits behind a guard or a `p and p.x` short-circuit,
or that is nil-tested anywhere, is **optional**; one never dereferenced or reassigned is
left **unknown**. Where the function carries a `---@param` annotation, the inference is
checked against it — and an inferred-required parameter annotated optional (`?`) is the
telling case: the body will crash on a `nil` the type says is allowed. That's a
disagreement with the type checker where one side is simply wrong, which is exactly the
kind of finding this project is built to surface. The inference is deliberately
conservative — it never calls a parameter required if the code checks it even once, so a
reported disagreement is trustworthy rather than a guess.

`:CartographDevirt` is where the type facts pay off. A method call `recv:m()` is a
dynamic dispatch; where a dominating guard narrows the receiver to a concrete type, the
target is (partly) resolved. When the receiver is a **string** (`if type(s) == 'string'`,
or the early-exit `if type(s) ~= 'string' then return`), `s:m()` *always* dispatches
through the string metatable to `string.m` — fixed at the C level, so it is sound even if
the global `string` is shadowed — and the site is reported **certified**, a named
static-call target and an inline candidate. When the receiver is another concrete type
(a table, say), the site is a **candidate**: the type is known but the actual target needs
a class/metatable binding that guard-narrowing cannot supply — it waits on the VM's
receiver typing. A receiver narrowed only to non-nil or truthy is *not* a devirt site,
because that says nothing about which method runs. The summary counts the two tiers, so
the report doubles as an honest measure of the devirtualization gap: what a concrete
receiver type turns static now, and how much the VM still gates.

`:CartographFields` is the data-member half of receiver typing — go-to-definition for a
field. Inside a method of class `C`, a `self.field` *read* resolves to the `self.field =
…` *write(s)* on `C` (its own methods plus its `extends` ancestors): where is this member
actually set? It's the field analog of `self:method` resolution, and it lands squarely on
the Ace3 `self.db`-assigned-in-`OnInitialize`, read-everywhere pattern. Self is typed by
the same genuine-object contract (the class owns ≥2 colon-methods); a field written in
several places resolves to the set (the definition is the join). Crucially this is
**resolution, not a lint**: a read with *no* same-class write is left unresolved, never
flagged — Lua's dynamic members (metatables, `rawset`, table loops) make a writeless read
a poor signal of a defect, so the undefined-member lint stays off and only sound
read→write links are reported.

**Reassignment-override** is the value-flow side of resolution. A table slot written by
more than one *unconditional top-level* def — `function T:m() … end` then `T.m = function
… end`, the monkey-patch idiom — is, at runtime, the **last write in load order**; a call
name-matched to a superseded def is redirected to the effective one (value-flow beats the
separator/first-def match). It is sound-gated on load-order: a **branch-selected** slot
(`if nLog then function kit:Debug … else … end`) has no last-write winner and is left
exactly as name-matched — measuring the real corpus, that conditional shape is the common
one and a naive "last wins" would be confidently wrong there, so it never fires. A runtime
reassignment *inside* a function is not a load-order sibling either. The redirect wears the
honest `~`; same-file only (a cross-file "override" is not a load-order fact).

**Prototype-OOP self-typing** is the same "receiver-type beats name-match" inversion, one
level up. A method of a *dotted* owner — `Widget.prototype:Refresh`, or the nested-namespace
`Addon.UIElementsLib._DropDownMenu:Toggle` — is a genuine object in its own right, but the
owner used to truncate to its first segment (`Widget`), so `self:m` inside it fell to a
promiscuous member-name match on an *unrelated* same-named def. Now `self` types to the full
dotted owner, and `self:m` resolves to that owner's own member — **overriding** a foreign
promiscuous match (every `Waterfall*.prototype:SetText` had wrongly landed on an unrelated
`FuBarPlugin:SetText`). Gated on the genuine-object contract (the owner owns ≥2 colon-methods);
measured to fire **zero** times on non-dotted owners — where the name-match is already right —
so it corrects the prototype/nested-OO idiom without disturbing the resolutions that worked.

`:CartographExpr` reads one level deeper still. The flow rows know *which* names a
statement defines and uses, but not the **shape** of the expression that computes them —
the operator, the operands, the callee, whether it allocates. That structure is a small
closed intermediate representation harvested alongside the flow rows (a literal, a name,
a field/index, a call, a unary/binary op, a table or closure allocation, or an honest
`?` for anything not yet modelled — so it never lies about what it doesn't understand).
On top of it ride the **Rung-0 lints**: a comparison whose two sides are identical
(`a == a`), a logical operator with a duplicated operand (`a or a`), a comparison to a
boolean literal, a self-assignment (`x = x`), the classic `c and x or y` ternary trap
when `x` can be falsy, a condition that folds to a constant, a string built with `..`
inside a loop (quadratic — accumulate and `table.concat` instead), and a branch
condition duplicating an earlier one in the same `if`-chain. Every equality-based check
is gated on purity, so it never flags two calls that might return different values, and
a runtime subtlety (NaN self-comparison, a metamethod on a field target) is marked `~`
rather than asserted. The representation carries its own correctness proof: the names it
says a row reads must exactly equal the names the independent def/use pass found — a
disagreement is a real bug on one side, and that gate runs clean across the whole
codebase.

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

## Tools (dev bench)

`tools/` is measurement tooling for working ON cartograph — outside the
plugin's runtime path, never required from `lua/cartograph/`.

```sh
# extractor-change gate: extract a named corpus, check calibrated counts,
# per-item diff (graphdiff) against the saved baseline snapshot. Exit 1 on
# any drift.
nvim --headless -u NONE -l tools/gate.lua server
# (re)establish the baseline on a known-good rev
nvim --headless -u NONE -l tools/gate.lua server --save
# df/flow PARITY gate: coarse(flow)==df (per-statement def/use, category-
# catalogued) + flow's CFG invariants (successors/liveness/reaching) run clean.
# Since the df-strangler completed (step 6), production df IS flow.coarse, so
# the gate extracts with legacy_df to build the INDEPENDENT (dfreg) df and
# checks flow.coarse still reproduces it — a pure regression oracle. Pins a
# per-corpus labeled census; fails on any class delta.
nvim --headless -u NONE -l tools/dfgate.lua cpp
# --show <class>: the divergence EXPLORER — dump a class's instances with source
# + the flow={}/df={} sets (the fix-side view); no class lists the classes.
nvim --headless -u NONE -l tools/dfgate.lua rust --show flow-over-collects
# dfconsumers: the df-strangler STEP-5 consumer census — who reads the df.* seam
# (a require-scoped scan = reliable + complete) plus a dogfood cross-check that
# surfaces cartograph REFUSING ambiguous method names (get/has/count/present) —
# the receiver-typing gap, and the argument for re-backing df.* with flow.coarse
# (consumers untouched, equivalence guaranteed by dfgate) rather than rewriting.
nvim --headless -u NONE -l tools/dfconsumers.lua
# EXTRACTION PROFILER: where does a corpus's cold-extraction wall go? Flips the
# treesitter `M.PROFILE` gate (nanosecond accumulators, output-inert, off by
# default) and prints the per-phase breakdown sorted by cost — parse /
# extract_defs (incl. flow.build, reported separately) / extract_calls /
# collect_mentions / resolve / constfold, with the unmeasured remainder as
# `other`. Measure-first for perf work: it pinned flow.build as the hot phase
# (52% of ghost) and the fusion win that followed (a redundant per-statement
# subtree walk, −43% flow.build) — MEASURE, don't guess (the obvious FFI
# micro-opt profiled as pure noise).
nvim --headless -u NONE -l tools/profile.lua ghost server
# THE MATRIX: every parity/honesty invariant × every registered corpus, one
# command — the push-time sweep. One inline extract per corpus feeds all the
# cheap columns (counts, validate, memory budget, df/flow parity, fold
# round-trip, silent-local gap, cold==warm cache); only `par` pays for a
# second extraction (inline==parallel, in a pristine child process — the
# previously unswept oracle: it found a real inline≠parallel divergence on
# its first full run). Each corpus runs in a fresh process, so one row
# crashing costs one row. Exit 1 on any FAIL, 2 on soft notes, 0 all green.
nvim --headless -u NONE -l tools/matrix.lua              # full sweep
nvim --headless -u NONE -l tools/matrix.lua --quick      # seconds-tier only
nvim --headless -u NONE -l tools/matrix.lua libs server  # named rows
nvim --headless -u NONE -l tools/matrix.lua --cols par   # one column
nvim --headless -u NONE -l tools/matrix.lua --save       # re-baseline structs
# GENERATED-CODE fuzz bed: synthesize a corpus (seeded, deterministic, valid
# by construction — tree-sitter parse-clean, lua additionally load()-asserted)
# and let the matrix's invariant columns judge it. The third oracle kind: not
# history (baselines), not ourselves agreeing (parity) — truth by
# construction. silent==0 is the headline oracle: a generated program where a
# bound callable resolves to nothing with no refusal is a fresh honesty bug.
# Failing seeds keep their dir as the repro artifact. Idiom mixes = the
# resolution-ladder bestiary. lua: forward decls, fn-value aliases,
# higher-order params, shadows, short names, setmetatable classes, requires,
# goto-continue. java: interfaces + @Service impls (the only LOCALLY-testable
# F1 bean redirects — local Java corpora are non-Spring), unique Builder<k>
# chains (the positive return-type-rounds path), nested enums with methods,
# overloads, method references, cross-file statics.
nvim --headless -u NONE -l tools/gen.lua lua --check --runs 20
nvim --headless -u NONE -l tools/gen.lua java --check --runs 10
nvim --headless -u NONE -l tools/gen.lua js --check --runs 10
nvim --headless -u NONE -l tools/gen.lua java --seed 7 --out /tmp/g  # just generate
# SYNTHETIC ANALYSIS GROUND-TRUTH: the same truth-by-construction oracle, for the
# analysis LENSES. Plants narrowing scenarios with a per-line answer key — including
# NEGATIVES (guards that must NOT narrow) — then runs the lens and diffs. The
# negatives are the point: a lens that fires where it must not is a false positive
# caught mechanically, not by eyeballing self. Exit 1 on any false pos/neg.
nvim --headless -u NONE -l tools/syngate.lua
# RUNTIME/CONFIRMED tier — the dispatch OBSERVER (the VM's runtime axis, the one
# honesty rung lua-ls structurally can't reach). Runs a bounded cartograph
# extraction under a call hook (JIT off so no traced call is invisible), maps
# every observed (caller -> callee) dispatch back to static graph nodes
# (self_oracle.resolve_fn), and feeds confirm.apply against cartograph's OWN
# self graph. CONFIRM (an edge the graph has, seen live) + RECOVER (an edge
# static REFUSED, seen live) — the latter is the product: it recovers the
# spec-hook dynamic dispatch (spec.qualify_call / is_method / resolve_import,
# function-valued table fields) that static resolution correctly refuses.
# SOUND by confirm.lua's spec: observed ⊆ static, so it CONFIRMS + RECOVERS,
# ABSENCE NEVER REFUTES; runtime facts are SAMPLES (counts vary run-to-run) —
# a session-live overlay, never folded or cached.
nvim --headless -u NONE -l tools/observe.lua          # workload defaults to synlua
nvim --headless -u NONE -l tools/observe.lua bnw      # any lua corpus as the workload

# SPEC AUDIT (project-management action: the subject is cartograph's OWN
# specs/packs, not user code) — M.spec + M.packs are hand-authored CLAIMS
# (grammar node names, stdlib verbs, framework DSL vocab) and nothing else
# checks them. Two tiers, never conflated: CONFIRMED stale = a query fails to
# COMPILE against the grammar (the grammar is the oracle); SUSPECT stale = a
# query capture / stdlib_names entry that never FIRES across the audited
# corpora (unexercised ≠ nonexistent). Vocab firing is counted from gate
# snapshots keyed by the FILE's language (mixed corpora exercise embedded
# langs); pack vocab is audited only where the pack is ACTIVE; plus GAP
# candidates (frequent plain-unresolved callees no vocab claims — where the
# next pack comes from).
nvim --headless -u NONE -l tools/specaudit.lua              # default corpus set
nvim --headless -u NONE -l tools/specaudit.lua ruby rails   # explicit corpora
nvim --headless -u NONE -l tools/specaudit.lua --extract    # extract when no snapshot
```

Three SYNTHETIC corpora are registered first-class in `tools/corpora.lua` —
`synlua`, `synjava` and `synjs` (js adds hoisted forward calls, fn-value
consts, let/var scope regimes, arrows, ESM + one CommonJS module, and
`min.js`, a one-line minified module exercising the (l,c) column spill),
identity `(GEN_VERSION, lang, seed, files)` instead of a git rev. `bench.corpus` materializes a missing root by running the
generator, so `gate synjava`, `dfgate synjava` and their matrix rows run on
**any machine, with zero corpus checkouts** — the portable regression tier
(the real pinned corpora keep the jobs synthesis can't do: ecology validity
and surprise). Both are fully calibrated: expected counts, structure
baselines, df/flow parity censuses. A generator change bumps `GEN_VERSION` →
new root paths + recalibration, the same discipline as expected counts.

Synthetic corpora also carry an **ANSWER KEY** — the matrix's `key` column.
While emitting its deliberate idiom sites the generator records the *intended
outcome* per call — resolve to THIS def at THIS honesty tier
(`plain`/`~`/`tinf`), or refuse with THIS rule — and the column checks the
extracted graph against it (the key regenerates in-memory from the seed;
nothing is persisted). This is the semantic gate: every other column asks
"did the answer change", the key asks "is the answer RIGHT". Where the
resolver's sound current answer is a refusal (enum-constant receivers,
overloads — the generator *knows* which modules it overloaded and predicts
refusal vs resolution per site), the key encodes the refusal explicitly: an
upgrade later edits the expectation as a reviewed claim, never as silent
count drift. Calibrating the keys formalized real gaps as
executable spec: V2 ctor-typing doesn't fire on module-top-level locals
(in-function is the supported shape); js receiver typing doesn't exist
(this-chains and `obj.method()` refuse as ambiguous — the encoded current
rung). The `want='silent'` key kind documents honesty gaps that must FAIL
the moment they're fixed — and it already worked once: it documented
resolve()'s `#name<3` short-name silent skip, the fix landed (short names
now resolve through the SAME-FILE tier; cross-file stays noise-gated), and
the site flipped to a positive spec line as the reviewed upgrade. F1 bean
redirects and rt-round chain tiers are pinned positively.

`tools/preflight.lua` is the dev loop as one command: git-diff impact (changed
lines → containing functions → reverse call cone → the specs whose
require-cones reach any touched file), then the development guards, then the
suite — `--fast` runs only the selected specs (`SPEC=` filter on
`tests/run.sh`; selection is import-cone based, so the *full* suite still
guards the push). `tools/guards.lua` self-applies the development lints with
cartograph's own seam declarations, and (reusing that same extraction) runs the
df/flow parity check on the repo — hard-gating `flow-invariant-errors==0` (the
CFG must never throw); the churning self census is reported here but pinned only
in `dfgate self`. The check core is `tools/dfparity.lua`, shared with `dfgate`. `tools/consumers.lua` is the shape roster
and seam rewriter (`--rw`/`--rwmod`/`--apply`, refusals printed as a review
ledger).

The **dogfood family** turns the tool on itself. `tools/dogfood.lua` is the
one-screen self-check (resolution by tier, the LSP answering its own graph,
lint) and the **seam-guard fence** — it exits non-zero if any code reads the
wide graph indexes raw instead of through the Band. `tools/ratchet.lua` logs
those numbers per run and prints the delta (`resolved -0.3%` is a regression you
see immediately). `tools/conflicts.lua <corpus>` shows each cartograph-vs-lua-ls
disagreement with source context and cartograph's tier, so a conflict is
triageable in seconds (the charter's "a disagreement is a bug on one side").
`tools/lspparity.lua <corpus>` is the serving acceptance number (consistency +
parity vs a lua-ls dump). `tools/gaps.lua <root>` ranks a project's unresolved
callees by the gate that stopped them — the resolution work-list. And
`tools/seammigrate.lua` enumerates any remaining raw wide-index reads with the
Band accessor each should become — the migration work-list.

Two **decision** tools answer "what's worth building." `tools/ablate.lua`
[corpus] drops each resolution pass in turn, re-extracts, and reports the
**net** resolution it loses — the marginal value `by_prov`'s gross credit
can't show (gross − net = redundancy; net ≈ 0 across corpora = a de-fund
candidate). `tools/levers.lua` [corpus] decomposes the *unresolved* calls by
the gate that stopped them, groups those into strategic levers (stdlib-profile,
pack/vocabulary, name-match, dispatch), and ranks them by the resolution points
each would add if realized — the "where's the biggest win" call as data, per
corpus (on zig it independently reproduces the ~50% std figure).

`tools/corpora.lua` names the corpora and holds calibrated baselines as data;
`tools/bench.lua` is the bootstrap + measurement discipline (timed runs, peak
RSS via `/proc`, median-of-N); `tools/snapshot.lua` saves slim extracts
(`~/.cache/cartograph-tools/`) so a one-minute extract is paid once per
version and diffed for free. A slim snapshot is instrument-faithful by
construction: `graphdiff` and `census` cannot tell it from the original
(pinned in `tests/snapshot_spec.lua`).

## License

TBD
