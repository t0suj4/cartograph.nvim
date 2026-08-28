# Charter

What cartograph is trying to become, what it refuses to become, and how you can
tell whether it got there. README.md says what the tool *does*; this says what
it is *for*.

Nothing here carries a status. Statuses rot in prose, and the whole reason this
file exists is that its content previously lived nowhere anyone could read it.
Progress lives in the tracker, and the milestones below name the tickets.

---

## The goal

> "I like this general graph viewer + editor."

**A place to see the structure of a codebase and stage changes against it.**
Navigator first, editor second.

Editors expose the dependency graph one query at a time — a rename box, a
references popup, a flat symbol outline. None of them is a *place*: somewhere
you stand in the structure, look around, and act on what you see. That missing
layer is the whole project.

Two halves, in this order:

**NAVIGATE.** A graph becomes navigable by *unfolding* it into a tree. A frame
is (axis, subject, cursor); the address is a stack of frames; `j`/`k` move
inside the frame you can see, `l` pushes, `h` pops, and rotation swaps the axis
while holding the cursor fixed. A position's identity is the path, not the
node — so the trail is not a convenience, it *is* the address. This has to work
beyond the filesystem, which is the part that is not finished.

**EDIT.** Transactions are the editor half: multi-file changes that preview as
diffs, apply through a journal, and undo byte-exact. The principle that makes
this safe on top of an analyzer is that **the reader verifies the writer** —
every operation ships an intended graph delta, the edit is spliced,
re-extracted, and diffed against that intention, and a mismatch rolls back.
Writing is span surgery on text the reader proved. Never authoring.

And a floor that is a complete product on its own: a live, honest map you
navigate and edit *through* — jump into an ordinary buffer, edit as usual, save,
the graph refreshes itself. Transactions are opt-in on top, not a prerequisite.

## What makes it general

The generality came from discipline, not flexibility. Anything that can produce
the neutral schema is a substrate, and every view, lint, refactoring and honesty
overlay works on it for free. That is why a new language is a spec module rather
than a project, and why SQL tables, FSM states and a running game map into the
same graph as functions.

**MCP and LSP are wires, not features.** The roles are *graph provider*
(anything returning the neutral schema) and *oracle* (anything answering ground
truth). Keeping transport out of the identity is what lets the same navigator
sit over a checkout, a running process, or a remote host.

## The sub-goal: superseding per-language language servers

This follows from holding the whole graph honestly; it is not what the project
is for. It matters because it is the sharpest available *test* of whether the
graph is good enough, and because the cross-language question is one we can ask
and a per-language server structurally cannot.

> "I want to supersede language servers — built around a common core, we can
> support polyglot projects."

The LSP model is one server per language, each blind outside its own. A real
polyglot project — a TypeScript frontend over a PHP backend over SQL, a game's
Lua mods over a C++ engine — runs N of them. Each sees one slice. None sees the
whole.

Five places where the architecture is ahead by construction:

1. **One engine, N cheap front-ends.** Every analyzer written once lifts every
   language at once. A per-language server reimplements the floor each time.
2. **Cross-language edges.** The schema is language-neutral, so a fetch, the
   route that answers it and the SQL that route runs are one graph with real
   edges between them. No per-language server can represent this.
3. **Whole-project residency.** The folded graph holds the whole project at
   once, with a persistent cross-session index. Mature servers re-index every
   launch — an architectural gap, not a tuning one.
4. **Uniform honesty.** Every fact carries a rung on one ladder, in every
   language, and an empty answer says *which kind of empty* it is. This is what
   makes a disagreement adjudicable instead of a shrug.
5. **Live calibration.** Runtime observation sharpens resolution across
   languages. A fixed heuristic cannot be corrected by evidence; a tier can.

And one place we are behind: single-language intraprocedural precision is a
mature server's home turf, and we do not win it in one leap. We climb it per
domain, per language, paced by the bar below.

### The bar

**A disagreement with a language server is a real bug on ONE side — not hedge
noise.**

That is the objective test for "this domain is done enough", and it applies per
domain and per language. The machinery to run it exists: on 59 WoW addons the
agreement rate is 99.6%, and 99.9–100% on individual large addons — which is
what makes the residue worth opening one by one instead of averaging away.

## Invariants

These are not preferences. Breaking one is a design change, not a fix.

**Sound-first: a wrong edge is worse than a missing one.** Never force a
frontier call to resolve. External, stdlib, comptime and dynamic stay honestly
refused. This costs headline coverage on purpose.

