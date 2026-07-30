# Reading cartograph's output honestly — @ 852916f

Cartograph's central design rule is that it never fabricates an answer. Every
report is written so that *not knowing* is expressible. If you relay a report and
drop the markers, you convert a hedge into a claim — which is exactly the failure
the tool is built to prevent.

## The honesty vocabulary

| marker | meaning |
|---|---|
| `~` | **name-matched (inferred)** — a unique name, not proven by types. The default for everything cross-file unless an oracle proved it |
| `dynamic` | a call the graph **knows** it cannot see (`$fn()`, variable methods) |
| `frontier` | unparsed/unreachable territory shown **as territory** (minified bundles, missing parsers, vendored code). Descend reaches in by text search |
| `torn` | a def extracted from beyond a parse error: visible and jumpable, **never** name-matched, because it escaped its context |
| `refusal` | ambiguity never picks a side — two candidates = no link. A refusal is a **place**: descend an unresolved call to see the candidates it refused between and the rule that refused |
| `alibi` | why a function is not dead: a caller, a **registration** (dispatch table / load-time data / annotation — the fn view's `◆ registered by` descends into it), an entry point, or a visibility promise. No alibi ⇒ *possibly* dead |

Resolution tiers you will see on LSP hover and in the census/ladder: `matched`,
`typed`, `proven`, `stdlib`, and for the unresolved, the refusal rule plus how many
candidates it saw.

Gutter classification on file rows: `▶` entry, `○` orphan (no importer, and not
matched by `entrypoints`).

## Empty views state which KIND of empty

This distinction is load-bearing and easy to destroy in a summary:

- **Computed absence** — "no callers found — entry point, or dynamically
  dispatched". The call graph *was built* and holds none.
- **Absent answer** — "⚠ index-only mode has no call graph", shown as a frontier
  with the count reading **`unavailable`**, not `0`. A thin index carries every
  file's definitions and no edges, so a function with four callers would otherwise
  read as having none.

The relation altitudes (callers, occurrences, registered-by, refusals) and a var's
usage sites all make that distinction. **Never report `unavailable` as `0`.**

Some verbs refuse outright rather than answer thinly: `:CartographMentions` refuses
on a thin index rather than reporting zero mentions, because that would be a
fabricated negative.

## A row FITS, or it says so

The symbols pane has `symbols_width` columns of text (default 30, gutter outside it)
and `wrap` off — so a longer row would be cut by the editor with no marker at all,
and the pane would silently withhold what it rendered. The rules:

- A row carries **one identity that fits**; whatever does not fit is detail with a
  home somewhere else.
- **File rows** show the shortest path **suffix** unique among the files on screen.
  Two `railbot.lua` in different directories each keep the directory that separates
  them; a unique basename drops its prefix entirely. Descend and the dropped
  directory is the dim breadcrumb above the header. **The path itself is never
  lost** — hover, `gf`, staging and the source pane read the real path, never the
  label.
- An identity too long even alone elides **in the middle**, both ends kept
  (`crash-site-…-machine.lua`). Only an identity is ever elided, and never silently;
  an annotation moves or goes instead.
- **Free text** — a statement, a call, a condition — elides at the **tail**
  (`local vonnCharacter = playe…`), because a statement reads left to right and its
  front identifies it. Every such row anchors to its source line, so the source pane
  holds it whole.

## Suppressed findings are still counted

On the `lints` lens, `l` on a finding descends into its **actions**: the full
explanation the 30-column row could not carry, `suppress here`, and a `fix` row that
is **always present** and states its own unavailability with a per-rule reason — an
action list that omitted the unimplemented option would say neither "there is no
safe rewrite" nor "nobody wrote one yet".

The count is never hidden: the lens says `◆ N suppressed here`, and
`:CartographExpr` lists each silenced finding with the marker that silenced it.
Otherwise "0 findings" would mean clean-or-hushed.

**The count is a door.** `l` on it descends into the findings it counts — dim `∅`
rows, one per silenced finding, each opening the same actions compartment a live
finding does, where `un-suppress` is offered. `h` returns to the lens you came from.
The empty view here says *"no finding here is suppressed — a marker MAY have gone
since the count was drawn"*; **may**, because this altitude is also reachable by a
trail return or a restored location, where nothing was ever suppressed.

Mechanics: `@cg-ignore: <rule>` is **appended** to the reported line (also honoured
on a comment line directly above; blank lines and code stop the walk). Appended
rather than inserted because inserting a line shifts every range below it — the
write would invalidate the map it was issued from. Naming rules keeps one marker
from silencing everything; a bare `@cg-ignore` silences all. Unknown comment syntax
**refuses** rather than guessing. The write is journaled, so `:CartographUndo`
reverses it.

## The subject of a row

`mark` and the cone verbs act on the row's **subject** — the node the row is *about*,
which is not always a node the row *is*:

1. the row's own symbol, at the file or working-set altitude;
2. else what the row **refers to** — a call site, an occurrence or a folded usage
   group is about the function whose body contains it, so marking works while you
   traverse references;
3. else the altitude's own subject — the function you descended into, the entity
   whose callers you are reading. No row at those altitudes is a symbol, so without
   this, `mark` had nothing to act on and refused.

Because case 3 marks something with **no row of its own** to carry the `●`, the verb
says which node it marked. A **file row has no subject** — a file is not a node — so
`mark` there reports that rather than guessing at its members. A "registered by" row
is the exception that looks like one: it names a registering *module*, and a module
**is** a node, so mark/cone/hover act on it directly by rule 1.

## Terminology you will meet in reports

**Graph:** `node` (kinds: `function`, `method`, `var`, `module`, `region` — a run of
top-level statements between function definitions, shown `≡`) · `edge` (`ref` =
call/reference, `import` = require/include, `use` = variable read, `reg` =
registration by a dispatch table or annotation) · `call` (a call-site record;
becomes a `ref` edge once resolved, or stays a **refusal**) · `occurrence` (one
*site* of an edge — an edge can have several).

**Views:** `altitude` (`files → file → fn → block`, plus side-views `region`,
`callers`/`used-by`/`sites`, `table`, `refused`, `registrations`, `states`,
`working set`) · `block` (derived on demand from the source, not a graph node) ·
`form` (one nested statement or call — a row, not a node) · `lens`.

**Navigation:** `focus` (the node the cockpit is rooted on, set by a **pivot**) ·
`context` (the transient hover preview — *the view follows the eye; focus follows
intent*) · `peek` (after an ascend the source pane lingers on where you were until
you move) · `trail` (the `h`/`l` structural path — return the way you came, distinct
from the jumplist, which records pivots) · `cockpit` (the whole tab: browser +
source pane + plan bar).

## The reference layer — why a stale plan is safe

Node ids embed line numbers and **never leave the session**. Anything durable —
pins, staged plans, journals — holds a **ref** instead: `{ file, kind, name,
ordinal?, witness? }`, resolved at use time. The witness is the clone detector's
hash reused as identity evidence (df shape + params + callees): insensitive to
renames and moves, **sensitive to behavior**.

Resolution policy, edit by edit: edits elsewhere survive; body edits survive **with
a drift note**; renames recover by witness **with a note, offered never assumed**;
reordered same-named siblings are disambiguated by witness (true clones fall to the
ordinal, with the caveat stated); deletion is `missing`, which is the truth. Refs
are provider-portable — one minted on a tree-sitter graph resolves against a lua-ls
dump of the same tree.

## Live refresh

Writing a file under the project root re-extracts just that file (imports resolved
against the whole project), splices it into the store, and **relinks in both
directions** — inbound edges survive edits through a `(kind, name)` remap, and calls
elsewhere that named a function you just created resolve to it. Navigation state
(focus, history, trails, exact browser location) carries across.

Staged changes **freeze** refresh. Dump-based graphs (lua-ls) **say so** instead of
silently staling.

## Reported accuracy claims

Where cartograph states a number about itself, it states the comparison too — quote
it that way or not at all:

- The LSP read surface, measured against lua-ls on the same corpus: **99.6–100%
  agreement where both resolve**, and it resolves more.
- The `silent-drop` lint gates on **boundedness, not name length**, and "in practice
  reports nothing" — it is a regression detector, not a finding generator.
- `sink-concat`/`sink-source`/`sink-reach` were validated to fire on the genuine
  article (a real, since-fixed injection in grocy) and stay at **0** on
  uniformly-parameterised corpora (mantis, sylius) — but the sink is always a `~`
  hypothesis.
