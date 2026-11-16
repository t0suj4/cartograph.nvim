# Changelog

Breaking or client-visible changes to cartograph's surfaces. Internal changes are in the git log.

## 2026-11-16 — `sites { kind = 'literal' }`: where a name is handled as a STRING (agent surface, additive)

- `sites` takes `kind = 'literal'`: every string literal whose content is the name (`fname == 'loadstring'`), found
  by parsing, with its enclosing function. A `literal-by-function` note ranks the functions. Only on request: the
  default kinds are unchanged (CART-1983).

## 2026-11-16 — every answer names the environment profile in force (agent surface, additive)

- `graph.profile` on every envelope: `{ name, selected, below }`. `name` is the profile in force (null when none);
  `selected` is the shape and directory that chose it, or `override`; `below` lists build-system shapes up to two
  directories DOWN whose profile the root does not apply.
- `graph_info` adds a `profiles-not-applied` note naming them: a monorepo parent applies none of its children's
  profiles, and their environment calls read as external while every count looks clean (CART-0815). Selection itself
  is unchanged.

## 2026-11-16 — `mentions`: a definition's own file lists its name (agent surface; cache v306)

- The mention index now holds each file's own DEFINITION names: an object-literal key (`getJSON: function …`), a
  class method, a go method — names with no identifier node, which the index never recorded, so `mentions` answered a
  `name-not-indexed` frontier (or omitted the defining file) for a name printed on its defining line. jquery/src:
  definitions in no file's entry 108 -> 44 of 392; hugo 876 -> 337. What remains is the index's documented rule
  (1-2 characters, the language's stdlib vocabulary), and the frontier now names WHICH rule (CART-1008).
- Cache VERSION 306: every cached graph re-extracts once.

## 2026-11-16 — profiles on demand: a version cartograph does not ship (Factorio 2.1)

- `lua-factorio-<v>` is DERIVED wherever `lua-factorio-api-<v>` loads, shipped or in the on-demand directory
  (`stdpath('data')/cartograph/profile`, `CARTOGRAPH_PROFILE_ONDEMAND`). It is fenced to versions whose global
  objects and functions match the hand environment, and is never an extraction environment. `lua-factorio-20` now
  exists too (CART-1938).
- The api class tables are found the same way (`classmatch.artifacts()`); it was a fixed three-name list.
  `portability_targets` lists on-demand and derived profiles.
- A move to a version not distilled answers `unavailable` with `absence_why.evidence.offers`: the apifetch and
  local factoriodistill commands. Nothing is fetched by a verb.
- `tools/apifetch.lua` writes into the on-demand directory, not the checkout's `spec/profile/` (CART-1950), and lists
  both. `factoriodistill.lua` / `prototypedistill.lua` take an output directory as arg[4].
- Hover signatures of the Factorio api are in CALL order: the documents list parameters alphabetically, so
  `script.on_event` read `(event, filters?, handler)` (CART-2104; 32 sigs per 2.0 artifact, 45 in 1.1).

## 2026-11-16 — `portability_sites`: signature changes are port sites (agent surface, additive)

- New site verdict `signature-changed`: a kept method whose parameters changed between the two versions' api
  artifacts, at a site whose argument count `breaks` (fits the old parameters, not the new) or is `shifted` (an inserted parameter moved
  a written one). A fit that is `unknown` (a table argument, an unknowable count) stays `kept`. Rows carry `signature`
  `{ from, to, added, removed }`, `arity` and `arity_why`; `subject.signatures` counts them. A site that still fits
  stays `kept`, and a compatible change (only optional parameters / keys added) is no finding (CART-1934).
- The Factorio api artifacts (`lua-factorio-api`, `-20`, `-11`) carry a new `params` field: every class method's
  parameters in call order. Re-distilled from their recorded sources; every existing field is unchanged.

## 2026-11-16 — `portability_sites` decides methods on objects by name (agent surface, additive)

- A site whose name no profile adjudicates (`player.teleport`: a method on an object) is decided by its METHOD NAME
  against every class of both versions' class tables. `lost` / `member-removed` when no target class declares it,
  `kept` / `member-supplied` when every class that had it still does, `not-adjudicable` / `member-moved` when it left
  some. New row fields: `confidence` (`profile` | `member-name`), `member`, `classes`. New subject fields: `refined`,
  `class_tables` (CART-1939). No protocol bump: fields only.

## 2026-11-16 — agent protocol 5: the `portability_sites` verb (agent surface, additive)

- New verb `portability_sites { from, to, file?, verdict?, limit? }`: the port worklist BY SITE. Every external call
  site (file, 1-based `line`, 1-based character `col`, `fn`, `callee`, `full`) with the move's verdict for its name:
  `lost`, `moved` (with `to` and `basis`: a root rename or member move), `kept`, `gained`, `not-adjudicable` (with
  `reason`, e.g. `receiver-class-present`). `subject.names` / `subject.by_site` count the verdicts per name and per
  site. The verdict is the NAME's; a changed signature or behaviour is not measured, and a note says so (CART-1951).
- Same gates as the move verbs: `same-profile`, `profiles-not-comparable`, `unavailable` for a profile that does
  not ship; `needs_calls`.
- Detect it: `graph.protocol = 5`, `serverInfo.version` `0.5`.

## 2026-11-16 — every answer names the commit its graph describes (agent surface, additive)

- `graph.revision` on every envelope: `{ vcs, commit, committed_at, branch, dirty, recorded_at }`, the root's git
  checkout when the graph arrived (`branch` null when detached, `dirty` = tracked files already edited). Null outside
  git, and for a loaded dump that carries none (CART-1884).
- `graph.drift` on every envelope: `{ head, moved, ref, behind, changed, stale, examples }`, read at answer time
  (memoized 5 s). `changed` = files under the root git says differ from the recorded commit (commits since and
  uncommitted edits), `stale` = those that differ from what the graph READ. A detached linked worktree is measured
  against the branch its main worktree has checked out.
- New note `graph-behind` when `stale > 0`, or when a detached checkout is behind that branch. A moved HEAD alone makes
  none: an edit the graph already re-read, then committed, is content the graph has. `graph_info` gains a
  `stale-files` note `{ checked, stale, examples }` over every file the graph read.
- No protocol bump: fields and notes are additive, as with `txn_undo`'s `journal` (CART-1917).

## 2026-11-15 — agent protocol 4: the `sites` verb (agent surface, additive)

- New verb `sites { name, file?, kind?, limit? }`: every SITE where a name is called or referenced, one row per occurrence
  with `file`, 1-based `line` and 1-based character `col` — of an EXTERNAL name too (an engine API with no definition in
  the graph, which `node_find` cannot find and `mentions` answers only per file). A call row carries `status`
  (resolved / refused / external / unresolved), `target`, `why`, the enclosing `fn` and the `qualified` callee
  (`player.set_quick_bar_slot`). Absent when nothing calls or references the name (CART-1933).
- Detect it: `graph.protocol = 4`, `serverInfo.version` `0.4`. Columns are unchanged.

## 2026-11-15 — agent protocol 3: the `selection` verb (agent surface, additive)

- New verb `selection`: the list pane's CURRENT ITEM as the source shares it — an item (`node`, 1-based `line`,
  1-based character `col`) or a non-item row's `kind` (file, statement, group, header, blank, …). It answers
  `shared = false` ("not shared") unless the editor opted in (`symbols.share_selection`) and the row is not
  local-only; the live altitude's runtime values are always local-only. A headless host has no pane: `absent`.
