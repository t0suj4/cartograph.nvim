# Language support — cartograph.nvim @ 852916f

Everything here was read out of the tree at commit `852916f`, mostly by running the
project's own introspection rather than transcribing prose. Re-derive with the
commands in each section if HEAD has moved.

## 1. What "16 languages" means

`tools/docaudit.lua` reports the shipped count and cross-checks it against every
doc sentence that claims a number:

```
languages shipped: 16 (bash c cpp go haskell java javascript lua odin php
                       python ruby rust scheme typescript zig)
```

The spec table actually holds **17 entries** — `tsx` is a separate spec that the
count folds into `typescript`. Both are real and independently filled.

Extensions, straight from each spec's `exts`:

| language | extensions |
|---|---|
| bash | `sh` `bash` |
| c | `c` `h` |
| cpp | `cpp` `hpp` `cc` `hh` `cxx` `hxx` |
| go | `go` |
| haskell | `hs` |
| java | `java` |
| javascript | `js` `mjs` `cjs` `jsx` (the JS grammar handles JSX) |
| lua | `lua` |
| odin | `odin` |
| php | `php` |
| python | `py` |
| ruby | `rb` |
| rust | `rs` |
| scheme | `scm` |
| tsx | `tsx` |
| typescript | `ts` |
| zig | `zig` |

## 2. The capability ladder

`lua/cartograph/spec/contract.lua` is a closed schema: every field a spec may
declare is registered into exactly one capability group, and an unregistered field
fails `tests/contract_spec.lua`. The groups, in dependency order, with what each
unlocks (verbatim from the contract):

| group | slots | unlocks |
|---|---|---|
| CORE | 7 | defs / calls / bare-name resolution (the neutral schema) — **required** |
| SCOPE&KEY | 15 | scoped + keyed resolution, receiver keying, the stdlib gate |
| IMPORTS | 9 | cross-file binding |
| TYPES | 14 | receiver / return / chain / field typing |
| EMITTERS | 13 | convention defs (accessors, ctors, ancestors, callbacks) |
| ANALYSIS | 12 | flow / df / effects / write-axis / taint |
| QUIRKS | 11 | *nothing new* — quarantined single-language shims |

QUIRKS is not a capability; ignore it when judging support.

### Group fill and slot depth

Regenerate both with:

```bash
nvim --headless -c "lua
package.path='./lua/?.lua;./lua/?/init.lua;'..package.path
local ts=require('cartograph.providers.treesitter')
local c=require('cartograph.spec.contract')
print(table.concat(c.matrix_report(ts.spec),'\n'))" -c 'qa!'
```

`matrix_report` prints `●`/`·` per group. Slot counts (how many registered fields
each language actually declares) come from `c.audit(ts.spec)`:

| language | CORE/7 | S&K/15 | IMP/9 | TYP/14 | EMI/13 | ANA/12 | QUIRKS/11 | total |
|---|---|---|---|---|---|---|---|---|
| lua | 5 | 4 | **5** | 2 | 3 | **8** | 1 | **28** |
| zig | 4 | 8 | 3 | **9** | 0 | 2 | 1 | 27 |
| php | **7** | 3 | 3 | 3 | 2 | **7** | 1 | 26 |
| java | 5 | **8** | 2 | 1 | 3 | 3 | 1 | 23 |
| ruby | 5 | 7 | 2 | 1 | **5** | 2 | 1 | 23 |
| typescript | 5 | 5 | 2 | 3 | 3 | 4 | 1 | 23 |
| tsx | 5 | 5 | 2 | 3 | 3 | 4 | 1 | 23 |
| javascript | 5 | 5 | 2 | 3 | 2 | 4 | 1 | 22 |
| rust | 5 | 7 | 2 | 0 | 1 | 3 | 2 | 20 |
| cpp | 5 | 3 | 2 | 1 | 1 | 3 | 3 | 18 |
| bash | 6 | 2 | 2 | 1 | 1 | 4 | 1 | 17 |
| go | 5 | 6 | 2 | 0 | 0 | 3 | 1 | 17 |
| haskell | 5 | 0 | 2 | 1 | 1 | 3 | 4 | 16 |
| scheme | 6 | 1 | 2 | 0 | 0 | 0 | 5 | 14 |
| c | 5 | 0 | 2 | 1 | 1 | 3 | 1 | 13 |
| python | 5 | 2 | 1 | 1 | 1 | 2 | 0 | 12 |
| odin | 4 | 6 | 0 | 0 | 0 | 0 | 2 | 12 |

**How to read it.** A group lights up on its *first* field, so `●` is presence, not
parity. The interesting facts are in the numbers:

- **lua is the reference language** — deepest overall, and by far the deepest
  ANALYSIS (8/12) and IMPORTS (5/9). Every Lua-only verb below lives on that.
