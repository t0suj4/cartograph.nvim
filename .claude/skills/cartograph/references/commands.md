# Command and key reference — cartograph.nvim @ 852916f

79 commands: 77 global + 2 pane-local. All global ones exist at startup (nothing
loads until one runs); those needing an open graph say so. Groups follow
`doc/cartograph.txt`. `[x]` = optional arg, `{x}` = required, `!` = bang variant.

Regenerate the authoritative list:

```bash
nvim --headless -u NONE -c "set rtp+=$PWD" -c "lua
local api=vim.api; local set={}
local og=api.nvim_create_user_command
api.nvim_create_user_command=function(n,f,o) set[n]=true; return og(n,f,o) end
vim.cmd('runtime! plugin/cartograph.lua')
pcall(function() require('cartograph.commands').register() end)
local k={} for n in pairs(set) do k[#k+1]=n end table.sort(k)
print('COUNT '..#k); print(table.concat(k,'\n'))" -c 'qa!'
```

## Opening and sessions

| command | what |
|---|---|
| `:Cartograph [target]` | open the cockpit. Target: a directory, `dump.json`, `mcp://name`, `self://loaded`. **Adds a band** rather than replacing — several projects stay resident |
| `:CartographIndexOnly [dir]` | thin symbol index for LSP + navigation, no analysis. Artifacts fill in **on demand per file**; call-graph verbs refuse only while coverage is PARTIAL. The graph remembers it began thin, so it is never served from cache as a full open |
| `:CartographRefresh[!]` | re-extract the current file (`!` = whole project) |
| `:CartographBands` | list open bands |
| `:CartographSwitch {band}` | switch the active band |
| `:CartographSelf` | declared vs live registrations (the `self://` oracle) |
| `:CartographLspAttach` / `:CartographLspDetach` | the in-process LSP read surface |

Navigation is one continuous trail **across** bands: `<C-o>` walks the current
project's history and then crosses back into the project you came from.

## Navigating and overlays

| command | what |
|---|---|
| `:CartographCone [depth]` | reachability cone on the cursor node (in = ancestors, out = descendants) |
| `:CartographTerritory` | partition the graph by which entry points reach each node |
| `:CartographSpines` | the tree structures hiding in the graph (call-dominator + subsystem) |
| `:CartographHeat` | **pane-local (symbols)** — toggle the hub/heat overlay: fan-in/out and role |
| `:CartographMark` | toggle the cursor row's *subject* in the working set |
| `:CartographWorkingSet` | open the working-set view |
| `:CartographWorkspace` | ad-hoc Lua against the loaded graph; a returned node list is browsable |
| `:CartographEval {lua}` | evaluate Lua against the graph (`store`/`spines`/`territory`/… in scope) |

## Honesty and resolution

| command | what |
|---|---|
| `:CartographCensus` | epistemic census — edge trust tiers and refusals by rule (the analyzer work-list) |
| `:CartographLadder` | the call graph's epistemic distribution (proven / linked / `~` / dynamic / refused / frontier) + the heaviest refusals |
| `:CartographMentions [name]` | which files **mention** a name (cursor word by default). Reads the mention index, not the call graph, so it answers where resolution **refused**. **Refuses on a thin index** rather than reporting zero. Per *file*, never per line. Scope-confined to the asking file's resolution scope. With a call graph present the resolved subset is marked a SUBSET (`=` resolved, `~` mention only) |
| `:CartographVersionFloor` | which language version this code needs, as an attributed **set** + the downgrade ladder. See `languages.md` §5 — 5 languages only |
| `:CartographRequires` | the code's own profile: external names + version floor as one requirement set, then the tightest environment and the dependency manifest. Coverage, never a verdict |
| `:CartographPortability[!] {runtime} [{to-runtime}]` | score the external surface against a target profile (tab-completes). Two runtimes = the **move diff**. `!` adds the read surface |
| `:CartographExternals` | the external boundary — unresolved names and the shape each use implies (`~`) |
| `:CartographRoster [{ecosystem}] [{dir}]` | the package roster of an **installed** ecosystem. Reads a directory, needs no extraction |
| `:CartographEscalate[!]` | escalate hedge-saturated fns to lua-ls (async): confirmed / CONFLICT / refuted / recovered. `!` = whole graph |
| `:CartographFieldHarvest` | disagreement harvest: our `self.field` read→write links vs lua-ls go-to-definition. A CONFLICT is a real bug on **one** side |
| `:CartographAudit` | diff the live indexes against a fresh derive (catches in-place writer drift) |
| `:CartographDogfood` | the self-analysis dashboard, LSP read surface attached |
| `:CartographDiscover[!] [verb]` | explain registry auto-discovery (`!` = deep tier) |
| `:CartographShapes` | explain project-shape detection for this root |
| `:CartographFeedback[!] [text]` | file feedback **about cartograph**, frozen at the current node. You type only what you EXPECTED; the observed half is captured automatically (rendered rows verbatim, the gesture and the rows it hit, frozen source, call provenance, parsers/profile/packs/index-only/cache version/commit). No arg = a compose buffer with git-commit semantics (`#` stripped, `:w` files, `:q` abandons). Entries **freeze** and never re-anchor. Works with no graph loaded and on a row with no node. `!` dumps every entry for this root as pasteable markdown |

