# Refactoring runbook — cartograph.nvim, run-verified @ 6ad0701, re-checked @ 730a2c9

The command tables in `commands.md` are the *interactive face*. This file is the
operating procedure: preconditions, the headless API, the refusal ladder, and what
each verb deliberately leaves to you.

> ## ⚠ TWO DATES, AND EVERY CLAIM BELONGS TO ONE OF THEM
>
> The observations here were made by **running** every write verb end to end against
> scratch corpora at `6ad0701` (2026-07-30). They were **re-checked by reading and
> probing** at `730a2c9` (2026-09-20), 263 commits later. Nothing was re-run. Which
> treatment a claim got decides how much it is worth, so each one says:
>
> | marker | meaning |
> |---|---|
> | **[re-checked]** | confirmed at `730a2c9` — the API exists, the gate is still there, the probe reproduces |
> | **[as observed]** | a `6ad0701` run result, **not re-run**. Trust the shape, re-measure the number |
> | **[FIXED since]** | a defect recorded here that has since been closed. Kept, not deleted: a closed ✗ is the reason a guard exists |
>
> **Why this file is not in `SKILL.md`.** That file documents the **MCP verb surface**
> (`txn_plan_*` over JSON-RPC). This one documents the **headless Lua API**, and the two
> do not cover the same verbs. Measured at `730a2c9`: the MCP planners reach exactly
> three modules — `moveapply`, `optapply`, `cloneextract`. **`clonemerge`,
> `hoistclosure`, `reorder`, `extract`/`extractapply`, `untangle` and
> `certificate`/`neutrality` have no MCP verb at all** and are reachable only from here.
> If you are driving over MCP and the verb you want is not in `graph_info`, this is
> where it lives.
>
> (`characterize` has no MCP verb either and is deliberately not in this file: it does
> not refactor — it emits a spec — and it is lua-only, which `M.plan` now refuses by
> name. Its own header is the documentation.)

## The one thing to know first: every write verb is agent-drivable headless

Cartograph has a designed, documented non-interactive surface —
`[[cartograph-apply-for-agent]]` in the source notes. Every write verb is
`plan → preview → apply` **with no cockpit, no panes, no keystrokes**. From
`moveapply.lua`'s own header:

> Use headless (agent-drivable — plan → preview → verified apply, no cockpit).
> The `:CartographMove`/`Diff`/`Apply` commands are the interactive face of this
> same sequence.

So **do not** try to synthesize `dd`/`p` keystrokes to build a move-set. Call the
API. Every one of these is reachable from `:CartographEval`, `:CartographWorkspace`,
or a headless `nvim --headless -l`.

> **Run-verified [as observed @ 6ad0701].** Every write verb below was executed end to
> end against purpose-built scratch Lua corpora — plan, preview, apply, and a behavioral
> check that the rewritten code still loads and returns the same values. Everything
> marked ⚠ or ✗ was an observed result, not a reading of the source.
>
> **[re-checked @ 730a2c9]** All 24 API entry points named in this file still exist, and
> the four ⚠ warnings that describe behaviour the source headers do not state all still
> hold. The two ✗ defects are both closed. The table below has **not** been re-run.

| verb | applied? | result |
|---|---|---|
| `moveapply` (extract-module) | ✅ | correct diff + requalified call site; ⚠ destination needs the scaffold you write (below) |
| `clonemerge` | ✅ | copy deleted, call site rewritten, 0 hazards, valid code |
| `hoistclosure` | ✅ | lifted + dedented correctly; refusal names the captured variable |
| `reorder` | ✅ | legal move applied; illegal move refused naming the crossed dep |
| `optapply` (CSE) | ✅ | `local b = x*y+1` → `local b = a`, span-CAS + parse-clean |
| `cloneextract` (extract-helper) | ✅ | helper synthesized, both bodies became tail calls, 0 hazards |
| `extract` (pure engine) | ⚠ → ✅ | was **broken** when the selection reads an enclosing param/upvalue; **[FIXED since]** — it now refuses without `fn_params` and crosses the parameter when given it. See the box in "Extract function" |

Behavioral check after applying all five transaction verbs — every value matched the
hand-computed expectation:

```
twins (merged)      OK -> 20      order (reordered)  OK -> 11/22
hoist (hoisted)     OK -> 3,6,9   cse (rewritten)    OK -> 26
near taxA/taxB      OK -> 149 / 189
```

### Step 0 — get a `store` (headless)

