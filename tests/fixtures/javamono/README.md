# javamono — java imports past a Maven module segment (CART-0675)

Driven by `tests/javaimports_spec.lua` through `ts.extract`.

| Root | Import edges | What it pins |
|---|---|---|
| `single/` | 1 | control: the conventional `src/main/java/` root |
| `multi/` | 1 (was 0) | the module segment: `mod_core/src/main/java/...` |
| `negative/` | 0 | same FQN in two modules refuses; `com/other/core/Registry.java` is not a tail match; `java.util.List` stays frontier |
| `ownroot/` | 1 | hive's `src/java` layout; the importer's own copy wins; two foreign copies refuse |
| `rootcopy/` | 0 | a class at the index root is a candidate like any other, not the importer's own |
| `single/src/main/java/com/example` | 1 | an index root inside a source root (the shorter-suffix fallback) |

`single/`, `multi/` and `negative/` are copies of the design corpus's
`examples/java-monorepo-layout` and `examples/negative/java-monorepo-layout`
(2026-09-24). Their source comments describe the defect as it was before the fix.
`ownroot/` and `rootcopy/` are ours.
