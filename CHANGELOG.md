# Changelog

Breaking or client-visible changes to cartograph's surfaces. Internal changes are in the git log.

## 2026-11-17 — Java: receivers the expression itself types — JDK final-method chains, ternaries, casts (graph; cache v332)

- `getClass().getName().compareTo(..)` is the JDK's String.compareTo (getClass is final, Class is final): external,
  no longer a name join over every project compareTo (908 calls on hive's thrift api).
- A parenthesized, ternary or cast receiver is typed by its terms — `(std ? STANDARD_FACTORY : TUPLE_FACTORY)
  .getScheme()`, `((IndexRequest) r).indexSource()`, `(new Client(p)).recv_x()`: one target resolves, several are
  refused over exactly the dispatch set (hive: 908 getScheme calls refused over 2 candidates, not 1,816).
  elasticsearch server: 43 calls resolved; 2 wrong same-file picks withdrawn (`((BytesStream) s).bytes()` had linked to
  an unrelated static bytes(XContentBuilder)).

## 2026-11-17 — Java: a method inside an anonymous class body is reached only from inside it (graph; cache v331)

- A call outside an anonymous or enum-constant body no longer resolves to a method declared in it (such a method is
  keyed to the named class around it, `Outer::execute`): it is refused `blocked`. elasticsearch server: 901 calls,
  e.g. `masterClient().execute(..)` had linked to an anonymous `ClusterStateUpdateTask.execute`.
- A `this` / implicit-this call inside such a body reaches that body's own member first (it shadows the outer
  class's); several of the name there are overloads and refuse. server 122, hive 10, libs 8.

## 2026-11-17 — graph_info: how much of each language the mention index covers (agent surface, graph; cache v330)

- `graph_info` carries a `mention-index-coverage` note: per language, the definitions whose name the mention index
  skips, by rule — `short`, `stdlib`, `shape`, `off` (a language that opted out), `unexplained` (no rule; expected 0).
  elasticsearch libs java 685 of 13,014 (157 short, 528 stdlib); hugo go 505 of 8,680; jquery/src 44 of 392.
- A file with definitions but no function body (a java record with no methods) now has a mention-index entry for
  their names; `mentions` lists it.

## 2026-11-17 — Java: overloads in the caller's own file are decided by argument count (graph; cache v329)

- The arity pass now also reads a same-file refusal whose candidates are overloads of one class: `new x_result()`
  beside `x_result(int)` and a copy constructor reaches the no-argument one. Overloads that share a count (they
  differ by parameter type) stay refused, as do overloads spread over two same-named nested classes.
- A record's implicit canonical constructor carries its components as parameters. It had none, so the pass read it
  as taking no argument: `new E(Set.of(..))` linked to a declared `E(List)` constructor, and now it is refused (both
  take one argument).
- A method inside an anonymous or enum-constant body is no candidate of a call outside that body, and a call inside
  one is not decided by either same-file pick (the anonymous class may inherit the name).
- A class spelled qualified, `new B.K()`, `new B.K().m()` or a variable declared `B.K<..>`, is decided by its head: an enclosing
  class or its member gives the path; a head no enclosing scope names is another file's class, and the call is not
  matched to this file's `K` (`settings.build()` on a `Settings.Builder` had linked to the file's own `Builder`).
- hive standalone-metastore: 3,910 calls resolved; elasticsearch server 10,151 (plus 59 record constructor calls, 7
  wrong record picks withdrawn), libs 1,039 (plus 30, 10 withdrawn).

## 2026-11-17 — Java: a call into one of many same-named nested classes resolves by lexical class (graph; cache v326)

- A Java method node carries `cpath`, the dotted path of its class (`ThriftHiveMetastore.a_args._Fields`), and a call
  that names a class through `this`, implicit this, a written class name or `new X()` carries the path of the class
  it means: the member type of the innermost enclosing class that declares it. A same-file refusal takes the one
  candidate on that path.
- It still refuses overloads on one path, a lookup that passes a class with a supertype clause or an anonymous class
  body, a qualified spelling (`new B.K()`, `B.K.f()`), and a candidate with no path. hive standalone-metastore: 1,722 calls resolved (1,148 `_Fields.findByThriftId`, 574 `new X()` in the thrift
  Processor / AsyncProcessor); elasticsearch server 28, libs 0. Every one was checked against an independent scan of
  the source's class nesting; nothing else moved.

## 2026-11-16 — Java: library supertypes no longer stand in for project classes (graph; cache v325)

- A supertype imported from the JDK (`import java.util.Map.Entry; class E implements Entry`) keeps its row but is
  marked external, so the project's own `Entry` classes stop gaining `E` as an implementer.
- A supertype whose import binds to no file in the tree (log4j's `AbstractStringLayout.Builder`, a test framework
  outside the root) is marked `ext` on its row and skipped by every hierarchy reader. A call keyed by such a class
  (`super.visitField()` on an ASM `ClassVisitor`) is external instead of joining a project method by name.
  elasticsearch/server: 471 wrong joins withdrawn, 184 of them a `super.m()` that had resolved to its own override;
  libs: 17 (CART-2079).