- **zig is TYPES-heavy** (9/14, the highest) and EMITTERS-empty — it has real
  receiver/return typing but no convention-def synthesis.
- **php is CORE-complete** (7/7) and ANALYSIS-deep (7/12) — that ANALYSIS depth is
  what the taint lints ride.
- **python fills every group and only 12 slots.** Groups-all-green is the most
  misleading row in the table. SCOPE&KEY 2/15, IMPORTS 1/9, ANALYSIS 2/12.
- **c and haskell fill zero SCOPE&KEY** — no scoped/keyed resolution, no receiver
  keying. For C, clangd is the answer (see §4).
- **scheme and odin fill zero ANALYSIS.** Nothing flow- or dataflow-derived has
  input. odin additionally fills zero IMPORTS, so it has no cross-file binding at
  all.
- **haskell has ANALYSIS but no CFG** — see §6 for why that distinction matters.
- **go and rust fill zero TYPES** — no receiver/return typing, so their method
  calls stay `~` rather than proven.

## 3. Non-spec language surfaces

**Container files (vue/svelte).** `providers/treesitter.lua` treats `vue` and
`svelte` as CONTAINERS: one file, several language regions, resolved into one
js/ts family. These depend on **nvim-treesitter's** custom injections —
`:checkhealth cartograph` warns when it is absent, and the files degrade without it.

**Tokens provider (stack languages).** `providers/tokens.lua` handles languages
that cannot have a faithful grammar even in principle — Forth's parsing words
rewrite the syntax at runtime:

| dialect | extensions |
|---|---|
| forth | `fs` `4th` `fth` |
| postscript | `ps` `ps.src` |

Defs come from definer words. **Word mentions are `ref` edges, not call sites**
(`capabilities.calls` = aggregated), so call-graph questions mean something
different here. A root of these opens through the provider automatically; a
**mixed** root opens through tree-sitter and reports how many dialect files it left
out, because the two providers promise different things about calls. Saving a
dialect file does not re-extract it.

**Missing parser.** The language opens as **frontier** modules — shown as
territory, descendable by text search. Never silently dropped.

## 4. Oracles — where `~` becomes proven

Everything cross-file is name-matched (`~`) unless an oracle proved it.

| oracle | languages | what it proves | config |
|---|---|---|---|
| **clangd** | c, cpp | call edges via `callHierarchy`; only functions clangd answered for are upgraded | `setup{ clangd = … }`; needs `compile_commands.json` (`:CartographCompileCommands` generates one via cmake/meson; `!` allows a full bear build) |
| **lua-language-server** | lua | reconciles hedges: confirmed / CONFLICT / refuted / recovered | `setup{ luals = … }`; `:CartographEscalate[!]`, `:CartographFieldHarvest` |
| **self://loaded** | lua (nvim) | declared vs live registrations | `:CartographSelf` |
| **MCP** | any | a running system's own answer; `:CartographLive` diffs it against the graph | `setup{ mcp = { name = { cmd = {…} } } }` |

Without `compile_commands.json` clangd degrades to open-file answers. A CONFLICT
between cartograph and lua-ls is a real bug on **one** side — it is reported, not
resolved.

## 5. Language-locked verbs

### Lua only (hard-gated)

`lua/cartograph/narrow.lua` declares `local EXT_LANG = { lua = 'lua' }` — commented
"INC 1: Lua only; add js/java as the vocab grows". Anything else returns
`unsupported` and the report reads `… not yet supported (Lua only)`:

- `:CartographNarrow` — guard-proved non-nil regions
- `:CartographParamNil` — inferred parameter nilability vs `---@param`
- `:CartographDevirt` — receiver narrowed to a concrete type

`lua/cartograph/fieldlink.lua` gates the same way:

- `:CartographFields` — `self.field` reads resolved to their writes

Also Lua-only by oracle: `:CartographEscalate`, `:CartographFieldHarvest`.

`:CartographPrototypes[!]` needs an environment profile **with a data stage** —
today only `lua-factorio`. It says so when there is none.

### C++ only

`lint.lua` gates its memory rules on `LEAK_CPP_EXT = { cpp, cc, cxx, hpp, hxx, h }`:

- **resource-leak** (`~`) — raw `new` pointer reassigned without a release between
- **member-leak** (`~`) — `m_x = new T()` never released anywhere in the program
- **null-deref** (`~`) — nullable-returning call dereferenced with no dominating
  guard (`if (p)`, early exit, `assert(p)`)

All three are honestly `~`: a macro or aliased pointer can fool the per-line match,
ownership transfer is not modelled.

### PHP only

The SQL-injection taint family:

- **sink-concat** — a *divergent* smell: this function concatenates a param into a
  query-shaped sink while a sibling doing the same shape sanitizes. The sanitizing
  peer is required — it is the evidence. Silent on uniformly-parameterised code.
