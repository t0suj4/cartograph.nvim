# Changelog

Breaking or client-visible changes to cartograph's surfaces. Internal changes are in the git log.

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
