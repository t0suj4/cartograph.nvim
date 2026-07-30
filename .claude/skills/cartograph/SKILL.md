---
name: cartograph
description: Use cartograph.nvim — the symbol-graph browser and transactional refactoring cockpit for Neovim. Covers opening a project (:Cartograph), navigating altitudes and lenses, reading the honesty markers (~ / dynamic / frontier / refused / torn), the analysis verbs (lint, clones, untangle, trace, version floor, portability), and staged multi-file edits (Move/Merge/Extract → Diff → Apply → Undo). Load this whenever cartograph, :Cartograph* commands, or its reports come up — and ALWAYS before claiming an analysis verb works on a given language, because support is per-language and uneven.
---

# cartograph.nvim

A keyboard-driven Smalltalk-style system browser over a codebase's symbol graph,
plus transactions: multi-file edits that preview as diffs, apply through a
journal, and undo byte-exact.

## Version this skill was built for

```
commit  852916f59e451268c29eb01ff061c01e7520c6ae  (852916f)
date    2026-07-30
subject The browser names its own lenses: a mode strip in the winbar
```

Verified against that tree: **79 user commands** (77 global + 2 pane-local) and
**16 language specs**. The project's own doc fence (`tools/docaudit.lua`) reported
zero drift at this commit, so `doc/cartograph.txt` is authoritative there.

Status is **EXPERIMENTAL** — upstream states commands, keys and APIs may change
without notice. Before trusting the tables in `references/`, check whether HEAD
has moved:

```bash
git -C <repo> log -1 --format='%h %cd %s'                     # is it still 852916f?
nvim --headless -u NONE -l tools/docaudit.lua                 # commands + language count
nvim --headless -c "lua package.path='./lua/?.lua;./lua/?/init.lua;'..package.path; \
  local ts=require('cartograph.providers.treesitter'); \
  print(table.concat(require('cartograph.spec.contract').matrix_report(ts.spec),'\n'))" -c 'qa!'
```

If HEAD differs, re-run those three and prefer their output over anything here.

(At authoring time the working tree also carried uncommitted work on
`panes/symbols.lua`, `panes/concerns.lua` and `exprlint.lua` — the lints-lens /
suppression compartment. The command surface and language specs were unaffected;
the `lints` lens behaviour described here reflects that in-progress state.)

## Language support is uneven — read this before answering "can it do X on Y"

**16 languages ship tree-sitter specs**, but shipping a spec is not one level of
support. Cartograph's own spec contract defines a **capability ladder** (CORE →
SCOPE&KEY → IMPORTS → TYPES → EMITTERS → ANALYSIS), and a language fills as much
of it as its spec author filled. A group counts as "filled" the moment **one**
field in it is present, so `●` means *some* capability, never completeness — the
slot count is the honest depth measure.

| language | exts | CORE | S&K | IMP | TYP | EMI | ANA | slots filled |
|---|---|---|---|---|---|---|---|---|
| lua | lua | ● | ● | ● | ● | ● | ● | **28** |
| zig | zig | ● | ● | ● | ● | · | ● | 27 |
| php | php | ● | ● | ● | ● | ● | ● | 26 |
| java | java | ● | ● | ● | ● | ● | ● | 23 |
| ruby | rb | ● | ● | ● | ● | ● | ● | 23 |
| typescript | ts | ● | ● | ● | ● | ● | ● | 23 |
| tsx | tsx | ● | ● | ● | ● | ● | ● | 23 |
| javascript | js mjs cjs jsx | ● | ● | ● | ● | ● | ● | 22 |
| rust | rs | ● | ● | ● | · | ● | ● | 20 |
| cpp | cpp hpp cc hh cxx hxx | ● | ● | ● | ● | ● | ● | 18 |
| bash | sh bash | ● | ● | ● | ● | ● | ● | 17 |
| go | go | ● | ● | ● | · | · | ● | 17 |
| haskell | hs | ● | · | ● | ● | ● | ● | 16 |
| scheme | scm | ● | ● | ● | · | · | · | 14 |
| c | c h | ● | · | ● | ● | ● | ● | 13 |
| python | py | ● | ● | ● | ● | ● | ● | 12 |
| odin | odin | ● | ● | · | · | · | · | 12 |

