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

Sixteen languages (lua, c, cpp, python, js, ts, php, ruby, java, go, rust,
haskell, scheme, zig, odin, bash) plus vue/svelte single-file components.
Everything cross-file is name-matched and marked `~` unless an oracle proved
it; ambiguity refuses to link rather than guess.

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
- **block** — the view you descend a compound statement (`if`/`for`/`switch`, a
  nested lisp call) or a function body into; derived on demand from the source.
- **form** — one nested statement or call, a row in a block view (not a graph
  node). A switch's ARMS are forms of their own — `case 1:` stays one row and
  its statements are one descent further in, rather than being flattened into
  the switch or (as they were until CART-0449, in every grammar but python)
  unreachable. An arm that falls through to the next carries no statements and
  says so by being a leaf.
- **lens** — a way of reading the current altitude's rows, cycled with
  `<Tab>`/`<S-Tab>`. fn/block/region offer `statements` (default) and `detail`
  (arguments, conditions, var/field reads); fn also offers `lints`. The pane's
  winbar names the lenses an altitude has, so finding out costs no keypress —
  and says `— one view here` where there is only one. The lens rides the trail.

**Navigation**:
- **focus** — the node the cockpit is rooted on (shown in the source pane),
  set by a **pivot** (`<CR>`, or `l` where descending enters something).