Nothing else works without this, and no verb's header documents it. Follow
`tools/dogfood.lua`:

```lua
local repo = '/path/to/cartograph.nvim'
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')          -- the language(s) you will parse
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local ts    = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local data = ts.extract(root)                      -- root = the project dir
data.root = data.root or root                      -- ts.extract may leave it unset
store.ingest(data)
```

`store` is a **module-level singleton**, not a handle you construct — `require` it and
`ingest` populates it. After that `store.data.root`, `store.generation`,
`store.data.nodes` and `store.node(id)` are live. Run it with
`nvim --headless -u NONE -l script.lua`.

Node ids look like `geom.lua::M.norm2@12` (file::name@line) and **do not survive the
session** — find your seed by scanning `store.data.nodes` for the name, never by
hardcoding an id.

### Move / extract-module

⚠ **[re-checked]** **`plan_extract_ids` is not enough — you must also `store.stage(id)`.** `apply` has a
verb-specific rung that compares the plan's moves against the **live** move-set
(`store.staged_ids()`, what `dd` populates interactively). Build the set
programmatically and that list is empty, so apply refuses every time with:

```
the move-set changed since planning — re-run :CartographMove
```

The upstream header example omits this, so following it verbatim **fails**. Stage the
ids between closing the set and planning:

```lua
local set = mv.close_moveset(store, { seed_id }, 'util/mathx.lua')
for _, id in ipairs(set) do store.stage(id) end     -- ← REQUIRED before apply
```

Related staging API on `store`: `stage(id)`, `unstage(id)`, `toggle_stage(id)`,
`unstage_last()`, `is_staged(id)`, `staged_ids()` (ordered, stable by file then name),
`clear_stage()`. A successful apply consumes the set for you.

```lua
local mv  = require 'cartograph.moveapply'
local tx  = require 'cartograph.txn'
local set = mv.close_moveset(store, { seed_id }, 'sub/dest.lua')  -- seed → deps
for _, id in ipairs(set) do store.stage(id) end        -- ← or apply always refuses
local plan, err = mv.plan_extract_ids(store, set, 'sub/dest.lua')
if not plan then return err end            -- the refusal NAMES the reason

local before, after, why = mv.preview(store, plan)     -- writes nothing
if not before then return why end
print(table.concat(tx.difftext(before, after, plan.touched), '\n'))

local ok, why2 = mv.apply(store, plan)     -- journalled; graph-PRESERVING witness
                                           -- (nil, reason if the move-set moved)
```

`close_moveset` is the piece that makes this usable: give it a seed node and it
closes over dependencies, so you do not hand-enumerate the set.

⚠ **[as observed — shapes not re-probed]** **`preview()` does not return a diff, and its shape differs per verb.** The
`moveapply.lua` header comment shows `print(mv.preview(store, plan))`, which prints a
table address — it is loose. The real contracts:

| verb | `preview(store, plan)` returns |
|---|---|
| `moveapply` | `before, after [, why]` — content maps keyed by relpath; **`nil` first** on failure |
| `reorder` | `before, after [, why]` — same (both are bare `txn.dryrun`) |
| `clonemerge` | `before, after [, why]` — same |
| `hoistclosure` | `before, after [, why]` — same |
| `cloneextract` | `before, after [, why]` — same |
| `optapply` | `difftext_lines, before, after` — **lines FIRST**, and on failure a *truthy* one-element table `{ 'optapply: …' }`, never `nil` |

`apply()` return shapes differ too — three of them:

| verb | `apply(store, plan)` returns |
|---|---|
| `moveapply` / `clonemerge` / `hoistclosure` / `reorder` / `cloneextract` | `entry, why` — the journal entry (`entry.verb`, `entry.id`), or `nil, reason` |
| `optapply` | `ok_boolean, entry_or_reason, diff` — **boolean first** |
| `optapply.run_*` one-shots | a result **table**: `{ ok, applied, declined, reason, diff, moves }` |

Render the two-map form yourself with
`require('cartograph.txn').difftext(before, after, plan.touched)` → a table of lines
(this is exactly what `:CartographDiff` does). Because optapply's failure path is
truthy, **never** test it with `if not lines then` — inspect the content.

### Extract function (pure engine — you write the file)