- **sink-source** — superglobal (`$_GET`/`$_POST`/…) reaching a SQL sink, scope-aware
  forward taint. Fires only when the taint is embedded in SQL-carrying string text,
  so bound parameters stay silent.
- **sink-reach** — the inter-procedural rung, over the *resolved* call graph.

The sink is always a `~` **hypothesis** ("sink unconfirmed"). Coercion counts as a
sanitizer *per language*: a PHP `int $x` rewrites the value at runtime, a TypeScript
annotation is erased and clears nothing — so the coercion set is declared per
language and defaults to none.

### Version floor — 5 languages

`versionfloor.lua` tables, by name:

| table | languages | meaning |
|---|---|---|
| `FEATURES` | javascript, typescript, tsx, python, ruby | syntax features holding the floor up (**certain** — it is in the tree) |
| `STDLIB` | javascript, typescript, tsx, python, ruby | version-gated stdlib calls (`~` — a name match cannot see its receiver's type) |
| `CHANGED` | python, ruby | behaviour changes, which **split** a range rather than bound it |
| `SCALE` | javascript, typescript, tsx → `ECMAScript` | an ECMAScript *year* is not a version number and never reads as one |

Any other language: `no version-floor table for <lang>` — reported as **uncovered,
not floor-free**. The answer is a **range** `[floor, ceiling)`, one section per
scale (ruby 3.1 and ECMAScript 2022 are different rulers and are never maxed
together), compared against what the project *declares* (gemspec / Gemfile /
pyproject / setup.py / tsconfig target). Computed newer than declared is a **broken
promise** with the site named; computed older is explicitly **not** a finding.

### Environment profiles — 3 languages

`:CartographPortability` and `:CartographRequires` score the external surface
against a shipped profile. What ships (`lua/cartograph/spec/profile/`), with the
version each records:

| profile | language | version | form |
|---|---|---|---|
| `luajit` | lua | LuaJIT 2.1.1741730670 | `.mpack`, minted by introspecting the interpreter |
| `lua-factorio` | lua | 2.0.72 | hand-authored `.lua` |
| `lua-factorio-11` | lua | 1.1.110 | hand-authored `.lua` |
| `lua-factorio-api` | lua | 2.0.72 | `.mpack` (published API description) |
| `lua-factorio-api-11` | lua | 1.1.110 | `.mpack` |
| `cruby` | ruby | 3.2.3 | `.mpack`, from the interpreter on PATH + default gems |
| `ruby-core` | ruby | 2.8.2 (RBS) | `.mpack` |
| `ruby-rails` | ruby | rails-7 | hand-authored `.lua` |
| `zig-std` | zig | d5181a9c | `.mpack`, distilled from source |

Rules that matter when relaying a result:

- A profile whose language differs from the code's is **refused**, not scored.
- "Not in the profile" is **not** "missing" — a dependency may supply it, or the
  artifact may be partial, so the profile's own size prints with the verdict.
- An artifact that cannot answer name queries says so rather than scoring 0%.
- The **two-runtime move diff** needs two same-language profiles that answer name
  queries: `luajit`↔`lua-factorio`, `lua-factorio-11`↔`lua-factorio`,
  `ruby-core`↔`ruby-rails`. Nothing else pairs.
- `!` adds the **read surface** — names touched but never called (`global.foo`,
  `game.x[…]`). Opt-in because it re-parses every function.

### Package ecosystems — Lua only

`:CartographRoster [{ecosystem}] [{dir}]` reads a **directory**, not a graph.
Shipped (`lua/cartograph/spec/ecosystem/`): **lua-factorio**, **lua-nvim**,
**lua-wow**. Default is `lua-factorio`.

A root the spec marks not derivable is reported **unspecified**, never guessed —
Factorio's install is absent from every standard location, so it must come from
`setup{ ecosystem_roots = { ['lua-factorio'] = { install = … } } }`. An ecosystem
with no declared package forms is **refused** rather than reported as an empty
install. Findings split ACTIVE vs LATENT by enablement: a conflict between two
disabled packages is a fact about the install, not a fault in it.

WoW addons additionally get `.toc` manifest handling (load order, stray files).

### Framework packs and adapters

**Packs** compose extra spec vocabulary on top of a language:

| pack | language | adds |
|---|---|---|
| `rails` | ruby | `synth_defs`, `ctor_finders`, `stdlib_names` |
| `rspec` | ruby | `stdlib_names` |

Pack vocab is audited only where the pack is **active** (`tools/specaudit.lua`).

**Adapters** are post-passes that build neutral nodes/edges for non-code or
config-driven wiring:

| adapter | subject | what it links |
|---|---|---|
| `django.lua` | python + templates | `path`/`re_path`/`url` registrations become route entities; `{% url %}` and `reverse()` link to them. An ambiguous name tail **refuses**. |
| `symfony.lua` | php + twig + yaml | routes declared in `config/routes*.yaml`; `controller:` links to its method; `path()`/`url()` in twig, `generateUrl`/`redirectToRoute` in php |
| `ansible.lua` | yaml | handlers as entities; every `notify:` links to the handler it names — a notify naming no handler is a silent no-op |
| `sql.lua` | any language with string-embedded SQL | tables become entities with read/write `use` edges; interpolated table names stay honest misses |
| `xlang.lua` | cross-language string-key dispatch | ships bindings for chromium WebUI (`chrome.send`), WordPress hooks, guile gsubr, `lua_register`; one `setup{ bindings = … }` entry adds a boundary |

Project **shapes** (`info.json` + `control.lua`, `manage.py`, `package.json`,
`wp-settings.php`, …) preset entry-point patterns and excludes. They are **inert
analysis hints only**: a shape never wires runtime dialing (mcp/live/db) and never
overrides a key you set in `setup{}`. `:CartographShapes` explains what matched.

## 6. Two tiers of language-agnostic: neutral schema vs the CFG

**Tier 1 — neutral schema. All 16 languages.** These read nodes/edges/calls, so any
language with a spec answers: clones (`:CartographClones`, `BlockClones`,
`NearClones`), census/ladder, mentions, cones, territory, spines, heat, externals,
the journal and the whole transaction family, the LSP read surface, greenspun
detection, and the structural lints (call-cycle, require-cycle, dead-function,
dead-state, seam-guard, layering, registry-audit, …).

**Tier 2 — the CFG. 14 languages.** `providers/treesitter.lua:4224` builds flow
only when the spec declares **`body_field`** (the node field holding a function's
body). Three specs do not:

```
body_field (CFG-capable): bash c cpp go java javascript lua php python ruby
                          rust tsx typescript zig          (14)
NO body_field:            haskell odin scheme               (3)
```

Verify with:

```bash
nvim --headless -c "lua
package.path='./lua/?.lua;./lua/?/init.lua;'..package.path
local ts=require('cartograph.providers.treesitter')
local yes,no={},{}
for l,s in pairs(ts.spec) do table.insert(s.body_field and yes or no, l) end
table.sort(yes) table.sort(no)
print('body_field: '..table.concat(yes,' '))
print('none      : '..table.concat(no,' '))" -c 'qa!'
```

Verbs that route through `expr.of` — which builds `EXT` from `body_field` specs and
returns `nil` for anything else — are therefore CFG-gated: **`:CartographExpr`**
(`exprlint.lua:99`), **`:CartographUntangle`** (`untangle.lua:920`),
**`:CartographOptimize`** (`optimize.lua:36`), plus `optapply.lua`'s own `EXT` for
**`:CartographOptimizeApply`**, and the clone signature path. `:CartographReorder`,
`:CartographBranchValues` and `:CartographExtractBlocks` read the same
extraction-time flow record.

`:CartographTrace` and the effects summaries carry **no language gate of their own**
— they read the df/argv artifacts extraction produced, so they answer as well as
those artifacts exist for the language (and honestly report a `~` frontier where
they stop: field/global aliasing, a dynamic call, varargs).

**Haskell is the case that breaks the simple story.** It fills ANALYSIS slots
through its *own* `dataflow` spec function rather than the generic CFG — the
provider comment at `treesitter.lua:4215` says so directly ("haskell's
custom-dataflow model isn't [a body_field lang]"). So haskell has df facts and no
CFG verbs. Odin and scheme have neither.

One more Lua detail inside the CFG tier: `expr.of` passes
`method = (node.kind == 'method') and lang == 'lua'` to `flow.build` — implicit-`self`
handling for Lua methods. It is a flow-build flag, not a lint rule, but it means
Lua methods get one modelling nicety the other 13 do not.

## 7. Verifying a claim instead of guessing

Cheapest first:

```bash
# does this language have a spec at all, and how deep?
nvim --headless -c "lua package.path='./lua/?.lua;./lua/?/init.lua;'..package.path; \
  local ts=require('cartograph.providers.treesitter'); \
  print(table.concat(require('cartograph.spec.contract').matrix_report(ts.spec),'\n'))" -c 'qa!'

# are the docs' language claims still true?
nvim --headless -u NONE -l tools/docaudit.lua

# are the specs' own claims still true against the grammars? (grammar is the oracle)
nvim --headless -u NONE -l tools/specaudit.lua

# every invariant × every corpus
nvim --headless -u NONE -l tools/matrix.lua --quick
```

And in the editor, the honest last resort: **run the verb**. Cartograph refuses
loudly and names the language when it cannot answer, so an attempted verb is more
reliable evidence than any table — including this one.
