# flowtype oracle — score cartograph.flowtype's Go walker against the Go type checker (CART-1621)

The flow analysis ignores every declared type; the type checker knows them. For every method call `x.m(…)`:

- a CONCRETE receiver: the checker's method is the truth — flow's exact answer must be it, a set must contain it;
- an INTERFACE receiver: the checker answers the interface's method; flow names concrete methods, each of which
  must be an implementer's (the oracle lists the in-tree implementers, matched by method NAMES: every package is
  checked in its own universe).

```sh
# 1. export data of the module's packages (the toolchain the module selects — helm: go1.26)
cd <module> && GOFLAGS=-mod=mod GOPROXY=off go list -export -deps -f '{{.ImportPath}} {{.Export}}' ./... > /tmp/x.exports
# 2. the oracle, built with THAT toolchain (export data is version-specific)
cd tools/experiments/flowtype_oracle && GOTOOLCHAIN=go1.26.0 go build -o /tmp/gooracle .
cd <module> && /tmp/gooracle <module> /tmp/x.exports $(go list -f '{{.Dir}}' ./...) > /tmp/x.oracle
# 3. the score (append `tests` to let test files' flows in)
nvim --headless -u NONE --cmd 'set rtp^=.' -l tools/experiments/flowtype_oracle/score.lua <module> /tmp/x.oracle
```

MEASURED 2026-10-10 on helm (52k lines, 3484 method calls), tests excluded: concrete in-tree 1254 — EXACT-RIGHT 709,
a set containing the truth 24, no claim 518, WRONG 0; interface in-tree 244 — every flow target an implementer's
(17 exact, 69 narrowed, 99 all, 59 none); external calls: 0 wrong. With tests: EXACT-RIGHT 898 (71.6%), 0 wrong.
