# mentions-unparsed-frontier — a closable frontier looks like a real one

Reproduces **F19** from
[`../../agent-surface/08-answers-that-hide-their-cause.md`](../../agent-surface/08-answers-that-hide-their-cause.md).

One Java class and, in `with-bundle/`, one vendored `*.min.js`. `*.min.js` files
are kept as opaque frontier modules by name
(`lua/cartograph/providers/treesitter.lua:4685`, `config.unparsed = true`), so the
graph has `unparsed_files = 1`. The bundle defines `vendorMap`. Nothing defines
`ServletContainerFactory`.

Distilled from a web-client module whose 9 unparsed files are vendored
jquery/leaflet/ol bundles. There, every `mentions` query for a Java server-side
name came back `frontier`, and an agent had to fall back to `grep` to conclude.

## Expected (measured 2026-10-02, cartograph `38caeaa`)

| # | Query | `with-bundle/` today | `no-bundle/` today | Want (`with-bundle/`) |
|---|---|---|---|---|
| 2 | `mentions ServletContainerFactory` | `frontier`, evidence `{unparsed_files: 1, indexed_files: 1}` | `absent` | **`absent`**: the name is not in the bundle's bytes, so the unparsed file cannot mention it. Evidence names the file and says it was byte-scanned. |
| 3 | same, `from` = `MapView.java` | identical to #2 | `absent` | as #2 |
| 4 | `mentions vendorMap` | `frontier`, **byte-identical evidence to #2** | `absent` | **stays `frontier`** (GUARD), now naming `vendor.min.js` as the file the name occurs in |
| 5 | `mentions MapView` | 1 row | 1 row | unchanged (control) |

The defect is row 2 against row 4. A question the tool can close and a question
it cannot are given the same answer with the same evidence. The unparsed files
are listed in the envelope's `graph.frontier.examples`, but not in the
absence's own `evidence`, so nothing ties the frontier to the file that causes it.

Row 4 is why the ask is a byte scan and not "scope the frontier by language". In
an Eclipse RAP client, Java code can name a JavaScript function by string, so a
Java-language filter could wrongly turn row 4 into `absent`.

## Run

```sh
cd with-bundle   # or no-bundle
nvim --headless -u NONE -l ~/git/cartograph.nvim/tools/mcpserve.lua . < ../queries.jsonl
```
