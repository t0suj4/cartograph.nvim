---
name: cartograph
description: Drive cartograph.nvim headlessly as an agent — a polyglot symbol-graph and transactional refactoring engine exposed over MCP (tools/mcpserve.lua, 25 verbs incl. a VERSION axis that diffs two runtime profiles) and one-shot JSON (tools/agentq.lua). Use it to ask who calls what, why a symbol is not dead, what a refactor would change, and to apply multi-file edits through a journal. Load this whenever cartograph, :Cartograph* commands, mcpserve/agentq, or its reports come up. ALWAYS load it before concluding "nothing found" from a cartograph answer — an empty result here is a typed claim with a reason attached, and the four reasons mean different things.
---

# cartograph, for an agent

A symbol graph over a polyglot codebase, plus transactions: multi-file edits that
preview as diffs, apply through a journal, and undo byte-exact.

You drive it **headlessly**. The interactive cockpit (`:Cartograph`, altitudes,
lenses) is for humans and you cannot use it.

## The one rule

**An empty answer is never a bare empty list.** Every verb that finds nothing says
*why*, and the reason is one of four values that do not mean the same thing:

| `absence` | means | your next move |
|---|---|---|
| `absent` | the question was asked and the answer is genuinely nothing | you may act on it |
| `refused` | something might qualify and a rule declined to pick | **do not** treat as nothing — read `absence_why.evidence` |
| `frontier` | the analysis cannot see this far | a different tool, or accept the limit |
| `unavailable` | the capability is missing on this graph or host | change the invocation |

This is the whole reason to use cartograph instead of grep. Measured on cartograph's
own tree: of 266 dead-code findings, **7 were `absent` and 229 were `refused`** — only
the 7 licensed a deletion. A tool that returned `[]` for all 266 would have been
wrong 97% of the time, and silently.

**Never collapse these into "no results".** If you report an absence to a user,
report which one.

## Running it

Two hosts, same envelope.

```bash
# a session — MCP, newline-delimited JSON-RPC 2.0, one JSON object per line
nvim --headless -u NONE -l tools/mcpserve.lua <root> [--index-only] [--write]

# one shot — one JSON document on stdout, nothing else
nvim --headless -u NONE -l tools/agentq.lua <root> alibi <file> <line>
```

`agentq` exit codes, so a shell can tell an answer from a refusal without parsing:

```
0  ok:true    an answer
3  ok:false   a REFUSAL — stable, do NOT retry; refusal.remedy says what to change
2  usage / protocol fault
1  internal error (still emitted as JSON, in `error`)
```

**A refusal is not an error.** Exit 3 is a considered answer. Retrying it unchanged
gets the same result; read `remedy`.

## Isolation: pin the tool, point it at the live tree

If you are working **on cartograph itself**, do not run the server out of the tree
you are editing. A syntax error mid-edit kills the host and a half-applied refactor
yields wrong answers — and from the client side those look identical.

The tool and the subject are already separate parameters:

```
the TOOL     which checkout runs mcpserve.lua   →  tools/worktree.sh (a committed ref)
the SUBJECT  the <root> ARGUMENT                →  your live working tree
```

So: run a **pinned** cartograph against the **live** tree. `-u NONE` means no config
is loaded, so there is no plugin state to isolate — only the code.

Consequence to expect rather than discover: a worktree checks out a *committed* ref,
so a pinned tool lags your working tree by up to one commit. That is correct for an
instrument and surprising if you forget it.

## The verbs

25, in the order they may be trusted in. `graph_info` first — it reports which verbs
are available on *this* graph and host, and why any are not.

```
READ      graph_info  node_find  node_at  edges_callers  edges_callees  why  lint_run
CATALOGUE clones_find  cone  ladder  territory  census  mentions  externals
VERSION   portability_targets  portability_move  portability_move_calls
WRITE     txn_plan_moveset  txn_plan_optimize  txn_plan_declare  txn_preview
          journal_list  journal_get
          txn_apply  txn_undo
```