Read that table with two cautions:

- **`python` looks complete and is thin.** Every group is `●`, but it fills only
  12 of ~70 slots — the fewest of any language whose groups all light up. Do not
  promise Python parity with Lua.
- **The flow substrate is gated on one field, `body_field`, and three languages
  lack it: haskell, odin, scheme.** `providers/treesitter.lua` builds a CFG only
  for `body_field` languages, so everything CFG-derived — expr lints, untangle,
  optimize, reorder, branch values, extract blocks — has nothing to read there.
  Haskell is the subtle case: it fills ANALYSIS slots via its *own* `dataflow`
  model, so it has df facts but not the CFG verbs. odin and scheme fill zero
  ANALYSIS slots and have neither.

**Beyond the specs:** `vue`/`svelte` single-file components parse as *container*
files via nvim-treesitter injections (so nvim-treesitter is required for them);
Forth (`fs`, `4th`, `fth`) and PostScript (`ps`, `ps.src`) open through a separate
**tokens** provider where word mentions are `ref` edges, *not* call sites. A
language whose parser is not installed opens as **frontier** modules — visible and
jumpable, never silently omitted.

### Which verbs are language-locked

This is the part most likely to produce a wrong answer if guessed:

| capability | works on |
|---|---|
| graph, navigation, LSP read surface, clones, census/ladder, mentions, cones | all 16 + SFCs |
| CFG/flow verbs (`Expr`, `Untangle`, `Optimize`, `OptimizeApply`, `Reorder`, `BranchValues`, `ExtractBlocks`) | the 14 `body_field` languages — **not haskell, odin, scheme** |
| `:CartographFields`, `:CartographNarrow`, `:CartographParamNil`, `:CartographDevirt` | **lua only** (hard-gated; others get "not yet supported (Lua only)") |
| `:CartographEscalate`, `:CartographFieldHarvest` (lua-ls oracle) | **lua only** |
| clangd oracle — *proven* call edges rather than `~` | **c, cpp only** |
| `:CartographVersionFloor` | **javascript, typescript, tsx, python, ruby only** — any other language reports "no version-floor table" |
| behaviour-change range *split* within version floor | **python, ruby only** |
| `:CartographPortability`, `:CartographRequires` | needs a shipped env profile: **lua** (luajit, lua-factorio 2.0.72, lua-factorio-11 1.1.110), **ruby** (cruby 3.2.3, ruby-core, ruby-rails), **zig** (zig-std) |
| two-runtime *move* diff (needs two same-language profiles) | luajit↔lua-factorio, lua-factorio-11↔lua-factorio, ruby-core↔ruby-rails |
| `:CartographRoster` | ecosystems **lua-factorio, lua-nvim, lua-wow** (all Lua) |
| `:CartographPrototypes` | **lua + a data-stage profile** — today only lua-factorio |
| framework packs | **ruby**: rails, rspec |
| framework adapters | **python**/django, **php**/symfony + WordPress hooks, **yaml**/ansible |
| SQL-injection taint lints (sink-concat, sink-source, sink-reach) | **php only** |
| memory lints (resource-leak, member-leak, null-deref) | **cpp only** (incl. `.h`) |

Full per-language detail, profile contents and the framework matrix:
**`references/languages.md`**.

## The core loop

```vim
:Cartograph                " open the cockpit on cwd (also: <dir>, dump.json,
                           " mcp://name, self://loaded)
:CartographIndexOnly       " thin symbol index, no analysis; fills in on demand
```

Layout is **symbols (left) | source | plan bar (bottom)**. In the symbols pane:

- `l` descend / `h` ascend through altitudes: `files → file → fn → block`
- `j`/`k` step (and step *out* at a block edge), `<CR>` pivots (re-roots)
- `<Tab>`/`<S-Tab>` cycle the altitude's **lens**; the winbar names them, e.g.
  `⇥ statements [detail] lints`