## 2026-11-16 — Java: a nested class extending a same-named nested class inherits through it (graph; cache v324)

- `class Builder extends FieldMapper.Builder` (and `implements Outer.Same`) now records its supertype. Its inherited
  methods resolve to the outer class's nested class (`FieldMapper.Builder` → `Mapper.Builder::build`).
  elasticsearch/server: +38 resolved; libs: +7. Nothing else moves (CART-2080).

## 2026-11-16 — Java: an inherited method is found through the right class's parent (graph; cache v323)

- When a call on a class must walk up to a parent class, the class is now the one its name means from the calling
  file: the caller's own file, its import, or the same package. An imported `p.a.Bound` no longer reaches the parent of
  an unrelated nested `Holder.Bound`. A nested subclass whose simple name collides elsewhere now finds its parent:
  elasticsearch/libs +21, server +6 (CART-1964).

## 2026-11-16 — Java: nested types and lambda parameters are typed correctly (graph; cache v322)

- A receiver declared as a nested generic type (`ImmutableOpenMap.Builder<K, V>`) is typed as that nested class. It
  is the outer class's nested class, not the caller's own class of the same name, when the tree has the outer
  class's file.
- An untyped lambda parameter (`(handlers, x) -> handlers.addMethod(…)`) no longer borrows the type of a field it
  shadows. A nested JDK type (`Map.Entry`, `System.Logger`) stays external instead of joining a project class of the
  same simple name.
- elasticsearch/server: +253 resolved, 32 retargeted to the right `Builder`, 67 wrong joins withdrawn (CART-1963).

## 2026-11-16 — `type-cycles` finds JPA relationships traversed from both ends (graph field; cache v321)

- `data.typerefs` rows now record each field's JPA relation (`jpa`, `mappedby`) and its Lombok exclusions (`xeq`,
  `xts`). A row with an empty `field` records the structural methods Lombok generates for the class (`lombok`).
- `type-cycles` reports `bidirectional`, the mapped relationships (`@OneToMany(mappedBy = "g")` ↔ `g`), and
  `bidirectional_traversed`, where the same `equals` / `hashCode` / `toString` reads both ends. A read is either
  hand-written code or Lombok-generated (`@Data` on an entity, the classic case). Such a method recurses forever on
  any populated instance. Tested on fixtures only: no JPA corpus is available on this machine (CART-2120).

## 2026-11-16 — C++ calls on a global variable are typed (graph; cache v320)

- `g_settings->get(...)`: a receiver that is a global variable now resolves through the global's declared class
  (`qhow = 'global'`). luanti: +111 resolved. 7kaa: +295. Inside a member function this applies only when the
  class and all its bases are declared in the tree, since a member of the same name would shadow the global.
- C / C++ module variables carry `tcls` / `tptr`: the declared class and its pointer depth (CART-2119).

## 2026-11-16 — C / C++ reference, array and double-pointer parameters are listed (graph; cache v319)

- A function's `params` (and `param_types` on its row) now include parameters declared as `const Foo &r`,
  `Foo &&rv`, `int a[]` or `Foo **pp`. They were missing, so a C++ function could look as if it had fewer
  parameters than it does. luanti: 1,256 functions affected. Calls and edges are unchanged (CART-2118).

## 2026-11-16 — the Java type graph, and a `type-cycles` tactic (graph field; cache v318)

- Java fields record the class names their type refers to, including generic arguments and array elements:
  `data.typerefs` rows `{ typename, field, refs, static }`.
- Toolbelt tactic `type-cycles` reports recursive type components, which `equals` / `hashCode` / `toString` read a
  field that closes a cycle, and which cycles one of those methods traverses all the way round. Counts are a lower
  bound: a type name two files define is dropped. On elasticsearch/server, 9 types meet that precondition for
  `equals` / `hashCode` and 1 for `toString`, all tree- or chain-shaped, so none is a back-pointer bug (CART-0697).

## 2026-11-16 — declared types are stored, and node rows show them (agent surface + graph; cache v317)

- C, C++, Go and Rust record each binding's declared type exactly as written. A module variable's node carries `ty`
  (`const Foo*`, `*Foo`, `&Bar`). A function's node carries `ptypes`, aligned with `params`, with `''` where none is
  written. An inferred type (`auto`, `:=`, an untyped `let`) is not recorded (CART-0696).
- `node_find` / `node_at` rows gain `type` on such a variable and `param_types` (`{ name, type }`) on such a function.
  Rows for other nodes are unchanged.
- Resolution is unchanged. Cache +0.2-0.5%.

## 2026-11-16 — Erlang / Haskell: calls on a multi-clause function's last line have their caller (graph; cache v316)

- In a function with several clauses (Erlang) or equations (Haskell), a call on the last line past the first
  clause's end column belonged to no function, so it had no caller edge. ejabberd: 156 calls; ghc compiler/GHC/Core:
  135. Nothing resolves differently (CART-2115).