## Analysing the focused function

Most of these need a **function or method focused** (they warn "focus a function
first" otherwise).

| command | what |
|---|---|
| `:CartographFields` | **lua only** — resolve this method's `self.field` reads to the write(s) on its class (own methods + `extends` ancestors). A writeless read stays unresolved |
| `:CartographPrototypes[!]` | **lua + data-stage profile** — every declared prototype as base reference + ordered field overrides + registration. Honest lower bound: `~` hedged on an opaque call, `∅` for an explicit-nil DELETE, `?` unread. `!` opens the records in the browser instead |
| `:CartographTrace [n]` | where parameter `[n]` (default 1) gets its values, one row per resolved call site. `▸` has a next hop, `~` is a frontier that says why it stops, `·` is an answer |
| `:CartographBranchValues` | the values live through each CFG branch (`~` = hedged reaching) |
| `:CartographNarrow` | **lua only** — where a guard proves a variable non-nil in a region |
| `:CartographParamNil` | **lua only** — inferred parameter nilability (required / optional / unknown) vs `---@param`. An unguarded deref of a nilable `?` param is a real defect |
| `:CartographDevirt` | **lua only** — dispatches whose receiver a guard narrows to a concrete type |
| `:CartographExpr` | expression lints: self-compare, duplicated operand, bool-comparison, self-assignment, pseudo-ternary, constant condition, concat-in-loop, duplicated condition |
| `:CartographReorder` | statement commutativity: deps, conflicts, freely-movable rows. `<CR>` reveals the statement |
| `:CartographOptimize` | loop-invariant computations (LICM). `*` = clean, `~` = aliasing- or branch-hedged |
| `:CartographUntangle` | independent concerns over the data+control+effect PDG, with the safe-to-split verdict and its why-not |
| `:CartographUntangleModule [dir]` | independent function clusters in this file — or a directory, for god-package scope — over call + shared-written-state edges |
| `:CartographExtractBlocks` | this function's control sub-regions as helper candidates, each with its `(params)->(returns)` interface and control-escape verdict |

## Lint

| command | what |
|---|---|
| `:CartographLint` | graph-aware lint → quickfix |
| `:CartographLintFix` | apply the current quickfix entry's annotation |
| `:CartographLintSigns` / `:CartographLintClear` | publish / clear in-buffer lint signs |

Rules are whole-program and cross-file — not a luacheck replacement, a complement.
Registered rules at this commit: `resource-leak`, `member-leak`, `null-deref`,
`silent-drop`, `seam-guard`, `truncation`, `require-cycle`, `sql`, `sink-concat`,
`sink-source`, `sink-reach`, `dead-state`, `db-audit`, `route-audit`,
`ansible-audit`, `ansible-vars`, `layering`, `clone`, `access-point`,
`registry-audit`, `pair-audit`, `schema-mirror`, `greenspun`, `dynamic-dispatch`,
`load-order`, `listener-audit`, `swallowed-type`, `dead-function`,
`redundant-require`, `call-cycle`.

Language-locked ones are in `languages.md` §5. These are **structural smells, not
proofs** — a dynamically-invoked function can still read as "no caller".

Suppression: `@cg-ignore: <rule>` appended to the reported line (or on a comment
line directly above). **Appended, not inserted** — inserting shifts every range
below and would invalidate the map the finding came from. A bare `@cg-ignore`
silences all rules on that line. Unknown comment syntax **refuses** rather than
guessing. The write is journaled, so `:CartographUndo` reverses it.

## Clones

| command | what |
|---|---|
| `:CartographClones [count]` | exact-structural clone groups (alpha-invariant on locals). `[count]` = min statements, default 3 |
| `:CartographBlockClones [count]` | contiguous statement runs duplicated across **or within** functions — the tier a whole-function census is blind to. Default 6 |
| `:CartographNearClones [count]` | functions differing by only a few edits: matched rows are the shared template, differing rows are the holes. `[count]` = max edit distance, default 2 |
| `:CartographClonesSigns` / `:CartographClonesSignsClear` | publish / clear clone signs — each hole sign sits at its exact substitution column, so `]d` jumps to it |

## Refactoring — each STAGES a transaction and writes nothing

Review with `:CartographDiff`, commit with `:CartographApply`.

| command | what |
|---|---|
| `:CartographMerge` | merge the focused function's clones |
| `:CartographMove` | the cut/paste move-set (`dd` cuts a row, `p` on a file row sets the destination) |
| `:CartographExtractModule {path}` | extract the move-set into a NEW file |
| `:'<,'>CartographExtract {name}` | **pane-local (source)** — extract the selected lines into a function |
| `:CartographExtractHelper` | propose the parameterized helper this function and its nearest near-clone could factor into — anti-unified template + body-safety verdict. A scaffold to read; **nothing is staged** |
| `:CartographExtractHelperApply [path]` | stage that helper for real. Same-file pair needs no argument; a cross-file pair takes a destination module path. Held to the sound subset; refuses outside it |
| `:CartographHoistClosure` | lift the focused **nested** closure to module scope — sound only when it captures nothing. Refuses a capture, naming the variable |
| `:CartographReorderApply {from} [through] {to}` | move statement `{from}` (or block `{from}..{through}`) before `{to}`, if the commute verdict certifies it |
| `:CartographOptimizeApply` | dry-run the CSE-reuse rewrite: the exact diff, journaled and CAS/span/parse-verified |
| `:CartographNeutralitySnapshot` | capture per-function behavior witnesses (df shape + params + callees) as a baseline |
| `:CartographNeutralityCheck` | diff witnesses against that baseline — neutral = a pure move, DRIFTED = the body changed |

## Transactions

| command | what |
|---|---|
| `:CartographDiff` | the unified diff the staged txn would write |
| `:CartographApply` | verify late-bound, journal, write, splice |
| `:CartographTxnClear` | abandon the staged transaction (writes nothing) |
| `:CartographUndo` | roll back the last applied txn, byte-exact |
| `:CartographRedo` | re-apply the most recently undone txn |
| `:CartographJournal` | browse applied/undone txns; `<CR>` = entry diff |

**The substrate.** `plan` is computed against the current graph and holds refs
(rename-tolerant identities), file stamps and the graph generation — nothing is
written. `verify` is late-bound at apply time: the generation must match, every ref
must resolve witness-clean, every touched file must be byte-identical to plan time
(stamp CAS), no dirty buffers. Any drift **refuses with its reason** — a refusal
costs a re-plan, never a corrupted write. `journal` records before-content first (a
create records absence): pending → writes → applied, so a crash mid-apply leaves
evidence and a manual rollback, never mystery. Touched files then splice back
through the same refresh machinery every save uses.

A verb writes only what it can prove complete. A Lua move writes the text, the new
require line and requalified call sites — but bare-name calls, shadowed aliases and
the moved body's own references stay **hazards**, disclosed with counts.

Staged changes **freeze** refresh (a transaction pins the graph it was planned
against).

## Outward: running systems, other toolchains

| command | what |
|---|---|
| `:CartographLive` | diff the RUNNING system (MCP) vs the graph |
| `:CartographStates` | browse the configured/detected state machine — states as rows with their reachability-cone size, descending into transitions and active entry points |
| `:CartographCompileCommands[!] [dir]` | generate `compile_commands.json` (cmake or meson configure; `!` allows a full bear build) |
| `:CartographProject[!]` | project the current view into Factorio (`!` = live, reproject on navigation) |
| `:CartographProjectStatus` | the projection's honesty state (synced / stale / drift) |
| `:CartographProjectStop` | stop the live projection |
| `:CartographBrush [file]` | paint the current buffer (or a file) into Factorio as biter corpses |
| `:CartographCanvas` / `:CartographCanvasStop` | serve / stop a browser canvas that paints into Factorio |

## Keys

Every binding is remappable; the FIELD name is what `setup{ keys = … }` takes, and
`false` unbinds one entirely. All 25 fields are published in `|cartograph-keys|`,
checked against `config.lua` by `tools/docaudit.lua`.

```lua
require('cartograph').setup {
  keys = { descend = '<Right>', close = false },
}
```

**Navigation:** `pivot` `<CR>` · `jump` `<C-]>` · `back` `<C-o>` · `back_alt` `<C-t>`
· `forward` `<C-i>` · `open_file` `gf` · `ascend` `h` · `descend` `l` · `down` `j` ·
`up` `k` · `cycle` `<Tab>` · `cycle_back` `<S-Tab>` · `close` `q`

`j`/`k` step *out* to the parent at a block's last/first row.

**Staging (symbols pane):** `cut` `dd` · `cut_visual` `d` · `paste` `p` ·
`unstage` `u`

**Node marks (symbols pane):** `set_mark` `m` · `goto_mark` `` ` `` — keyed by
**node**, not line, but otherwise exactly vim's meaning, which is why they keep the
key.

**Unbound by default** — graph operations with no vim idiom behind them ship as
commands and do not squat on vim keys: `mark`, `set_view`, `set_next`, `set_prev`,
`cone_in`, `cone_out`.

```lua
require('cartograph').setup { keys = { mark = ',m', set_view = ',M',
  set_next = ']w', set_prev = '[w', cone_in = ',c', cone_out = ',C' } }
```

## Lenses per altitude

`cycle` (`<Tab>`) moves between an altitude's lenses; the winbar names them
(`⇥ statements [detail] lints`, bracketed = in effect) so finding out costs no
keypress. A single-view altitude says `— one view here` rather than drawing nothing,
because blank chrome cannot be told from chrome that failed. The strip prints the
key **as you have it bound**. Checked against `panes/symbols.lua` by
`tests/lensbar_spec.lua`.

| altitude | lenses |
|---|---|
| fn | statements · detail · lints |
| block | statements · detail |
| region | statements · detail |
| files | flat · tree |
| file | members · live |

- **statements** — the code's statements in order (each altitude's normal view)
- **detail** — descendable fine-grained elements: arguments, conditions, var and
  field reads. Rows elide at the tail; the full text is one hover away
- **lints** — `:CartographExpr`'s findings as rows; `l` on a finding descends into
  its actions
- **flat** — the file roster, alphabetical, shortest unique path suffix
- **tree** — the same files as an include tree (or a declared load order)
- **members** — what the file's module exposes
- **live** — what the RUNNING instance says it exposes; `self://` only, since
  nothing on disk can answer it

Cycling **follows your position**: the thing under the cursor is carried to its row
in the new lens. With no row there (an argument vanishing in `statements`) it
becomes a **ghost** anchored to its enclosing statement, and cycling back restores
it exactly.

## Configuration

`setup()` is optional — every field has a default. ~30 fields total, each
documented where it lives in `lua/cartograph/config.lua`. The ones worth knowing:

```lua
require('cartograph').setup {
  cache   = false,
  exclude = { 'warpc' },
  mcp     = { game = { cmd = { 'my-mcp-server' } } },
}
```

| option | sets |
|---|---|
| `keys` | remap any binding |
| `symbols_width` | the symbols pane's **text** budget in columns (default 30; the gutter is outside it). Every row's identity is rendered to fit |
| `entrypoints` | path patterns for files expected to have no importer → classify `entry` (`▶`) not `orphan` (`○`) |
| `exclude` | extra vendored directory **names** to skip |
| `cache` | per-file shard cache; warm opens |
| `parallel` | worker processes for cold opens |
| `refresh` | re-extract on save and splice into the graph |
| `shapes` | project-shape presets (`false` disables) |
| `discover` | registry auto-discovery (Greenspun detection) |
| `unparsed` | keep minified bundles as opaque frontier modules |
| `pins` | human dispatch declarations: name the target of a dynamic call site the analysis cannot resolve |
| `bindings` | cross-language string-key dispatch boundaries |
| `clangd` | the clangd oracle for C/C++ |
| `luals` | the lua-language-server oracle for Lua |
| `profile` | environment profiles |
| `mcp` | graph servers, `{ name = { cmd = {…} } }` |
| `db` | link `sql::` entities to live tables |
| `fsm` | the state-machine adapter |
| `factorio` | the Factorio projection surface |
| `ecosystem_roots` | where an installed package ecosystem lives, keyed by name |

Complete per-project wirings (a Factorio mod with the live oracle, a WordPress tree
with the database link) live in `examples/`.

## Providers

| provider | what it promises |
|---|---|
| tree-sitter | directories; any language with a spec. All edges name-matched (`~`), capabilities partial by construction |
| dump | a neutral-schema JSON file (e.g. the lua-ls `--graph` CLI) |
| `mcp://name` | a server tool returning the neutral schema; stamped sources cache like local files, stampless ones re-fetch |
| `self://loaded` | the running nvim as one corpus — every loaded plugin's runtimepath unioned under a synthetic root. A session-scoped **sample**, not cached |
| tokens | stack languages (Forth, PostScript) — see `languages.md` §3 |
| clangd | an **oracle** over the cpp skeleton: call edges proven via `callHierarchy` |

The prefixed targets are checked against what `:Cartograph` actually accepts
(`tools/docaudit.lua`), so this list cannot offer a target that does not work.

## Health

`:checkhealth cartograph` reports nvim version, installed parsers (each missing one
is a language that opens as frontier modules), nvim-treesitter presence (vue/svelte
injections + worker runtimepath), the cache codec fast path, and the optional
oracles (clangd, git).