- **context** — the transient hover preview that takes over the source pane,
  restored when you move off. *The view follows the eye; focus follows intent.*
  A context may name a **view** — a different rendering of the same subject —
  for the case where source is not the useful answer. The first is the files
  altitude's **neighbourhood**: hovering a file row shows, at full width and
  untruncated, what that file requires and what requires it, one hop, each
  neighbour with its def count, so descending is not blind. A whole file is not
  a recognition anchor, and one hop is small enough to render whole (measured:
  6 rows at the median, 36 at p90). `<C-]>`/`gf` on a neighbour row goes there —
  a row that names a file is a door to it. A module that has not been read (lazy,
  unparsed) reports its imports **unknown**, never a rendered zero.
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
  — a constants preamble reads as one row) so a run of script code can be
  skipped past; a region descends into **its statements**, each anchored to its
  source line, compound ones descendable again and call rows going to the
  callee. A region carries no dataflow (measured: 0 of 1,076 across three
  corpora, against 100% of functions), so those statements come from the source
  on demand — `forms`' RUN mode, since a region spans siblings and is therefore
  not a node — and their calls from the file axis, because a file-scope call
  record has no owner. `<Tab>` toggles the top level between the flat list and
  **layers** — the same one row per file, ordered by how deep the file sits in
  the import graph once its CYCLES ARE CONDENSED, level 0 (requires nobody)
  first, so the roster reads as load order. The level shows in the number
  column, not as an indent: an indent would be the walk's path, not the file's
  depth. A mutually recursive group is announced (`── cycle: 57 files ──`) and
  its members run contiguously, because "these files are a cycle" is the fact a
  drawn tree hides by rendering it as depth. This replaced an include tree that
  nested each file under every requirer: on mantis it drew 524 files as 3353
  rows up to 26 levels deep, `/config_api.php` matched 252 of them, and the
  indent pushed names off the pane — while the real condensed depth was 3.
  **Entry points** are first-class: files matching `setup{ entrypoints = {...} }`
  patterns (defaults cover the Factorio lifecycle — `control.lua`, `data.lua`,
  `settings.lua`, the `-updates`/`-final-fixes` variants — plus `main.lua`)
  get a `▶` sign instead of the `○` orphan warning; a file opens into
  **all its definitions** in source order —
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
statement reads (`l` opens the var's usage sites). The fn altitude adds `lints`
— `:CartographExpr`'s findings as rows, where `l` descends into a finding's
actions. The lens rides the `h`/`l` trail (ascend restores the lens you had),
but not the `<C-o>` jumplist.

A suppressed finding is still **counted**, and `◆ N suppressed here` is a **door**:
`l` opens the findings it counts as dim `∅` rows, each leading to the same actions
compartment, where `un-suppress` is what's offered. A count you can't open is a
receipt, not an affordance — without the door, a marker written five minutes ago
could not be found again from inside the browser, since `:CartographUndo` only
reverses the newest journal entry.

The pane's winbar names them, because a lens you can't discover is a lens you
don't have:

```
⇥ statements [detail] lints
```

The bracketed one is in effect, the key is the one you have *bound*, and an
altitude with a single view says `— one view here` rather than drawing nothing
— blank chrome is indistinguishable from chrome that failed. It obeys the same
30-column budget as the rows: too narrow to list them all and it degrades to
`[detail] +2`, counting what it withheld instead of truncating the list into a
claim that those are all of them.

### Configuration

Every binding is remappable (defaults assume qwerty; dvorak/colemak users can
rebind anything without touching pane code):

```lua
require('cartograph').setup {
    keys = { jump = '<C-j>', back = '<C-h>' },  -- names in lua/cartograph/config.lua
    symbols_width = 30,                         -- the browser's TEXT budget
}
```

**A row fits, or it says so.** `symbols_width` is the browser's *text* budget in
columns — the gutter sits outside it, and the window is sized to hold both. It
isn't cosmetic: `wrap` is off, so a longer row gets cut by the editor with no
marker and the pane silently withholds what it rendered (measured on a real
project: 28 of 35 file rows clipped at 30 columns, and the per-file symbol count —
the thing you scan the roster for — went first). So every row carries **one
identity that fits**, and whatever doesn't is detail with a home somewhere else. A
file row shows the shortest path suffix that is *unique among the files on screen*:
two `railbot.lua` in different directories each keep the directory that separates
them, a unique basename drops its prefix entirely, and descending (`l`) into the
file shows the dropped directory as a dim breadcrumb above the header. An identity
too long even alone is elided in the middle with `…`, both ends kept. The path is
never lost — hover, `gf`, staging and the source pane read the real path, never the
label. `tests/width_spec.lua` is the fence.

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
parameters (the enclosing function's parameters and locals the selection reads)
and return values (locals defined in the selection and used after it) from the
data-flow, shows the interface in the pane, and **stages a transaction** — review
the exact bytes with `:CartographDiff`, commit with `:CartographApply`, undo with
`:CartographUndo`. `:CartographExtractFn <first> <last> <name>` is the same verb
without the pane, addressing FILE line numbers, so a script or an agent can drive
it headlessly.

It is deliberately conservative: it works on **whole top-level statements** and
**refuses** a selection that cuts a loop/branch body, contains a
`return`/`break`/`goto`, uses the enclosing `...` (a separate function cannot
receive it), or would split a shadowed variable — scope-correct CFG reaching
decides that last one, never a name match. It cannot see non-local
(table/global) state, so that risk is disclosed as a hazard rather than silently
assumed away — verify those by eye.

Two report surfaces feed the same verb, so a finding can be acted on where you
read it:

- `:CartographExtractConcern <letter> [name]` stages one **concern** of
  [`:CartographUntangle`](#untangle-independent-concerns--safe-to-split) as a
  helper.
- `:CartographExtractCluster <letter> <dest.lua> [dir]` stages one **cluster** of
  `:CartographUntangleModule` as its own new module — the god-file split, end to
  end.

Both are **two independent analyses that must agree**: untangle picks the
boundary, and the extract/move machinery re-derives the mechanics. A cluster
untangle calls independent can still be refused on the mechanics, and that
refusal is the honest answer rather than a bug on either side.

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

Groups are ranked by **how many files the copies span**, not by how long the
block is. Length was the only signal this tier used to have, and it is the
wrong one: the real extractions in this repo's own history are 5–25 duplicated
lines per site, at or under any sane length floor.

Each group is also labelled with whether the extract verb can lift it
automatically — `[auto, helper takes 2]` — or only a human can, with the verb's
objection quoted: `[manual — the selection contains return/break/goto]`. That
label is deliberately *not* part of the ranking. Checked against this repo's own
git history, ranking on it buried the very seam the history certifies as real:
the LE-u32 pack loop duplicated across `at.lua`, `csr.lua` and `fold.lua` sat at
rank 183 of 479, refused because the block ends in a `return` — which is true
for lifting a *fragment*, and irrelevant here, because the duplication is a
whole function body whose return is the helper's return. That is precisely what
the commit consolidating it did. A seam is duplication worth sharing; auto-
extractability is whether one verb can do it for you.

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
capture it.

One shape of *structural* is not a restructure at all, and the report calls it
out: when an otherwise identical statement has a **literal on one side and a
read on the other**, the copies may not have been parameterized — one of them
may simply have gone stale. That is a bug report rather than a refactoring
suggestion, and it comes free from an analysis already running. This repo's own
history supplies the example: two copies of a scratch-window helper where one
read the close key from config and the other hardcoded `'q'`, so that binding
silently ignored a user's remap until the copies were folded together. The
report states it as a question — *either that is the parameter, or the
hardcoded copy is stale* — because nothing here establishes the two were ever
equal; what it checked is a literal facing a read, in a row that diverges
nowhere else. It is deliberately narrow: a row diverging in two places is two
different statements, not one drifted one, and a `nil` is the absence of a
value rather than a constant anyone forgot to update. On this tree it finds
nothing, which is the honest answer.

That check only sees inside near-clone *functions*, and drift is a property of a
single **statement** — so `nvim -l tools/clones.lua --rowdrift` is a second tier
for the same defect, aimed where the first is blind. It buckets every statement
by its own text with exactly one leaf blanked, so two rows meet only if they are
the same statement differing at that one position, and then applies the
condition that makes it precise: **the literal must equal the value the named
constant actually holds**. Neither half works alone — a matching row on its own
yields mostly noise, and "this literal equals a constant" on its own fires on
every `2` in a file that defines a `2`. Together they say something narrow: this
statement is written elsewhere using the name, and this literal *is* that name's
value.

The case that forced the tier is in this repo's own history. `fold.lua` defines
`RULE_SHIFT = 2` because the rule occupies bits 1–3; two decode sites divide by
`RULE_SHIFT`, the encoder multiplies by it, and one decode site divided by a
bare `2`. Correct while the constant is 2, silently wrong the moment the bit
layout moves — which is the single thing a named shift exists to prevent. The
two functions involved are not clones of each other, so the near-clone tier
cannot see it, and found nothing on this tree. The tiers are complementary
rather than nested: a literal facing an *expression* (`'q'` against
`require('cartograph.config').keys.close`) is the near tier's to find, because
one side is a whole call chain rather than a leaf.

A constant does not have to be a bare `local SHIFT = 2`. The two table-of-constants
forms count too — `local C = { SHIFT = 2 }` and a module-scope `C.SHIFT = 2` — and a
resolvable `C.SHIFT` is treated as a *single* blankable position rather than a field
chain, because the thing it competes with on the other side is one literal. Which
form to support was measured before it was built: across two 50-addon WoW batches and
this repo, the table forms hold two to four times more constants than bare scalars,
so reach went from 116 to 483 here and 1160 to 2934 on one batch.

The size cap that comes with it is not a taste call, it separates two populations.
Constructor tables are bimodal — small named-constant tables (`CTRL`, `ASSIGN_OP`)
and large *data* tables. Of 17,510 constructor fields on one WoW batch, about 15,000
live in nine tables: seven Atlas localisation tables and two game databases. Nobody
hardcodes a copy of a localisation string by accident. Booleans are dropped for the
same kind of reason, at the consumer rather than in the index: every `true` in the
tree equals a `true` flag, so the value half of the gate stops discriminating and
only the weak shape half is left.

Its yield is small and stated rather than dressed up: across this repo, three of
the four WoW batches (133 addons) and one other tree, it has fired exactly once —
on the `fold.lua` case
above, and tripling the reach did not add a second. It earns its place by being
**silent when there is nothing** and by catching what no other tier can reach, not
by volume. The constant must still live at module scope in the *same file* as the
site that reads it; the cross-file hop was measured and deliberately not built,
because the require-a-constants-module idiom appears zero times in either WoW batch
and ten times here. It is also the heaviest tier here — two re-parses per file — so
it is a dev-bench command, and large JavaScript trees currently exhaust memory where
`--near` copes. None of it is Lua-only: the expression layer learned the other
languages' constructor spellings, and the same index finds 1,048 constants in Ghost
where it had found 323.

And if anti-unification finds no real divergence at all (the
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
whole graph. Both clone reports are honest about their own confidence. The
near-clone count is stated as a lower bound, since a copy that inserts a local
can drift past the matcher — and each pair's position is printed as a **band**
(`#10-14 of 36`) rather than a point rank, because that tier orders on shared
statements and edit distance alone, so every pair sharing those two numbers is
genuinely unranked against the rest. Printing one of them as "12th" would assert
a comparison that was never made: measured on this repo's own history, the same
pair came back 13th on one run and 14th on the next, from identical input.

### The working set

Mark what you're working on; dive freely; come back. These ship as **commands**,
**unbound by default**: a graph operation with no vim idiom behind it doesn't
squat on a vim key (`m` already marks, `M` is middle-of-screen). The `keys.`
name after each is what to bind if you want it on a key.

- `:CartographMark` (`keys.mark`) — toggle the row's **subject** in the
  **working set** (● in the gutter; file rows carry ● when the file holds a
  member). The subject is the row's own symbol, else what the row *refers to* —
  a call site is about the function containing it — else the altitude's subject,
  so marking works while you traverse references and from inside a function,
  where no row is a symbol. It reports which it marked, since an altitude
  subject has no row to put the ● on. `:CartographCone` reads the row the same
  way.
- `:CartographWorkingSet` (`keys.set_view`) — the working-set altitude: your
  members grouped by file, with the cursor on the **last-visited member** — the
  way back from a code dive. `l` dives back in, `h` returns the way you came.
- `keys.set_next` / `keys.set_prev` — cycle through members (conscious pivots:
  `<C-o>` undoes).

```lua
require('cartograph').setup {
  keys = { mark = ',m', set_view = ',M', set_next = ']w', set_prev = '[w' },
}
```

The full default table, and everything else that is deliberately unbound, is in
`:h cartograph-keys`.

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

> A **fourth** seam now sits under the first: `transport.lua` answers *where bytes
> come from*, separated from what reads them. Its ops are `list`, `stamp` and
> `read` (with a ranged form and an optional bound reader) — three rather than one
> because their dependency footprints differ: a zip serves listing and stamping
> from its central directory, which is stored uncompressed, and needs zlib only for
> content. So "enumerable and stampable but not readable" is a real state a
> substrate can be in, and a missing library degrades a corpus instead of failing
> it. Failure has two kinds, `ABSENT` (authoritative) and `UNAVAILABLE`
> (indeterminate), because the extractor turns "no content" into a confident
> negative fact — a file it cannot read used to leave the graph entirely and its
> callers were reclassified as the project boundary. A zip archive is a substrate
> on the same contract (`lua/cartograph/zip.lua`, reading all 195 archives of a
> real Factorio mods directory), and composition is threaded rather than global,
> because extraction also runs in spawned worker processes that receive their job
> as JSON.

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
     imported one). That correction had a blind spot worth naming, because it
     silently withheld work rather than getting anything wrong: the two name
     indexes were consulted as `tail[m] or exact[m]`, which picks an index by
     whether the *qualified* list is empty **anywhere in the corpus** instead of
     whether it answers for this module — so as soon as any file defined
     `<anything>.m`, a module's own **bare** `m` became invisible and the
     correction stopped firing. Consulting `exact` as a fallback recovered 47
     calls on zig and 290 on ghost, with 174 further calls redirected off a
     foreign namesake and onto the module the `require` actually binds
     (`indexnow.listen()`, `registry.registerHelper()` — that last one had been
     resolving to a *test* file's export). Nothing was lost on either. A value-receiver method (`fn setExtra(symbol: Symbol)`) is
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
     Activation is inferred, but it **disposes to an explicit choice**: an
     extraction may pass `profile = "<name>"` to activate one regardless of
     what the shape thinks, or `profile = false` for none — the same nil/false
     asymmetry the pack option has, where absent means "detect" and an explicit
     value means "this". An unusable name is an **error**, never a silent
     fallback to detection: a distilled ingredient artifact or a signature-keyed
     one is refused with the reason, because a typo that quietly changed how a
     whole graph resolves while reporting success is the failure this fence
     exists for. It also makes a profile's contribution *measurable* — on the
     Von Neumann mod, extracting with and without gives 265 vs 201 resolved
     calls out of the same 635, so the profile is worth exactly 64 and nothing
     is fabricated. An overridden graph deliberately does **not** populate the
     project's cache, so measuring can't poison the ordinary open.
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
   - **tokens** (stack languages: Forth, PostScript): these cannot have a
     faithful grammar *even in principle* — Forth's parsing words rewrite the
     syntax at runtime — so the graph comes from token-level convention
     instead: definer words give defs, literal-name mentions give references,
     load order binds them (nearest-preceding, which *is* Forth's redefinition
     semantics). A root of these opens through it automatically; the file walk
     is tree-sitter's, so the same exclusions apply. Word mentions are ref
     **edges**, not call sites, and the graph says so
     (`capabilities.calls = aggregated`) — which is also why a **mixed** root
     opens through tree-sitter and *discloses* how many dialect files it left
     out rather than folding them in under a promise that doesn't hold for
     them. One root, one provider identity.
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

### Member-target definitions (JS/TS)

`X.y = function(){}` is a definition, and JavaScript was the only front end that
didn't say so: `const f = function(){}` minted a def, `X.prototype.m = …` minted
one, and the plain member target minted **nothing** — so `jQuery.extend`,
`module.exports.reload` and every other pre-class export was invisible, and calls to
them could not resolve. Lua had always minted the same shape (`M.f = function() end`).
`tools/assigndef.lua` measured the gap before it was closed; the gates measured the
result per call against a pre-change baseline:

| corpus | recovered | out of a refusal | redirected | **lost** |
|---|---|---|---|---|
| ghost | 1844 | 663 | 311 | **0** |
| grocy | 1230 | 12 | 0 | **0** |
| jquery | 36 | 11 | 20 | **0** |
| mootools | 4 | 16 | 35 | **0** |

The redirects are the column that matters, because a redirect can *destroy* a right
answer. Sampled on ghost they are corrections — `notify.notifyServerReady()` had been
resolving to boot.js's own local wrapper of the same name, `siteApp.reload()` to a
foreign namesake. On jquery, 10 of 20 fix calls that had been landing on the wrong
`error` / `matchesSelector`; 2 are wrong (`jQuery.error(…)` now hits `find.error`);
mootools' 35 are all `ua.match(/…/)` — String's `match`, where the old and new answers
are equally wrong. Nothing was lost anywhere.

**The other half is a veto**, and the gates are what forced it. A query cannot ask
whether a receiver is a module namespace or a function-local object, and the answer
decides whether the def is a fact or noise: `opt.complete = function(){}` inside
`jQuery.speed` answered every bare `complete()` callback call in the corpus, and
mootools' `this.$each = function(){}` has tail `each` (a `$` is not a word character),
so it captured every `each()` call. So the spec withholds a def when the receiver is a
local declaration or `this` — never for a `prototype` assignment, since those minted
before and a prototype method is a class method however its constructor is scoped.
Ghost's 1008 newly *ambiguous* calls are the honest side of the same coin: a test
file's `console.warn = …` stub now competes with `Command.warn`, and most of those
sites are `logging.warn`, which neither owns.

A positional parameter is deliberately **not** treated as local: in the AMD shape
every pre-ES6 library uses, `define(["./core"], function (jQuery) { … })` passes the
namespace itself as a parameter, and vetoing those removed 36 of jquery's 52 new defs
— its whole `jQuery.*` surface.

### Destructuring and imports bind names (JS/TS)

`const {k: ren} = src` used to record `def=[] use=[ren,src]` — the bound name was not
merely missing, it was counted as a **read of the statement that defines it**. Everything
keyed on def/use was wrong there: liveness, reaching, the scope model, unused-binding
lints, and the linker, which saw a module's own imports as reads of names nothing defines
and filed them as external surface.

Two different wrong behaviours by spelling, which is why no single symptom could count the
population — the shorthand form vanished silently (its binder is a
`shorthand_property_identifier_pattern`, absent from every leaf-name set), while renames,
arrays, rest and imports leaked as uses.

| ghost | patterns | bound names |
|---|---|---|
| javascript | 2732 (7.5% of declarators) | **4413** |
| of which destructured `require()` | 1466 | 2094 |
| typescript | 137 | 217 + 788 bound by `import` |
| jquery / mootools | **0** | — (pre-ES6; they must not move, and don't) |

A language declares `binder_fields`: which children of a pattern are in **def position**.
It is field-precise, because two children of a pattern genuinely *read* — an
`object_assignment_pattern`'s `right` (`{dv = fallback}`) and a computed key
(`{[dyn]: computed}`). A blanket "everything under a pattern binds" fabricates a def for
each *and* loses a real read.

The rule keys on the **pattern node**, not the declarator, so all three sites that hand
def-position to a pattern are covered by construction: a declarator, an assignment
(`[a, b] = [b, a]`), and a `catch ({message})` — which arrives with def-position *false*
and binds anyway. Destructured parameters come along for the same reason. `du` and the
expression IR read one exported rule (`flow.pattern_binders`), so the two cannot drift.

An aliased import binds the **alias**: `import {N2 as N3}` binds `N3`, and `N2` names an
export of the other module, so it is neither a local binding nor a local read. The module
linkage rides the import edge, which is unaffected.

And a shorthand property in an object **literal** is a *read*: `const o = {a}` desugars to
`{a: a}`, so it references `a`. Its pattern-position sibling is one letter longer and
*binds* instead, and only that one had ever been declared — 5047 occurrences in ghost's
JavaScript, 509 in its TypeScript, zero in jquery and mootools.

> Neither `du` nor the expression IR recorded it, which is why `expr.gate` — a genuine
> two-implementation oracle — reported **clean** on a fixture built to expose it. A gate
> like this finds only the bugs the two implementations do not *share*.

A **spread** reads its operand too, and that one was a wrong *kind* rather than a missing
case: `spread_element` was mapped to `vararg`, a kid-less leaf. Correct for Lua's `...`,
which names nothing; wrong for `{...base}` / `[...xs]` / `f(...args)`, which all carry an
operand. A spread is now a vararg only when it has none.

> The same lua-shaped assumption inside a language-agnostic IR as the field selector one
> construct over — a kind chosen against one language and silently wrong for the rest.

The three read-forms are one node (`spread_element`); the two bind-forms — `...rest` in a
parameter list, `[p, ...tail]` — are `rest_pattern`, covered by `binder_fields`.

### Receiver-path agreement

A call `a.b.m()` and a candidate named `b.m` agree on the *receiver*, which the
bare tail `m` says nothing about; where exactly one admitted candidate agrees,
that beats whichever name index answered first. It fires on idioms four languages
share — Go's embedded fields (`h.PathSpec.RelURL()`, where the field is named for
its type), C++ namespaces (`base::OS::Abort()`), Rust paths
(`grep::matcher::LineTerminator::crlf()`), JS namespace objects and private fields
(`this.#MemberLinkClickEvent.create()`) — and every call it changed had been an
**ambiguous refusal**: go +69, v8 +187, ghost +14, rust +9, with nothing lost or
redirected on any of the 29 corpora.

A **bare** candidate is deliberately neutral, never agreeing. Letting bare `m`
agree with `R.m` is the tempting extension and it is unsound: it would promote a
free function over a method for every receiver call in every corpus, and deciding
`foo.bar()` between a bare `bar` and `Class.bar` needs the receiver's *type*, not
its name. That line is where name-based resolution stops and receiver typing
begins — shipped for Zig (whose return types are written in the syntax), and
measured low-value for the dynamic languages, where the generic conventions are
exhausted and what remains is per-framework.

## Lint

`:CartographLint` runs graph-aware, whole-program checks and drops the findings
into the quickfix list. Not a luacheck replacement — it makes the *cross-file*
checks luacheck can't.

**Every rule declares what its findings claim**, because the counts do not mean the
same thing and a number that gates a build must be distinguishable from one that
proposes a conversation:

| disposition | what a finding is | gated? |
|---|---|---|
| **authoritative** | a defect by construction | **yes** — `seam-guard`, `silent-drop`, `truncation`, `load-order`, `dead-confined`, `annotation-mismatch` |
| **suggestive** | a proposal; needs a human, or a user-supplied template, to become a verdict | no — track the trend |
| **calibration-bound** | a count dominated by a known calibration question | no — triage before trusting it |
| **annotation** | not a defect at all; it labels structure for readers and views | no |

The bar for *authoritative* is positive justification, not absence of doubt: mistaking
a proposal for a defect fails builds for doing the right thing, while mistaking a
defect rule for a proposal only loses a gate. So the set is small and deliberately
hard to grow — a spec pins it by name, and another fails if any rule ships without
deciding. `greenspun` is the named suggestive case: it finds *more* when a language's
expressions become visible for the first time, so a rising count there is something to
triage, never a regression.

**A template is how a suggestion becomes a verdict**, and the environment is where one
is known: a profile declares its own registry idioms, derived from the declared API
signatures, so a discovered registry that matches one is correct platform usage while a
definition that duplicates one is `idiom-shadow` above. Those declarations compose with
the built-in cross-language boundaries rather than replacing them.

The rules:

- **dead-function** — a *local* function with no caller anywhere (exported
  functions and metamethods are excluded — public/dynamically-dispatched surface
  isn't dead). *Suggestive*: an entry point or a dynamically dispatched target
  reads as dead here, which is exactly what the next rule fixes.
- **dead-confined** — the same emptiness, **proved** instead of proposed, so a
  finding is a defect by construction. Three source facts, none of them a
  heuristic: the language says the function is file-local, its name is never read
  in a *value* position anywhere in that file (so it cannot be in a dispatch
  table, cannot have been passed as a callback, cannot have been fetched from
  another module — every one of those is a value position), and no *refused* call
  in the file could have been naming it. The message states the proof, so a reader
  can check it without trusting the analyzer. `dead-function` skips whatever this
  rule proves, so the two never double-report.
- **annotation-mismatch** — a `---@param NAME` that names no parameter of the
  function its comment block adheres to. The only part of a type annotation that
  can be checked *without* modelling a single type — a function either has a
  parameter of that name or it does not — so it is authoritative while everything
  else about an annotation stays a claim. Catches the stranded docblock (an edit
  inserted a helper between a doc comment and the function it documents) and the
  stale `@param` left behind by a signature change. Sound about three shapes that
  only look like disagreements: `@param ...` (a real parameter the signature list
  doesn't name), a dotted `@param opts.field` (checked against its root), and a
  language that declares no annotation syntax at all (not asked, rather than
  answered "none"). `tools/annotcensus.lua` is the measurement behind it.
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
- **idiom-shadow** — a definition that reimplements one of the *environment's own*
  registry idioms. The profile declares them, derived from the declared API
  signatures rather than guessed: `commands.add_command` is a string-keyed registry,
  `remote.add_interface` takes a whole `{[string]: function()}` one, `script.on_event`
  is keyed by an enum and `script.on_init` by nothing at all. A project definition
  carrying the same verb is Greenspun's tenth rule stated against a *known* idiom — on
  one real mod, a library builds its own `script` table with its own
  `on_event`/`on_nth_tick`/`on_init` and hands the handler tables out itself. An
  **annotation**, not a defect: providing your own event layer is an abstraction, and
  what a reader needs is the fact that this name is not the platform's.
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

## The data stage (prototypes as base + overrides)

`:CartographPrototypes` reads a project's **declarative data** — and the shape it
reads is the point, because a Factorio prototype is *not* a table literal:

```lua
local chest = table.deepcopy(data.raw["container"]["wooden-chest"])
chest.name = "vn-chest"
chest.inventory_size = 8000
pathReplaceRecursively(chest)      -- an opaque call
data:extend{chest}
```

A **base reference**, an **ordered sequence of field overrides** (order is the
fact — a later override wins), and a **registration**. Reading it needs
module-*top-level* rows, which is where 72% of a real 1.1 mod's 344 field
assignments live, so it could not exist before the module harvest.

It is a **lower bound by construction**, and says so in four ways rather than
smoothing over any of them. An opaque call receiving the prototype marks it
`~HEDGED` — not "mutator", because Lua passes tables by reference and the honest
claim is that a rewrite can't be *ruled out*, so `log(x)` is hedged too and you
can discount it from the callee. A non-literal value keeps its **path** and
records *why* the value is unknown (`<call>`, `<table>`, `<name>`). An unresolved
base **names the local** to follow instead of shrugging. And an explicit
`x.field = nil` is reported as a **delete** — a fact, and a different one from
"we couldn't read this".

On a real 2000-line mod: 54 prototypes in 31 modules, 26 registered, 14 hedged, and
**zero** left as a bare unknown — every one resolves to a named basis (copy ·
derived · copy-unresolved · literal · patch). Registration is read from the row's
dataflow **use set** rather than from the constructor, because `data:extend{chest}`
mentions `chest` only as an argument the dataflow already tracks.

A prototype written as a bare **literal** is read too, and it is the shape that
dominates elsewhere: across 195 installed mods, 3280 of 3874 `data:extend` sites
hand over an inline table against 594 that pass a variable. The expression IR models
a constructor entry as a key/value pair, so a literal names itself — its own `type=`
is its discriminator, exactly as `data.raw[<type>][<name>]` is for a copied one, and
`local x = {}` followed by `x.type = "sound"` is the same fact one line later. Those
entries are kept in `fields`, separate from `overrides`, because a literal's own keys
are construction and an override is a mutation. On the four-mod cross-project corpus
that took the readable property population from 1349 to **11448**.

The domain semantics are three declared fields (the registrar call, the base
table, the copy verbs) and activation rides the **env profile**, not the file
extension — so a plain Lua project is never read as a prototype tree, and another
ecosystem's data stage is a different adapter rather than new machinery.

## Trace (where a parameter's values come from)

`:CartographTrace [n]` answers "what actually reaches this argument?" for
parameter `n` of the focused function: one row per **resolved call site**, with
the classified value each one passes. Descend (`l`) takes the next hop and
splices it in under the row; pivot (`<CR>`) reveals the site in the source pane.

Expansion composes because every hop is another origin: a value that is itself a
parameter walks *up* the call graph, a local expands to its dataflow defs, a call
expands through the target's return summaries. Each row wears what it is — `▸`
has a next hop, `·` is an answer (a literal, or `(not passed — nil here)` where a
call omits the argument entirely), and `~` is a **frontier that says why it
stops**: a field or global (aliasing), a dynamic call, varargs. It never guesses
past one; a function with no resolved callers reports *why* it has none rather
than an empty list that reads as "nothing passes here".

It needs the whole graph, since the rows *are* call sites — on the thin index it
refuses instead of showing an honest-looking zero.

## What this code requires (one set, three questions)

An environment profile says what it *provides*. `:CartographRequires` derives the
inverse — what the code **requires**, in the same currency — and then porting,
version and dependencies are all set algebra over that one set:

```
this code REQUIRES — ruby: 2485 external name(s), version floor 3.1
  TIGHTEST ENVIRONMENT — shipped profiles by coverage of that set:
    ruby-rails        21.2% covered  (528 of 2485; profile claims 1734)
  NOT RANKED — 1 shipped artifact(s) of this language answer no
  NAME query, so each is not rankable here rather than 0% covered:
    ruby-core (302 symbols)
      — not a target: it has no name surface and no prototype surface — it
        is signature-keyed (String#chomp) or a distilled ingredient, so a
        verdict against it would call every name unknown
  DEPENDENCY MANIFEST — the requirement set grouped by who provides it:
    ruby-rails                    527 name(s),  1501 call(s)
    claimed by no profile        1957 name(s)
        id                                  500 call(s)
        DB.exec                             122 call(s)
```

Both halves of the requirement live in one place — the external names *and* the
version floor — which is what stops the three answers from drifting apart: the
portability audit scores exactly this set rather than walking the graph again.

Two honesty rules do the work. **Coverage is not a verdict**: full coverage means
this boundary holds no counter-evidence, not that the code runs there. And an
artifact that *cannot answer name queries* is **not ranked, and named as such** —
the RBS-derived `ruby-core` profile is keyed by signature (`String#chomp`), so a
0% would read as a claim about CRuby when it is a fact about the artifact.

Which is why **the roster is not the target list**. Every artifact that ships is
in the roster; a *target* is one that can answer the question you asked, and the
two differ by five files here. Three `lua-factorio-api-*` artifacts hold the whole
API — 291 members — keyed by class (`LuaGameScript::print`), a key space no call
name can match: they are *ingredients* a hand-authored profile republishes, and
scoring against one gave `0.0% covered` where the profile republishing the same
data answers 33 of 92. Two `lua-factorio-proto-*` artifacts answer no name
question at all and are the target of the *data-stage* diff instead. So the filter
is on what an artifact can **answer**, never on the `ingredient` marker it
declares — filtering on the marker was the obvious fix, and it would have dropped
both working data-stage targets while missing all three that caused the bug.
What is dropped from the ranking is *listed with its mechanism*: five artifacts
skipped in silence would read as "only three profiles ship".

## Portability (will it run there, and where does it break)

`:CartographPortability <runtime>` scores the **external surface** — what the code
uses but doesn't define — against a target environment, and buckets each name.
With **no argument** it prints the target list instead of a usage line: which
artifacts answer the *name* question, which answer the *data-stage* one, and which
ship and answer neither — with the mechanism, because none of them is a useless
file (see [the roster is not the target list](#what-this-code-requires-one-set-three-questions)).

```
portability — MOVING FROM factorio 1.1 (declared in info.json) TO lua-factorio 2.0.72
  33 of 92 external name(s) provided by the target
  the profile claims 280 symbols; a verdict is only as good as that
  NOT IN lua-factorio — 59 name(s) the artifact cannot adjudicate, grouped by WHY:
    48 name(s), 101 call(s) — RECEIVER-TYPED — the artifact models global-rooted
      calls only, so these have no representation in it at all …
     3 name(s),  16 call(s) — BARE AND UNCLAIMED — no shipped profile claims these …
     8 name(s),   8 call(s) — ANOTHER LANGUAGE — seen in files this profile does
      not describe …
  no ABSENT group: nothing here is a name a fully-enumerated class could have held
```

Two things in that header are the point. The **declared** end comes from the
package manifest — a file the resolver already parses — so the report states a
*move* rather than scoring against one unnamed side. And the not-in list is
**grouped by why the artifact is blind**, because "candidate porting work" was
wrong for every entry rather than for most: with a methods-only artifact that
models global-rooted calls, a miss was never evidence the target lacked the name.
Only `ABSENT` — the root is a global whose documented class is *fully enumerated*
and does not hold the member — says anything about the target, and the report says
so explicitly when no such group exists.

A dotted name needs its **root** provided, not just its tail — `print` is a
LuaJIT base function but `game.print` is Factorio's API, and matching on the tail
would have hidden the single most important dependency. That costs some true
positives where a receiver's type is unknown (`user.save` under Rails), and that
is the safe direction: under-claiming over-reports the work, while over-claiming
would *hide* a blocker.

The verb is small because it's one intersection: `externals.lua` already computes
what the code doesn't define, and every environment profile already declares what
a runtime provides. **No `<runtime>-provides` sets had to be authored** — a
profile *is* a provides set, so every distilled artifact that ships is already a
target, and `runtimes()` derives the list rather than hardcoding it. Run the same
codebase against different profiles and the diff is the porting work.

With **two** targets it diffs the move instead — the names whose status changes
*are* the porting work:

```
portability — MOVING FROM rich TO lean
  1 name(s) LOST, 1 gained, 1 provided by both, 1 by neither
  LOST — rich provides these, lean does not (the porting work):
    Rails.logger    4 call(s)
```

Both audits score the *same* requirement set, so nothing can drift between the
two sides, and the diff is directional — `a → b` losing a name is `b → a` gaining
it. On a real Factorio mod, moving to plain LuaJIT:

```
portability — MOVING FROM lua-factorio TO luajit
  58 name(s) LOST, 0 gained, 48 provided by both, 669 by neither
    util.by_pixel     470 call(s)      data.extend       318 call(s)
    serpent.line       23 call(s)      util.mul_shift      8 call(s)
```

Those 58 names *are* what ties the mod to Factorio. "0 gained" is the sanity
check: `lua-factorio` is a superset of plain Lua, so a move to LuaJIT can only
lose.

The same move on Ruby answers the question the lever was designed around — *will
this run without Rails?* On discourse's models:

```
portability — MOVING FROM ruby-rails TO cruby
  17 name(s) LOST, 55 gained, 47 provided by both
    I18n.t         302 call(s)      Rails.logger    31 call(s)
    Rails.env       18 call(s)      Rails.root      12 call(s)
```

Note the 55 *gains*: `ruby-rails` carries framework vocabulary, not a copy of Ruby
core, so each profile provides names the other doesn't. These two **overlap rather
than nest** — unlike `lua-factorio ⊇ luajit` — and the report says so when gains
outnumber losses, rather than letting it read as "plain Ruby is richer than Rails".

Both pairs exist because of two distillers — `tools/luadistill.lua`, which mints
the `luajit`
profile by **introspecting the interpreter** it runs inside, and
`tools/rubydistill.lua`, which asks the `ruby` on PATH the same way (177 free
functions, 143 namespaces, 2,024 typed members from 3.2.3, plus the default gems
so `URI.parse` isn't wrongly reported as unavailable). `for k in pairs(string)`
measures the runtime that will actually execute the code, where a hand-typed list
would only claim. nvim's own additions are excluded by name, since a profile called
`luajit` must not quietly promise `vim`, and the stamp records which LuaJIT it
saw. A move still needs two name-queryable profiles for one language — satisfied for
Lua and Ruby, and for **two versions of the same environment**: `lua-factorio-11`
is the Factorio 1.1 profile, distilled from the vendor's own published API
description and expressed as a *delta* over the 2.0 one (a second hand-maintained
copy of the shared Lua half would drift, and the drift would read as a version
difference). A JS pair awaits a second profile (a `node` introspection would work
the same way).

### The read surface (names touched, never called)

The audit above is built from **call records**, so a name that is read and never
invoked cannot appear in it — and two whole classes of porting work live exactly
there. On a real Factorio mod, `game.entity_prototypes[...]` is an index
expression and `global.foo` a field access: neither produces a call record.
`:CartographPortability! <from> <to>` adds that second surface — the bang is where
this verb spends real time — and a version pair turns it into a worklist:

```
reference diff — READS moving from lua-factorio-11 to lua-factorio
  10 LOST, 0 gained, 16 unchanged, 0 in neither
  LOST — present in the OLD environment, absent from the new:
    global.savedRailbots      11 read(s)  was: namespace global
    global.playersNeedZoom     9 read(s)  was: namespace global
    game.entity_prototypes     2 read(s)  was: member of LuaGameScript
    game.active_mods           1 read(s)  was: member of LuaGameScript
```

Those are the two real 1.1 → 2.0 items: `global` became `storage`, and three
`game` members moved to `prototypes.*` / `script.active_mods`. A status **change**
is evidence in a way an absence is not — it survives both artifacts being
incomplete the same way.

When the expression layer does not model a corpus's language, the section says
**NOT COMPUTED** and how many functions were never examined — because a read
surface that returns nothing looks exactly like a corpus with nothing to read, and
those are different answers.

It is behind the bang because it re-parses every function (~3.5 ms each — 6 s on a
1700-function corpus), and the default report *announces* it so its absence is
never read as emptiness. Reads are **locality-filtered** (parameters, locals and
declared loop bindings are excluded), which is what lets their roots be judged
more sharply than callees: a root the profile does not know is not "some
receiver", it is a global the target lacks.

Coverage is honest about its edges: it finds what the expression layer models as
field access, and **that is a per-language declaration, not a general capability**.
The layer was effectively a Lua one — a measured `?`-share of 5.4% on Lua against
~40% on PHP and ~38% on Python, with PHP carrying *three* field nodes and Python
*none*, because their grammars' node names had simply never been entered. Adding
four verified names (PHP `member_access_expression`, Python `attribute` and
`subscript`, Go `selector_expression`) took dotted reads from 54 to 151 on a PHP
corpus, 0 to 154 on Python, and **38 to 3363 on Go** while removing a third of its
opacity — from one node name.

Still outside it: **Java**, where `method_invocation` and `argument_list` are 58% of
the unknowns in one concept, and adding `field_access` alone was tried and reverted
because it unblocked nothing while the surrounding calls stayed opaque. Where the
iterated expression of a loop is itself a bare name it is treated as a binding, which
can only make an external name look local rather than inventing one.

This paragraph used to name **Ruby** here too, and say it produced no expression
records at all. That was measured, true when written, and false the next day — the
commit that added Ruby's `method` and `singleton_method` node names landed while the
sentence stayed. Ruby now answers for 173 of 192 sampled functions. The correction is
worth keeping visible rather than quietly deleting, because *a measured fact quoted in
prose is a claim with a shelf life* and nothing in the tree fences one: the doc audit
checks names against a registry and counts against the spec roster, and a sentence
asserting that a language produces **none** of something is neither — its only oracle
is a run. Note which direction rots unseen. A stale claim that a language *is* served
gets caught the first time somebody tries it; a stale claim that it *is not* is never
caught, because nobody tries.

### Stages: one root, one language, three environments

A Factorio mod is not one environment. `game` exists at runtime and not while
prototypes are being defined; `data` is the other way round. A profile scoped only
by root and language cannot say that — it claims all of them at once, so
`game.print()` inside `prototypes/entity/belt.lua` reads as **provided** when it is
a load-time crash. A profile may now declare `stages`, and one that doesn't behaves
exactly as before.

```
  STAGES: 31 file(s) placed in a load stage, 35 stage-scoped call site(s) judged;
  none is used outside the stage that provides it
    3 file(s) reached by NO entry point, so no stage applies and nothing above ruled
    on them (dead code, another language, or a load mechanism we do not model):
    prototypes/entity/demo-entities.lua, …
```

A file's stage comes from **reachability over the import graph**, not a path glob —
a glob over `prototypes/` would be one mod's layout dressed up as a rule, and it
could not express a helper required by *both* `data.lua` and `control.lua`, which
runs in both environments and may use only what **both** provide. Entry points are
declared by the profile because they are the engine's own loading contract, and that
includes `migrations/*.lua`, which nothing requires — the engine loads it directly,
so reachability alone can never place it (202 such files across 51 of 195 installed
mods). Anchored to one level: files *deeper* than `migrations/` are ordinary
requires, and reachability is the right mechanism for those.

When a name is used at the wrong stage, that is **not an absence**. The environment
has it, in a different stage — a stronger claim than not-provided, and a crash
rather than a missing feature, so it gets its own section rather than being buried
in the not-in-profile list.

**Only a module-level use is decidable, and this is where honesty costs coverage.**
Lua evaluates a function body when the function is *called*, so a runtime-only name
inside a function of a data-stage file is a violation only if something calls it at
that stage. Worse, the idiom for a stage-agnostic helper is to guard the global:
`space-exploration/scripts/log.lua` really contains `if Log.debug_prints and game
then game.print(…) end`. Judging those gave 17 findings on that corpus and every one
was false. They are **withheld and counted**, never silently dropped, and a local
that merely shares a global's name is recognised as a local — a parameter called
`data` carrying event data accounted for the other five false findings.

Every denominator is printed, because a bare "0 findings" cannot be told from
"nothing was checked": sites actually **judged**, candidates **withheld**, locals
recognised, and the files no entry point reaches, on which nothing was ruled. A call
resolving to a project definition is skipped too — `k-lib.lua` assigns
`script.on_event = function(…)`, overwriting the API member, so those 33 calls
dispatch to the mod's own code.

**What this does not do is find bugs.** Measured across 195 installed mods, the
factorio corpus and the Von Neumann mod: 961 + 35 judged sites, zero real
violations, and four entry-level candidates that all dissolved on inspection.
Factorio crashes loudly at load when a mod touches a global its stage lacks, so the
bug never survives development — the platform already fences the class. The
partition earns its place for other reasons: it is what makes the data-stage diff
below scope its population honestly, and reporting orphans found three genuinely
dead files. Treat a violation report as a safety net, not a yield.

### The third surface: a declarative DATA stage

Calls and reads are both *name* surfaces. A Factorio mod's data stage is neither —
it is a set of **prototypes** whose properties are table keys and field
assignments, so no dotted name exists to adjudicate. Give the verb two
**prototype-stage** artifacts and it dispatches on the stage they declare:

```
prototype diff — the DATA STAGE moving from lua-factorio-proto-11 to lua-factorio-proto-20
  54 prototype(s) read; 17 write(s) and 9 deletion(s) hit a removed property, 259 unchanged

  WRITES TO A REMOVED PROPERTY — 1:
    result                          recipe               prototypes/entity/assembling-machine.lua:70

  DELETIONS THAT NO LONGER DELETE — 9:
    animation                       assembling-machine   prototypes/entity/assembling-machine.lua:59
    circuit_wire_connection_points  transport-belt       prototypes/entity/belt.lua:33
    module_specification            mining-drill         prototypes/entity/mining-drill.lua:56

  THIS IS A LOWER BOUND — 28 of 54 prototype(s) could not be adjudicated at all:
    18 prototype(s) with NO READABLE TYPENAME — a literal with no `type=` anywhere,
       or one whose keys are COMPUTED, so nothing owns their properties
```

Two things make this a worklist rather than a name match. First, **a prototype
carries its own discriminator** — it is copied out of `data.raw[<typename>][<name>]`
— so each property is checked against the property set of the prototype that *owns*
it, walking the declared inheritance chain. Matching removed property *names*
against every `key =` instead is useless: measured on the same mod, `height` matched
44 sites and was lost by exactly one prototype, and `name` matched 26 and was never
lost at all.

Second, **a deletion is not a write**. Nine of those ten lines assign `nil` to
*remove* a property. That is neither a no-op nor a crash: the property is gone in
2.0, so the line now removes nothing and the entity silently keeps whatever the
deletion used to suppress. Different repair, different urgency, so they are
different sections — reporting all ten as "a value written to a property that no
longer exists" would be right about the facts and wrong about the work.

The lower bound is stated rather than implied, and it shrank rather than vanished:
a literal with no `type=` anywhere, or one whose keys are computed, still has nothing
that owns its properties. Those are counted as **unread**, alongside prototypes whose
typename could not be resolved and prototypes passed to an opaque call that Lua's
by-reference semantics say may have rewritten anything. A *runtime* artifact is **refused** here rather than
answered — it carries no typenames, so it would call every property fine.

It's the easiest verb here to overstate, so: the bucket is **NOT-IN-PROFILE**,
never "missing" — a dependency may supply the name, or the artifact may be
partial, and cartograph cannot tell which. The profile's own symbol count is
printed next to the verdict so a thin artifact can be discounted, and a profile
for a *different language* is refused outright rather than marking every name
unprovided and looking catastrophic.

## Roster (what the install actually holds)

Everything above is about *this* code. `:CartographRoster [ecosystem] [dir]` is
about the packages around it — an installed ecosystem's own directory, read
before there is a graph at all:

```
roster — lua-factorio
  mods:///mnt/c/Users/t0suj4/AppData/Roaming/Factorio/mods
  197 package(s), 5614 source file(s)
  ROOTS
    user     /mnt/c/Users/…/Factorio  (candidate)
    install  NOT SPECIFIED — the spec declares it NOT DERIVABLE, so it must be
             configured; nothing is guessed
      218 dependenc(ies) point at packages the install provides — unverifiable
      while the install root is unknown
  FORMS   archive 195 · directory 2
  READ THROUGH  disk -> zip
  ENABLEMENT   11 enabled · 186 disabled · 0 not listed
    affects HONESTY, never resolution: a disabled package is still present and
    still readable, so a require into it resolves and carries that its target
    does not load in this configuration
  IDENTITY   from the manifest, always. The two cheaper guesses, scored:
    filename hint      0 of 195 disagree — it held on every archive here, so it
                       is a sound SEARCH key (which is all it is declared to be)
    inner directory    112 of 195 disagree — THIS is why identity is never a
                       path: an archive's top directory is not its package name
  DEPENDENCIES   423 required · 432 optional · 472 satisfied here · 218 from the install
    2 LATENT — the package declaring the dependency does not load
    26 LATENT — at least one side is disabled
    163 optional dependencies are absent — normal, not a fault
    among the packages that LOAD: nothing required is missing, mis-versioned or
    in conflict
```

**Enablement is what makes the verdicts usable.** The first version of this
report announced *26 conflicts* on a perfectly healthy install — every one a pair
of mods that are present and disabled, which is the normal state of a mods
directory (186 of 197 here). A finding is ACTIVE only if the packages involved
actually load; the rest are kept and marked LATENT, because they are true and
they are not faults. That split is licensed by the spec itself, which declares
`enablement.affects = 'honesty'` — never resolution.

The same care applies in the other direction: an **optional** dependency that is
absent is not a missing one (optionals outnumber required misses on the real
corpus), a version constraint that cannot be compared yields **no opinion**
rather than a verdict, `base` and `core` are counted as coming from the *install*
rather than reported missing, and an unparseable dependency string is reported
rather than dropped.

The identity lines are a rule auditing itself. The spec says identity comes from
the manifest and never from a path, so the report scores both cheaper guesses —
and they don't fail together: the filename hint held on all 195 archives (it is a
sound *search key*, which is all it claims to be), while the archive's own top
directory disagrees on 112. That's the disagreement the rule exists for,
reproduced independently of the note that first recorded it.

Two refusals rather than empty answers: a root the spec marks `derivable = false`
is reported **unspecified** — a different statement from "the search failed" —
and an ecosystem that declares no package *forms* is refused by name.
`lua-wow` knows its identity rule (`name_from = 'directory'`) but has no form to
enumerate, so it says so instead of reporting a folder full of addons as an empty
install.

## Mentions (name-level evidence, where resolution refused)

`:CartographMentions [name]` — the word under the cursor by default — answers
"which files mention this name" from the **mention index**: the identifier set the
id pass records per file. It reads no call graph, so it still answers where
*resolution* refused. A refused call tells you nothing about its target, but it
still tells you the name occurs.

The honesty is the feature, because a list of files that mention a name is easy to
mistake for references:

- a mention is an identifier **occurrence** — nothing claims two files name the
  same thing, so the report states how many defs share the spelling, since that is
  what decides whether the evidence means anything;
- **per file, never per line** — the index interns each name once per file, so a
  per-site answer does not exist at this altitude and is not invented;
- **scope-confined** to the asking file's resolution scope, the same cut resolution
  makes, so the list is the candidate set a resolver would consider rather than
  every file sharing a spelling;
- when a call graph is present the **resolved subset is marked as a subset** (`=`
  resolved, `~` mention only), leaving the residual visible instead of hidden.

On a graph with **no** mention index it *refuses*. The thin index has none —
`index_only` skips the pass that builds it — and reporting "0 files mention it"
there would be a fabricated negative: the answer is unknown, not none.

## Version floor (what this code needs — and what older costs)

`:CartographVersionFloor` answers "which language version does this actually
require, and why". The floor is a *consequence*, so the report leads with the
**attributed set** rather than a number — the feature and the site holding it up:

```
version floor — ruby: 3.1            held up by 153 site(s) at 3.1
  3.1  {x:} hash value shorthand     150  about.rb:124 (+149 more)
  3.1  def f(&) anonymous block        3  concerns/reviewable_action_builder.rb:71
  2.7  ... argument forwarding         1  problem_check.rb:11
  2.3  &. safe navigation            266  about.rb:64 (+265 more)

  downgrade ladder — sites to fix per older target:
    to 2.7   fix 153 site(s)
    to 2.3   fix 156 site(s)
    below 2.3   fix 667 site(s) (all of them)
```

That ladder is the backwards-compatibility half: a floor is usually held up by a
*few* high-version sites, so each rung is the exact edit cost to widen support.
Rungs appear only at observed feature versions, which is where the cost actually
changes — "to 3.0" would cost the same 153 as "to 2.7", so pricing it separately
would add a line and no information.

Version-gated **stdlib calls** (`Enumerable#tally` → 2.7, `Hash#except` → 3.0)
ride underneath as a second, deliberately weaker tier:

```
  ~ consistent with the floor — stdlib name matches (receiver type unknown):
    2.4  Regexp/String#match? (~ name-matched)   5  theme_field.rb:472 (+4 more)
```

They are kept **out** of the floor and out of the ladder, because a name match
cannot see its receiver's type — `x.tally` is 2.7 only if `x` is an Enumerable,
and Ruby won't say. Folding a `~` into a fact is exactly the laundering this
separation prevents; when the hedged tier *would* raise the floor, the report says
so conditionally instead. What keeps the tier sound is the graph's own
disposition: a gated name counts only where the call resolved to **nothing** in
the project, so a project method that happens to be called `except` is attributed
to the project. The cost of that soundness is under-reporting — a stdlib name the
project also defines disappears from the list — and the report discloses that
rather than letting the absence read as evidence.

Three honesty properties, all tested. The floor is a **lower** bound from
**syntax only**, so it says "needs at least" and never "runs on". Detection is
over the **tree**, not the text — `&.` inside a string or a comment is not a
feature use, which a regex would get wrong. And a file that cannot be read or
parsed is counted as UNKNOWN rather than folded into a clean result.

### The version is a RANGE, not a floor

A floor answers "how old can I go". The mirror is "how new breaks me" — names a
later version **removed** — so the real answer is an interval:

```
version floor — ruby: 2.3        held up by &. safe navigation at a.rb:2
⚠ CEILING 3.2 — the first version that REMOVES something used here:
    3.2  Object#taint (~ name-matched)   1  a.rb:3
    supported range: [2.3, 3.2)
```

And when the two ends cross, that's stated outright rather than left for the
reader to compute — 3.1 syntax plus a name removed in 3.0 gives:

```
✗ NO VERSION WORKS: the floor (3.1) is not below the ceiling, so no
  single version satisfies both ends. One of the two sites has to change.
```

Removals come in two shapes and need two mechanisms. Method-shaped ones
(`Object#taint`, `time.clock`) go through the same disposition gate as the stdlib
tier. Constant- and import-shaped ones can't — `Fixnum` is a constant, `$SAFE` a
global, `import distutils` a statement — so those are detected in the tree by node
type and exact text, with the project's own definitions excluded: if a codebase
defines `class Fixnum`, its references are to *that*, not to the removed builtin.
Module paths match at a dot boundary, so `distutils.core` counts and
`distutils_helpers` doesn't.

When nothing turns up, the report says *"no ceiling in evidence — 12 known
removals were checked for"* rather than staying silent, because silence reads the
same whether we looked or not.

The hedges point in opposite directions and that's the useful part: a wrong floor
fact makes the floor too **high**, a wrong removal makes the ceiling too **low**.
Both narrow the interval and neither widens it, so the reported range errs
conservative at both ends. Deprecated-but-present names are deliberately absent —
`File.exists?` still works, and listing it would invent a ceiling. ECMAScript gets
no ceiling table at all, since it doesn't remove features; the report says so
rather than implying an unbounded upper end.

### A behaviour change is a split, not a bound

A removal *bounds* the range. A behaviour change **splits** it — the same code
does two different things either side of the boundary — so the fact is
**conditional on the range**:

```
version floor — ruby: 2.3        ⚠ CEILING 3.2 → range [2.3, 3.2)
⚡ BEHAVIOUR SPLITS INSIDE THE RANGE [2.3, 3.2):
    3.0  &:sym — Symbol#to_proc returns a lambda since 3.0   1  a.rb:3
    The SAME code does different things either side of that version.
```

The identical `&:upcase`, in a codebase whose floor is already 3.1, produces *no*
hazard — you are always on the new behaviour — and the report says so
(`1 behaviour change(s) found but OUTSIDE the range`) rather than dropping the
evidence or crying wolf. Reporting these unconditionally would be pure noise:
discourse's floor is 3.1, so all three of its 3.0-era changes are correctly
outside its range.

Shipping now: `Dir.glob` result ordering (sorted since 3.0), `&:sym` returning a
lambda (3.0), the 2.7→3.0 keyword-argument separation via `**opts`, and
`asyncio.get_event_loop` with no running loop (3.10).

### Declared vs computed — the project's own answer key

A project *declares* a floor in a real artifact; this *computes* one from the
code. Comparing them is a free bug-finder, and the two directions are
deliberately **not** symmetric:

- **computed newer than declared → BROKEN PROMISE.** Positive evidence (a
  feature, at a site) that the declaration is a lie. On `ruby-lsp`, whose gemspec
  declares `>= 3.0`: *"but this needs 3.1 — because of `{x:}` hash shorthand at
  test/fixtures/hash_literal_omitted_values.rb:3"*.
- **computed older than declared → nothing.** Reported as "no detected feature
  needs past 2.3" and explicitly labelled *not a finding*, because our floor is a
  lower bound and an undetected gate may well justify the declaration.

That `ruby-lsp` case also shows the finding qualifying itself: every site holding
the floor up is under `test/fixtures/`, which a gem usually doesn't ship, so the
report says so and tells you to check reachability rather than asserting a defect.

Declarations are read from each ecosystem's real artifact — `*.gemspec`
`required_ruby_version`, a `Gemfile` `ruby` directive, `pyproject.toml`
`requires-python`, `setup.py` `python_requires`, and `tsconfig.json` `target`
(which *is* the ECMAScript scale). `ESNext` is treated as known-but-open-ended,
which is not the same as absent.

### Scales are never mixed

A mixed repo declares more than one floor and has more than one *ruler*, so the
report sections per scale:

```
2 version scales here (ECMAScript, ruby) — reported SEPARATELY: a max()
across different rulers would be a meaningless number.
version floor — javascript/typescript: ECMAScript 2022
version floor — ruby: 3.1
```

This was a real bug, caught on `ruby-lsp`: with one `max()` the Ruby code reported
"floor 2022", because 2022 > 3.1 numerically. Ruby 3.1, Python 3.8 and ECMAScript
2022 are three different scales and comparing across them is meaningless.

Three tables ship: **Ruby** (10 syntax features 2.3 → 3.1, 18 gated methods),
**Python** (11 features 3.3 → 3.12, 9 gated methods) and the **JS family** (13
features ES2015 → ES2022, 6 gated methods, one table serving
`.js/.mjs/.cjs/.jsx/.ts/.tsx`). A table is per-language, small and additive —
each entry is a node type plus an optional structural predicate — and adding one
needs no engine change, since the languages a report covers are derived from the
tables themselves.

The JS family also fixes the scale, since **ECMAScript years and TypeScript
versions are different axes** — `max(ES2020, 4.9)` is meaningless. So the table
carries ES years only, TS-version syntax like `satisfies` is deliberately absent
rather than folded into a nonsense number, and the report names the scale
(`ECMAScript 2020`) so a year never reads as a language version.

Two guards keep a table from rotting. Every feature entry must fire on its own
snippet, because a wrong node type detects nothing *silently* rather than
loudly. And every stdlib key must be reachable through the lookup, so a dotted
key the extractor never produces in that form can't sit there dead.

The predicates earn their place on real ambiguity. `[*a, *b]` and `f(*args)` are
both `list_splat`, and only the one inside a literal is PEP 448, so the 3.5 entry
tests its parent — otherwise every call in the codebase would raise the floor. A
`#private` member is `field_definition` in the JavaScript grammar but
`public_field_definition` in the TypeScript one, so that detector keys on
`private_property_identifier`, which exists in both — keying on the field node
would have silently covered only half the family, and the spec runs the shared
table against *both* grammars for exactly that reason.

On django-oscar (483 files) that reads: floor **3.8, held up by a single walrus
operator**, with 3.6 costing one fix and 3.5 costing ten.

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
until a reorder gathers it. `:CartographExtractConcern <letter> [name]` stages the
candidate you're looking at — the report's letter is the handle, so the listing is
a work-list rather than a dead end.

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
`:CartographExtractCluster <letter> <dest.lua> [dir]` stages that handoff as a
transaction — the god-object split from *finding* to *diff* without hand-building
a move-set. An uncertified cluster still stages, with the possible coupling
carried as a hazard rather than blocking: the move mechanics are sound either way,
and what is unproven is disclosed, never silently. What counts as shared state is
a per-ecosystem sharing-model seam (the default couples any written module var).

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
reassignments (which may be read before the write) are never certified. "Allocation"
is a *structural* question asked of the expression IR, and until recently the IR knew
only Lua's spelling of a constructor — so a JavaScript object literal answered "does
not allocate", which is a claim rather than an admission of ignorance, and the hoist
came out certified. That set now carries every language's constructor whose shape has
been verified against a real parse, and it is deliberately generous: an extra entry
declines a legal rewrite, a missing one breaks a program.

Two other things in that sentence turned out to be doing less work than they claimed,
both found by re-reading the *other* rows of the one loop that exposed the first. A
three-part `for`'s **init clause** was modelled as the opening statement of the loop
body — so the lens asked whether a statement that runs once has the same value every
iteration, answered yes, and offered to hoist it; in JavaScript that breaks `let`'s
per-iteration binding and every closure made in the body sees the final value. The init
is now an ordinary row before the loop, which is what it is. And "loop induction
variables" were read off the header *text*, non-greedily up to the first `=`, so
`for (let i = 0, j = n; …)` disclosed `i` and hid `j` — a value computed from `j` was
certified invariant while `j--` ran every iteration. The loop head's own def set answers
that structurally, and the text scan survives only for the languages whose head carries
no def at all. For the clean
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
compound narrows nothing. The region includes the branch *not* taken: in the `else` of
`if not p` the variable is non-nil, and in an `elseif` every condition the chain already
tested is known false — facts that are true of the most ordinary code there is and that
this lens, for a while, declined to state because it had only ever been taught to speak
about the positive branch. The guard vocabulary is per-language and extensible. Beyond nil and
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

The lens reads **Ruby** as well as Lua, and the vocabulary was written from a census of
6,494 real guard conditions rather than from the Lua one, which turned out to matter:
`x.nil?` is the *rarest* form in Ruby at under 2%, so a nil-centred translation of the
Lua vocabulary would have covered almost nothing. What Ruby code actually guards on is
presence predicates and plain method dispatch. Two consequences are worth knowing when
reading the output. First, **there are no field paths**: in Lua `x.y` is a table read,
stable until something writes it, so the lens narrows it under a staling gate; in Ruby
`x.y` is a *method dispatch* that may answer differently on each call, with nothing
syntactic to separate an `attr_reader` from a computation — so Ruby facts are about bare
variables and instance variables only, and the largest single category of guard is
deliberately refused. Second, and pulling the other way, Ruby admits a fact no other
language here does: **dispatching a method at all proves the receiver non-nil**, because
`nil.empty?` raises. That fact holds on *both* branches — the call already happened —
which makes it the only polarity-independent narrowing in the system, and on real code
it is also the largest. Its soundness lives entirely in two exclusions the lens takes
seriously: safe navigation (`x&.m`, which exists precisely to permit nil) and the
methods `NilClass` genuinely answers (`to_s`, `class`, `nil?`, and under ActiveSupport
`present?`/`blank?`) — so `x.to_s.empty?` proves nothing at all, while `x.owner.active?`
proves `x` non-nil and says nothing about `x.owner`. The other three verbs below still
find their subjects with Lua-specific syntax and **refuse Ruby by name** rather than
walking it and reporting an empty result, which would read as "nothing to say" instead
of "not wired up".

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

The same gates ride a **pre-commit fence** — `.githooks/pre-commit` runs the
doc audit, the **nav audit**, the dogfood seam guard and the suite, cheapest
first. It is checked in but inert in a fresh clone until git is pointed at it:

```sh
tools/install-hooks.sh      # git config core.hooksPath .githooks
```

`git commit --no-verify` bypasses it for a WIP checkpoint.

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
# A DIFF IS ONLY EVIDENCE IF THE CORPUS HELD STILL. A corpus is PINNED (repo +
# rev + expected) or LIVING (no rev). A pinned checkout that moved or is dirty
# answers no question at all — the gate exits "NOT APPLICABLE" rather than
# guessing. A living one reports its diff as CONTEXT instead of failing, because
# it cannot certify it held still, and there are three ways to fail that: no
# recordable identity (a symlink assembly of unpacked mod dirs has no rev to
# record), a rev that moved, or a dirty tree — a rev names a commit, not a
# working tree. Pinned corpora never go advisory, so the gating population is
# exactly the corpora that can vouch for themselves.
# df/flow PARITY gate: coarse(flow)==df (per-statement def/use, category-
# catalogued) + flow's CFG invariants (successors/liveness/reaching) run clean.
# Since the df-strangler completed (step 6), production df IS flow.coarse, so
# the gate extracts with legacy_df to build the INDEPENDENT (dfreg) df and
# checks flow.coarse still reproduces it — a pure regression oracle. Pins a
# per-corpus labeled census; fails on any class delta.
nvim --headless -u NONE -l tools/dfgate.lua cpp
# ROW CENSUS: the FINE model's gate, and the one nothing else could give. `struct`
# gates nodes/edges/calls and opening a control form mints neither; `dfpar` gates
# the COARSE projection, which groups a control row together with its body and so
# reads the same whether the loop opened or not. Measured, 2522 rows and 988 opened
# control structures could appear and vanish with every other column green — which
# is how a whole language's switch could be opaque for a long time. Runs as the
# matrix `rows` column on the shared extract; a form that stops opening drives its
# own key to zero, so the diff NAMES it (`for_range_loop 257→0 (GONE)`).
nvim --headless -u NONE -l tools/matrix.lua cppmodern --cols rows
# CONTROL CENSUS: which control forms does flow fail to open, which can this corpus
# WITNESS at all, and what is being folded? Three modes, three different blind spots
# — each of which has cost a real bug. Asks the tree structurally and reads
# flow.classes(), never a private copy of the answer.
nvim --headless -u NONE -l tools/ctrlcensus.lua ~/git/elasticsearch/libs --lang java
nvim --headless -u NONE -l tools/ctrlcensus.lua <dir> --coverage   # can it gate this form?
nvim --headless -u NONE -l tools/ctrlcensus.lua <dir> --folded     # one row hiding many
# NAVIGATION CENSUS: what can the BROWSER not descend into? The same question one
# altitude out — ctrlcensus asks which control forms FLOW fails to open, this asks
# which forms a DESCENT cannot reach. Every navigation hole so far was found by a
# user pressing the key and getting silence; `child_forms` is a pure function, so
# reachability is computable and needs no answer key: the walk that finds the holes
# builds its own vocabulary of what a statement is (and a second calibration by
# ratio, or every nested call in ruby is a finding). Reports the CAUSE — the
# shallowest link where the route dies — not the symptom. EVIDENCE, not a gate.
nvim --headless -u NONE -l tools/navcensus.lua ~/git/mantisbt/core --lang php
nvim --headless -u NONE -l tools/navcensus.lua <dir> --chain    # the path to each trap
nvim --headless -u NONE -l tools/navcensus.lua <dir> --vocab    # what it calls a statement
# First run, 40 files per corpus: zig 9491 trapped statements, scheme 584, cpp 220,
# java 176, ruby 180, rust 546, js/php/go/python/odin 11-47 — and lua ZERO, the one
# language we navigate every day. Re-run after every fix: a cause leaving the report
# can uncover the next one behind it rather than emptying the count.
# FIRST FIX OFF IT (CART-0458): `else if` written as TWO WORDS lost its whole body in
# every language admitting the spelling, because the nested if matched no table entry.
# The grammars disagree about where it hangs (php/js/c/cpp/zig/rust under an
# else_clause, java/go as the outer if's own child) and agree it is spelled the same as
# its host, so the rule is "see through a child of the HOST's own type" — no name list.
# php 28→0 · js 29→0 · cpp 220→49 · java 176→101 · go 47→32. ruby stayed 180: its traps
# sit behind a shallower cause, which is the re-run rule doing its job.
# SECOND FIX (CART-0457): THE NODE ITSELF. Every rule in child_forms reads a node's
# CHILDREN, so a block or a transparent wrapper handed in as the subject was a dead
# end — ruby's `do |x|` body, a bare `{ }` scope block, a braceless `if (x) a();`, and
# rust's whole if/for/while family (an if_expression under an expression_statement).
# One rule, three symptoms: ruby 180→76 · rust 528→38 · cpp 49→14 · java 101→95.
# ★★ AND ZIG WENT 9491→16778 WHILE LOSING ITS LARGEST CAUSE OUTRIGHT: every newly
# reachable statement enriches the census's vocabulary, so it can suddenly SEE traps it
# had no words for. The total is NOT monotone under a fix — read the cause list.
# THIRD FIX (CART-0463): zig's three grammatical peculiarities — a body wrapped TWICE
# (`if_statement > block_expression > block`), a label hanging beside what it labels
# (`outer: for`, and an `else { }` that parses as a labeled_statement with no label),
# and a container declaration as the VALUE of a variable declaration (`const S =
# struct {...}`). 16778 → 6414, all three top causes gone; the label spellings
# (c/cpp `statement_identifier`, go `label_name`) opened labelled loops in three more
# languages nobody was aiming at. Then back UP to 8403, honestly: `enum_declaration`
# is java's spelling too, and there it holds modifiers and a name beside its body, so
# opening it would FABRICATE two rows per java enum. Refusing costs zig 2014 traps and
# is filed as CART-0466 — one name, two grammar shapes, and the tables are global.
# FOURTH FIX (CART-0459): java 95 → 1. `class_body` had been in the block set from the
# start, so a METHOD worked and everything shaped like one did not — a CONSTRUCTOR's
# statements were the largest single java cause (79), and enum / interface /
# annotation-type members had no route either. Four names, plus a SPLICE set for
# `enum_body_declarations` (pure grammar: its children belong to the enum's own list).
# The enum-name collision is sidestepped rather than fought — `enum_body` is java's
# alone. The one survivor is an anonymous class in a return, which is CART-0462.
# FIFTH FIX (CART-0460): python 11 → 0, two names (`except_clause`, and `except*` is
# `except_group_clause` — probed, not assumed). Its `else_clause` and `finally_clause`
# were already in the set under names it SHARES with other grammars, so a try showed
# its body, its else and its finally and dropped only the handlers between them: a
# partially-correct answer in the middle of a construct, with nothing marking the gap.
# SIXTH FIX (CART-0461): scheme 546 → 0. A quote sigil is PUNCTUATION, not a level, so
# `'`, `#'`, `` ` ``, `#\`` and their unquotes are seen through and the form they wrap is
# the row; a vector keeps its own row because it is a collection, not a sigil. Quoted
# DATA is descendable on purpose — user direction: any collection literal is structure,
# and an INTERPRETATION of it is a separate offered layer (CART-0467/0468).
# REACHING A NAME INSIDE A ROW (CART-0471), which is what the detail lens was built
# for. Reaching `y` in `q(y, x + 1)` is a POSITION question — a token at a column —
# and a lens answered it with containment: a mode switch, a scan of indented item
# rows, then a descend.
# ★ THE BROWSER'S OWN VERB WAS ALREADY RIGHT AND ONLY HALF-WIRED: descend_fn_row has
# always resolved THE WORD UNDER THE CURSOR (a callee, then a module var), while the
# block and region altitudes had no word logic at all — block took the row's first
# resolvable callee whatever the cursor was on, and region only handled a var row.
# They share it now, so "go to this name" needs no key of its own. Names come from
# `spec.mention_types` — the declared set the mention collector already resolves with
# — and each resolves BY RANGE off the var use edges, which answers shadowing for
# free: a local has no use edge covering it.
# The LABEL PICK (`keys.pick`, UNBOUND — a label motion is not a vim idiom and does
# not squat on a vim key) stays for the rows a cursor word cannot serve: a flattened
# summary row, whose names are not at their source positions. It labels the line in
# the SOURCE pane, which has the real columns — a browser row's text is collapsed and
# elided, so a name's column there addresses nothing. Measured p90 is 9 names per
# line, so the digits alone label nine rows in ten.
# AND THE DETAIL LENS IS RETIRED (CART-0472, user: "maybe the detail lens would allow
# descending into a row which would offer navigating symbols within and step like
# statement otherwise"). A row's names are a LEVEL below it now, not a lens beside
# it: `descend` on a statement that names more than one resolvable thing opens
# them, j/k steps them and steps OUT at the edges — which needed nothing built,
# because step() already did that and was merely gated to the block altitude. The
# rows are ts.names, so the lens's hand-written arg/cond/var kinds — its ceiling,
# and why it lost a ternary's condition and every nested call's argument — are gone
# with it. A statement whose ONLY resolvable name is its single callee still
# descends straight into the callee: a one-row level would be a detour.
# Retiring it deleted the lens set entry, the renderer, `line_detail` and its two
# descend branches, the provider's whole `detail()` machinery (119 lines: DETAIL_MAX,
# bounded, ARG_LISTS, COND_TYPES, detail_items) and four specs' worth of
# expectations — including the doc's own lens table, which `lensbar_spec` checks
# against the code, so the retirement could not be half-done.
# ★ And it found a dead end by accident: a REGION's ▸ rows carried a block key that
# the region branch never read, so the marker promised a descent and delivered
# nothing. The new region branch could never run — an earlier one already won — and
# dead code is how the bug announced itself.
# ★ The census caught two bugs in its own fix: the unquotes come in two families
# (`unsyntax`/`unsyntax_splicing` inside a quasisyntax, not `unquote`), and the lisp
# signature heuristic ate real content the moment quoted forms became forms — it was
# only ever correct because the descent was closed.
# EXPRESSION CENSUS: the expression IR's gate, and until now it had none. `expr.gate` is a
# real two-implementation oracle — `expr.reads(row)` (the identifier leaves the IR reads) vs
# `row.use ∪ row.rmw` (du's read census over the same node), derived independently — so a
# disagreement is a real bug on ONE side. The only runner calling it was syngate, over a
# GENERATED LUA corpus, iterating `kind == 'function'`: two restrictions that compound, since
# in java and ruby essentially all code is a METHOD. Its clean zero was a statement about lua
# functions and was read as one about the IR. Pointed anywhere else it fires — cpp 114631,
# cppmodern 45821, bash 5737, libs 2472, ruby 435 — so the column PINS a per-corpus census
# rather than asserting zero, keyed by (axis, row type), because "2472 disagreements" is not
# actionable and "1378 of them are C declarations" is. Four open classes, each with a ticket.
# (the census core is tools/exprcensus.lua; the column reads it off the shared extract)
nvim --headless -u NONE -l tools/matrix.lua libs --cols expr
# …AND THE CENSUS CORE IS ALSO A COMMAND, which it documented for a week without being one:
# the file was a pure library, so the invocation in its own header PRINTED NOTHING AND EXITED
# 0 — from a census tool, indistinguishable from "no disagreements found" (CART-0409). It runs
# now, guarded on arg[0] so `matrix`'s dofile of the same module stays inert.
#   --show <class>    the instances of one (axis:rowtype) class, with the SOURCE LINE
#   --bucket <class>  every instance normalised (identifiers→x, numbers→0) and counted, so a
#                     10000-instance class names its own top shapes instead of being read 40
#                     at a time. A SAMPLING AID, not an oracle — what it surfaces gets probed
#                     directly before anything is changed.
# It paid for itself on the first run. CART-0404 called cpp `missing:declaration` 10667 "the
# single biggest IR/du gap"; the bucket showed the same three header rows repeating, and the
# class is 414 DISTINCT rows counted 25.8× — a C++ class body parsed as C becomes one
# function_definition that every method in the header resolves to (CART-0410). The census now
# prints `instances/distinct` and orders by distinct, because the inflation is PER-CLASS
# (25.8× here, 1.0× for binder:if_statement) and so it corrupted the RANKING, not just the
# magnitude. Pins stay keyed on instances; two numbers, neither pretending to be the other.
nvim --headless -u NONE -l tools/exprcensus.lua cpp --bucket missing:declaration
# …AND FOUR CORPORA COULD NEVER RUN IT AT ALL (CART-0423). zig, odin, v8 and wow printed
# NOTHING — not a header, not a zero, not an error — and exited 0. Four of thirty-seven,
# silently absent from every sweep since the census shipped, and nothing distinguished "no
# output" from "found zero" from "never ran". The exit code was laundered twice over: the
# harness read `$?` through a pipe, and `proc.code` reads 0 for a child killed by a signal,
# so a SIGKILL rendered as a clean exit. THEY WERE RUNNING OUT OF MEMORY.
# The cause is that `expr.of` re-parses the WHOLE ENCLOSING FILE once per subject — right
# for one interactive visit, quadratic-ish for a consumer sweeping every function in a file.
# MEASURED: one tree-sitter parse costs 21-53 BYTES OF RSS PER SOURCE BYTE (16.9 MB for
# zig's InternPool.zig, 564 MB for its 11 MB CodeGen.zig), and the census's growth INSIDE a
# file matched the isolated per-parse cost exactly. zig died 21.7s in, at subject 570 of
# 8590. Never slow — just fatal.
# ★ AND THE LUA GC COULD NOT SEE ANY OF IT: while RSS tripled, the Lua heap FELL, 834->465
# MB, because a tree-sitter tree's Lua footprint is ~0 and its cost is C-side. Collecting
# every 20 subjects recovered only ~30% and STILL DIED — measured, so "collect harder" was
# never the fix. The parse had to stop happening.
# THE FIX IS TWO HALVES, and each is inert without the other: expr keeps a ONE-ENTRY parse
# cache keyed on the SOURCE ITSELF (identical bytes, identical tree — a stale hit is
# impossible by construction, so there is no lifetime to get wrong), and the census walks
# BY FILE so consecutive subjects hit it. Extraction already emits nodes file by file, which
# is exactly why relying on that would be wrong: it would work everywhere until a corpus
# arrived unordered and degrade silently. The order is explicit and the hit rate reported.
#   php    982 MB -> 183 MB, 13.6s -> 4.1s      zig   OOM at 5983 MB -> 2471 MB, 52.9s
#   go    2743 MB -> 659 MB, 38.2s -> 13.5s     odin  OOM at 4377 MB -> 1636 MB, 23.0s
# Identical censuses on every corpus that already ran (php 857, go 3053) — a pure
# performance change that is also 2.8x faster, because the re-parse was the wall clock too.
# ★ ONE THING GOT WORSE BEFORE IT GOT BETTER, and it is worth stating: releasing the tree
# per file and COLLECTING per file took go from 38s to 179s — 923 full collections. The
# trigger is now the quantity that actually drives the peak, SOURCE BYTES released, with a
# budget derived from the measured 21-53 B/byte rather than picked.
# All four corpora are pinned for the first time: zig 16088, odin 16585, wow 3261, and v8
# 165533 instances over 10274 DISTINCT rows (16.1× — CART-0410's header duplication at full
# size, so rank v8's work by the distinct column, never by that total). None is a regression;
# they are first sightings of numbers that were always there.
# ★ AND THE FIRST ONE READ REFUTED THE STORY ITS NAME SUGGESTED. zig is 87% one class,
# `binder:variable_declaration` = 14002 over 14002 distinct rows, which looked like the
# vanished-binder family CART-0358 fixed for JS destructuring. It is not. Every instance is
# `missing={} extra={<the declared name>}` on an ordinary declaration — `const ip =
# &zcu.intern_pool;` — i.e. the row's own TARGET harvested as a READ. That is the INVERSE:
# du is right, the IR over-reads, and it is CART-0404 (the C/C++ declaration row reads what
# it declares) in a third language. v8's `binder:declaration` 30547/3859 is the same defect
# in C++ at a scale the cpp corpus never showed. A CLASS'S COUNT AND ITS STORY ARE TWO
# FINDINGS; this one took 53 seconds of `--show` to keep from hardening the wrong one.
nvim --headless -u NONE -l tools/exprcensus.lua zig --show binder:variable_declaration
# ★★ FIXED (CART-0404's zig half): zig 16088 -> 3456, `binder:variable_declaration`
# 14002 -> 1371, and 78.5% of a corpus's census went with it. NO OTHER CLASS MOVED AND NO NEW
# CLASS APPEARED — the check this ticket's first C/C++ cut failed, where fixing the aimed-at
# class minted 139174 rows of another and the net went UP 56%.
# THE CAUSE: zig's declaration is FLAT. `const x: T = y;` is a `variable_declaration` whose
# children are the bare identifier, an optional `type` FIELD, the `=` token and the
# initialiser — no `init_declarator`, no `variable_declarator`, so every earlier path in the
# LOCALDECL branch had nothing to key on and the row fell to the generic `?` walk, which
# reads every identifier it meets INCLUDING THE DECLARED NAME.
# ★★ AND THE MACHINERY WAS ONE BRANCH AWAY, BUILT FOR ANOTHER LANGUAGE. `assign_sides`'s
# positional fallback splits on the assignment OPERATOR TOKEN and returns N targets / M
# values; it exists because odin's `assignment_statement` carries no fields (CART-0304). A
# zig `variable_declaration` is that same syntactic shape wearing a declaration's name — so
# this is the operator split reused, not a new zig-shaped rule inside a language-agnostic IR,
# which is also why it AGREES with du rather than merely disagreeing less.
# ★ THE DECLARED TYPE IS A READ, AND THAT IS A ZIG FACT: `const items: []const Inst.Ref =
# …` has du reading {Inst, Ref}, because in zig a type IS a value (`const T = struct {…}`).
# C's `int` is a KEYWORD and names nothing, so the older fallback drops types — right there,
# wrong here, and dropping it cost 5 `missing:{Inst,Ref}` rows on one file.
# ★ IT CANNOT FIRE WHERE THE FIRST CUT WENT WRONG: the path needs an assignment OPERATOR and
# no declarator, so C's `Foo f(x);` and `int a, b;` still reach the honest fallback. MEASURED
# CONTAINMENT: odin PINNED matches (its declarations are `const_declaration`/`var_declaration`,
# not in LOCALDECL), 21 quick-tier rows all green, and rust's `binder:let_declaration` is 3 —
# rust is NOT over-reading its declared names, so the defect is specific to the FLAT shape.
# ★★ AND THE 1371 THAT REMAINED WERE DU'S SIDE (CART-0431), NOW ALSO FIXED — zig
# 3456 -> 1495, so 16088 -> 1495 across the pair: 90.7% of a corpus's census, from two
# changes that had to be made in that ORDER. du's `k = 4` said every direct `identifier`
# child of a declaration is def-position — right for lua, which reaches that branch only
# for a declaration with NO operator (`local x = 1` hangs an `assignment_statement` that
# re-dispatches as ASSIGN), and wrong for zig, where name, type and value all sit at depth
# one. `var i: usize = index;` stored `def={i,index} use={}`: A PARAMETER'S INCOMING
# DEFINITION KILLED AT THAT LINE and the read of it never counted, so reaching-definitions
# and liveness were wrong for zig, silently, in the STORED rows (cache VERSION 139).
# ★★ TWO WRONG SIDES AGREEING IS WHAT A TWO-IMPLEMENTATION GATE EXISTS TO BREAK, and this
# gate could not: the IR's `?` fallback read both names, so it reported agreement. Fixing the
# IR is what exposed du — the argument for the gate, not a footnote to it, and the same
# lesson cache v138 recorded one version earlier.
# ★★ AND ONLY ONE OF THE TEN CLASSES THAT MOVED IS THE ONE EITHER TICKET NAMED:
# binder:block_expression 498 -> 285, binder:switch_case 298 -> 132, binder:block 94 -> 58,
# missing:variable_declaration 236 -> 0. A REGION row's def set was inflated by the
# declarations inside it, because one rule decided def-position for every identifier the walk
# reached. A defect measured on one node type was never confined to it.
# ★ BOTH SIDES NOW SPLIT A FLAT DECLARATION ON THE SAME ASSIGN_OP TOKEN, and that table has
# ONE OWNER (`flow.ASSIGN_TOK`) — a second copy is exactly the "kept in step" arrangement
# that let the two disagree for as long as they did. MEASURED WHY IT MUST BE THE OPERATOR SET
# AND NOT A LITERAL `=`: a first cut testing `'='` put three rows back, because zig spells
# `extra_index += items.len;` as a `variable_declaration` too. The rows it broke were not the
# rows it fixed, so the TOTAL held still at 4 while every row underneath it changed — A COUNT
# THAT HOLDS STILL IS NOT A COUNT THAT MEANS NOTHING CHANGED.
# ★ CONTAINMENT, PROBED ACROSS 15 GRAMMARS: only zig reaches `k = 4` WITH an operator. lua
# reaches it with none (both its forms), and the other thirteen never reach it at all.
# ★★ AND GATING THAT CHANGE TURNED UP A FABRICATED SYMBOL (CART-0434, cache v140). zig's
# `struct` column was RED — verified pre-existing by stashing, byte-identical without the
# change — on a node named `LLVMTargetMachineRefZigLLVMCreateTargetMachine`, which exists
# nowhere. An extern-C MACRO eats the return-type slot, so the cpp grammar reads the next two
# identifiers as a namespace and a name:
#   ZIG_EXTERN_C LLVMTargetMachineRef ZigLLVMCreateTargetMachine(…);   // zig_llvm.h:107
# Worse than a wrong name: the RETURN TYPE is presented as a NAMESPACE, so qualified
# resolution hunts a member of something that does not exist and every caller of the real
# function resolves to nothing.
# ★ ONE CAUSE — a MACRO or a LINE BREAK hiding the return type — AND tree-sitter RECOVERS
# THREE DIFFERENT WAYS, sharing no signal between them:
#   1. a MISSING (zero-width) `::` token   ZIG_EXTERN_C LLVMTargetMachineRef Zf(…)
#   2. an ERROR child, the `::` REAL       V8_WARN_UNUSED_RESULT MaybeDirectHandle<Object>
#                                          Accessors::ReplaceAccessorWithDataProperty(…)
#   3. BOTH, at different DEPTHS           V8_NOINLINE V8_PRESERVE_MOST std::pair<…>
#                                          read_leb_slowpath(…)
# so `qname` descends FIRST and then tests this level, because EVERYTHING ABOVE THE DEEPEST
# SIGNAL IS RETURN TYPE. It keeps a real qualifier behind the signal —
# `ScriptCompiler::CompileFunction`, never `CompileFunction` — and cannot fire on well-formed
# C++ by construction: a written `::` is never zero-width and an ERROR is a failed parse.
# ★★ FIVE CORRECTIONS, AND THE MOST USEFUL MEASUREMENT WAS THE ONE THAT WENT UP. Testing the
# current level before descending answered `std::pair<IntType,uint32_t>read_leb_slowpath` —
# one macro stripped, the rest still glued — and the v8 residual went 15 -> 17, because three
# FULLY glued names became HALF glued and a detector scores those the same. That is a
# different error from the other four: they MISSED A SHAPE, this one found a real shape IN
# THE WRONG ORDER, and re-reading the code would have called it correct — it WAS correct, at
# the level it was looking at.
# ★★ EVERY COMPLETENESS CLAIM I MADE FROM REASONING WAS FALSE ("small", "gone"); every one
# from the detector held. THE DETECTOR MUST BE BLIND TO WHICH SHAPES THE FIX HANDLES: mine
# was "a `>` immediately followed by a letter" — two minutes to write, knowing nothing about
# the fix — and it caught a missed shape three times and a wrong traversal order once.
# I had measured zig 1, cpp 2, cppmodern 0 and called it small: THE POPULATION I MEASURED WAS
# NOT THE POPULATION WITH THE ANSWER, and v8 is the corpus the ticket itself named.
# ★ AND THE FIRST PROBE COUNTED TEXTS WHILE THE GATE COUNTS NODES — cpp's two hits are in
# VARIABLE declarations that never become a node name, which is why its baseline stayed
# green. Only the node-level number is the blast radius.
# RESULT: v8's glued qualified-identifier names 0, zig's `struct` RED -> GREEN against the
# EXISTING baseline with no --save, cpp/cppmodern unmoved. The 14 v8 names still carrying a
# fabricated shape are OTHER defects — C++20 `requires`-clause constructors (CART-0435) and
# a body/macro/parameter-list stored as a name (CART-0436) — filed, not folded in.
# ★ The spec that matters is the NEGATIVE CONTROL: a real `ns::f` must never be truncated to
# `f`, which would break C++ member resolution on every corpus — a far bigger blast radius
# than the bug being fixed.
# COMBINATORIAL GRID: the bestiary plants each FORM once, and every bug the row model gave
# up was at an INTERSECTION — elsif x CHAIN-LENGTH-2, block x CONDITION-POSITION, block x
# ASSIGNMENT-RHS, rescue x INSIDE-A-BLOCK, modifier x LOOP. CART-0394 said it outright: "the
# missing cell is the INTERSECTION, which no count asks about." So emit the CROSS PRODUCT —
# FORM x SHELL x BODY x CHAIN, one method per cell, named by its coordinates — and feed it
# the oracles that need NO answer key (a planted region must have rows; reads == use u rmw).
# NOTHING IS PERSISTED: the generator is the artifact, minted into a tempdir per run and
# minted TWICE to gate determinism, because a corpus regenerated per run makes a wobbly
# emitter indistinguishable from a regression. `--out` is for a human reading a red cell.
# It paid on its first run: EVERY `c_ifs_*_ch2`/`_ch3` cell fired and NO `_ch1` cell did,
# which names the axis without anyone guessing it.
# The grid's sha256 is PINNED beside its census, and that is not the same check as the
# double-mint: two mints share ONE Lua state, so nondeterminism that is stable WITHIN a
# process and varies BETWEEN them (a string-hash seed reaching a pairs(), an env var, a
# clock) agrees with itself and passes. The digest is the only check spanning runs, machines
# and days — the population a regenerate-every-time corpus actually lives in. It also answers
# what the counts cannot: hash SAME + counts moved = the analyzer changed; hash MOVED = you
# edited the grid, so the counts are a new baseline rather than a regression. A selftest
# perturbs one byte and requires the digest to move, because a check that cannot fire proves
# nothing.
# (the EMITTER is tools/genmatrix.lua — pure, no GEN_VERSION, writes nothing;
#  tools/gridgate.lua is the runner that mints it and applies the five checks)
nvim --headless -u NONE -l tools/gridgate.lua java
# A SECOND LANGUAGE IS PART OF THE CLAIM — one language proves the emitter, not the design.
# ruby has no braces, so no `unbraced` axis; its equivalent split is the MODIFIER form, and
# its shells include `inblock` (an attached do…end, where 18-20% of ruby statements live).
# It plants two cells that open tickets NAME but nobody had ever emitted: MODIFIER x LOOP
# (CART-0394) and `for x in xs` (CART-0393).
nvim --headless -u NONE -l tools/gridgate.lua ruby
nvim --headless -u NONE -l tools/gridgate.lua java --show expr:try_with_resources_statement
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
# THE CLONE LADDER, and one DEFECT tier riding the same index. Default is
# function-granular exact clones; --blocks is contiguous statement runs ranked
# by how many files they span; --near is whole functions within a couple of
# edits, each divergence named as the parameter it would become. --rowdrift is
# not a clone tier at all: it reports a literal that duplicates the value of a
# module constant, in a statement written elsewhere USING that constant by name
# — statement-granular, so unlike --near the two sites need not sit in cloned
# functions. Its yield is small (one finding across this repo, 82 WoW addons
# and one other tree) and it is the heaviest of the four; large JS trees
# THE FOLD QUEUE joins discovery to PLANNING: for each near-clone pair it asks
# the extract verb for a plan and ranks by what the fold would COST — lines
# removed minus added, hazards, params — so the order answers "what should I
# fold next" rather than "what is biggest". Refusals are COUNTED ROWS with their
# reason, because they are most of the work: on this tree 5 of 59 pairs plan, 14
# refuse only for want of a destination module, and the 5 that plan predict a net
# of +1 line. Ranking by size would have led with a fold that GROWS the file.

# currently exhaust memory where --near copes.
nvim --headless -u NONE -l tools/clones.lua --blocks
nvim --headless -u NONE -l tools/clones.lua --near
nvim --headless -u NONE -l tools/clones.lua --fold      # the fold QUEUE
nvim --headless -u NONE -l tools/clones.lua --rowdrift
# THE MATRIX: every parity/honesty invariant × every registered corpus, one
# command — the push-time sweep. One inline extract per corpus feeds all the
# cheap columns (counts, validate, memory budget, the fine ROW census, the
# EXPRESSION-IR census, df/flow parity, fold
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
# A PER-ROW DEADLINE, so a WEDGED corpus renders as a named death instead of a stall
# (CART-0429 — folded in from the CART-0423 verification harness, whose only real advantage
# over this file was `timeout 2400` per invocation; its rc column is NOT folded, because a
# shell reading `$?` through `timeout` cannot see a signal at all while the ERR path here
# reads `proc.signal` first). 2400s is that harness's measured-safe number: all 37 corpora
# ran under it without one trip, against a largest measured row of 174.4s.
nvim --headless -u NONE -l tools/matrix.lua --timeout 600   # tighter deadline
nvim --headless -u NONE -l tools/matrix.lua --timeout 0     # no deadline at all
#   zig  ERR
#   zig: the row hit its 5s DEADLINE (--timeout) and was SIGKILLed 10s later, having
#        ignored the TERM — it did not FAIL, it never finished (code 0, signal 9)
# ★★ `vim.system{timeout=}` IS A REQUEST, NOT A DEADLINE, and the first cut of this shipped
# on that assumption: it sends SIGTERM, does not escalate, and an `nvim --headless -l` child
# DOES NOT DIE ON TERM — measured, a child given 2s ran its full 20s of work, printed its
# output and exited on its own, while the parent reported `code = 124`. So `matrix zig
# --timeout 5` printed `timeout 5s/row` in its own header and then a green 118.8s row. The
# probe that green-lit it used `sleep` as the child, which dies on TERM; the real child is
# the one that doesn't. ★★ AND 124 IS THE PARENT'S INTENT, NOT THE CHILD'S FATE — it is set
# when the timer fires whether or not the kill landed, so it reads identically for "killed
# at the deadline" and "ignored the deadline and finished fine". The escalation is therefore
# owned here (TERM, then SIGKILL after a 10s grace) and the ERR text reads the flag set by
# the code that does the killing, never an exit status: a hard-killed row arrives as
# `code 0 signal 9`, which is exactly what an OOM kill looks like.
# SCOPE THE WHOLE GRID TO ONE FILE (CART-0429) — the dev loop for anything that changes the
# harvest: every column at once, on the file you are actually working on.
nvim --headless -u NONE -l tools/matrix.lua zig --file 'InternPool%.zig$'
#   zig  1.6s  valid OK · rows ~ · expr ~ · dfpar ~ · fold -- · silent OK · cache OK
#   (a full zig row is ~135s; nodes 433 instead of 9768)
# ★★ A SCOPED ROW IS NOT A GATE, so the verdicts say so. Every baseline here is a
# CORPUS-WIDE claim — `expected` refs/nodes, `budget_mb`, the rows/expr/dfpar pins, the
# saved struct baseline — and judging a two-file extract by any of them yields a red cell
# that means nothing, which is worse than no cell. So: rows/expr/dfpar go `~` (REPORTED,
# NOT GATED — the census still prints, which is the whole point, it just stops pretending
# to be a verdict); counts/mem/key/struct/par go `--` and are SKIPPED, `par` because it
# would re-extract the whole corpus to compare against a subset; and valid/fold/silent/
# cache STILL GATE, because referential integrity, the fold round-trip, silent-local and
# cold==warm are INTRINSIC — a subset is a perfectly good subject for them.
# The downgrade lives in the one function every column reports through, so a ninth
# baseline-comparing column cannot be added that forgets to honour it.
# AND THE PARSE CACHE'S REUSE RATE PRINTS UNDER THE GRID, one line per row (the folded
# harness's other half). `miss` IS the parse count, so the by-file walk's claim is that it
# TRACKS THE FILE COUNT — which is why the file count is printed beside it, here and in
# exprcensus: a bare "89.5% reuse" can be checked against nothing.
#   go      7346 hit   866 miss over   866 file(s)  89.5% reuse
#   zig      370 hit     1 miss over     1 file(s)  99.7% reuse   (--file, one file)
# ★ IT PRINTS UNCONDITIONALLY, AND THAT IS THE FOLD: the details section suppresses a cell's
# detail when the cell is OK, so hanging this off the `expr` column would have hidden it on
# exactly the green rows the old harness showed it on — a fold that only reports when
# something else is already red is a drop wearing a fold's name.
# ★ REPORTED, NOT GATED, deliberately: a miss also happens once per SUBJECT in a file that
# fails to parse (`expr.parse_root` counts the miss before its pcall and caches nothing on
# failure), so the same two numbers mean "the grouping regressed" and "this corpus has an
# unparseable file" and a threshold here would be an invention. What makes it worth printing
# is that the census output is IDENTICAL under both: the performance defect that cost four
# corpora their census for months is invisible to every verdict in this grid.
# THE DEV LOOP IS COLD BY DEFAULT, AND THAT IS THE POINT (CART-0429). `bench.extract` goes
# straight to the provider and never consults the cache, because A GATE MUST NOT VERIFY A
# CACHED ARTIFACT — CART-0245 is the proof it matters: a warm zig graph once carried 4122
# edges into nodes that were never saved while the `valid` column stayed green, since
# validate ran on the COLD graph and nothing ran it on what the cache produced.
# The cost is real though. MEASURED: a repeat extract of an UNCHANGED corpus buys nothing
# (go 12.30s -> 11.48s), and zig is 106.8s on EVERY invocation — so iterating on an
# analyzer re-pays a full extraction every run.
# So warm is OPT-IN, per call or per shell, and it VALIDATES what it serves before handing
# it back (0-205 ms, measured, against extracts of tens of seconds):
CARTOGRAPH_BENCH_WARM=1 nvim --headless -u NONE -l tools/exprcensus.lua go
#   bench: WARM — warm open — 922 files unchanged
#   go  fns=4143 methods=4067 · disagreements=3053 · PINNED: matches   26.7s -> 13.1s
# ★ GATES SAY `cold` EXPLICITLY rather than trusting the environment not to say warm — an
# opt-out that depends on nobody having opted in is not an opt-out. tools/gate.lua and
# tools/matrix.lua both pass it, and the matrix would otherwise make its own `cache` column
# CIRCULAR: that column exists to prove warm == cold, which it cannot do while reading the
# warm graph as its own baseline.
# ★ AND A NON-CANONICAL EXTRACT NEVER TOUCHES THE CORPUS CACHE, in either direction —
# `--file`, defs_only, dataflow_only, index_only, legacy_df. A scoped extract holds a
# SUBSET: writing it would poison the cache for every later reader, and reading the full
# cache would silently undo the scoping the caller just asked for. It says so out loud:
#   bench: COLD — opts.files makes this a NON-CANONICAL extract
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
# next pack comes from). It also fences the one spec field the LANGUAGE FENCE
# is blind to: `fn_types` is a TABLE of node types, not a query, so nothing
# compiled it and a php entry the grammar had RENAMED sat there naming nothing.
# Two directions, because only the second catches an OMISSION and an omission
# is what a partial table looks like: every entry must EXIST in the grammar
# (the compile tier), and every node type the `functions` query is observed to
# capture as a def must be NAMED by the set. An empty set is read as a declared
# REFUSAL rather than a defect — scheme's function node is `list`, the same
# type as every other s-expression, so it genuinely cannot answer from node
# types alone and says so instead of falling back to a default that would
# report "no functions in this file".
nvim --headless -u NONE -l tools/specaudit.lua              # default corpus set
nvim --headless -u NONE -l tools/specaudit.lua ruby rails   # explicit corpora
nvim --headless -u NONE -l tools/specaudit.lua --extract    # extract when no snapshot

# ★★ AND A MACRO BETWEEN `class` AND ITS NAME DISSOLVES THE CLASS EVEN WHEN THE GRAMMAR IS
# RIGHT (CART-0439). `class V8_EXPORT_PRIVATE Foo : public Base { … }` parses as a
# `function_definition` whose TYPE is the macro, whose real name sits in an ERROR node, whose
# BASE CLASS is the declarator and whose class BODY is a function body — so every constructor
# and inline method comes out a FREE FUNCTION NAMED AFTER ITS CLASS. With no base clause the
# ERROR vanishes entirely, so `has_error()` cannot see it.
# THE REPAIR IS A NEW SPEC SLOT, `src_repair` (spec/contract.lua, implemented in spec/cpp.lua,
# called at the extraction parse seam): blank the offending macro WITH SPACES and re-parse to
# a fixpoint. ★ LENGTH-PRESERVING IS THE WHOLE DESIGN — every byte offset, line and column is
# unchanged, so all graph ranges still address the RAW file, and the repaired tree IS the
# control tree: `interface`, `qualify`, `is_method`, `block_skip` and flow work UNMODIFIED and
# no query changed. It fires only where the parse is ALREADY broken, so it cannot fabricate.
# A plain-text superset prefilter rejects 93-94% of C++ files before any tree walk; measured
# cost 2.9-4.0% of a cold extract. v8: 866 wreck sites -> 65, nodes -12151, refs -7623 (8341
# fabricated free functions became qualified methods ON THE SAME LINE; the rest are prototypes
# which, inside a REAL class, are `field_declaration`s and mint nothing — CART-0410's 7kaa
# signature).
# ★★ AND BOTH CORPORA THAT GATE C++ ARE ZERO-DIFF (TSGAP-0007): neither colobot nor 7kaa uses
# an export macro, so a defect deleting containers across 483 files of the SCALE corpus was
# invisible to every C++ gate. THE CORPORA THAT GATE A LANGUAGE WERE CHOSEN BEFORE ANYONE
# KNEW WHICH IDIOMS WOULD MATTER.
# ★ AND C/C++ FUNCTIONS HAD NO PARAMETERS AT ALL, always (CART-0438). `params_field =
# 'parameters'` names a field a `function_definition` does not have — the list hangs on the
# `function_declarator` one level down. Both now declare `params_of`, descending to the
# INNERMOST declarator (a constrained ctor nests a misparsed outer one). ★ THE HOOK ALREADY
# EXISTED AND ONLY ONE OF ITS TWO READERS CONSULTED IT: flow's `param_names` did, the node
# builder did not, so odin declared `params_of` in CART-0304, got parameters in its FLOW and
# none on its NODES — silently, because nothing compares the two readers.
# WHAT `.h` MEANS IS A PROPERTY OF THE TREE, not of the extension (CART-0410). spec/c.lua
# claims `.h`; spec/cpp.lua claims only .hpp/.hh/.hxx — so every C++ project using the
# ordinary convention had ALL its headers parsed with the C grammar. `class Foo { … }` is
# not a syntax error in C: `class Foo` reads as type + declarator and the body as its
# compound_statement, so THE WHOLE CLASS BECOMES ONE function_definition and every method
# prototype inside resolves to that node, inheriting the class's field list as its rows.
# The rule is REPO SHAPE — a tree holding any .cpp/.cc/.cxx/.hpp/.hh/.hxx names its headers
# C++ — decided ONCE from the full file list, carried on the graph as `data.h_lang`, and
# re-adopted by store.ingest so a later re-parse agrees with the build.
#   · UNCONDITIONAL `.h → cpp` WAS MEASURED AND REJECTED: on real C headers the C++ grammar
#     LOSES real declarations (openfirmware 2196 → 2050 def nodes — a run of file-scope
#     `int curcol;` swallowed once one construct puts the parser in an error state). A
#     pure-C tree must pay nothing, and under a shape rule it never triggers.
#   · THE PARENT DECIDES, ALWAYS. A worker sees a BATCH, and a batch of `include/*.h` holds
#     no C++ source — it would answer C for a C++ repo. Deriving it at INGEST is wrong one
#     level down for the same reason: the store is SHARDED, and a shard can be all headers.
#   · AND THE PARENT MUST ADOPT WHAT IT SHIPS. Relink runs in the parent, and its
#     never-cross-language gate asks the language per node; threading the value to workers
#     while leaving the parent on the default gave nodes 9024 == 9024 against inline and
#     refs 8073 vs 9229. A divergence in ONE column, with the others agreeing.
# MEASURED: 7kaa nodes 12144→9024 (−3120 fabricated `function` nodes) with refs 8040→9229;
# v8 — 1813 .h against 1267 .cc, more header than source — nodes +17393 and refs +42677
# (+57%). ★ THE NODE DELTA HAS OPPOSITE SIGNS on those two (7kaa's headers declare, v8's
# define inline) and only the REFS direction agrees across both, which is the one to read.

# AN ASSIGNMENT USED AS A VALUE IS NOT A READ OF ITS TARGET (CART-0415). C spells
# `a = b = c` as `a = (b = c)` and a for-init comma list as a chain of assignment
# expressions, so the inner assignment reaches the harvest as a VALUE — and its target was
# counted as a read. The largest remaining cluster, and again ONE cause across several
# classes so none of them ranked: binder:expression_statement 387 + binder:comma_expression
# 217 + binder:for_statement 134 distinct rows on cpp.
#   · ★ THE `?` WAS DOING ITS JOB. `x1a = x1b = x1` harvested as an honest unknown that KEEPS
#     BOTH NAMES, exactly as the closed schema promises. The defect is that a `?`'s kids are
#     walked UNIFORMLY and one of them sits in DEF POSITION — and `?` is for constructs the
#     harvest does not model, while an assignment is very much modellable. So the schema
#     gained a kind rather than `reads` gaining a special case:
#         { k='assign', t=<target>, v=<value>, kids={t,v} }
#     `kids` for the same reason `pair` carries it (kids-walkers lose nothing); the target
#     routes through target_reads, which already knew `a[i] = v` reads `a` and `i`.
#   · PLAIN_ASSIGN, not ASSIGN: an augmented form (`a += b`) genuinely READS its target and
#     keeps falling through to `?`, where both kids are read — correct there.
# cpp 2578→1488 (42%, and 1373→501 DISTINCT rows) · jquery 1780→22 across the arc ·
# haskell→0 · php −11% · ruby −11% · rails −14% · libs −18%. No cache bump: harvest only.
# ★ AND go ROSE, 2938→3055, which is filed rather than re-pinned over (CART-0416): du folds
# a type-switch binding onto every `case`, and an assignment INSIDE A CLOSURE was being
# counted by both sides. Fixing ONE side of a shared error makes the number go UP — which is
# the hazard of a two-implementation oracle, and why the direction is not the thing to read.

# CONDITIONAL COMPILATION IS CONTROL FLOW, at a different phase (CART-0380). `#if` /
# `#ifdef` / `#elif` / `#else` CONTAIN statements and flow classified none of them, so their
# bodies were attributed to the enclosing function AS IF UNCONDITIONAL — an `#if A / #else`
# pair read as BOTH bodies running in sequence — and the directive's own row harvested every
# name in the branch. Opened now like any other conditional: a head row carrying ONLY the
# condition, the body regioned, `#elif`/`#else` as chain links.
#   · THE STATEMENTS HANG DIRECTLY UNDER THE DIRECTIVE — there is no block — which is ruby's
#     `begin` shape, where a TYPE-based body stop has nothing to stop at. Hence HEADFIELD,
#     the mirror of BODYFIELD: forms whose head is exactly one FIELD (`condition`, or `name`
#     for `#ifdef`), so every other named child is a body statement. `false` = no head at
#     all (`#else`), which evaluates nothing.
#   · ★ THE `#if` EVALUATOR IS STILL BANKED and this does not need it. Deciding WHICH branch
#     is live is the TU-walk; it would NARROW this, not replace it. The ticket sat at P3 for
#     a year on the premise that the evaluator had to come first — the cheap half was
#     separable all along, which is the no-go ledger's own worst-death category.
#   · ★ AND IT WAS FOUND BY `ctrlcensus --folded`, the mode built for exactly this after
#     java's switch_block and ruby's begin: 156 candidates in 200 of 7kaa's files across four
#     types. THAT MODE NOW REPORTS ZERO on the same corpus.
# MEASURED: cpp rows 78202→81377 (+3175 previously-invisible rows), opened 18827→20038, and
# the control INSIDE those bodies surfaces with them (if_statement +358, for_statement +105).
# expr `binder:preproc_ifdef` 114→0 GONE. `counts` and `dfpar` unmoved.

# AN UNBRACED CONTROL BODY IS STILL A BODY (CART-0414) — every body test was a TYPE test,
# and `compound_statement` is only one SPELLING of a body. `if (c) x = 1;` puts a bare
# `expression_statement` in the `consequence` field, which no type test names, so the head
# row walked into it and BOTH sides folded the body's name onto the head — du as a DEF (a
# control head that assigns something) and the IR as a READ. The category disagreement is
# the ONLY reason this was catchable: dfparity compares df against flow and both are built
# from that same walk, so the leak itself was ungated. 985 instances / 947 distinct rows on
# 7kaa, the largest class in the census once the selector fix stopped masking it.
# The fix asks the GRAMMAR for the body FIELD (`flow.body_children`, called by du AND by the
# expression harvest) — the CART-0397 elsif fix one construct over.
#   · A field child that is itself a CONTROL FORM is deliberately NOT stopped: `else if` is a
#     nested if_statement in `alternative`, and its CONDITION belongs to the head row.
#   · ★ WHICH IS WHY THE STOP IS PER NODE, NOT PER ROOT. Computed once for the root, du kept
#     reading the chain LINK's unbraced body while the IR correctly stopped — 18 java grid
#     cells, EVERY ONE an `unbraced_ch2`/`ch3`. The grid found the intersection it exists to
#     find: the bug was neither "unbraced" nor "chain" but their product.
#   · ★ AND IT DE-DUPLICATED RUBY. A modifier (`x unless c`) has a `body` field, so the head
#     used to walk the modified statement and collect its attached block a SECOND time —
#     ruby rows 7745→7734, and every dropped row is a verified duplicate.
# dfparity moves on ruby only, DIRECTION CHECKED not assumed: flow > df in every sampled
# instance (`other = other.x if other.y` → flow keeps `other`, df drops it; `rescue E => e` →
# flow defs `e`, df defs nothing), flow < df never.

# A FIELD SELECTOR IS NOT A VARIABLE READ, AND THE IR SAID IT WAS (CART-0402) — the
# single largest defect the expression census ever held, and its size was invisible because
# the census is keyed by (axis, ROW TYPE): one cause firing under many row types is reported
# as many classes and ranked as none of them. `expr_reads` counted the `k` in `a.k`
# UNCONDITIONALLY. du counts it only where the grammar spells it with a type in that
# language's `ids` set — `identifier` in lua/java/python/ruby/odin/zig, `name` in php, but
# `field_identifier` in c/cpp/go/rust and `property_identifier` in js/ts. A LUA-SHAPED
# ASSUMPTION INSIDE A LANGUAGE-AGNOSTIC IR: the closed schema's own defect one level down,
# where the SCHEMA is language-agnostic and the reads function was not.
# The fix records `selid` on the field node at BUILD time — the only point where the
# selector's node TYPE is in hand; by `reads` there is only a string — and takes the ids set
# from `flow.leaf_ids`, never a private copy, because du is the OTHER implementation in this
# two-implementation oracle and an oracle whose sides read different copies tests the copies.
#   cpp 39752→3156 (92%) · cppmodern 30913→986 (97%) · go 35668→2939 · mootools 1232→37 ·
#   jquery 1780→104 · rust 5525→834 · grocy 4742→248 · python 341→10 · libs 304→255
#   UNCHANGED, exactly as the per-language probe predicted: java, ruby, lua, php, odin, zig,
#   bash, and both gridgates — whose selectors du already counts.
# ★ WHICH SIDE IS RIGHT IS STILL OPEN. This makes the IR implement the SAME RULE as du, so
# the gate now tests "both sides implement the ids spec" and is deliberately blind on this
# axis. Whether a member name should be a variable read AT ALL is a du-model question —
# semantically it is not one in any of these languages — and it stays ticketed rather than
# being quietly settled by a green gate.

# A CACHE KEY MUST BE AS FINE AS THE ANSWER (CART-0412) — the same defect, one field over,
# and the reason the language decision is now split in two. `elang_for`/`parse_lang_for`
# memoize on the BARE EXTENSION, while `ext_disclaim` (the CART-0347 fix that stops a
# Laravel `.blade.php` being parsed as php) reads the FULL FILENAME. So `x.php` and
# `v.blade.php` shared one cache key and could not hold different answers: whichever
# resolved FIRST decided for both. Order A restored exactly the 192-fabricated-node
# template parse that fix removed; order B returned nil for EVERY real php file in the
# process — a whole language going dark, which looks identical to a repo with no php in it.
# Now the memo holds the by-EXTENSION half plus the disclaim list, and the per-FILE suffix
# test runs on every call (a few compares against a list that is empty for every language
# but php). ★ STALENESS WAS NEVER THE RISK — the registry really is static, and the old
# comment said so, about the wrong thing.

# LANGUAGE FENCE — the audit that exists because four of these shipped in one arc and
# not one was caught by a test. A module that serves several grammars can hardcode a
# single grammar's vocabulary (`node:type() == 'if_statement'`, `stmt.t ==
# 'assignment_statement'`) and stay green forever, because the test suite is Lua-only:
# a Ruby-shaped hole leaves every assertion passing. One of the four was silently
# UNSOUND — the helper that stales a narrowing when its variable is reassigned matched
# only Lua's node name, so on Ruby it staled nothing at all. The oracle is the compiled
# grammar itself (`language.inspect(lang).symbols`), so "which grammars define this
# node type" is read, not guessed, and a module declares what it serves with a
# `@langs` line. The verdict is deliberately CALIBRATION-BOUND rather than
# authoritative: a deliberate single-grammar branch has the same *shape* as the bug, so
# each hit is either fixed or waived in place with `-- @langs-ok <reason>` — and the
# waiver is the point, since all four originals were assumptions nobody had written
# down. It knows two correct patterns and stays quiet for both: a per-language table,
# and a disjunction whose alternatives together cover every declared language. Like
# `pathsat`, it refuses to report until a fixture of planted positives *and* controls
# passes, because an audit that has never fired is indistinguishable from a clean tree.
nvim --headless -u NONE -l tools/langaudit.lua              # part of the pre-commit fence
nvim --headless -u NONE -l tools/langaudit.lua --all        # + modules with no @langs claim

# LUA PROFILE — mint the `luajit` L2 profile by INTROSPECTING this interpreter,
# rather than transcribing a manual: `for k in pairs(string)` measures the runtime
# that will execute the code. nvim's own additions are excluded by name (a profile
# called luajit must not promise `vim`) and the stamp records which LuaJIT it saw.
# Gives lua-factorio a comparable SIBLING, which is what the portability move-diff
# needs: two name-queryable profiles for one language.
nvim --headless -u NONE -l tools/luadistill.lua          # writes the .mpack
# …and the DECLARED half beside it (CART-0266): member SIGNATURES read from
# lua-language-server's @meta, which is the only source that can say what a stdlib
# call RETURNS. Introspection decides EXISTENCE (a measurement), the meta decides
# SHAPE (a claim, sig_kind='annotation'), and the exact join makes each a check on
# the other. --meta <dir> points at another copy.
nvim --headless -u NONE -l tools/luadistill.lua --meta <dir>
# API-DESCRIPTION OFFER: some environments publish their own API description, so a
# profile for ANY version is obtainable rather than hand-authored — which is what
# turns "the target lacks this name" into "1.1 had it and 2.0 does not". The URL is
# SPEC DATA (spec/ecosystem/*.lua api_source), never a literal at a call site, and
# NETWORK IS NEVER IMPLICIT: extraction, every verb and every report stay offline,
# and a test enforces that nothing under lua/cartograph/ even reads the field.
nvim --headless -u NONE -l tools/apifetch.lua            # what is OFFERED. No request.
nvim --headless -u NONE -l tools/apifetch.lua --check    # ask the index (CONTACTS host)
nvim --headless -u NONE -l tools/apifetch.lua 1.1        # resolve + fetch + distil
# A bare MINOR is not addressable (`1.1` 404s where `1.1.110` resolves), and a
# manifest declares the bare form — so a declared version is RESOLVED against the
# published index first, which is what makes "if available" a check, not a guess.
nvim --headless -u NONE -l tools/factoriodistill.lua <api.json> 11   # version-keyed
nvim --headless -u NONE -l tools/luadistill.lua --show    # print, write nothing
# and the same move for ruby: ask the interpreter on PATH, load the DEFAULT GEMS
# (so URI.parse isn't wrongly reported absent), and record which were loaded.
# Gives ruby-rails a sibling => "will this run without Rails?" is answerable.
nvim --headless -u NONE -l tools/rubydistill.lua

# DOC AUDIT — the same action pointed at our own USER DOCUMENTATION, which
# drifts for the same reason (hand-authored claims about a surface that grows
# every session). Three oracles, never conflated: the REGISTRY (proof — the
# commands that actually exist, captured by intercepting registration while
# sourcing plugin/, because nvim_get_commands() mangles multibyte descs); a
# SOURCE SCAN (evidence — pane-local commands don't exist until their pane is
# built, so they're read as text); the SPEC ROSTER (proof — ts.spec vs the
# language count each doc sentence claims). Two tiers: CONFIRMED DRIFT = the
# doc states something FALSE (a :Cartograph name that no longer exists, a
# language count contradicting its own list), always fatal; UNDOCUMENTED = a
# real command the helpdoc never names, a coverage gap that rides a RATCHET
# (may shrink, never grow). The helpdoc is held to complete coverage; README
# is prose, checked only for dead names and the roster claim.
nvim --headless -u NONE -l tools/docaudit.lua           # audit
nvim --headless -u NONE -l tools/docaudit.lua --emit    # + paste-ready help lines
```

`tools/navaudit.lua` is the same idea for the **cockpit**. The analysis half of
cartograph has uniform honesty; the navigation half's failure mode is *silence* —
a missing wire renders as "nothing here", which reads exactly like a real "none",
so it never trips a fence and only a user finds it. Three checks, ratchet 0:

- **surface honesty** — a file that reads whole-graph facts (`topo():callers`,
  `occurrences`, …) must also be able to say they are *absent*. The unit is the
  **surface, not the verb**: every earlier index-only guard sat on the command
  surface, so the cockpit reached a fabricated "none" by *navigating*. A pane is
  a surface; so is an LSP handler. Writing this check found a second instance.
- **concern disposition** — every altitude either has a `panes/concerns.lua`
  entry or is listed as explicitly not a concern, with a reason; stale or dead
  entries on either side fail too.
- **hover disposition** — every altitude is in the node-hover class or listed
  with why it is not, so a new altitude cannot ship undecided.

```sh
nvim --headless -u NONE -l tools/navaudit.lua
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
CFG must never throw); the churning self census is reported here as context and
**pinned nowhere**. It used to be pinned in `dfgate self`, and that entry's
comment had grown to 25 lines recording ~30 recalibrations — each one us
analysing our own newly written source — which is what a baseline looks like when
it cannot hold. `dfgate` now skips a corpus with no pinned `rev` (`--force` prints
the census anyway, labelled as context). The check core is `tools/dfparity.lua`, shared with `dfgate`. `tools/consumers.lua` is the shape roster
and seam rewriter (`--rw`/`--rwmod`/`--apply`, refusals printed as a review
ledger).

The **dogfood family** turns the tool on itself. `tools/dogfood.lua` is the
one-screen self-check (resolution by tier, the LSP answering its own graph,
lint) and the **authoritative-lint fence** — it exits non-zero on any finding from a
rule whose disposition says a finding *is* a defect: a raw read of the wide graph
indexes instead of through the Band, a silently-dropped callable, a multi-return
truncation, a load-order violation. Suggestive and calibration-bound counts are
printed beside it and never gate, grouped by what they claim. The fence needs no
pinned baseline because that set is currently empty on our own tree — the rule is
"stays zero", and a fence with nothing to calibrate cannot go stale. `tools/ratchet.lua` logs
those numbers per run and prints the delta (`resolved -0.3%` is a regression you
see immediately). `tools/conflicts.lua <corpus>` shows each cartograph-vs-lua-ls
disagreement with source context and cartograph's tier, so a conflict is
triageable in seconds (the charter's "a disagreement is a bug on one side").
`tools/lspparity.lua <corpus>` is the serving acceptance number (consistency +
parity vs a lua-ls dump). `tools/gaps.lua <root>` ranks a project's unresolved
callees by the gate that stopped them — the resolution work-list. And
`tools/seammigrate.lua` enumerates any remaining raw wide-index reads with the
Band accessor each should become — the migration work-list.

`tools/annotcensus.lua` <corpus|path> is the **annotation census**: the tag mix
(and how much of it is prose a reader must ignore *by name* — nvim's own
`@brief`/`@toc`/`@text` are not type tags), how many tags actually reach a
definition, what the `@return` types name, and the `annotation-mismatch` findings.
It takes a bare path as well as a registered corpus name, on purpose: the point is
to weigh a candidate corpus *before* registering it. What it measured is why the
annotation work is scoped the way it is — three quarters of the fuel is
`@class`/`@field` type declarations rather than definition annotations, and the
attach rate ranges from 1.7% (`nvim-lspconfig`, whose 6600 tags are mostly config
schemas adhering to nothing) to 97.3% (this repo, which only annotates defs). The
`nio` corpus is registered for exactly this: every other Lua corpus we gate on is
effectively unannotated, so anything reading annotations would otherwise ship
untested by construction.

`tools/pathsat.lua` <corpus|path> is the **contradictory-path ceiling probe**: would a
boolean path solver earn its keep? It asks whether any statement's dominating guard
conjunction (`cfg.guards_over`) asserts both `C` and `¬C`, which would prove it
unreachable — and reports a *ladder* of tiers (RAW → PURE → NOREASSIGN → STRICT),
because the naive form is a name match and the drop between tiers is the finding.
Across seven Lua corpora (~51,000 functions) the filters remove all but **three** naive
hits, and no survivor needed a solver at all — real guard conjunctions are small enough
that contradiction detection is a set-membership test rather than a satisfiability
problem. It refuses to print corpus numbers until a fixture of known positives *and*
known near-misses passes, on the principle that a probe reporting zero is
uninterpretable until it has been shown able to fire — a gate that has now caught four
bugs in the probe itself before it reported anything.

Two of those three only became visible later, and how they did is the more useful half
of the story. The first verdict was **one** survivor, and it was banked as a *lower
bound* rather than an answer, because `guards_over` was at the time blind to the
negative fact an `else` or `elseif` carries — so the shape where a copy-pasted condition
is most likely to appear was the shape the probe could not see. Teaching the dominance
relation to emit `¬C` in the else of `if C` raised the count, and both new finds are real
defects in shipped third-party code: one where an early exit has already established a
value truthy, making the `else` of a later test on it unreachable — so that function can
never report a boolean `false`, only `nil` — and one where `elseif level == 3` is simply
written twice, leaving the second branch dead. The same run also produced two *false*
positives, and neither was caused by the change: both were admissions the top tier had
always been capable of and had never reached. A condition reading a container
(`if t[k] then … load() … if t[k] then`) is mutable through the intervening call exactly
as a call is, which the name-keyed filters are structurally blind to and only the purity
filter can refuse; and `char == "  "` versus `char == " "` were collapsed into one key by
a normalizer that squashed whitespace over the condition's source *text*, when
whitespace is insignificant between tokens and significant inside one. Making a
mechanism more precise surfaces the false positives its filters could always have
admitted — the first run after a precision fix is a report about the instrument as much
as about the world.

`tools/holecensus.lua` <corpus|path> [--by kind|tier|rule|file] [--verify [N]] is the
**test-template hole census**: if a test were generated as a *template with holes*, how many holes would
each function have, and which are **our gap** rather than the honest frontier? A hole is
never *labelled* "our bug" — an **edge** is drawn to the evidence that indicts us, tiered
because the answer keys have unequal authority (an observed call-site literal is
`measured`; a same-file definition is `derived`; a declared annotation is only a `claim`,
since docblocks demonstrably lie — that is why `annotation-mismatch` exists). Absence of
the edge *is* the frontier, rendered as an unlinked hole rather than as silence. `--by`
rotates the same structure: by hole kind, by tier, or **by owning rule**, which reads as a
work-list of our own analyzers. What it measured: emittability is **monotone in annotation
density** — 51.2% of `nio`'s functions carried no blocking hole versus 1.8% of `desynced`'s,
tracking 1.06 versus 0.003 annotation claims per function. (Those figures counted the hole kinds
the census computed at the time. It now consumes the *emitter's* hole set — which also knows about
reachability, the module load and the environment — and nio reads **2.8% emittable / 0.5%
runnable**. The trend held; the level was measuring a smaller question than the word implied.)
`--verify` really runs the synthesized population — a purity-gated subprocess per function, so it is
opt-in — and prints what a run proved rather than what a fill implied, with the failures split by
whether the *subject* raised or *we* broke. It exists because this tool's own third headline once
said `runnable` over an unverified count. The oracle hole is irreducible
by construction and is *not* counted against emittability: filling it with one run is the
design, not a gap. An **absent `require` is not fatal** either — it becomes an
*injection point*, since short of globals and mutation we know what a body does with what
it is given, so a stub makes the function testable and the test then characterizes
behaviour *under that stub* (which its header must disclose, because a stub is a supplied
premise). Measured: reclassifying absent-callee roots from unbuildable fixtures to
injectable stubs raised `desynced` from 1.8% to 5.2% — but it *lowered* `self` from 19.7%
to 17.3%, because a function that writes module state or mutates an argument cannot be
isolated by injection and honestly blocks. So the frame's value tracks **purity**, not just
how much environment is missing.

That census then indicted us. Its top absent callees on every Lua corpus were the *Lua
standard library* — `match` 432, `concat` 222, `sort` 211, `close` 193, `open` 180 — each
100% frontier for a stub, i.e. the most documented API there is and we could not say what
it returns. *"If we don't know how to stub it, that's a gap on our side"* (user). The names
were never the problem: `luadistill` introspects them. A stub needs the **signature**, and
only a declaration carries one, so the distiller now also reads lua-language-server's
`@meta` — **two sources, two tiers, checking each other**. `for k in pairs(string)` is a
*measurement* of the interpreter that will run the code; an `@meta` docblock is a *claim*.
The join is exact, so each audits the other and both directions inform: a function the
interpreter has and the meta doesn't is an honest signature gap (2 of them); a member the
meta declares and LuaJIT lacks is a claim about another runtime — `string.pack`,
`math.type`, `table.pack` — moved out of `sigs` rather than served, because hovering a
5.4 signature over a function LuaJIT doesn't have would fabricate a member of the very
runtime the profile measures. The cross-check is what *found* them: the meta gates those
behind an `@version` tag, a second mechanism beside the `#if` preprocessor.

Result on `self`: frontier holes **12194 → 10520**, the census's emittable count 17.4% → 18.0%, and
functions with *zero* holes of any kind 89 → 124. (That emittability figure counted the hole kinds
the census computed at the time — it now consumes the emitter's, which knows about reachability, the
module load and the environment, and the same corpus reads **3.7% emittable / 3.2% runnable**. Both
numbers are printed, because *a tier is not a value*: an `@param number` makes a hole non-blocking
and still gives you nothing to call the function with. The answer-key loop caught the divergence.) On `desynced` the frontier falls 251 and
emittability does not move at all — its absent callees are a game engine, not the stdlib —
which is the exact inverse of the injection frame's distribution. Two complementary levers.

The honesty is in the split, not the count. A signature is `SOUND` when the call names its
own namespace (`table.concat`) or is a free function; `HEDGED` when only the member name
matched (`s:match` → `string#match`, the sole stdlib owner of that name — a guess that
happens to have one candidate, receiver unverified); and a `SET` when several owners
declare it (`close` is *file*'s and *io*'s — the receiver decides and we don't have it).
Sampling the hedged population found the rule's one real failure: 176 sites signed from
`buf#get`/`buf#put` (LuaJIT's require-only `string.buffer`) and `profile#start` against
this repo's own `cv:get`, `store:get`, `timer:start`. Generic member names on an optional
extension library are the worst possible source for a name-only rule — so eligibility is
**derived, not blocklisted**: an owner may answer a bare name only if the interpreter
presents it as a namespace, or if a member of one *declares it as a return type* (`io.open`
returns `file*`, so `file#seek` may sign `fd:seek()`). That drops 39 canon entries, and the
frontier count *rises* by exactly the wrong answers removed.

`tools/portgraph.lua` <corpus|path> is the **port graph**: for library functions we cannot
see, we can never name the types — but if `FindComponent`'s return flows into
`RemoveFromParent`'s first argument, those two anonymous **ports** are observably
interchangeable, and sweeping the corpus for such flows partitions opaque values into
compatibility classes. *You don't need the name, you need the partition.* Ports are
`(callee, slot)`; edges come from three observed flow shapes (a local mediating two calls,
direct nesting `B(A())`, and a method receiver `h:Destroy()`); union-find does the rest —
no solver. The naive partition is **expected to be degenerate**, and the tool prints the
largest-class share as the number the propagation rules have to beat, plus the top ports by
degree as their work-list: `ipairs#a1` (degree 137 on this repo) accepts anything iterable,
so it unifies every table in one stroke. What already works is the part the blob doesn't
reach — with no declarations anywhere, observed flow alone recovers
`nvim_get_current_win#ret ~ nvim_win_set_height#a1 ~ getwininfo#a1` as one class, which is a
window handle.

The **propagation rules** that make the partition usable came out of a matrix, and the
matrix killed the rule that looked most obvious. One rule survives: a callee that is
*unqualified*, is not a project definition, and whose degree clears a threshold is a
**universal sink** — its edges are recorded but do not transit, because a port that
collects every string in a codebase has no single type. That plus a degree gate takes the
largest class from 69.7% of ports to 21.6% on this repo and from 79.8% to 15.2% on a game
mod, with every hand-read real class intact. The rule that died was "the callee's root is a
known builtin": `vim` is in the builtin roster as an always-present module table, so it
condemned every `vim.api.*` port and destroyed the window-handle class — which was visible
*only* because the acceptance metric is two-sided. On largest-class share alone it read as a
clear win. What survives the rules are real types nobody declared:
`math.floor#ret ~ math.min#ret ~ math.ceil#ret` is a number, and in the game mod four
different faction getters unify with the parameter that consumes them.

Compatibility is **evidence, not equality**, so every relationship carries how many sites
observed it and a class is a *query at a stated threshold* rather than a stored fact.
`--port 'callee#slot'` is the user-facing form: it answers "what accepts this?" with a
ranked list carrying counts, never with a type name we don't have —
`nvim_get_current_win#ret` reports seven observed partners, `nvim_win_set_buf#a1` at three
sites and the rest at one. Tempting as it looks, filtering by that count is **measured
harmful**: requiring two observations drops the largest class from 21.6% to 6.5% of ports
and destroys every real class, because most specific flows in real code happen exactly once.
A metric can be improved by destroying the thing it measures, which is why the acceptance
check has a second side.

A **declaration on any one member names the whole class**, which is where the payoff
compounds: measured on this repo, one annotation names **3.4 ports** on average and not a
single one names only itself. The same door takes a profile later, so nothing here waits on
one. And because a class can be checked against the declarations its members carry, two
different declared types inside one class is a **conflict** — meaning either the partition
over-merged or the docblocks disagree, and it is reported rather than resolved by majority,
since which side is wrong is exactly what a declaration cannot settle. Those conflicts land
where they should: 18% of large classes and **0% of small ones**, which makes
conflicts-per-class a partition-quality check that needs no hand-reading. The sobering figure
is coverage — only 5.4% of resolved ports carry any declaration at all, even here, because
ports sit on external and stdlib callees; a game mod has none whatsoever.

All of that is a lens, not just a probe: **`:CartographPortClasses`** opens the roster of
classes (each named by its highest-degree members), `<CR>` descends into one to see its ports
split by axis — *produced by* versus *accepted by* — and `<CR>` again gives a port's observed
partners ranked by evidence. Focused on a function it starts at that function's own ports, so
the question it answers is "what else can go where this parameter goes?"; a port name as an
argument goes straight there. `tools/portgraph.lua` and the lens read the **same** module, so
the measured numbers and the displayed ones cannot drift apart.

And then the census stopped counting and started **emitting**.
**`:CartographCharacterize`** (headless: `tools/characterize.lua <root> <fn|file:line>`)
turns one function into a *runnable* characterization spec — self-contained, no harness,
`nvim --headless -l` or plain Lua. Every value we cannot know is a `HOLE(...)` that
**errors**, so an unfilled spec *fails*. That is not a stylistic choice: a suite that goes
green because its assertions are missing is absence-rendered-as-silence at its most
dangerous, since it looks exactly like coverage.

What the environment already supplies is **not** a hole, and that is where CART-0266's
signatures pay off twice: the spec runs in a Lua interpreter, so a `table.concat`
dependency is *satisfied by the runtime*; it `dofile`s the subject, so a same-file
definition is *satisfied by the load*. Both are still rows, disclosed as **premises**,
because "no hole" and "a hole the environment fills" are different claims. And the
module load is a premise too: `require 'a.b.c'` is aligned against a file the graph holds
to *derive* the package path, and a require that cannot be aligned becomes a hole rather
than a crash inside the spec's own preamble. That last one only showed up by driving the
verb on a real module; the fixture required nothing, so `dofile` worked and hid it.

**How the spec reaches its subject** is a hole of its own, and it is *four* answers rather
than one. A `function M.add()` is a member of whatever the module returns — checked, not
assumed, because a file that does not end in `return M` would give a spec that dies with
"attempt to index nil". A **file-level** `local function` is an **upvalue** of whichever
exported function references it — so the spec walks upvalues from the module's exports and
gets the real function object, with no stub and no source rewriting. That walk compares
`linedefined` and the source file, not just the name, because a `local sort = table.sort`
beside a `local function sort` would otherwise hand back an impostor and the spec would
characterize a different function while reading as a success.

Those two halves are deliberately different channels: cartograph *derives* from source that
an exported function mentions the local, and the emitted spec *observes* it by walking for
real. A disagreement is a genuine bug on one side, and the walk coming back empty fires the
hole rather than leaving a nil subject to crash three lines later. The spec also says out
loud that it reached past the module's public surface, because a subject reached that way is
one the module never promised. Measured on this repo: 658 of the 798 file-level locals whose
carrier *could* exist are recovered (82%), which moved emittable from 3.7% to 4.4%.

Walking a module's exports needs a module, though — and most functions have none to offer. 1118
file-level locals live in **scripts** (`tools/`, `tests/`) that return no table at all, and 620
more are **nested** inside another function, so they are not objects until the enclosing call
runs. Neither is reachable *that* way, and the first version of this paragraph called them
unreachable full stop, which was a limit of the mechanism written down as a limit of the code.

They are reachable by **reconstruction**: a declaration compiles from its own source text, and
its free names resolve as globals — which is exactly how the fixture holes above already supply
things. So the mechanism supplies the closure and the existing machinery supplies what the
closure reaches for. What comes back is an *equivalent* closure and **not** the object the file
builds: same bytes, but its captured state is what the spec supplied rather than what the
enclosing scope held, so a subject sharing mutable state with that scope will not behave
identically. That makes it `derived` and never `measured`, and the spec prints the difference
rather than keeping it to itself.

Three things keep it honest. The spec **re-reads the file every run** — an embedded copy of the
declaration would keep passing after the function was edited, reporting "unchanged" about source
it no longer describes, which is the one failure a characterization test must never have. It
anchors on the declaration's **signature**, not its line number (which goes stale when anything
above it moves) and not its whole line (which for a one-liner is the body too, so a body edit
would lose the subject instead of reporting `CHANGED`). And a declaration that does not *own*
its lines is refused outright: `local BOXED = setmetatable({}, { __tostring = function () … end })`
compiles perfectly as a statement while binding something else entirely, so "it compiles" was
never a sufficient check. Measured: emittable **4.4% → 9.4%**, runnable **3.7% → 5.7%**.

Filling a hole is **discharging a hedge**, so it follows the decline ledger's protocol: a
fill without a stated **basis** is refused, and the tier records *who* answered —
`measured`, `derived`, `claim`, or **agent-supplied**, a fourth tier that exists because
without it an agent's guess is byte-identical to an observed call-site literal. The oracle
hole is stricter still: fillable by **running** (a recorded behaviour) or by a **spec**,
*never by prediction*, because a predicted expected value produces a test that passes
because the prediction matched the prediction — indistinguishable from a real
characterization test and worse than none.

The output never enters the push fence: `plan()` refuses any path under `tests/` or ending
`_spec.lua`, and the default lands in `characterized/`, gitignored. A characterization
spec is *supposed* to fail when behaviour changes; wiring one into pre-commit would block
every legitimate refactor. It is a tool you invoke, and the write still rides the full txn
ladder — journal, CAS, and a load gate on our own output. This is the executable
counterpart to `:CartographNeutralityCheck`, which certifies a refactor by hashing the df
shape: a **proxy** for the same question, where this is a real assertion. Run it before and
after, and a behaviour change reports as `CHANGED: M.add returned 8, characterized as 7`.

Then **`:CartographCharacterizeRun`** fills the oracle by *running* the function — the one
verb in this plugin that executes your code, which is why it is its own command and not a
flag. The exception is the point rather than a crack in the rule: every analysis refuses to
run anything, which is exactly *why* the expected value is a hole and never a guess. But a
hole is not a wall. The value exists, one run away, and a recorded run is `measured`
evidence — the strongest tier there is and the only one that can ever answer this question.
We still never *invent* it; we observe it, label it observed, and record what we ran.

Four things make that safe enough to ship, and the first is the loop closing on itself:
**our own effect analysis decides.** `effects.purity` already labels every function
`pure` / `io` / `writes` (with `~` when it is unsure), so "is running this safe" has an
answer we *computed*. Only `pure` runs by default — `io` would touch the world, `writes`
would mutate module state, and a hedged `pure~` means our analysis is not certain; all three
are refusals, overridable only explicitly, and a forced run is disclosed in the spec header.
The subject runs in a **separate process**, so an infinite loop or an `os.exit` cannot take
the editor. **Serialization is a refusal surface**: a value with no Lua literal form — a
function, userdata, a cyclic table, NaN, a table with a table key — leaves the oracle a
*hole* with the reason, rather than a fabricated fixture. And **determinism is checkable**:
two runs, and a disagreement is reported as the subject's nondeterminism, because a spec
that fails at random teaches its reader to ignore failures.

The run carries an **execution budget**, and it is two-sided because each half is blind to
what the other catches. An **instruction count** is deterministic — the same subject trips it
at the same point on every machine, which matters more here than anywhere else, since a
load-dependent limit would make the *recording* flaky and recording reproducible values is the
whole job. It only works with the **JIT off**, though: measured, a 100-million-iteration loop
finished having produced *zero* ticks, because LuaJIT count hooks fire only in the interpreter
and a hot loop compiles to a trace. So the probe runs interpreted — slower, and the only way
that half of the fence is real rather than decorative. A **wall clock** covers everything the
hook cannot see: a real nine-require module load costs 6000 instructions and ~15 ms, nearly all
of that time spent in C, so the clock is not a redundant second fence but the only fence on
most of the cost. Output is capped as well, which bounds memory rather than time. Each limit
names itself when it fires, and a successful run records what it **cost** in the spec's own
basis — a default nobody can see the cost against is a superstition.

Development turned up three defects worth naming, all of them found by running the thing
rather than by reading it. A recorded **table** produced a spec that would not parse: nvim's
headless `print` emits CRLF, and Lua treats a bare `\r` as a *line terminator*, so the
provenance comment ended early and the rest of the line parsed as code — a value crossing a
process boundary is bytes, not text, until something normalizes it. `local got = f(x)` kept
only the **first** return value, so a function returning `nil, err` was characterized on half
its behaviour while the spec read as complete; the capture is now `select('#', ...)`-based,
which also distinguishes `return nil` from `return`. And the emitted header carried the graph
**generation**, so applying bumped it and a re-characterization of an unchanged function
wrote different bytes — a generated file that changes when nothing it describes has changed
shows up as a diff in every review and trains its reader to stop reading it. The write is now
idempotent to the byte: identical content journals nothing, because a journal entry per no-op
would fill the undo stack with steps that undo nothing.

And then the refusal turned into an **injection**. Refusing to run an `io` subject was the
safe answer and a poor one: it excluded exactly the population a refactor most needs a
witness for. So instead of refusing, cartograph injects **its own functions** — the same
frame that turns an absent `require` into an injection point, pointed at the *dangerous*
case instead of the *absent* one. A fake `io.open` records the call and touches nothing;
`os.execute("rm -rf /nope")` is recorded, never performed; and the containment claim is
checked against the filesystem, not against the roster.

The bigger prize isn't running io functions. It's functions that **return nothing**, whose
behaviour *is* their effects: those used to emit "no oracle … which this spec does not
observe" — true, and silence where a hole belongs. Now the **call log is the oracle**, and a
population that was entirely uncharacterizable is characterizable. `M.log(msg)` is
characterized as `print("[log] hello")`.

Three things shape the design. The roster is **derived from the effect vocabulary**, not
hand-listed: a channel we have no fake for is refused *by name*, because a sandbox with a
hole in it looks contained and is not — "refuse io" became "refuse *unknown* io". A
**nondeterministic** channel is injected too, which only surfaced by driving it: the
vocabulary calls `os.getenv` pure-but-nondet, so an io-only filter passed it through and the
run recorded this machine's real `$HOME` — a value that fails on anyone else's machine, and
one the purity *label* cannot see either. And **a fake is a supplied premise, not the truth**:
with a fake that fails, `io.open(p) ~= nil` records `false`; with one that succeeds, `true`.
Both are facts about our stubs, so the basis says the value was measured *under the sandbox*
and the emitted spec **reinstalls the same sandbox** — a spec running against a different
world could not reproduce the value it was handed.

Two defects fell out of driving it, and both are about injecting into a namespace you also
use. `print` is io in the vocabulary, so the sandbox faked it — and the *probe reports through
print*, so it silenced itself and the run failed with "produced no value". Our own output
handle is now captured before any injection can land. And a spec loaded **in-process** left
the fake installed, so the host's output went silent after the first spec ran; the sandbox now
restores every global it replaced, before the assertions, so even a *failing* spec leaves the
process clean. A sandbox that outlives its subject has escaped.

Then the whole thing collapsed into one mechanism. The sandbox roster, the io refusal, and
(a layer up) the VM's host problem were three ways of asking *what does this code need from its
environment, and who supplies it* — which is a **hole**, and the hole machinery already had
everything: an id, an owning rule, a tier, a mandatory basis, prediction refused, a premise
line, and an unfilled hole that *errors* instead of passing. When three mechanisms keep needing
the same list, the list is a first-class thing you haven't named yet.

So `env:io.open` is a row that ships with a **default fill** (our fake, at `claim` — a fake is
something we *declared*), and `env:vim.fn.tempname` is a row that ships **unfilled**. The
refusal disappears: an unmodellable channel no longer makes the whole subject unreachable, it
blocks the run *naming itself* and makes the spec error — and supplying it, from an agent or a
profile or a recorded value, makes the subject characterizable. Measured on this repo, that
moved **2633 of 3601 functions** out of a categorical label gate and into addressable holes.
A profile signature rides along as *evidence* rather than a fill, because a type is not a value —
the same reason an `@param` doesn't fill an input hole.

Three defects fell out of doing it, each the same shape: a stale copy of state that had moved.
The row-building loop copied a **fixed field list**, so a pre-supplied fill was silently dropped
and every env hole read as unfilled. `plan.sandbox` was computed once at plan time, so an agent
filling a hole *afterwards* was accepted, never installed, and the run went through the real call
while the oracle was tiered `measured` — the sandbox is now a **view over the holes**, which are
the single source of truth. And the patcher matched two-segment names, so `vim.fn.tempname`
fell through to patching a global *literally called* `"vim.fn.tempname"`: accepted, installed
nowhere, and the spec ran unsandboxed while looking contained. A name-shape assumption that fails
**open** is the worst kind, so a path we cannot walk now errors.

Then a sharper observation collapsed the value problem too: **if a return value is only passed
around, we never need to know what it is.** The `io.open` fake returned `nil`, which made
`if f then f:write(s) f:close() end` skip its body — so the recorded log was the *open* and none
of the writing. A characterization that claims to describe what a function does, omitting the two
calls that do it, and *looking complete*. But `f` is only ever the receiver of `:write` and
`:close`: it needs an **identity, not a value**. So a fake hands back an opaque **sentinel** that
records its own use, and the trace becomes
`io.open("/tmp/zz","w") -> <h1> | <h1>:write("hi") | <h1>:close()` — numbered, because one handle
used twice is a different program from two handles used once.

And when the subject *does* inspect such a value, that isn't a violation of opacity — it's a
**derived hole with a relation**, plus the operator that observed it as a constraint.
`"h=" .. f.name` yields `inspect:<h1>.name`, *derived from `<h1>`*, constrained *string-coercible*.
The run teaches the plan: that hole did not exist before it ran. Which also fills the tier
ladder's empty rung — a fill that *satisfies* a recorded constraint is `derived`, neither observed
nor declared, and that is the line between deriving a value and fabricating one.

Two inspections a sentinel cannot cover are refused rather than faked, and both limits are
measured rather than assumed: `#f` fires no `__len` under LuaJIT and would **silently answer 0**,
so it's caught statically and blocks; a comparison raises, and the refusal names the *inspection*
rather than the interpreter. The proxy is used exactly where the metatable can see, and the static
side covers where it cannot.

And then the input hole got an answer. `input:n` says *choose a value* and offers no way to
choose one — but what a person actually knows isn't the value, it's the **condition**: "the file
is non-empty", "the mode is fast". So **`:CartographCharacterizeAssert` lets you declare the
predicate and derives the value from it**: `n > 10` asserted true yields `n = 11`, and the run
demonstrably takes that branch (`M.pick` asserted true returns 1, asserted false returns 2).

That fills the tier ladder's last empty rung, and the split is worth being precise about. The
**premise** is a `claim` — someone declared it — while the **observation stays `measured`**,
because an asserted input is not a fiction: `n = 11` is a real value and the run really returned
"big", so the *pair* was observed. What the assertion weakens is **generality**, not the
observation; conflating those would tier every measurement by the reason someone picked its input.
The report discloses **which branch the assertion selected**, since a spec that quietly picks a
side reads as characterizing the function when it characterized one path.

There's no solver, and that's measured rather than hoped: an earlier probe found conjunctions in
real code are tiny, so this is **inversion of a closed set** of comparison shapes — `>`, `>=`, `<`,
`<=`, `==`, `~=` against a literal, plus bare truthiness and `nil`. A condition comparing two
unknowns is **refused by name**, because a value satisfying a half-understood condition looks
derived and is a guess.

That distinction — generality is not the same as the observation — turned out to be the whole
answer to the input hole, and it took a while to notice. `holes.blocking` treated an input as an
unconditional wall, commented *"we cannot choose the value"*. But we can always choose a value; that
sentence encoded "we do not know the **right** value", which is a claim about generality wearing the
costume of a claim about runnability. So **`:CartographCharacterizeSynth` synthesizes the input from
what the body requires of it**: `p.foo` means a table carrying `foo` — and the field names come free
with the access — `p + 1` means a number, `p()` a function, `s:upper()` a string because `upper` is a
string method while `o:render()` is a table carrying a function field. Shapes are per **access
path**, not per parameter: `ipairs(p.items)` makes `items` a table, `#o.list + o.count` gives one
field a table and its sibling a number, and `c.opts.mode.name` nests three deep. That distinction is
not academic — the first version derived a shape for `p` and merely *created* empty ones for its
fields, which then got filled with an opaque string, and iterating a string raised. It accounted for
143 of 196 `bad argument to a builtin` failures in the verified run; deriving the fields turned 96 of
them into passing specs. Measured on this repo: of
4411 blocking input parameters, **46.9% are never inspected at all**, so literally any value runs,
and the other 53.1% carry a shape the code itself pins.

A synthesized value is `derived` when the body constrained it and `claim` when nothing did, never
`measured` — it's *our* value, and "the code told us the shape" and "we picked something harmless"
must not share a word. A parameter the body uses as two types is **refused** rather than resolved,
since picking a side would run the function under a premise the code contradicts. And because a
minimal value **picks a path** — `{}` for a parameter the body loops over characterizes the *empty*
case — the spec says so at the top, in the same breath as the values: the behaviour recorded is
real, its *generality* is ours. That's why it is a separate command rather than a flag, and why the
census reports it as a **third number** instead of folding it into emittable. Diluting evidence with
our own guesses on the largest hole population in the corpus is precisely how a survey lies by
confidence.

That third number is called **fillable**, and the name is a correction. It first shipped as
*runnable under synthesis* while counting only that the input holes got **filled** — a proxy for the
claim the word made, in the very tool that exists to catch proxies. `holecensus --verify` really runs
the population, and the honest figures are **9.4% emittable plus 16.8% verified, together 26.2%** —
not the 52.3% the unverified count implied. The capability is real (of the 1499 fillable, all 588
whose oracle a run could observe emit a **passing** spec, and zero pass-then-fail) but the headline
overstated it by 2.5×. Verification is opt-in because it costs a purity-gated subprocess per
function, which no default census can afford; what is *not* an option is keeping the word and
dropping the check. **A name may only claim what the check behind it performs** — the third time that
rule has had to be applied here, after emittable-vs-runnable and the reach count.

**A raise is a behaviour, so it gets characterized.** Of 399 subjects that produced no value, 366
were the subject *raising* on the input we chose, and a function whose behaviour on that input is to
fail had no spec at all. Now the call is guarded and the error is the expectation: `f({}) raises
"attempt to index a nil value"` is reproducible, and it is exactly what a refactor breaks silently.
The assertion runs in **both** directions — a subject that stops raising has changed as much as one
that starts, and a spec checking only the message would pass silently the day the function begins
returning.

Two things keep that honest. The message's `file:line` prefix is **stripped**, because comparing the
raw text would report a false `CHANGED` for any edit above the raising line, which teaches a reader
to ignore failures. And a raise caused by *our own premise* is refused rather than recorded: a
sentinel that got compared, or a `require` that cannot resolve in a fresh process — the latter's
message embeds the searched paths, so it is not even stable between runs. Together with the field
shapes above, this took the verified figure from 26.2% to **37.6%** and reduced "produced no value"
from 399 to 6. A separate 441 functions were emittable but refused to run because a hole carried a *tier* and no
*value* — 395 of those same-file definitions a reconstruction no longer receives from a module load,
a cost the reconstruction knowingly paid. Those are now **re-emitted**: for a name the subject reads
from its own file, cartograph finds that name's module-level declaration and puts it back into the
spec, so the spec evaluates *the same source the file does*. No evaluator and no serializer are
involved, which matters because a function value has no literal form — source can supply what a
serializer never could. A multi-line constructor is grown until it compiles rather than brace-matched,
and a declaration that would *perform* something (`local DANGER = os.time()`) is refused by name,
since re-emitting it would call `os.time` at spec load. It is the one supply step here that happens
automatically, because it involves no choice: the file's own source is answering a name from that same
file, which is exactly the claim `satisfied_by` makes when a module load answers it.

And then the choice went away entirely. A condition on an unknown has no right answer to pick —
it has **two behaviours**, and describing one is describing half. So `:CartographCharacterizeFork`
runs it **both ways** and shows both states: neither is presented as *the* behaviour, both are
`claim` tier, and **what differs between them is the deliverable**. Rendering `f.size > 0` as
"these lines run / these lines run" says what that condition *does* better than any prose we could
write.

Forking also buys a lint nobody asked for. If the two states are **observationally identical** —
same return, same effect log — the condition decides nothing: a guard that guards nothing. That's
*behavioural* where the structural redundancy check can't reach, and it's hedged in the same
breath, because it says nothing about paths the fork didn't explore.

The combinatorial explosion is real but **rare**, which I measured before building anything:

| | 0 forks | ≤1 | ≤2 | ≤4 | worst |
|---|---|---|---|---|---|
| self (3403 fns) | 55.0% | 73.3% | 83.3% | **91.9%** | `M.extract` 45 (3.5×10¹³ states) |
| nio (217) | 83.4% | 92.2% | 96.3% | 99.1% | 7 |
| desynced (1900) | 58.2% | 75.3% | 83.1% | 90.5% | `AddStats` 89 |

Over half of all functions have nothing to fork, and ~90% sit at four conditions or fewer — 16
states, trivially enumerable. **So for most of the corpus the smart thing is to be dumb**:
enumerate to a stated bound, no heuristic and no search. For the remaining ~10%, the answer isn't
a cleverer search — it's the **scan**: fork every condition *independently*, 2n runs instead of
2ⁿ, and keep only the ones whose states differ. That turns n into k live axes, it's the only
reduction here that *measures* rather than assumes, and the lint and the reducer are the same
pass — a condition that changes nothing is both a finding and one fewer axis. What it scanned and
what it skipped are both stated, because a silent cap reads as "we explored everything".

And that is what the whole arc was for. `:CartographCertify` records what the touched symbols
return and DO, you refactor, and `:CartographCertifyCheck` replays the same runs and compares —
**neutrality with real assertions instead of a hash**. The existing witness check is a genuine and
useful proxy: it hashes a body's *shape* (df shape + params + callees), so it certifies a MOVE and
correctly drifts on an extract-helper. What it cannot do is speak for a body that changed **on
purpose**, which is the refactor you are least sure of.

Measured on a two-symbol case, the proxy got **both answers backwards**:

| symbol | reality | witness hash | certificate |
|---|---|---|---|
| `M.tag`, `"[" .. s .. "]"` → `"<" .. s .. ">"` | **changed** | NEUTRAL — same shape | **CHANGED** |
| `M.add`, body rewritten *and* params renamed | **neutral** | DRIFTED — body touched | **NEUTRAL** |

Neither result is a criticism of the proxy — its own header says it certifies moves, not rewrites —
but it is exactly why a real assertion was worth building.

Two pieces of honesty carry it. **A hash always computes and a run does not**: a symbol with an
unfilled hole cannot be certified by assertion, so it is reported as covered *only by the witness
hash* — named, never counted as neutral, because a certificate that borrowed the proxy's coverage
while implying the assertion's strength would be worse than the proxy alone. And inputs replay **by
position**, so a parameter rename survives (keyed by name, the check broke on the most
behaviour-neutral refactor there is), while an **arity** change is reported as a *signature* change
rather than a behaviour comparison between two different functions.

Meanwhile `writes` stopped being a refusal at all. A separate process contains anything
process-*local*, so a module-state write is both safe and reproducible in one — measured, a
function incrementing a module counter returns `1` on three separate runs, because each run is
a *first* call. What a process cannot contain is the world, which is why `io` is the label
that needed a sandbox. The recorded value carries that premise, because a reader who doesn't
know it is the first call will misread the number.

And once a run can be recorded, a tool can propose invariants — which is where most such tools go
wrong, because an invariant that held over five inputs is not a property of a function. So
`tools/invariants.lua` **attacks its own proposals**: it proposes from one run and then varies every
axis that run did not, because *an invariant inferred from runs that all took the same branch is
wrong exactly along the axis the evidence never varied*. The fork already knows which axis that is,
and the assertion inverter can construct an input that takes the other side — so the counterexample
is **derived from the function's own control flow**. The invariant proposes, the inverter attacks,
the run decides, and none of the three steps guesses.

Measured on a two-line function:

```lua
function M.lookup(k)
    if k == "known" then return k end
    return nil
end
```

One run with `k = "known"` supports **four** wrong candidates at once — always returns `"known"`,
always returns a string, never returns nil, returns argument 1 unchanged. Forking the single guard
refutes **all four**, each row carrying the counterexample that killed it. A propose-only tool ships
those four as knowledge. Against `function M.always(x) if x > 0 then return "yes" end return "yes" end`
the same attack refutes nothing, which is the half that makes it discriminating rather than merely
destructive.

The honesty is in three places. A survivor is `derived` with a **support count**, never a fact. **No
opinion is not support** — a template that cannot read a value abstains, because "checked and true"
and "could not check" are different rows. And an invariant that survived because we **could not
attack it** is not one that nothing could refute, so the report states what it could not vary and
why: with no forkable condition it says outright that every row rests on one input set, which is the
weakest evidence the tool can produce.

Two **decision** tools answer "what's worth building." `tools/ablate.lua`
[corpus] drops each resolution pass in turn, re-extracts, and reports the
**net** resolution it loses — the marginal value `by_prov`'s gross credit
can't show (gross − net = redundancy; net ≈ 0 across corpora = a de-fund
candidate). `tools/levers.lua` [corpus] decomposes the *unresolved* calls by
the gate that stopped them, groups those into strategic levers (stdlib-profile,
pack/vocabulary, name-match, dispatch), and ranks them by the resolution points
each would add if realized — the "where's the biggest win" call as data, per
corpus (on zig it independently reproduces the ~50% std figure).

`tools/assigndef.lua` <corpus> is the same question asked of a *missing def form*:
a callable bound by assignment (`M.f = memo(g)`, `X.y = function(){}`) sometimes
gets no def node, so every call to it is unresolved. It classifies each site by
what the right-hand side is — LITERAL (the body is here), WRAPPED (the identity is
here, the body elsewhere), ALIAS (wants the alias *followed*, not a def minted) —
and reports, per class, how many unresolved calls a minted def would explain and
how many have a competitor in the same scope (a hedge, not a fact). It answers
the question that matters before an extraction change: **which language, which
form, worth how much.** On the measured corpora the answer was not the one the
motivating bug suggested — Lua's wrapper case is worth 0.18% of its unresolved
calls, while a JavaScript function literal assigned to a member target
(`jQuery.extend = function(){}`, the non-`prototype` form) was worth 6.4% on jquery
and 1.9% on ghost. That one shipped: see [Member-target definitions](#member-target-definitions-jsts).

`tools/corpora.lua` names the corpora and holds calibrated baselines as data;
`tools/bench.lua` is the bootstrap + measurement discipline (timed runs, peak
RSS via `/proc`, median-of-N); `tools/snapshot.lua` saves slim extracts
(`~/.cache/cartograph-tools/`) so a one-minute extract is paid once per
version and diffed for free. A slim snapshot is instrument-faithful by
construction: `graphdiff` and `census` cannot tell it from the original
(pinned in `tests/snapshot_spec.lua`).

## License

TBD
