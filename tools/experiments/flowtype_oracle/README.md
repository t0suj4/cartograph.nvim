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

MEASURED 2026-10-10 on helm (52k lines, 3484 method calls), tests excluded: concrete in-tree 1254 — EXACT-RIGHT 1098
(87.6%), a set containing the truth 27, no claim 126, WRONG 0; interface in-tree 244 — every flow target an implementer's
(18 exact, 88 narrowed, 99 all, 39 none); external calls: 0 wrong. With tests: EXACT-RIGHT 1140 (90.9%), 0 wrong.
The progression (each step scored, none allowed a wrong answer): 709 (walker v1) -> 749 (a pre-pass of the tree's
types; zero values `var x T`, typed consts, conversions T(x) allocate a T) -> 921 (a multi-value truncation bug
`local a, b = x and f()` had disabled the zero-value rule — cartograph's own truncation lint flags it) -> 1063 (a
method's receiver IS a T) -> 1098 (type assertions and one-type `case *T:` filter: a runtime type check).