## 2026-11-16 — C++ name matches that contradict the receiver's declared class are withdrawn (graph; cache v315)

- A C++ call resolved by name into a method of a class unrelated to its receiver's declared (or enclosing, or field)
  class is now external, `ext.why = 'typed-receiver'` with the declared type. Unrelated means not that class, not an
  ancestor, not a descendant. luanti/src: 70 withdrawn, e.g. irrlicht `IImage::fill` had linked to a project
  `MeshMakeData::fill`. When the ancestry is not fully in the tree nothing is withdrawn (CART-2114).
- typedef / `using` aliases of a class are recorded (`data.typealiases`), so a receiver declared through an alias is
  its class's.

## 2026-11-16 — C++ inheritance is recorded (graph; cache v314)

- A C++ class's base classes are `data.extends` rows, one per base. A typed member call (binder, field, implicit this)
  whose class does not define the method resolves to the nearest base that does. Two bases at one level that both
  define it are refused. luanti/src: +466 resolved (CART-2116).
- Lint's dead-function alibi (`overridden-by`) now covers C++ overrides of a base method.

## 2026-11-16 — C++ member-field receivers are typed too (graph; cache v313)

- `m_env->step()` inside a member function, where `m_env` is a field the class declares (usually in its header), now
  resolves through the field's declared class, as a declared local does. `this->m_env->step()` too. luanti/src: +542
  resolved, `qhow = 'field'` (CART-2112).
- `data.fieldtypes` gains C++ rows `{ typename, field, ftype, ptr }`, where `ptr` is the pointer depth. A call record
  carries `rfld` (owner class, field, operator).

## 2026-11-16 — a chain whose head only a profile resolves is typed on the first open (graph; cache v311)

- `x.querySelectorAll(s).forEach(…)`, where the node profile resolves `querySelectorAll` and declares its return type
  `NodeListOf`, now resolves `forEach` to `NodeListOf.forEach` when the graph is first built. Before, only a later
  refresh resolved it. converse.js: +3. A cold graph and a refreshed one now agree (CART-2110).

## 2026-11-16 — C++ member calls are typed by their receiver's declared class (graph; cache v310)

- A C++ call `x->m()` / `x.m()` whose receiver is a parameter or local declared as a class, a `this->m()`, or a bare
  `m()` inside a member function now resolves to that class's `m` when exactly one definition of it exists, `prov =
  'recv'`. Only calls unresolved before are affected; nothing resolved is retargeted. luanti/src: 15,196 -> 16,878
  resolved. 7kaa: 13,970 -> 16,228 (CART-2111).
- Typed only when the operator fits the declaration (`->` on a pointer, `.` on a value or reference): `->` on a class
  value is its `operator->`. A template parameter, `auto`, `std::` types, templates and overloads key nothing.
- A call record carries `rcls`, the receiver's class.

## 2026-11-16 — `prov = 'recv'`: a resolution the receiver's TYPE keyed is no longer `base` (graph field; cache v309)

- A call resolved by an exact match on a key the language spec qualified from the receiver's inferred type is
  `prov = 'recv'`. The cases are a declared binder type (java / go / rust / zig / php), the enclosing class of an
  implicit this / self / `$this` / super (java / php / ruby), or a `new T()` receiver. `base` now means a name
  matched: a bare name, a class the source wrote (`T::m`, `Class.m()`), or a typed key that missed and landed by its
  tail. Targets are unchanged. elasticsearch/libs: base 16,669 -> base 6,656 + recv 10,013. ripgrep: 504 recv.
  luanti/src: 0 (CART-0695).
- A call record carries `qhow`, the mechanism: `binder` / `self` / `super` / `ctor` / `written`. `edges_callers` rows
  and `census.by_prov` show the new value. No protocol bump: `prov` was always an open set of resolver names.
- Cache VERSION 309: every cached graph re-extracts once.

## 2026-11-16 — a polyglot root applies a profile PER BOUNDARY (agent surface + graph fields, additive)

- A root whose build markers below (up to two directories down: `rebar.config`, `package.json`, …) add a language
  the upward probe lacks is POLYGLOT: each file takes the profile of its nearest boundary declaring its language. The
  brotardcast parent opened as one root resolves 64,757 calls, up from 39,576 (+25,181, all `stdlib`: OTP on the
  ejabberd side, node on converse.js) (CART-2108).
- The graph carries `profiles` (the boundaries: dir, source user / computed / default, markers, language -> profile);
  `profile` on such a graph is a display summary of the runtimes (`node+otp`).
- `graph.profile` gains `boundaries` on a polyglot root; `below` keeps the shapes NO boundary applies (upward wins for
  a language). `graph_info` adds a `profile-boundaries` note.
- Cache: a polyglot root's manifest carries the boundaries' canonical key and is gated on it: a marker added or removed
  below is a clean miss. A root whose markers below add nothing (51 of 51 cached roots but hugo) keeps its key, its
  graph and its envelope byte for byte. No VERSION bump, no protocol bump.

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