```lua
local at, ex = require 'cartograph.at', require 'cartograph.extract'
local all = store.content(node)            -- WHOLE file lines (readfile of node.file)
local p = ex.plan {                        -- pure: no file access at all
    df = require('cartograph.df').get(node),
    sel = { first = 5, last = 6 },         -- 1-based FILE lines
    fn_start = at.sl(node.range) + 1,      -- at.sl is 0-based → the signature line
    fn_params = node.params or {},         -- ← MANDATORY (see the box below)
    body_end = at.el(node.range), file_lines = all, name = 'calc' }
if not p.ok then return p.reason end       -- e.g. cuts a control body
-- p.params / p.returns / p.new_fn / p.call / p.insert_before / p.replace
local out_lines = ex.apply(p, all)         -- splice; the DRIVER writes the file
```

`insert_before = fn_start`, so the helper is placed as a **sibling immediately before
the enclosing function**, at the signature line's indentation — not nested inside it.

Working case (selection reads a body-local): `params={"x"} returns={"z"}`, and the
generated helper and call site are both correct:

```lua
local function calc(x)      function M.f()
    local y = x + 1             local x = 10
    local z = y * 2             local z = calc(x)
    return z                    return z
end                         end
```

**[FIXED since — kept because it is why `fn_params` is mandatory]**

✗ **BUG (at `6ad0701`) — a selection that reads the enclosing function's PARAMETER or an
upvalue produced broken code.** `extract.plan` computed `params` only from statements
whose reaching def was inside the function body; its comment said upvalues and enclosing
params are *"captured by closure"* — but `insert_before = fn_start` places the helper as
a **sibling**, where nothing is captured. Observed, selecting the two lines of
`function M.f(seed)`:

```lua
-- params={} — `seed` was omitted entirely
local function calc()
    local y = seed + 1      -- nil global here
    local z = y * 2
    return z
end

function M.f(seed)
    local z = calc()
end
```

At runtime: `attempt to perform arithmetic on global 'seed' (a nil value)`.

**Closed 4 days later by `a965ac1` (2026-08-03), whose subject is about something else
entirely** — "The missing verb was hiding an unsafe one", the commit that built
`extractapply.lua`. It was never ticketed and the commit message never names this
defect, so this paragraph is the only record that it existed. The fix is two lines and
both are worth knowing:

- `extract.lua:76` — **`fn_params == nil` REFUSES**, and the refusal quotes the symptom
  observed above: *"without it a parameter the selection reads is silently dropped from
  the helper's interface and becomes a nil global. Refusing rather than emit that."*
- `extract.lua:146` — each `fn_params` name enters `encl`, so an enclosing parameter the
  selection reads now crosses into the helper's interface.

**[re-checked @ 730a2c9]** Probed on the fixture above: with `fn_params = {'seed'}` the
plan is `params={seed} returns={z}` and the emitted helper is `local function
calc(seed)`. ⚠ **`nil` and `{}` are different answers** — `nil` means *not supplied* and
refuses; a zero-parameter enclosing function must pass `{}` explicitly. Both real
callers (`untangle.lua:600`, `extractapply.lua:112`) supply it, so this bites only
hand-written headless drivers — like the recipe above, which is why that line is there.

### Reorder a statement

```lua
local ro   = require 'cartograph.reorder'
local res  = ro.analyze(store, fn_id)      -- per-pair verdicts + opaque hedges
local plan = ro.plan_move(store, fn_id, from_line, to_line, through_line)  -- or (nil, why)
ro.apply(store, plan)                      -- journaled, CAS + parse-clean gated
```

⚠ **[re-checked]** **Argument order differs from the command.** The API is
`plan_move(store, fn_id, from, to, through)`; the command is
`:CartographReorderApply {from} [through] {to}` — `through` sits in the *middle*
there and *last* here. Getting this backwards moves the wrong block, and the commute
verdict will happily certify a move you did not mean.

### Apply an optimize finding (CSE reuse)

```lua
local oa   = require 'cartograph.optapply'
local plan = oa.plan_cse(store, fn_id)     -- also plan_localize / plan_hoist / plan_pre
local lines = oa.preview(store, plan)      -- difftext LINES first (see the box above)
local ok   = oa.apply(store, plan)         -- span-CAS + parse-clean witness
oa.run_at(store, 'm.lua', 5)               -- one-shot plan+apply at a site
oa.report(store, fn_id)                    -- what's applyable, touching nothing
```