**Absence is typed.** `absent` / `refused` / `frontier` / `unavailable` are four
different answers and must render differently. Measured on our own tree: of 266
dead-code findings, 7 were `absent` and 229 were `refused` — only the 7
licensed a deletion. A tool returning a bare `[]` for all 266 would have been
wrong 97% of the time, silently. This is the single most load-bearing rule in
the project.

**The schema is closed.** Six node kinds, four edge kinds. A new axis is a new
predicate value, not a new kind. When something does not fit, the answer is
almost always that it is an edge you have not named yet.

<!-- @claim charter-schema: The schema is closed at six node kinds and four edge kinds. -->
<!-- check: (function () local v = require 'cartograph.validate' local function n(t) local c = 0 for _ in pairs(t) do c = c + 1 end return c end return n(v.NODE_KINDS) == 6 and n(v.EDGE_KINDS) == 4 end)() -->

**Never draw the graph.** A rendered node-and-arrow picture fabricates
spatial relationships the data does not have, and it is a hairball at any real
scale. The unit of attention is one node and its edges; navigation is
re-rooting.

**Runtime observation confirms and recovers — it never refutes.** Observed
behaviour is a subset of static possibility. It may raise a fact's tier or
recover one that was missed. It may never narrow away something static analysis
found, because the workload that would have exercised it may simply not have run.

**Nothing persists across a boundary without a validity key.** A derived value
reused without a stamp is a guess wearing a cache's clothes.

## Non-goals

The canonical "do not rebuild this" list. Each entry says *why it is closed*,
because a non-goal with no mechanism attached is the most expensive kind of
stale claim: a stale positive claim makes you try something and fail fast, while
a stale negative claim stops you trying at all and nothing ever contradicts it.

### Refused by design

**Creative code generation.** cartograph is the author's hands and verifier, not
the author. It emits edits it can verify, and refuses edits it can only propose.

**Out-precisioning a mature LSP in one leap.** Not a rejection of the goal —
supersession *is* the goal — but of the schedule. It arrives domain by domain
via the bar, and where another tool is still ahead we use it as an oracle rather
than racing it.

**Being a second knowledge store, a second tracker, or a second doc site.**
Every surface added is a surface that drifts.

### Measured dead — do not re-litigate

Each of these was built or measured and then killed. What follows each is the
*mechanism* of the kill, which is also the only thing that could reopen it: a
kill is a measurement of one representation, not a proof about the idea, and a
premise can go stale.

- **Static Lua VM inference, every arm.** Return-from-param was dead on arrival
  (the corpus evidence was Java-only); return-rounds on Lua measured ~1% and was
  unsound on overrides. *Reopens if:* a Lua corpus with declared returns appears
  — i.e. annotations, not inference.
- **Undefined-member lint on Lua.** False positives, approximately zero true
  positives. *Reopens if:* receiver typing gets a real type source on dynamic
  languages.
- **Resident record-fold, all remaining directions.** Derive, columnar,
  bytecode, varint, fixed-hot-sparse-cold — every one landed on the same
  memory-versus-access curve for at most 1.4 MB. Records are intrinsically
  tight. *Does not reopen for residency*; the wire and peak forms are a
  different question and are live under M4.
- **Fold identity on structured node ids.** Built, round-trip exact, then
  measured a resident *regression* (82 KB to 847 KB on self) and reverted. The
  whole-string interner is already near-optimal. *The surviving corollary:* a
  shared interner, not structured ids.
- **A general fence over stale header prose.** 853 header lines in `lua/`
  match negative-existence phrasing and almost all are legitimate claims about
  *user code*; another 14 are count-shaped and most of those are dated records
  of a past measurement. Flagging a record of what *was* as a stale claim about
  what *is* would be wrong. *Superseded by:* opt-in tagged claims, below.
- **Generics inference (B2).** De-funded at ~2.4% of the resolution gap.
- **Curating the stdlib profiles by hand.** Measured negative. A profile can
  only ever *subtract* — it removes hedges, it does not mint findings.

Fuller records of the kills, with the numbers, live with the work that produced
them.

## Milestones

Nine, each with a gate that can fail. Referred to by NAME, not by number —
the list will reorder and numbers rot when it does. Status lives in the
tracker, not here.

The first two are the goal itself; the rest serve it.

