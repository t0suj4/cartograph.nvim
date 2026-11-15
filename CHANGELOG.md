# Changelog

Breaking or client-visible changes to cartograph's surfaces. Internal changes are in the git log.

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