One-shot runners that plan+apply in a single call: `oa.run`, `oa.run_localize`,
`oa.run_hoist`, `oa.run_pre` (all `(store, fn_id, opts)`), and `oa.run_at(store,
file, line, opts)`. `oa.at(store, file, line)` and `oa.plan_at(...)` locate a site
without applying.

### Merge clones — no staging needed

The contrast with move: `clonemerge.plan(store, id)` takes the focused id **directly**,
so there is no move-set and no `store.stage()`. Verified end to end:

```lua
local cm = require 'cartograph.clonemerge'
for _, t in ipairs(cm.twins(store, id)) do print(t.name, t.file) end  -- returns full
                                    -- node records; print .name/.file/.id, not the table
local plan, why = cm.plan(store, id)
-- plan.survivor.name, #plan.removed, #plan.rewrites, #plan.hazards
local entry, awhy = cm.apply(store, plan)
```

Observed on an exact twin pair: `survivor=M.alpha removed=1 rewrites=1 hazards=0`, the
copy deleted and `M.beta(3, 4)` rewritten to `M.alpha(3, 4)`. Valid, behavior-preserving
code with nothing left to finish.

### Hoist a nested closure

```lua
local hc = require 'cartograph.hoistclosure'
local plan, why = hc.plan(store, closure_id)   -- the NESTED fn's node id
local entry = hc.apply(store, plan)
```

The nested closure is an ordinary node — find it by name in `store.data.nodes`
(e.g. `hoist.lua::scale@3`). Applied cleanly and **dedented** the body to module level.
The refusal path is exact, naming the variable:

```
REFUSED: captures enclosing local `factor` — parameterize it first (extract-helper)
```

### Extract a parameterized helper from a near-clone

```lua
local cl, ce = require 'cartograph.clones', require 'cartograph.cloneextract'
local prs  = cl.near_of(store, fn_id, {})      -- pairs involving this fn only
local plan, why = ce.plan(store, prs[1], {})   -- {} → same-file; cross-file needs a path
local entry = ce.apply(store, plan)
```

Applied with 0 hazards, synthesizing the helper and turning **both** bodies into tail
calls — `local function taxA_extracted(amount, hp1)` with `return taxA_extracted(amount, 7)`
and `(amount, 9)`. Both values verified correct afterwards.

⚠ **[re-checked: `min_rows` still defaults to 3]** **`clones.near` has undocumented floors that silently hide short functions.**
`:CartographNearClones [count]` exposes only max edit distance, but the engine also
applies `min_rows = 6` and `min_shared = 2` (opts keys: `max_dist`, `min_rows`,
`min_shared`). A 4-statement near-clone pair returns **0 pairs** with no explanation —
`near-clones: none`. Lower `min_rows` explicitly if you are looking at small functions:

```lua
cl.near_of(store, fn_id, { min_rows = 3, max_dist = 2 })
```

Useful read-side helpers: `cl.analyze_pair(pair).kind` (`'value'` = parameterizable) and
`cl.extract_proposal(pair, store)` — a review scaffold naming each hole, its two
fillings and their exact source positions, plus a body-safety verdict.

### Untangle → extract a concern

```lua
local un  = require 'cartograph.untangle'
local res = un.analyze_flow(flow)          -- concerns + interleave metrics
if un.concern_safe(res, c) then            -- else un.why_unsafe(res)
    local plan = un.extract_plan(store, fn_id, res, c, 'name')  -- an extract.plan
end                                        -- (plan.ok → feed to extract.apply)
-- module scope: un.analyze_module(store, file) → un.module_safe(res, c)
--               → un.extract_module(store, res, c, 'sub/dest.lua')
```

Note `untangle.analyze` is explicitly **comprehension, not a safety claim** — it
partitions over *data* deps only. `concern_safe`/`module_safe` is the gate you must
consult before extracting; control, anti/output and side-effect ordering are not yet
in the model.

**The real workflow is `untangle → gather → extract`**, and both intermediate refusals
were observed:

1. *Concerns converge on a shared `return`* → they are **one** concern, and extraction
   refuses on control escape: `the selection contains return/break/goto`. The report
   still helps — it names `cohesive sub-groups: 3 group(s) inside the 1 concern(s) —
   suggested seams, NOT free to split` and how many dependency edges cutting them
   would break.
2. *Concerns are interleaved* (`A B A B A B`, `tangle 4`) → `concern_safe` returns
   **true** and both are `CERTIFIED safe to split`, yet `extract_plan` refuses:
   `concern is scattered (interleaved with other concerns) — gather/reorder first`.
   So certified-safe ≠ extractable-now; use `ReorderApply` to gather the concern's
   statements contiguously first.