Ask `graph_info` before assuming a verb works. Two capability axes are reported
separately because your next move differs:

- **`needs_calls`** — about the GRAPH. On an index-only graph a call verb *refuses*
  rather than answering "none".
- **`mutates`** — about the HOST. `mcpserve` is **read-only by default**; `--write`
  grants the mutating verbs. Gated verbs are still advertised, with the gate stated
  in their description.

### The version axis — and pick the right one

`portability_move` diffs the **read** surface between two profiles of the same runtime;
`portability_move_calls` diffs the **call** surface. **Use `portability_move` for a
version port.** The call surface is call-derived, so a 1.1 → 2.0 Factorio move reports
`lost=0` — everything that actually changed (`global.*`, `game.entity_prototypes`) is
*read*, never called. Picking the call verb gets you a clean bill of health for a broken
port.

`portability_targets` gives the from/to vocabulary, and lists non-targets with the reason
they are blocked. Guessing profile names is what it exists to prevent.

A `lost=0` answer is `absent` — a real result meaning the move loses nothing this code
reads. It is not the same as a refusal (the two profiles cannot be compared) or
`unavailable` (no profile ships for that version). The three render differently on
purpose.

## Reading an answer

```
ok  verb  graph  subject  result  tier  absence  absence_why  notes  refusal
```

- `absence` / `absence_why` — the table above. `absence_why` carries `premise`,
  `why` and `evidence`.
- `tier` — how well-founded the answer is, a rung on the ladder. **Read it with the
  verb's `tier_basis`** from `graph_info`:
  - `resolution` — rows are name resolutions, so a non-empty result carries a rung
  - `observation` — rows are read off the parse; `tier` is **always null**, and that
    null means *"this question has no rung"*, not *"unknown"*
  - `mixed` — per answer
- `tier_headline` — whether the headline rung is the `floor` (weakest row) or the
  `peak` (strongest). **The same field name means opposite things across surfaces**,
  which is why it is published. `peak` answers "is there any support"; `floor`
  answers "how good is the worst of these".
- `notes` — disclosures that are not refusals. `ref-caveat` (a ref resolved with
  drift), `headline-scope`, `tier-order-disputed`, `staged`.
- Addressing: every verb taking an `id` also takes a durable `ref`
  (`{file, kind, name, ordinal?, witness?}`). A stale ref **refuses** with rule
  `stale-ref`. Prefer refs across edits; ids embed line numbers and move.

## Writing

The order is the order of trust, and it is enforced:

1. `txn_plan_moveset` / `txn_plan_optimize` / `txn_plan_declare` — propose.
   Writes nothing.
2. `txn_preview` — diff it. Writes nothing.
3. `journal_list` / `journal_get` — read the history.
4. `txn_apply`, then `txn_undo` if needed.

### Adding to a declared table — `txn_plan_declare`

The commonest edit there is, and the one the other write verbs did not model: a
day of real work measured 15 commits, ZERO file moves, diffs `+158/-0` and
`+130/-1`. Two ways in, and they get identical checking:

- `member` — **you write the text** (`subscript_list = true`). It is parsed and
  matched against the members already there.
- `subs` — **cartograph writes it**, filling the container's template holes from a
  real member, so indentation and quote style come from the file.

**Read the refusal; it is usually the useful answer.** It describes the
CONTAINER, not your syntax — *"the new member does not fit the ones already there
(leaf-vs-tree, size-skew)"* means the members have a structure yours does not.
**54.9% of container literals with two or more members share no shape at all**, so
`do not share a shape` is the ordinary reply, not a bug: there is genuinely no
template to check against, and editing the file directly is the right move.

The plan declares two guards and both REFUSE rather than warn — `parses` (the
file still compiles) and `shape-preserved` (the member still fits the container,
re-derived from the written bytes). Neither claims the change is *correct*.

