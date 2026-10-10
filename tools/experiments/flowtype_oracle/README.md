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

## TypeScript (`ts/`)

`ts/oracle.js` asks the TypeScript checker (any `typescript` package: `node ts/oracle.js <typescript pkg> <project>`)
for every `x.m(…)`: the resolved declaration and what holds it — `class` / `object` (a method or function-valued
member WITH a body: the callee itself, scored exact), `function`, and the SLOTS scored for coverage only: `abstract`,
`field` (a property holding a function value), `interface`. `ts/score.lua` joins row by row (test files excluded on
the flow side unless `tests`).

MEASURED 2026-10-10 (types ignored by the walker): typescript-language-server — class methods 661 of 759 exact-right
(87.1%), 2 sets containing the truth, 95 no claim, 0 WRONG; interface members 122 of 166 answered. turborepo (an
untouched second corpus) — class 213 exact-right, 92 no claim, 0 WRONG (59 unprobed: calls in test files). The walker
rules each step added: `this` inside C's method is a C, a static is the class's own (methods and fields).

TYPE-SYSTEM-HEAVY corpora (user 2026-10-10): effect (`packages/effect`, 694 src files) — functions 2621 exact-right,
class methods 675, object members 9, 0 WRONG (its `Effect.map`-style `export const map = dual(2, …)` calls name a
VARIABLE: coverage only); arktype — class 331, object 41 exact-right, 0 WRONG. The oracle picks an overloaded
function's IMPLEMENTATION (the declaration with a body). Two walker rules came from these: an anonymous function the
graph has no node for is unknown, never an answer; `x instanceof C` (an `if` or a ternary) NARROWS x in the branch —
a real flow port solved to a fixpoint, not only a verdict filter (otherwise a callback handed on inside the branch
still reaches every class's method).