Once gathered (`A A A B B B`, `tangle 0`), the report lists
`A: extractable — 0 param(s), 0 return(s)` and `extract_plan.ok = true`. **Read the ✗ box
under "Extract function" before trusting that plan** — a `0 param(s)` concern that reads
the enclosing function's parameters is exactly the broken case.

## One transaction at a time — a COMMAND-layer rule, not an API one

Interactively, every staging verb starts with the same check and refuses:

```
cartograph: a transaction is already staged — :CartographApply or :CartographTxnClear first
```

So the interactive loop is strictly **stage → `:CartographDiff` → `:CartographApply`
*or* `:CartographTxnClear`** before the next verb. There is no queue. Staged changes
also **freeze refresh** (a transaction pins the graph it was planned against), so a save
mid-transaction will not update the graph under you.

⚠ **[re-checked]** **Headless, this rule does not apply.** `store.set_txn` is called *only* from
`commands/refactor.lua`; the engine `apply` functions never touch `store.txn`. Verified:
two `optapply.apply` calls back-to-back in one process both returned `true` with
`store.txn == nil` throughout, nothing cleared between them. So a scripted refactor can
chain verbs freely — but you lose the plan-bar review step, which is exactly why you
should print `preview` between each.

One caveat when chaining in-process: each apply re-splices the graph, so **re-find node
ids after every apply** rather than reusing ones captured earlier.

On success `:CartographMove` consumes the move-set (cleared before the splice, since
a staged set would freeze it).

## The refusal ladder at apply time

`plan` is computed now; `apply` is **late-bound** and re-checks everything:

| gate | refuses when |
|---|---|
| generation | the graph generation changed since plan time |
| refs | a ref no longer resolves witness-clean |
| witness | the behavior witness drifted (the body changed) |
| stamp CAS | a touched file is not byte-identical to plan time |
| buffers | a touched file has unsaved changes |
| verb-specific | move: the live move-set is no longer exactly the plan's moves |

**A refusal costs a re-plan, never a corrupted write.** Read the reason, re-plan,
retry — do not force anything.

Two extra witnesses on top of the ladder, per verb class:

- **graph-PRESERVING** (move): the relocation must not change the graph.
- **graph-CHANGING** (optapply): the recompute — and any call inside it — *is*
  removed. This is **reported, not rejected**; it is the whole point, and why move's
  preserving witness would not do.
- **span-CAS**: the exact text at each edit range still equals what the plan captured.
- **parse-clean**: the edited file re-parses with no ERROR node.
- **synthesis gates** (extract-helper): the result must parse *and* must contain the
  helper plus both rewritten call sites.

## Hazards are your half, by design

From `moveapply.lua`, verbatim on why:

> What this verb deliberately does NOT write: call-site requalification and import
> wiring. Both are language-specific guesses (which alias names the dest module
> here? what does an import line look like?), and **a transaction that guesses is a
> transaction that lies**.

So a plan reports `N hazard(s)` and you finish them. What shows up as a hazard:

- call sites naming the old home that could not be requalified
- `<file> should import <dest>` / `<dest> should import <file>`
- bare-name calls, shadowed aliases, and the moved body's own references
- a `require` path guessed root-relative (extract-helper cross-file)
- **go**: `<dest> will need its package clause — cartograph wrote none`

A Lua move *does* write the text, the new require line, and requalified call sites —
the hazards are the residue it could prove necessary but not spell.

**[FIXED since — CART-0542, and kept because the RULE it establishes did not change]**

✗ **An extract-module destination could be written in a state that does not even load.**
Observed at `6ad0701`, moving `M.norm2` out of a `local M = {}` / `return M` module:

```lua
-- util/mathx.lua, exactly as written:
function M.norm2(x, y)
    return square(x) + square(y)
end
```

No `local M = {}`, no `return M`, no `square`. Loading it fails outright:
`util/mathx.lua:1: attempt to index global 'M' (a nil value)`. The three hazards named
precisely that:

```
capture: M (file-local in geom.lua, shared with staying code) is referenced
         — require it, or copy it into the extracted module
capture: square (file-local in geom.lua, shared with staying code) is referenced
         — require it, or copy it into the extracted module
util/mathx.lua should import geom.lua
```

