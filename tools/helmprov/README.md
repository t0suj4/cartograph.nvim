# helmprov — Helm's own renderer, with the attribution it already computes kept

`text/template` knows, at every step, which parse node it is executing (`state.at`, for its error messages) and where
that node sits in its template (`Tree.ErrorContext`). Helm renders charts through it (`pkg/engine`) and throws that
attribution away. helmprov is the same render with the attribution recorded (CART-0870):

- every rendered file's text — the same documents `helm template` emits (verified per file, as multisets of documents:
  Helm reorders documents by install order and adds `# Source:` headers afterwards);
- `spans`: every output byte range of a file, attributed to the template node (`file:line:col`, the column 0-BASED,
  Go's own) that wrote it — `text` spans reproduce the template source byte for byte, `action` spans are `{{ … }}`
  output; the bytes an `include` produces belong to the include action;
- `reads`: every `.Values` / `$.Values` chain evaluated, with its node — inside included helpers too.

Run: `nvim --headless -u NONE -l` → `require('cartograph.helmprov').render(<chart>)` builds it on first use with
`build.sh` (offline) and decodes the JSON.

## What is copied, from where, under which license

| Directory | Source | License |
|---|---|---|
| `tpl/` (and `tpl/parse/`, `tpl/internal/fmtsort/`) | Go 1.26.0 `src/text/template`, `src/internal/fmtsort` | BSD-3-Clause, `LICENSE-go` |
| `engine/` | Helm `pkg/engine` at 53dfa521e019 | Apache-2.0, `LICENSE-helm` |

The changes: `tpl/prov.go` (the recorder) and the provenance hooks in `tpl/exec.go` (a counting writer around a
top-level execution, a span per action and text node, a read per `.Values` chain); in `engine/`, imports of the copy,
sprig's `FuncMap` converted to the copy's type, and the spans carried through the engine's `<no value>` removal. With
the recorder unset the executor is the standard library's.
