# Milestones

Where each of the nine gates in [CHARTER.md](CHARTER.md) stands. The charter says
what the gates are and why they are phrased the way they are; this file says
which have been met, and carries nothing else.

The work is tracked in a private tracker. The `CART-…` IDs below are handles
into it, kept so a commit and a ticket can be matched to a milestone; they
resolve to nothing from outside, and nothing here depends on reading them.
The evidence for a state is a commit, which is public.

## State

Three states, deliberately coarse: **open**, **partly met** (a clause of the
gate holds and another does not, both named), **met**.

| Milestone | Handle | State | As of | Evidence |
|---|---|---|---|---|
| **NAVIGATE** | `CART-0608` | open | 2026-11-10 | |
| **EDIT** | `CART-0609` | open | 2026-11-10 | |
| **POLYGLOT** | `CART-0596` | open | 2026-11-10 | |
| **RESOLUTION** | `CART-0598` | open | 2026-11-10 | |
| **AGENT** | `CART-0600` | open | 2026-11-10 | |
| **OBJECTIVE** | `CART-0601` | partly met | 2026-11-05 | see below |
| **SERVE** | `CART-0597` | open | 2026-11-10 | |
| **SCALE** | `CART-0599` | open | 2026-11-10 | |
| **TRANSLITERATE** | `CART-0611` | open | 2026-11-10 | |

**OBJECTIVE — partly met.** The gate is "Von-Neumann runs on Factorio 2.0,
driven by a declared objective rather than by hand".

- *Holds:* Von-Neumann runs on Factorio 2.0 (the port, finished 2026-08-31).
- *Does not hold:* the port was applied by hand, before the objectives tactic
  existed. What exists is a retrodiction — run on the 1.1 → 2.0 pair, the
  tactic (`f2b8584a`) pairs 8 of 8 lost reads the way the hand patch did.
- *What would meet it:* a port driven end to end by a declared objective.

## When to update this file

Rarely. A row changes when, and only when:

1. **a clause of a gate is measured** — it now holds, or a measurement shows it
   no longer does; or
2. **a milestone's tracker ticket is closed or reopened.**

Ordinary progress under a milestone is not a change here. Each update sets the
state, the date, and the commit that is the evidence; a gate met in part names
the clause that holds and the one that does not.

`.githooks/commit-msg` warns — it never blocks — when a commit message names a
milestone handle, or a ticket filed under one, and this file is not part of the
commit (`tools/milestonecheck.py`). The warning is a question, not a verdict:
most such commits move no gate.
