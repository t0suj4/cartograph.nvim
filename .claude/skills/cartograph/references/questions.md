# Before you do it by hand: question → instrument

**The standing rule** (user, 2026-09-26): *finding what cartograph can do for us is a standing rule, and every
discovery about its capabilities is written down, so nobody does it by hand the next morning.*

Three habits make that true:

1. **Look here first.** Before writing a throwaway script, find the question below. Many of the tools are
   phrased as the question they answer (their first header line).
2. **A throwaway that answers a question twice becomes a tool** — or goes under
   [Done by hand, not yet a tool](#done-by-hand-not-yet-a-tool) with its ticket, so the next person knows it
   was needed and what it found.
3. **Every new tool or flag gets its line here in the same commit.** `tests/questions_index_spec.lua` fails when a
   `tools/*.lua` appears nowhere in this file — the older capability inventory (a memory file) was a rule alone
   and stopped being updated for a month; this one is fenced.

All commands run from the repo root as `nvim --headless -u NONE -l tools/<tool>.lua …`; the argument lists below are
the tools' own usage lines. Corpus names come from `tools/corpora.lua`.

## Is the graph right? Did something drift?

| Question | Instrument |
|---|---|
| Do all corpora still produce their pinned counts / the saved graph, and do the oracles agree? | `tools/matrix.lua [<corpus>...] [--cols counts,struct,dfpar,fold,silent,cache,par] [--save] [--jobs N]` |
| One corpus against its pin and baseline | `tools/gate.lua <corpus> [--save]` |
| WHAT KIND of node moved vs the baseline (a grammar upgrade reading locals as functions shows as `+ function bare`) | `tools/gate.lua <corpus> --kinds` (graphdiff.by_kind) |
| Did the DF distribution move? (a derived projection counts/struct never compare) | `tools/matrix.lua <corpus> --cols dfshape` — vs the distribution the baseline recorded at `--save` |
| Does the expression IR read what dataflow reads (the two-implementation self-gate)? | `tools/exprcensus.lua <dir> [--lang <l>] [--show <class>]` — class `match` = a match test the IR cannot see from one row (named, not a defect) |
| What did extraction SEE and not RECORD? Which constructs leave no fact in the graph (the L2 loss)? Is an absence "the code does not do that" or "the schema had no slot"? | `tools/lossreport.lua <corpus|dir> [--lang L] [--top N] [--show TYPE]` — maximal dark subtrees by type and position, staged (extraction vs after the post-passes), a WITNESS line that must decline calls. ejabberd/src: -spec 3391, record constructs, macro args, data tuples, exports; converse.js: imports (no site on import edges), TS declarations |
| Which inferred edges does the code contradict (fabrication)? | `tools/fabcensus.lua <corpus|path> [--show <bucket>]` |
| REVERSE: which REFUSED calls could the calling file's own import/require binding settle? (a work list) | `tools/fabcensus.lua <root> --backward` — buckets settles / settles-by-shape / several / via-reexport / bound-lacks |
| Which files USE another file's export (or global) with no require of it — working by load order? (a work list) | `tools/userequire.lua <corpus>`; lint rule `use-without-require` (info, suggestive) |
| Which captures and query slots does each language bind, and which slots could a language fill that it does not (PROJECTING)? | `tools/specaudit.lua --capabilities [--top=N]` (no corpus needed; rediscovers CART-0692) |
| Same corpus, same graph twice? (per layer) | `tools/determinism.lua <corpus|dir> [--runs N]` |
| Does a data reader agree with an independent implementation, row by row? | `tools/oraclejoin.lua <join> [--repos a,b,…] [--show N]` |
| Does a module compare node types its declared languages lack? (the language fence) | `tools/langaudit.lua [--all]` |
| What can this tree NOT be falsified by? Which promises has any test triggered? | `tools/instrumentcensus.lua lines` · `tools/refusalcensus.lua /tmp/cov.txt` |
| Construct the input that breaks a promise instead of searching for one | `tools/counterexample.lua [--keep]` |
| Can cartograph refactor itself and stay green? | `tools/selfrefactor.lua [--dir D] [--n N]` |

## The grammar

| Question | Instrument |
|---|---|
| What tree does tree-sitter really build (field names, anonymous tokens)? Did a grammar upgrade change it? | `tools/tsdump.lua <lang> <file|-> [--named] [--view] [--parser <so>] [--vs <so>]` (bob keeps the previous nvim's parsers for `--vs`) |
| Does the parse view (lua dialect, scheme `@`, cpp `= default`) fix a misread? | `tools/tsdump.lua <lang> <file> --view` |
| "Walk a corpus and count that" without writing a file | `tools/probe.lua <corpus|dir> --expr '<chunk>'` |

## Is it already here? (ask BEFORE implementing something or searching elsewhere)

| Question | Instrument |
|---|---|
| Does the tree already contain this functionality, compiled out by default? How is it turned on? (erlang + rebar + autoconf) | `tools/features.lua <root> [--all]` — configure switch and default -> rebar variable -> macro / dependency -> the `-ifdef` code it compiles out, with line ranges and functions. ejabberd: SIP (~1,400 lines, `--enable-sip`), Elixir, roster gateway workaround, multihost SQL schema |
| Is a missing dependency or behaviour producer really missing, or just behind a disabled feature? | `tools/producers.lua <root>` marks each one `[compiled out by default: MACRO — ./configure --enable-x]` |

## What does the tree reach for? (environment, dependencies)

| Question | Instrument |
|---|---|
| What does a vendored artifact reach for, and does anything supply it? | `tools/surface.lua` |
| Distil a surface into an L2 environment profile | `tools/nodedistill.lua`, `tools/npmdistill.lua <corpus|dir>`, `tools/domdistill.lua`, `tools/erldistill.lua` (now also OTP behaviour callbacks), `tools/hrldistill.lua --from <dir-or-.hrl>`, `tools/dtsread.lua` |
| The Maven build layer, and the java import resolver against package declarations | `tools/pomtree.lua <repo>…`, `tools/javaimports.lua <repo>…` (⚠ `tools/mavenpoms.lua` DOWNLOADS from Maven Central — network) |
| Does the stage partition carry the JS runner globals? | `tools/stagefit.lua <corpus|dir> [--decl <key>]` |
| A fact the tree lacks: who CONSUMES it (other repos' manifests), where the dependencies it selects are on disk, who produces the callbacks its -behaviour lines owe — each cited by the selecting line | `tools/producers.lua <root> [--search DIR]... [--lib DIR]...` (CART-1118; finds, attaches nothing) |

## Dead or alive?

| Question | Instrument |
|---|---|
| Which functions are dead / possibly dead, and why is this one alive? | lint `dead-confined`, `dead-function` (MCP `lint_run`, `:CartographLint`); the alibi verb (`lint.alibi(store)`, MCP `why`) — inheritance contract both ways since CART-0714; erlang `-behaviour` callbacks (the tree's `-callback` + the otp-api profile's `behaviours`, alibi kind `behaviour-callback`) since CART-1117 |
| Which records does an erlang tree declare and never use; which fields are never named? | `tools/erlrecordcensus.lua --unused` |

## Across the wire: the XMPP triple (ejabberd × payload spec × converse.js)

| Question | Instrument |
|---|---|
| Which client function's IQ request reaches which ejabberd handler CLAUSE, with what bound across the wire? | `tools/xmppmerge.lua [--rows]` |
| Seen from the server: per handler its namespaces, per clause reached / shadowed / rejected / unasked | `tools/xmppmerge.lua --server-view` |
| Is the absent-attribute rule still the generated decoder's? (oracle over every `decode_*_attr_*`) | `tools/xmppmerge.lua --check-absent` |
| Every registered IQ endpoint (both carriers), its handler, and the request each clause ACCEPTS as XML | `tools/xmppserver.lua [<server-root>] --rows` |
| What each handler SENDS, as a term (complete / partial / opaque) and whether it is on the wire | `tools/xmppserver.lua --sends [--rows]` |
| What the client BUILDS: every `stx` template as an element tree with holes and namespaces | `tools/stxcensus.lua <dir> [--all] [--stanzas] [--json <out>]` |
| What `xmpp_codec.spec` declares, and its consistency oracles (records, OTP's own parser) | `tools/xmppspeccensus.lua [--rows] [--erl]` |
| Every record reference against its module's scope, with dependency roots; the compiler as oracle | `tools/erlrecordcensus.lua [--root DIR] [--app NAME=DIR] [--lib DIR] [--rows] [--erl]` |
| Registered vs declared namespaces, joined by URI (the older CONFORM) | `tools/rootjoin.lua [<left>] [<right>] [--rows]` |
| Could we emit a client for this endpoint, and if not, who blocks it? | `tools/endpointcensus.lua <corpus|dir> [--rows]` |
| Who implements and who calls each gRPC method across languages? | `tools/grpcjoin.lua [<corpus>|<dir>]` |

## Templates, clones, the algebra

| Question | Instrument |
|---|---|
| Other implementations of one concept, incomplete ones included | `tools/variants.lua <corpus|dir> --query <name>` |
| What should a template be able to say? What do container members share? | `tools/divergecensus.lua <corpus|path>`, `tools/membercensus.lua <corpus|dir>` |
| The helper signature of every near pair; does the pairwise lgg compose? | `tools/hocensus.lua`, `tools/familydiff.lua <corpus|dir>` |
| Which syntactic positions does the minting rule not cover? | `tools/mintcensus.lua <corpus|dir> [--lang L]` |
| Drive the vendored algebra with real IR; how much of it is absorbed; has the vendored copy drifted? | `tools/algebradrive.lua`, `tools/elemdrive.lua`, `tools/algebraledger.lua`, `tools/vendordrift.lua [--gate]` |

## Performance

| Question | Instrument |
|---|---|
| Every shipped performance lens over every function, with its denominator | `tools/perfscan.lua <root> [--files <pat>]` |
| Redundant idempotent setup, and where one copy would do | `tools/redundancy.lua <root>` |
| What a file's references resolve to (fact cost); profile-guided index-a-scan | `tools/factcost.lua <file.lua>…`, `tools/idxprofile.lua <module> <file.lua> <workload.lua>` |
| Does `pattern_degree` agree with Lua's own matcher? | `tools/patternjoin.lua ['<pattern>' ...]` |
| The runtime tier from outside the process (OpenTelemetry spans) | `tools/otelobserve.lua <corpus|dir> --spans <file>` |
| How do real YAML/XML implementations decide ambiguous input? | `tools/ambiguity.lua [--write] [--joins]` |

## Making a deliberate exception (derive by default; scope an override)

| Question | How |
|---|---|
| How do I override a DERIVED answer for one tree only? | `setup{ scoped = { [path prefix] = { key = value } } }`, read by `config.for_root(root, key)` (longest prefix wins, global fallback). User rule: derivation over hand-maintained lists; exceptions only through scoped configuration. Keys today: `behaviour_suppliers = 'derived' \| 'otp'` |

## In-process: library calls that answer a question

| Question | Call |
|---|---|
| What does this function read from its argument? (erlang clause heads as read sets) | `expr.of(store, fn_id).heads` — each fact a binding with a path or a constant |
| One multi-clause erlang function as one record, arms as alternatives | `expr.of(store, fn_id).fl` (stitched; `flow.successors(fl)`) |
| What XML a record pattern accepts | `xmppspec.lift(facts, spec)` + `xmppspec.render(V)` |
| What value (term) an erlang expression builds | `erlterms.term(node, src, ctx)` + `erlterms.status(term)` |
| Run the enrichment passes the open path runs (xlang, sql, frameworks, k8s/proto, erlreg, db) over extracted data | `require('cartograph.postpass').run(data, { say = fn, skip = { name = true } })` — `PASSES` is the one declared sequence |
| A module's visible records; its record uses; unused records/fields | `erlrecords.new{…}:scope(f)`, `:uses(f)`, `:check(f)`, `erlrecords.usage(E, files, root)` |
| Every stx template in a directory (namespaces harvested first) | `stx.scan(dir, {all})`, `stx.templates(src, {resolve})`, `stx.inventory(recs)` |
| Server endpoints, a handler's heads, its sends | `xmppserver.endpoints(data)`, `.reads(store, h)`, `.sends(dir, {E, spec})` |
| The whole client × server merge, both points of view | `xmppmerge.merge{client, server, spec}` → `.rows`, `.server` |
| unify / join / instantiate terms | `require('cartograph.algebra').load()` → `A.unify`, `A.join`, `A.instantiate` (⚠ `join` generalizes = keeps what is SHARED; `unify` combines — MERGE is `unify ∘ compose`) |

## Done by hand, not yet a tool

Each of these was answered by a throwaway on the date shown. Promote it, or keep its ticket moving — do not
write it again from scratch.

| Question | What was found | Ticket |
|---|---|---|

Closed 2026-09-26 (promoted to a tool): behaviour callbacks read as dead → the `behaviour-callback` alibi (CART-1117); the send-site term census → `tools/xmppserver.lua --sends` (holes by step);
producer discovery → `tools/producers.lua`; nodes gained/lost by kind → `tools/gate.lua --kinds`; the df distribution
before/after → the matrix `dfshape` column.

## Backlog: tools not yet phrased as a question

Every other `tools/*.lua`, with its own first header line (generated 2026-09-26). Move a tool up into a question
section when you use it; the fence only requires that each appears somewhere in this file.

- `tools/ablate.lua` — ablate — "does this resolution pass earn its keep?" The measure-first
- `tools/agentq.lua` — agentq — THE AGENT ENVELOPE, phase 0 (CART-0143, under CART-0142's T3).
- `tools/annotcensus.lua` — ANNOTATION CENSUS ([[CART-0240]]): what is actually IN a corpus's type
- `tools/answerkey.lua` — THE ANSWER-KEY LOOP (CART-0265, step 4 and the last leaf of the CART-0260 arc).
- `tools/apifetch.lua` — apifetch — OFFER to obtain an environment's own API description, and distil it
- `tools/assigndef.lua` — assigndef — WOULD MINTING A DEF FOR AN ASSIGNMENT-BOUND CALLABLE EARN ITS KEEP?
- `tools/bandlinkgate.lua` — bandlinkgate — the F1 RECALL DIFF (federation). Proves the cross-band linkage
- `tools/bandlocality.lua` — bandlocality — federation's VIABILITY number (merging-strategies Tier 2). If we
- `tools/bandrecall.lua` — bandrecall — federation's RECALL gate (merging-strategies Tier 2). bandlocality
- `tools/bandruby.lua` — bandruby — F1 Ruby-linkage scoping (merging-strategies / federation). Ruby is
- `tools/bench.lua` — The measurement bench: the bootstrap + timing/memory discipline every
- `tools/bufsweep.lua` — bufsweep — the BUFFERING sweep ([[cartograph-thin-index]]). The peak/IPC matrix showed the
- `tools/callargs.lua` — callargs — is c.args derivable from c.argv? ([[cartograph-thin-index]] lossless narrowing).
- `tools/callcolsdecide.lua` — callcolsdecide — the callcols-DEFAULT-ON decision matrix ([[cartograph-thin-index]]).
- `tools/callcolslive.lua` — callcolslive — the LIVE-PATH parity gate for config.callcols_store (record-fold
- `tools/callfields.lua` — callfields — measure the CALL record's field occupancy + LOSSLESS narrowing opportunity
- `tools/callgate.lua` — CALLCOLS PARITY GATE (per-corpus CLI) — the resident-store faithfulness fence.
- `tools/callmatrix.lua` — callmatrix — the ACCESS-MODEL micro-matrix (record-fold arc, brick 3,
- `tools/callmigrate.lua` — callmigrate — the CALL-store migration work-list (record-fold arc, brick 3,
- `tools/callparity.lua` — CALLCOLS PARITY — the faithfulness gate for the resident columnar call-store
- `tools/characterize.lua` — CHARACTERIZE, HEADLESS — the agent entry point for CART-0262. No nvim session, no
- `tools/classmatch.lua` — SHAPE-MATCH MEASUREMENT (CART-0590) — the harness that produces the numbers
- `tools/clones.lua` — CLONES: structural duplication across a tree, as one command.
- `tools/conflicts.lua` — conflicts — triage the cartograph-vs-lua-ls DISAGREEMENTS with source
- `tools/consumers.lua` — Shape-consumer roster over a Lua tree. The Encapsulate Field checklist:
- `tools/ctrlcensus.lua` — ctrlcensus — WHICH CONTROL FORMS DOES flow FAIL TO OPEN, per language (CART-0363).
- `tools/demandcalls.lua` — demandcalls — MEASURE what on-demand call materialization costs in fidelity
- `tools/dfconsumers.lua` — Tool 2 (df-strangler step 5): the df-CONSUMER CENSUS + the migration verdict.
- `tools/dfgate.lua` — The df / flow PARITY GATE (per-corpus CLI).
- `tools/dfmat.lua` — dfmat — gate ON-DEMAND DATAFLOW materialization ([[cartograph-thin-index]]). df/flow are
- `tools/dfparity.lua` — df / flow PARITY CHECK — the shared core behind tools/dfgate.lua (the
- `tools/distill.lua` — tools/distill.lua — distill a runtime's stdlib surface into an L2 environment
- `tools/docaudit.lua` — The DOC AUDIT — validate cartograph's OWN user documentation against the
- `tools/dogfood.lua` — dogfood — cartograph on cartograph, headless (CI / pre-commit). Extracts our
- `tools/dumpcompare.lua` — dumpcompare — the OFFLINE disagreement harvest ([[cartograph-goal-vm-linker]] the
- `tools/eagergate.lua` — eagergate — the BAND-LOCAL EAGER-RESOLUTION probe (federation, [[cartograph-band-
- `tools/edgegate.lua` — edgegate — the faithfulness gate for the resident columnar EDGE store
- `tools/f2determ.lua` — f2determ — the CACHE-DETERMINISM probe (F2 step 3 gate, [[cartograph-thin-index]]).
- `tools/f2gate.lua` — f2gate — the FEDERATED-RESOLUTION reproduction diff (federation F2, [[cartograph-band-
- `tools/f2graphdet.lua` — f2graphdet — GRAPH-level cache determinism ([[cartograph-thin-index]], F2 step 3).
- `tools/f2peak.lua` — f2peak — the F2 PEAK-WIN measurement (federation, [[cartograph-band-federation]] /
- `tools/factoriodistill.lua` — factoriodistill — distill Factorio's runtime-api.json into an L2 profile
- `tools/fatguard.lua` — fatguard — the FAT-RECORD migration meter (leaping the wall, [[cartograph-thin-index]]).
- `tools/flowanat.lua` — flowanat — decompose what the BULK of flow/df actually is (the wall-leap follow-up,
- `tools/foldstratdiff.lua` — foldstratdiff — CROSS-STRATEGY parity for the fold-emit knob ([[cartograph-thin-index]]).
- `tools/gaps.lua` — gaps — the single-project RESOLUTION work-list: the unresolved callees ranked
- `tools/gatepredict.lua` — GATE PREDICTION: from a diff, which of the 37 corpus gates CANNOT move?
- `tools/gatescore.lua` — GATE SCORE: replay history against the predictor and look for REFUTATIONS.
- `tools/gen.lua` — The GENERATED-CODE fuzz bed: synthesize a corpus with a seeded generator,
- `tools/genmatrix.lua` — genmatrix — COMBINATORIAL control-form generation (CART-0405).
- `tools/gramdiff.lua` — gramdiff — THE PORTING QUESTION, ASKED OF A GRAMMAR (CART-0666).
- `tools/gridgate.lua` — gridgate — run the COMBINATORIAL grid (tools/genmatrix.lua) past the keyless oracles.
- `tools/guards.lua` — Development guards, self-applied: the CI-shaped dogfood run.
- `tools/harvest_scan.lua` — harvest_scan — the disagreement harvest AT SCALE ([[cartograph-goal-vm-linker]]).
- `tools/harvest_ts.lua` — TS-analyzer disagreement harvest: cartograph's ts.extract vs the TypeScript
- `tools/holecensus.lua` — THE TEST-TEMPLATE HOLE CENSUS (CART-0258) — "could we generate a test for this
- `tools/hybridtemp.lua` — hybridtemp — the HYBRID-BY-TEMPERATURE probe ([[cartograph-thin-index]]). Resident call
- `tools/ifaceceil.lua` — ifaceceil — the INTERFACE→IMPL hop CEILING probe (federation F1, [[cartograph-band-
- `tools/indexlsp.lua` — indexlsp — wire + gate the LSP/nav path over the INDEX-ONLY graph ([[cartograph-thin-index]]
- `tools/indexonly.lua` — indexonly — gate + measure the INDEX-ONLY front-end ([[cartograph-thin-index]] M.index_only).
- `tools/invariants.lua` — INVARIANTS THAT ATTACK THEMSELVES, headless (CART-0285).
- `tools/keyaccess.lua` — THE KEY-ACCESS CENSUS (per-corpus CLI).
- `tools/ladderparity.lua` — ladderparity — proves ladder.report (tally + narrowable) is IDENTICAL with the resident
- `tools/levers.lua` — levers — "where's the biggest resolution win on THIS corpus?" The
- `tools/lookupsnarrow.lua` — lookupsnarrow — gate the NAME-NARROWED lookups (treesitter.M.lookups `narrow`),
- `tools/lspparity.lua` — lspparity — the dumpcompare ORACLE INVERSION, at the SERVING boundary. Where
- `tools/lspserve.lua` — T2: the STDIO LSP HOST — the SAME pure handler table (lua/cartograph/lsp.lua)
- `tools/luadistill.lua` — luadistill — mint a `luajit` L2 profile by INTROSPECTING the interpreter this
- `tools/mcpserve.lua` — T3: THE MCP STDIO HOST — the pure verb table (lua/cartograph/agent.lua)
- `tools/mentionbuf.lua` — mentionbuf — SIZE the per-file mention buffers, i.e. price KEEPING them past
- `tools/navaudit.lua` — The NAV AUDIT — fence the NAVIGATION surface the way tools/docaudit.lua fences
- `tools/navcensus.lua` — navcensus — WHAT CAN THE BROWSER NOT DESCEND INTO, per language (CART-0456).
- `tools/nodegate.lua` — nodegate — the faithfulness gate for the resident columnar NODE store
- `tools/observe.lua` — The DISPATCH OBSERVER: cartograph's runtime/confirmed tier, driven
- `tools/patchcensus.lua` — MONKEY-PATCH CENSUS (CART-0618) — where does this code modify a table it did
- `tools/pathsat.lua` — THE CONTRADICTORY-PATH CEILING PROBE (CART-0256) — "would a boolean path
- `tools/peak.lua` — peak — "is this corpus LOCKED by scale?" The measurement resident.lua can't
- `tools/peakattr.lua` — peakattr — decompose the parallel-merge RESIDENT graph by component, so a peak
- `tools/portdeps.lua` — portdeps — WHO SUPPLIES WHAT THIS MOD EDITS, and have they ported yet (CART-0656).
- `tools/portgate.lua` — portgate — self-consistency gate for the per-band PORT SURFACE (ports.lua,
- `tools/portgraph.lua` — THE PORT GRAPH (CART-0268, W1 of the anonymous-type partition CART-0267).
- `tools/postings.lua` — postings — gate + SIZE the mention postings (store.build_postings), step 1 of
- `tools/preflight.lua` — PREFLIGHT: the dev loop as one command.
- `tools/profile.lua` — P0 EXTRACTION PROFILER ([[cartograph-perf-cut]]): where does a corpus's
- `tools/protopop.lua` — protopop — WHAT IS IN THE PROTOTYPE POPULATION, and what the data-stage reading
- `tools/prototypedistill.lua` — prototypedistill — distill Factorio's prototype-api.json into an L2 artifact for
- `tools/ratchet.lua` — ratchet — the honesty TREND meter. dogfood is a snapshot; this appends the
- `tools/rbsaudit.lua` — rbsaudit — validate the ruby-rails profile's hand-authored canonical owners
- `tools/rbsdistill.lua` — rbsdistill — distill Ruby RBS into a checked-in, version-keyed profile artifact
- `tools/recsize.lua` — recsize — total resident size of RAW RECORDS (node/edge/call tables) vs the CSR fold
- `tools/recwaste.lua` — recwaste — exact PARTIAL-SPARSITY waste in the callcols string columns ([[cartograph-thin-index]]).
- `tools/relinkmem.lua` — relinkmem — decompose the INTERMEDIATE (transient) relink structures (federation /
- `tools/rescolacc.lua` — rescolacc — the STREAMING-ACCUMULATOR parity gate (record-fold step 2, the
- `tools/rescolgate.lua` — rescolgate — the RESOLUTION-ON-COLUMNS parity gate (record-fold arc, the
- `tools/rescolmatrix.lua` — rescolmatrix — the RESOLUTION-STORE comparison matrix (record-fold arc, the
- `tools/resident.lua` — resident — the true post-ingest STORE resident, per index table (record-fold
- `tools/resolveparity.lua` — resolveparity — EXTRACT vs RELINK on the same graph: do the two resolution drivers
- `tools/retceil.lua` — retceil — the RETURN-TYPE ceiling probe (federation, [[cartograph-consumer-federation]]
- `tools/retsynthceil.lua` — retsynthceil — the RETURN-TYPE SYNTHESIS ceiling probe (VM work, [[cartograph-local-type-
- `tools/rowcensus.lua` — ROW CENSUS — the gate for the FINE row model (CART-0389).
- `tools/rubydistill.lua` — rubydistill — mint a `cruby` L2 profile by asking a REAL ruby interpreter what
- `tools/rubyfinder.lua` — rubyfinder — instrument the rails ORM-finder receiver-typing rung: does it FIRE,
- `tools/rubylever.lua` — rubylever — decompose the rails corpus's UNRESOLVED calls to decide the real
- `tools/rubymintparity.lua` — rubymintparity — INLINE vs PARALLEL parity for the ruby-rails minting face
- `tools/rubyowner.lua` — rubyowner — SIZE the owner-precision opportunity for ruby-rails minting
- `tools/rubyprofile.lua` — rubyprofile — measure the ruby-rails PROFILE's disposition-face delta + confirm
- `tools/scopekey.lua` — scopekey — gate + measure SCOPE-CONFINED candidates (store.mentioning_in),
- `tools/seamguard.lua` — The RECORD-FIELD SEAM GUARD — the fence that keeps a seamed field CLOSED
- `tools/seammigrate.lua` — seammigrate — the seam-guard's CONSTRUCTIVE twin. The guard (dogfood) says
- `tools/snapshot.lua` — Snapshot: save/load an extract's data table so a 55s extract is paid once
- `tools/summarycensus.lua` — summarycensus — the SUMMARY-SURFACE census (federation, [[cartograph-consumer-federation]]).
- `tools/symtabgate.lua` — symtabgate — the SYMBOL-TABLE equivalence + realized-peak gate (federation F2 step 3,
- `tools/syngate.lua` — The SYNTHETIC ANALYSIS ground-truth gate ([[cartograph-synthetic-analysis-groundtruth]]).
- `tools/thinindex.lua` — thinindex — measure the COST of the tiny index vs the bulky pipeline that produces it
- `tools/translit.lua` — TRANSLIT — the expression IR's own round-trip oracle: emit lua from the schema, parse
- `tools/typeeager.lua` — typeeager — the BAND-LOCAL TYPE-INFERENCE eager-vs-deferred probe (federation,
- `tools/varintcol.lua` — varintcol — the aggressive-varint-columnar compaction ceiling ([[cartograph-thin-index]]).