- Detect it: `graph.protocol = 3`, `serverInfo.version` `0.3`. Columns are unchanged from protocol 2 (CART-2101).
- In-process (not the wire): `symbols.selection`, `symbols.subscribe { follow = 'item' | 'selection' | 'cursor', meta, fn }`.
  The list pane's buffer emitted a synthetic CursorMoved for a move made from another window (CART-2097); that
  compat emission is REMOVED (CART-2103, once the 2D-plane research had moved onto `symbols.subscribe`). An in-process
  listener that wants every move — forwarded ones included — follows `symbols.subscribe`; a buffer CursorMoved listener
  now sees only the moves nvim itself delivers.

## 2026-11-15 — `txn_undo` takes the journal id it should undo (agent surface, additive)

- `txn_undo { journal = <id> }` undoes THAT entry: the `subject.journal` txn_apply returned. While a newer entry
  stands it refuses `not-latest` and names the newer entries, so a client never rolls back another client's work
  on the same root. A bad id refuses `unknown-entry`, an entry already rolled back refuses `not-applied` (CART-1917).
- A bare `txn_undo` still works as before (the newest applied entry, whoever applied it) and now adds a
  `not-this-host` note when that entry was not applied by this host.

## 2026-11-15 — LSP position encoding is negotiated (lspserve / the LSP server)

- The LSP server now picks `positionEncoding` from what the client offers: `utf-8` when listed, else the LSP default
  `utf-16`. It used to declare `utf-8` whatever the client offered, so a stdio client without utf-8 read byte columns
  as UTF-16 ones. nvim's own client offers utf-8 and sees no change (CART-2092).
- A position that addresses no character in its line answers `null`; a range that will not convert is left out.

## 2026-11-15 — agent protocol 2: columns are CHARACTERS (breaking for agent clients)

- The MCP agent surface (`tools/mcpserve.lua`) now speaks 1-based **character** columns. Before, a column
  was a 1-based **byte** column, so an agent counting characters misread every column on a non-ASCII line.
  Affected: the `why` verb's `col` argument, and the `col` on its rows (CART-2086, the user's decision).
- Detect it: every answer's `graph` carries `protocol = 2` and
  `positions = { line = 1, col = 1, unit = 'char' }`, and `serverInfo.version` is `0.2`. A client that
  reads or sends columns must check `graph.positions.unit` and refuse a protocol it does not speak.
- A column past the end of its line is a usage error, never clamped.
- Graphs now declare their position base (`pos_base`, 0-based line, 0-based byte column). A graph that
  declares none, from a dump or an MCP server, is stamped once with a warning naming its origin.