- Hover previews in the source pane; **movement never changes focus** — pivots are
  deliberate. `<C-]>` jumps to the callee, `<C-o>`/`<C-i>` walk the jumplist.

Staging an edit is cut/paste, then plan → review → commit:

```vim
" dd cuts a row into the move-set; p on a file row sets the destination
:CartographMove            " stage (writes nothing)
:CartographDiff            " the exact bytes it would write
:CartographApply           " late-bound verify, journal, write, splice
:CartographUndo            " byte-exact rollback  (:CartographRedo re-applies)
:CartographTxnClear        " abandon the staged plan
```

Every edit verb rides that substrate: `:CartographMerge`,
`:CartographExtractModule`, `:'<,'>CartographExtract`, `:CartographExtractHelperApply`,
`:CartographHoistClosure`, `:CartographReorderApply`, `:CartographOptimizeApply`.
**What a verb refuses is as load-bearing as what it writes** — a refusal names its
reason and costs a re-plan, never a corrupted write. A Lua move writes text, the
require line and requalified call sites, but discloses bare-name calls and shadowed
aliases as **hazards** with counts, for you to finish.

Command reference, grouped as upstream groups them: **`references/commands.md`**.

## Reading the output honestly

Cartograph's whole design is *never fabricate an answer*. Do not flatten its
markers when relaying a report — they carry the epistemic tier:

| marker | means |
|---|---|
| `~` | name-matched (inferred): unique name, **not** proven by types |
| `dynamic` | a call the graph knows it cannot see (`$fn()`, variable methods) |
| `frontier` | unparsed/unreachable territory shown *as* territory (min.js, missing parser) |
| `torn` | a def recovered from beyond a parse error — visible, never name-matched |
| `refused` | ambiguity never picks a side: two candidates = no link. A refusal is a **place** — descend it to see the candidates and the rule |
| `alibi` | why a function is not dead: a caller, a registration, an entry point, a visibility promise |

Two distinctions that change what an answer *means*:

- **A computed absence is not an absent answer.** "no callers found — entry point,
  or dynamically dispatched" means the call graph was built and holds none.
  "⚠ index-only mode has no call graph" reads `unavailable`, not `0`.
- **Elision is never silent.** Rows fit `symbols_width` (default 30): identities
  elide in the *middle* (`crash-site-…-machine.lua`), free text at the *tail*.
  A file row shows the shortest *unique* path suffix — the real path is still what
  hover, `gf` and staging use.
- **A suppressed finding is still counted** (`◆ N suppressed here`), and that count
  is descendable.

Fuller vocabulary, empty-view kinds and the budget rules:
**`references/reading-output.md`**.

## Driving it from a tool or an agent

- **LSP read surface** — `:CartographLspAttach` serves the open graph as an
  in-process LSP: definition, references, hover, symbols, call hierarchy,
  implementation, type definition, plus tier-tinted semantic tokens. Hover states
  *why* (tier, or the refusal rule and candidate count). Namespaced
  `cartograph/why` and `cartograph/graphInfo` exist specifically for tools and
  agents. `tools/lspserve.lua` runs the same surface over stdio for any editor.
  It is **read-only** — writes belong to the transaction family.
- **`:CartographEval {lua}`** and `:CartographWorkspace` run ad-hoc Lua against the
  loaded graph (`store`/`spines`/`territory` in scope); a returned node list is
  browsable.
- **Headless** — `nvim --headless -l tools/dogfood.lua` is the self-analysis
  dashboard and a CI fence. `tests/run.sh` runs the suite. `tools/matrix.lua`
  sweeps every parity/honesty invariant × corpus.
- **Network is never implicit**: extraction and every report stay offline.

## Getting it wrong safely

- Don't claim a verb's finding is a proof when the report hedged it `~`.
- Don't report "0" where cartograph said `unavailable`.
- Don't assume a language has a capability because it "ships a spec" — check the
  tables above, and prefer running the verb over predicting it.
- `:CartographFeedback` files a report frozen at the current node, capturing the
  observed half itself. It works with **no graph loaded and on a row with no
  node** — an absence is a useful report.