Meanwhile the *other* two files were rewritten correctly and completely — `geom.lua`
lost the function, `app.lua` gained `local mathx = require 'util.mathx'` and had
`geom.norm2(x, y)` requalified to `mathx.norm2(x, y)`.

So the rule is stronger than "a half-done refactor": **ignoring hazards yields broken
code, not merely incomplete code.** Read them before apply, and prefer moving symbols
whose captures you have already checked.

**[FIXED since]** The module SCAFFOLD specifically is now written when the destination
file is created (CART-0542, `done`) — it was the one hazard that was mechanical rather
than a guess, and `moveapply`'s header now lists it beside call-site requalification and
the import line as things a spec hook opts into. ⚠ **The `capture:` hazards are NOT
fixed and will not be**: which module a shared file-local should come from is exactly
the guess the verb refuses to make. The paragraph above still describes them.

## Per-verb preconditions and refusals

Check these before planning; each refuses with a reason naming the offender.

**`:CartographMove` / `plan_extract_ids`**
- a `var` moves only when **module-level** — a function-local var is lexically
  scoped and lifting it is meaningless (and unsound)
- extract-module destination: a plain path inside the root (no `/`-absolute, no
  `..`), must **not already exist** ("that is a MOVE"), and must have a language
  spec — "the graph could never see the new file" otherwise
- a symbol already living in the destination refuses

**`:CartographMerge`** — merges witness **twins** (same kind, equal behavior witness
= df shape + params + callee set, elsewhere in the graph) by deleting copies and
rewriting their call sites to the survivor. Import wiring stays a hazard.

**`:CartographHoistClosure`** — lifts a nested `local function` to module scope.
Sound **exactly when it captures nothing**: every free read must resolve to a
module-level name or a global. Refuses and **names the captured variable** (a capture
means "parameterize it first" — that's extract-helper's job). Also refuses on `...`,
a name collision with an existing module-level def, or a closure not occupying whole
source lines. Self-recursion by its own name is fine.

**`:CartographExtractHelper` / `…Apply`** — needs, each verified before a plan:
- **value-parameterizable** divergences (every hole a leaf value with a range)
- **body-extractable** for *both* copies: top-level, no vararg, no self-recursion
- equal param count, single-line holes, clean multi-line body, a free helper name
- the rewrite is a **tail call** (`return helper(…)`), preserving every return
- cross-file additionally: every free read must be a **global**, not a source-file
  local; and on a Factorio project, no free read may be a phase-bound global
  (`data`/`game`/`script`/…) unless every destination phase is that global's own

**`:CartographReorderApply`** — ⚠ **the arguments are absolute FILE LINE numbers, not
the `#N` statement indices the report displays.** `reorder.report` prints rows as
`#1  L4`, `#2  L5`, `#3  L6`; you pass the **`L` values**. Verified: `plan_move(store,
fn, 5, 4, nil)` moved the L5 statement before L4, and the illegal direction refused with
`the move would cross #3, which has a dataflow dep (local p) with a block statement`.
Only what the commute verdict certifies. Verdicts are
per statement *pair*: `dep` (local dataflow), `state` (same module var/field), `world`
(both write io). Statements with unresolvable effects are **OPAQUE** — listed with
the hedge, **certified for nothing**. `free` means free *w.r.t. what is modeled*;
reads through calls are not modeled and the report says so.

**`:CartographExtract`** (source pane / `extract.plan`) — whole top-level statements
only (the granularity `df` resolves). Refuses a selection that **cuts a
control-structure body** or contains a **control escape** (`return`/`break`/`goto`).
It cannot see table/global state, so that risk is a disclosed hazard, not an
assumption.

## Certifying the result

```vim
:CartographNeutralitySnapshot   " before
"  … refactor …
:CartographNeutralityCheck      " after
```

Headless equivalent — `nu.snapshot(store)` returns the witness count,
`nu.check(store)` returns `(compare, nil)` or `(nil, why)`, and `nu.report(cmp)`
renders it:

```lua
local nu = require 'cartograph.neutrality'
nu.snapshot(store)                          -- baseline, BEFORE the refactor
--  … refactor …
local cmp, why = nu.check(store)
print(table.concat(nu.report(assert(cmp, why)), '\n'))
```

⚠ **[re-checked: `neutrality.lua:114`]** **The baseline is in-memory and session-scoped.** `M._snap` is a plain table keyed
by `store.data.root`, so it does not survive an nvim restart and there is no
cross-commit persistence (the source calls that a banked follow-on). Check without a
snapshot returns *"no baseline — run :CartographNeutralitySnapshot before the
refactor"*. Snapshot and check must happen in **one session**; the txn re-splices the
live graph, so the loop needs no disk.