**`txn_apply` refuses a plan that was never previewed** (rule `unpreviewed`). On a
machine transport the preview is the only step between proposing an edit and making
one.

Apply verifies **late**, at apply time, not at plan time: generation match, refs
resolving witness-clean, stamp CAS, no dirty buffers. Those four are the precondition
that lets a machine apply at all. A refusal there is the guarantee working — read it,
do not route around it.

`declined` rides in every plan/preview/apply answer, with its evidence field present
even when empty, so "nothing was declined" and "the ledger was not filled in" stay
distinguishable.

### The loop, not the four steps

One plan is one turn of a loop, and the loop matters because **an apply invalidates
the world you planned against**:

1. **Locate, and take the `ref`.** `node_find` / `node_at`, then carry the durable
   `ref` from the row — not the `id`. Ids embed line numbers and move under every
   edit; a ref survives a rename and drift.
2. **Plan.** `txn_plan_moveset` takes a SET (`seed` ids and `seed_refs` refs,
   unioned), `txn_plan_optimize` its own subject, `txn_plan_declare` a container
   plus a payload. Writes nothing.
   ⚠ A ref that resolves WITH a caveat — drifted witness, apparent rename, ordinal
   match — is a `ref-caveat` **note** on the read side and a **refusal** here. The
   write side is stricter than the read side ON PURPOSE: a wrong answer is
   recoverable, a wrong edit is not.
3. **Preview.** Not optional — apply refuses `unpreviewed`. Preview re-checks the
   generation itself; `dryrun` does not, so a stale plan would otherwise diff
   today's disk against yesterday's offsets and print a confident, wrong patch.
4. **Apply**, then `txn_undo` if needed.
5. **Now re-derive.** The apply bumped the graph's generation, and a plan handle
   **dies with the generation it was planned against** — so every other plan you
   were holding is now dead, and every `id` you were holding has moved. Go back to
   step 1 and re-locate by ref. Do not batch plans across an apply.

Two more properties of the handle, both deliberate: it is **session-scoped** (it
dies with the server, like an `id` and unlike a `ref`), and the registry is
**capped** — a long-running server drops the oldest, and an evicted id refuses by
name rather than resolving to something else.

**A refusal is a question, not an obstacle.** Read its `rule` and `remedy`: some
refuse for want of a PREMISE you can supply, and supplying it is the sanctioned
path. Routing around a refusal — re-planning to dodge it, editing the file
directly — discards the only guarantee that separates this from a text editor.

## Live defects — know these before driving writes

- **CART-0582 (P1)**: journal entry ids are `os.time()`-granular and the entry file is
  overwritten. **Two applies of the same verb to the same root inside one second
  destroy the first's undo.** Space out applies, or check `journal_list` after each.
- **CART-0583**: `txn_plan_moveset` is not marked `mutates`, so it answers on a
  read-only host — and planning still clears the live move-set. Planning is not
  side-effect-free on an interactive session's state.
- **CART-0579**: refusal evidence double-counts sites (a site matching two ways is
  listed twice), so `"candidates existed at N site(s)"` overstates N. Count the
  distinct lines in `evidence.sites`, not N.

## What not to claim

Language support is **per-language and uneven**, and a verb working on Lua says
nothing about Ruby. `graph_info` reports the graph's own frontier; `census` and
`externals` report what was not resolved. Check before generalising.

`references/` (commands.md, languages.md, reading-output.md) documents the
**interactive** surface and is pinned to commit `852916f` (2026-07-30). It is stale
and it is not the agent surface — do not quote its tables as current.

## Drift check

This file describes the agent surface at:

```
commit  c1955fc   The header said the version diff could not be demonstrated; it demonstrates in one call
```

Verify before trusting the verb list:

```bash
git -C <repo> log -1 --format='%h %cd %s'
nvim --headless -u NONE -l tools/mcpserve.lua <root> <<< '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

If `tools/list` names verbs this file does not, the file is behind.