| Milestone | The gate |
|---|---|
| **NAVIGATE** — every axis enterable (`CART-0608`) | Every axis can be entered from outside the pane — by name, by address, or from a graph fact — not only by descending the file tree; and an address survives a graph change |
| **EDIT** — the editor half (`CART-0609`) | An extracted module **loads**. Not "the diff applied cleanly" — the resulting tree runs |
| **POLYGLOT** — one graph across language bands (`CART-0596`) | A call crossing the C++/Lua boundary in luanti resolves as one edge in one graph, and no single-language server can answer it at all |
| **RESOLUTION** — raise the ceiling (`CART-0598`) | Resolution rises **and** the fabricated fraction of the inferred tier falls, both from one run |
| **AGENT** — a machine drives the whole loop (`CART-0600`) | A headless plan → preview → apply → verify lands a multi-file refactor on a real repo with no human step, undo byte-exact. **A verification harness first**: if a feature cannot be driven headlessly, we cannot prove it works |
| **OBJECTIVE** — express what we want to achieve (`CART-0601`) | Von-Neumann runs on Factorio 2.0, driven by a declared objective rather than by hand |
| **SERVE** — the graph over a wire (`CART-0597`) | A week of real editing served over the wire with no fallback for definition / references / documentSymbol. Where the sub-goal above is measured |
| **SCALE** — unlock the locked corpora (`CART-0599`) | gitlab extracts inside a 15 GB box and its census pins |
| **TRANSLITERATE** — emit host-compilable code (`CART-0611`) | A selected region of our own source compiles as another language and the round-trip oracle holds, with the templates that replace the runtime supplied as declared data |

Two of these are phrased against a trap rather than a target, which is
deliberate:

RESOLUTION's gate is a **pair**. About a tenth of the inferred tier is
fabricated, so the honest fix *lowers* the headline before it raises it — and a
milestone phrased as "resolution up" alone would reward exactly the wrong move.

EDIT's gate says **loads**, not applies. Applying is solved: multi-file edits
preview, journal, and undo byte-exact. What is unsolved is that the artifact an
edit produces is correct as a module, and a gate phrased as "the refactor
applied" would already be green.

## How to apply this

**Navigation and editing are the point; everything else is in service of them.**
A capability that makes the graph richer but does not make it more navigable or
more editable has to say which of the two it eventually serves.

**The primary user is a human at a keyboard.** Agent-drivability is a
*verification harness* — a feature that cannot be driven headlessly cannot be
proven to work — and a bet that it makes the work easier. It is not the
destination. The wager underneath is that with complete enough features, making
the human interaction serious is the *easy* part; so when the two compete, spend
on the feature, not on the surface.

**Lua's head start is practical, not strategic.** It leads because it is what we
dogfood on, and that is the whole reason. Every Lua-locked capability is
scaffolding debt, not a moat — when one ships, "what would the other fourteen
languages need" is a real question with an answer owed, not a nice-to-have.

**Honesty is never traded for usability; it is SCOPED.** When a truthful answer
is overwhelming — 229 refusals beside 7 actionable findings — the response is
presentation and scope, never a weaker claim. Layering, budgets and lenses exist
for exactly this, and a mode that hides the refusals is different in kind from a
mode that shows fewer of them.

Prefer work on an axis where we are ahead by construction — cross-language
edges, another cheap front-end, whole-project residency, the serving surface —
over another single-language precision rung. The second is the ratchet, and the
bar sets its pace.

Treat a disagreement with another tool as a candidate bug to triage, not as an
automatic deferral.

Check every proposed feature against the non-goals before building it. If it is
on the measured-dead list, the question is not "should we try again" but "has
the kill mechanism gone stale", which is a different and much cheaper question.

## How this file stays true

Two fences, and an honest limit.

`tools/docaudit.lua` checks this file's countable claims against the code. A
claim can carry its own executable check:

```
<!-- @claim <id>: the sentence being claimed -->
<!-- check: a Lua expression that must return truthy -->
```

The check should call the mechanism's own predicate rather than reimplement it —
a check that reimplements what it checks drifts from it, which is the failure
class the fence exists to catch.

The angle brackets above are load-bearing: a scanned file cannot hold an
*example* tag, because the scanner has no way to tell a specimen from a claim
and will try to run it. A placeholder id does not parse as one, which is why
every example is written this way.

**Opt-in is the limit, and it is stated rather than hidden.** An untagged
sentence here is not checked by anything, and the measurement above is why: a
fence over prose in general is a noise machine. So the discipline is to tag a
claim *when it turns out to be load-bearing*, not to sweep the file.