⚠ **[as observed]** **A neutrality pass is not evidence the refactor happened.** Observed: after an apply
that **REFUSED**, `check` still reported

```
refactor-neutrality — 5 neutral · 0 DRIFTED · 0 renamed · 0 removed · 0 added
✓ every surviving function is behavior-neutral (certified move)
```

…because nothing changed, so nothing drifted. The check answers "did any body change?",
not "did my edit land". Always assert on `apply`'s own return value; treat neutrality
strictly as a *drift* detector layered on top of it.

It diffs each function's behavior witness (df shape + param count + callee names —
independent of file and line). Unchanged ⇒ **certified neutral**, a pure relocation.
Drifted ⇒ the body changed.

**Scope, honestly:** it certifies **moves, not rewrites**. An extract-helper or
accessor migration legitimately changes a body (A becomes a tail-call wrapper) so it
*correctly* drifts — that is not a failure. A drift on something you intended as a
pure move **is** a real red flag. Gone/appeared functions are reported, and a
gone↔appeared pair sharing a witness is recovered as a **rename** (also
body-neutral). The witness is keyed by name; a name shared by several functions
compares as a witness **multiset**.

## Language support on the WRITE side

Analysis coverage (`languages.md`) does not carry over. The write verbs synthesize
*syntax*, so they gate separately and much harder:

| verb | languages |
|---|---|
| `:CartographMove` | any language with a spec (text relocation); requalification + imports are proven only where the spec has import wiring — **Lua** is the developed case |
| `:CartographExtractModule` | any language with a spec for the destination path; **go** gets a package-clause hazard |
| `:CartographMerge` | language-agnostic deletion + call-site rewrite; import wiring always a hazard |
| `:CartographHoistClosure` | **Lua only** — hard-gated: `only Lua is supported for now` (`hoistclosure.lua:52`, and the module now DECLARES `@langs lua`) |
| `:CartographExtractHelperApply` | **Lua** (same-file *and* cross-file) · **JavaScript** (`js`/`jsx`/`cjs`/`mjs`) **same-file only** — the JS entry sets `module = nil`, so cross-file refuses: *"cross-file extraction is not supported for javascript yet (no module wiring)"*. No other language has a synthesis table |
| `:CartographReorderApply` | the `body_field` languages (rides flow verdicts) |
| `:CartographOptimizeApply` | the `body_field` languages (`optapply.lua` builds its own `EXT` from `body_field`) — but see the ⚠ below |
| `:CartographExtract` | needs `df` for the function — the `body_field` languages |

**[re-checked @ 730a2c9]** `body_field` is now **15**, not 14: `bash c cpp erlang go java
javascript lua php python ruby rust tsx typescript zig`. Three of the 18 specs have none
(`haskell odin scheme`). The JS cross-file refusal string is unchanged.

The analysis half of extract-helper is language-agnostic; **only the synthesis syntax
is per-language** (the `EXTRACT` table in `cloneextract.lua`). That table still has
exactly two entries.

⚠ **"REACHED" AND "SERVED" ARE DIFFERENT, AND THE ROW ABOVE IS THE FIRST.**
`:CartographOptimizeApply` admits all the `body_field` languages and **serves lua**: its
rewrites are lua syntax, its ASSIGN table and no-throw `builtins` set are lua's. On
another language it does not error — it declines every candidate, and the declines are
phrased as facts about your code. `optapply.lua` now declares `@langs lua` and says so;
closing the admission itself is CART-0315.

**[new since @ 730a2c9] The scope is machine-readable now.** `tools/langaudit.lua` fences
every module's `@langs` line on each commit, and on the **agent** surface this table's
content is a field: `graph_info` reports a `langs` column per verb, and a subject in
another language refuses with rule `lang-scope` (`txn_plan_optimize` = lua,
`txn_plan_extract_family` = lua javascript, null elsewhere = serves any). The commands in
this table have **no such gate** — they do not go through the agent dispatcher — so for
the interactive surface this table is still the only answer.

## A worked sequence

Moving a function to a new module, headless, verifying it changed no behavior. **This
exact shape was executed successfully** against a scratch corpus — it is the tested
path, staging included:

```lua
-- 0. bootstrap (see Step 0) → `store` is populated

-- 1. snapshot the witnesses BEFORE (same session as step 5 — in-memory baseline)
local nu = require 'cartograph.neutrality'
nu.snapshot(store)

-- find the seed by NAME; ids are session-scoped
local seed
for _, n in ipairs(store.data.nodes) do
    if n.name == 'M.norm2' then seed = n.id end
end

-- 2. close the move-set over deps, STAGE it, then plan
local mv  = require 'cartograph.moveapply'
local set = mv.close_moveset(store, { seed }, 'util/mathx.lua')
for _, id in ipairs(set) do store.stage(id) end   -- ← apply() checks staged_ids()
local plan, err = mv.plan_extract_ids(store, set, 'util/mathx.lua')
assert(plan, err)                             -- refusal names the reason

-- 3. READ the preview before writing anything
local before, after, pwhy = mv.preview(store, plan)
assert(before, pwhy)
print(table.concat(require('cartograph.txn').difftext(before, after, plan.touched), '\n'))
print(#plan.hazards .. ' hazard(s):')
for _, h in ipairs(plan.hazards) do print('  ' .. h) end

-- 4. apply (journalled, late-bound verify) — returns the JOURNAL ENTRY
local entry, why = mv.apply(store, plan)
assert(entry, why)                            -- drift ⇒ re-plan, never force
print('applied ' .. entry.verb .. ' ' .. entry.id)

-- 5. certify: witnesses unchanged ⇒ a pure move
--    (only meaningful because step 4 was asserted — see the warning above)
local cmp, cwhy = nu.check(store)
print(table.concat(nu.report(assert(cmp, cwhy)), '\n'))
--    drifted ~= {} on an intended pure move is a red flag

-- 6. LOAD the destination — hazards are not cosmetic
--    then fix each `capture:` hazard before calling the refactor done
-- 7. bail out if needed:
--    require('cartograph.journal').rollback(store.data.root)   -- byte-exact
```

If step 4 refuses, re-run from step 2 — the plan was stale, which is the system
working. `:CartographUndo` rolls the applied transaction back byte-exact, refusing if
files moved on since.

## Rolling back: the journal API

`apply` returns the journal **entry** (`entry.verb`, `entry.id` — e.g.
`1785445042-extract-module`), and rollback is keyed by **root**, not by store or entry:

```lua
local jr = require 'cartograph.journal'
local entry, why = jr.rollback(store.data.root)   -- the newest applied txn
local entry, why = jr.redo(store.data.root)       -- re-apply the newest undone one
jr.list(store.data.root)                          -- browse applied/undone
jr.last(store.data.root)
```

There is **no** `journal.undo` — it is `rollback`, and it takes the root. Verified
byte-exact on the scratch run: both edited files restored `true` on a byte comparison,
and the created `util/mathx.lua` was **removed** (a create's undo is deletion).
Rollback only reverses the newest entry, and refuses if files moved on since.

- **Don't synthesize keystrokes** to build a move-set — use `close_moveset`.
- **Don't stage two verbs** without applying or clearing between them.
- **Don't force past a refusal** — re-plan. The refusal is the safety property.
- **Don't treat hazards as noise** — they are the part the tool proved necessary and
  refused to guess. An unfinished hazard list is a half-done refactor.
- **Don't read a neutrality drift as a bug** after an extract-helper; it is expected.
- **Don't assume analysis coverage means write coverage** — `HoistClosure` is Lua
  only, and cross-file extract-helper is Lua only, regardless of how well the
  language scores in the capability matrix.
- **Don't trust `free` in reorder as unconditional** — it is free w.r.t. the modeled
  effects; opaque statements are certified for nothing.
- **Don't forget `store.stage()`** before a programmatic move apply — the single most
  likely reason a scripted refactor refuses.
- **Don't take a green neutrality report as proof the edit landed** — assert on
  `apply`'s return first.
- **Don't assume the destination module is valid** after extract-module — load it, or
  read the `capture:` hazards and write the scaffold yourself.
- **Don't write `extract.plan`'s output without checking `p.params`** against the
  selection's free reads — an enclosing parameter is silently omitted.
- **Don't read `0 pairs` from `clones.near` as "no near-clones"** — `min_rows = 6` hides
  short functions with no message.
- **Don't pass `#N` indices to `reorder.plan_move`** — it takes file line numbers.
- **Don't reuse node ids across an apply** when chaining headless — re-find them; the
  graph re-splices.
