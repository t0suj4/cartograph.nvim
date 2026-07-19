-- The incremental cache: extraction is a pure function of file contents,
-- and node ids are deterministic (file::name@line) — so an unchanged
-- file's entire contribution to the graph, INCLUDING edges between two
-- unchanged files, is still valid. The cache is that contribution,
-- SHARDED PER FILE: a shard holds everything a file originates (its
-- nodes, its calls, the edges leaving its nodes, its stamp, its mention
-- index), so a save touches only the shards a change actually dirtied —
-- O(diff), not O(corpus). The MANIFEST (stamps + unparsed roster) is the
-- sidecar and the commit point: the warm/cold decision reads a few KB,
-- never a blob it might discard. Load is a deterministic concat of
-- shards — the state was globally consistent when saved, so no relink.
--
-- Only RAW graphs are cached (before xlang/sql/toc/clangd post-passes —
-- init re-runs those on every open; oracle verdicts are session-live by
-- design). Slice opens (opts.subdirs) bypass the cache entirely.
-- setup{ cache = false } opts out.

local M = {}

-- bump when the extractor's OUTPUT shape changes (new node fields,
-- resolution semantics) — a stale-format cache must miss, not mislead
M.VERSION = 87 -- v87: ODIN-R1 PACKAGE-QUALIFIED RESOLUTION. A proc in `package P`
               -- gains a `P.proc` EXACT key (alt_keys, keeps the bare key so
               -- same-package calls' dir-scoped reach is unchanged — dual-key,
               -- NOT qualify, which would strand repeated procs on the tail
               -- path). A `pkg.proc()` call (member_expression operand) keys
               -- `<pkg>.proc` via the import alias/name (→ import path last
               -- segment) or the file's own package; exact_only (a package is
               -- explicit → miss = honest frontier, no bare-tail guess). Odin's
               -- core IS the corpus, so these resolve. MEASURED 15.74→19.13%
               -- (+5099, −159 all wrong-edge removals, 136 corrections). Torn
               -- defs (post-parse-error, e.g. fmt.odin/io.odin ~L681) stay
               -- unkeyed — a pre-existing grammar limit, out of scope.
               -- v86: ZIG LOCAL FIELD-ACCESS TYPING. A local `const x =
               -- param.field; x.method()` is treated as the field chain
               -- `param.field.method()` — chain_root sees through the local
               -- binding (emits c.chainroot=type(param), c.chainfield=field), so
               -- the SHIPPED resolve_field_chain resolves it, no new post-pass.
               -- The dominant local idiom (`const sema=…; sema.typeOf()`). PERF:
               -- the per-fn local map is built ONCE PER FILE and cached on the src
               -- string (a per-call body walk blew extraction 90s→400s+).
               -- MEASURED +21 (41.78→41.80%), 0 lost, 0 wrong; the field-access
               -- path is the real one (freecall/return path measured 0 — freecall
               -- is only 525 vs 10.8k field-access locals). Most of the ~198
               -- ceiling is same-file (already tail-resolved); +21 cross-file.
               -- v85: ZIG INSTANCE-CHAIN FIELD TYPING. An instance chain
               -- `root.field.method()` resolves via struct field types: the
               -- root's type (a param type, c.chainroot) → the field's type
               -- (data.fieldtypes, scan_fields) → the method. FILE-BOUND, not
               -- bare-name: the field type binds to a FILE (an @import alias in
               -- the field's file, else a same-file local `const T = struct`) and
               -- the method resolves IN that file (resolve_field_chain, additive
               -- unresolved-only). Bare-name exact[T.method] was UNSOUND — same-
               -- named types collide across subsystems (measured 25% wrong:
               -- MachO's StringTable is link/, not the mingw one). MEASURED +23
               -- (41.76→41.78%), 0 lost, 0 wrong; most of the 215 file-bound
               -- resolutions duplicate the same-file tail. c.chainroot/chainfield
               -- in validate.CALL_FIELDS; data.fieldtypes merged in parallel.lua.
               -- The bulk of instance chains stay unresolved (local roots need
               -- local type inference; generic fields need generics modelling).
               -- v84: ZIG MULTI-LEVEL CHAIN TYPE. A chained call
               -- `root.Type.method()` (e.g. `link.File.open`, `Mir.Memory.encode`)
               -- names its method in the PascalCase segment right before it (the
               -- type namespace), persisted as c.chainty. resolve_chain_type (an
               -- ADDITIVE, unresolved-only post-pass) keys exact[Type.method] and
               -- fills only the cross-file chains the bare-tail path left
               -- unresolved (same-file chains already resolve; instance chains
               -- `l.field.method` carry no chainty → untouched, need field-typing).
               -- MEASURED +66 resolved (41.71→41.76%), 0 lost, 0 changed — purely
               -- additive. c.chainty declared in validate.CALL_FIELDS.
               -- v83: ZIG VALUE-RECEIVER DUAL-KEY. A top-level value-receiver
               -- method (`fn eql(self: Foo)` / `fn setExtra(symbol: Symbol)`)
               -- keeps its bare same-file reach AND gains a `Foo.eql` exact key
               -- (spec.alt_keys) so a POINTER-typed receiver call (`p.eql()`,
               -- p:*Foo) — which exact-only-refuses rather than fall back to
               -- bare — finds its own value-recv method. Gated to a genuine
               -- receiver (param named `self` or the lowercased type), which
               -- dodges the constructor trap (`init(gpa: Allocator)`). Unique
               -- cross-file → resolves; same-named across modules → honest
               -- ambiguous-refuse; same-file → same-file priority. MEASURED
               -- +227 resolved, 0 lost, 6 CORRECTED — the R5 residual
               -- cross-module mis-picks (Tokenizer tapi/LdScript, Symbol.setExtra
               -- MachO/Elf vs Coff, Atom.freeRelocs Elf/MachO) all flip to their
               -- own file (41.71%).
               -- v82: ZIG @import MODULE BINDING. `const Foo = @import("f.zig")`
               -- binds Foo→that file (scan_imports emits an import edge with the
               -- alias; resolve_import maps the .zig path relative to the
               -- importer; std/builtin imports rejected). resolve_module_alias
               -- then resolves `Foo.member()` to f.zig's export — binding beats
               -- name-match. recv_local preserves the single-identifier receiver
               -- so a LOWERCASE alias (`bar.run()`, which R5 leaves bare) is also
               -- recognized. MEASURED +480 resolved, 0 lost, +17 CORRECTED —
               -- incl. fixing R5's residual cross-module mis-picks (a `name` call
               -- that hit Coff.Symbol now binds to the imported Elf/Symbol).
-- v81: ZIG-R5 RECEIVER TYPING. A `recv.method()` call is keyed
               -- `Type.method` from the receiver's declared type: a PascalCase
               -- receiver IS the type (`Foo.init`), a lowercase receiver is an
               -- instance typed from the enclosing fn's POINTER param
               -- (`sema: *Sema` → `sema.x()` = `Sema.x`). The def side mirrors
               -- it: a top-level fn with a pointer receiver first-param
               -- (`fn fail(func: *Func)`) keys `Func.fail` (via first-param
               -- type, NOT filename — so `const Func = @This()` aliasing keys
               -- consistently). exact_only_key blocks promiscuous tail fallback
               -- for `Type.method`. Measured 39.25%→40.68% on the compiler, but
               -- the win is CORRECTNESS: 21.5k methods re-keyed bare→owning-type
               -- + ~28 cross-file receiver fixes. Residual: cross-module
               -- same-named types w/ value-receiver locals (Symbol/Tokenizer)
               -- can mis-pick — next rung (value dual-key / module scoping).
-- v80: ODIN LANGUAGE SUPPORT (v1) — the 14th language. C/
               -- procedural family: `proc` declarations (no methods — procs
               -- are free), `T :: struct`, package(dir) scope. NO new hooks.
               -- Grammar via TSInstall odin; corpus = the core stdlib (1279
               -- files): 32316 procs, 15.7% resolved — LOW because Odin is
               -- heavily package-qualified (`fmt.println`) and v1 doesn't do
               -- package keying; the package-qualified-resolution arc (Odin-R1:
               -- package-aware qualify + `pkg.proc` keying + import-alias
               -- binding) is where it climbs (banked). UFCS also banked.
-- v79: ZIG LANGUAGE SUPPORT (v1) — the 13th language. A spec
               -- table in the procedural+struct+method family (like Go): `fn`
               -- declarations (free + struct members), struct methods keyed
               -- `T.method` from the enclosing `const T = struct` (qualify),
               -- bare + field (`Foo.init`/`x.m`) calls, file-namespace scope,
               -- `pub` = exported. NO new hooks — reuses the closed spec
               -- contract ([[cartograph-modular-specs]]). Grammar via TSInstall
               -- zig. Corpus = the self-hosted compiler (src/, 171 files):
               -- 6138 fn + 2452 methods, 39.3% resolved. The receiver-typing
               -- ARC (Type.method keying = Zig-R1, x.m instance typing = R5, and
               -- @import module binding) is banked — mirrors the ruby arc,
               -- deferred so it gets the same measured diff-validation.
-- v78: RUBY R5b — `@ivar` constructor typing. Extends R5's
               -- additive ctor-typing to instance variables: `@x = C.new;
               -- @x.foo` → `C#foo` (own/inherited). Tiny reuse — ruby_ctor_binds
               -- also matches an instance_variable LHS, recv_local also returns
               -- ivar receivers; the existing recv path + single-assignment gate
               -- + parallel merge all carry over (per-file `@x` key; a same-named
               -- ivar across two classes in one file drops via the gate —
               -- conservative). ADDITIVE, 0 losses: activesupport +3, discourse
               -- app +35. +1 ruby_r5 ivar spec. R5b-pack (rails finder-typing:
               -- @x=User.find→User#m, +60 discourse/app) + param/RBS typing banked.
-- v77: RUBY R5 (RESCOPED, ADDITIVE) constructor/receiver typing.
               -- `x = Const.new; x.foo` → `Const#foo` (own or inherited via the
               -- R4 ancestor chase). THE RESCOPE that fixed the reverted R5:
               -- ADDITIVE, not exact-only — `full` stays BARE so the file-local
               -- heuristic is untouched; only UNRESOLVED `x.foo` (c.recv set,
               -- not c.to) get ctor-typed, disambiguating where the heuristic
               -- was ambiguous. Same ctor scan as the reverted R5 (ruby_ctor
               -- binds, single-assignment gated) — the difference is purely in
               -- CONSUMPTION. 0 losses (measured): activesupport +2, discourse
               -- app +164 / lib +68 — vs the reverted exact-only R5's −163/−284.
               -- Rides resolve_ruby_ancestors (recv path) + parallel merge
               -- (acc.ruby_ctor). new c.recv call field; +4 ruby_r5 specs.
-- v76: RUBY R4 `super` KEYWORD follow-on. Bare `super` /
               -- `super(args)` (its own grammar node, NOT captured by the calls
               -- query) now emits a call resolved to the ANCESTOR's same-named
               -- method — the enclosing def's name chased up C's ancestors
               -- (resolve_ruby_ancestors superx path; chase already skips C's
               -- own def). Instance super → superclass/include chain (p#m);
               -- singleton super (def self.x) → superclass singleton chain
               -- (p.m). HEDGED ~, additive (super wasn't a call before).
               -- activesupport +22 resolved (141 super calls captured; the rest
               -- = super-to-external-ancestor honest frontiers). +3 ruby_r4
               -- super specs. c.superx call field.
-- v75: RUBY R4 — INHERITANCE + MIXIN ancestor resolution. When a
               -- bare/self call keyed `C#m`/`C.m` (R2/R3) MISSES (the method is
               -- inherited), walk C's ancestors — superclass chain + include/
               -- prepend modules (instance) + extend modules (singleton) — for
               -- the nearest UNIQUE def (resolve_ruby_ancestors over ancestor
               -- edges from ruby_ancestors; multi-parent, since mixins). HEDGED
               -- ~ (nearest static ancestor; full MRO/dynamic dispatch
               -- unmodeled), unique-or-skip. PURELY ADDITIVE (0 losses):
               -- recovers exactly the frontiers R2/R3 declined. activesupport
               -- +115 (19.6→20.9%), discourse/app +1051 (13.1→14.9%). The
               -- CONTRAST to R5 (reverted, net-negative): R4 adds sound
               -- resolutions without removing a heuristic. Ancestor edges ride
               -- the parallel merge (acc.ruby_anc, file-deduped). +6 ruby_r4
               -- specs; R2 mixin-frontier test updated (now R4-resolved).
-- v74: RSPEC TEST-DSL PACK — the 2nd overlay pack, proving
               -- MULTI-PACK composition (rails + rspec compose end-to-end on a
               -- real corpus). v1 = VOCAB: RSpec + factory_bot DSL verbs
               -- (describe/context/it/let/subject/expect/to/eq/allow/receive/
               -- shared_examples/build_stubbed/…) declared framework vocab.
               -- MEASURE-FIRST: impact is modest+honest — spec DSL calls were
               -- ALREADY unresolved-external (not mis-bucketed), so the pack's
               -- value = composition proof + correct model (a project method
               -- named `subject`/`describe` no longer mis-matches), NOT a
               -- resolution gain (specs are framework-dominated, 0.9% resolve).
               -- New `rspec` corpus (discourse spec/models, packs rails+rspec).
               -- The let/subject example-group def-emitters need a scoping model
               -- (spec code = blocks not methods) = banked v2 (compose_spec
               -- extension for pack-contributed scope/hooks). +3 ruby_rspec specs.
-- v73: RAILS OVERLAY PACK — the modularity milestone. First
               -- framework/DSL pack composing onto a base language spec
               -- (M.packs + M.compose_spec: union stdlib_names, chain
               -- synth_defs via metatable; activated per-corpus opts.packs,
               -- threaded through extract + relink). ActiveRecord/ActionController
               -- verbs (save/where/find/create/params/render/…) MOVED OUT of
               -- base ruby stdlib_names into the pack (a pure-Ruby project's
               -- `save` resolves to its own def, not refused as AR vocab).
               -- Pack def-emitters (ruby_rails_synth): belongs_to/has_one/
               -- has_many/has_and_belongs_to_many → Model#assoc + #assoc=;
               -- delegate → a reader per method. Base ruby unchanged
               -- (activesupport 19.5→19.6%, +1). rails corpus (discourse
               -- app/models) +1667 assoc/delegate nodes; resolution R5-gated
               -- (association reads are obj.assoc). +5 ruby_rails specs; new
               -- `rails` corpus. attr_* stays base-ruby. NEXT: R4/R5 unlock the
               -- association-read resolution the pack set up.
-- v72: RUBY R3 = OPEN-CEILING (bare-call capture) + attr_*
               -- DEF-EMITTERS. (1) scan_bare_calls surfaces bare no-paren
               -- calls (`save`, attribute reads) that parse as `identifier`
               -- not `call`, applying ruby's var-vs-call rule (a bare name is
               -- a local read iff bound in the enclosing method: param, block/
               -- rescue/for/pattern, or assignment LHS) — sound: never emits a
               -- call for a var read. Survivors key via R2 (Owner#m). (2)
               -- synth_defs emits attr_accessor/reader/writer as real method
               -- nodes (Owner#foo reader / Owner#foo= writer; singleton in
               -- class<<self), the def-emitter mechanism the rails pack reuses.
               -- (3) resolve(): an explicit def shadows a synth accessor of the
               -- same name (def beats attr_accessor). activesupport +274
               -- (15.4→19.5%); discourse lib +2090 (→19.6%), app +2045
               -- (→13.1%). Ceiling alone = 0 losses; attr_* = 6 tangled
               -- singleton/instance precision losses (now honest frontiers, no
               -- wrong edges). +9 ruby_bare/attr specs. Ruby-only.
-- v71: RUBY R2 IMPLICIT-SELF KEYING. A bare call (or `self.m`)
               -- inside a method dispatches on self → the enclosing owner:
               -- instance-method body → `Owner#m`, singleton context
               -- (def self.x / class << self) → `Owner.m`, class-body DSL
               -- left bare (R3). Corpus-wide (`#` joins the dotted-global
               -- scope-crossers via spec.hash_qualified, ruby-only so JS
               -- private `#field` is untouched); HEDGED `~` (subclass may
               -- override); exact-or-nothing (inherited via mixin/superclass
               -- = honest frontier → R4, never a tail-guess). activesupport
               -- +158 (13.4→15.4%); discourse lib +859 (→14.9%), app +988
               -- (→10.7%). 8 activesupport losses ALL inherited-method
               -- (mixin/superclass) refusals, no wrong targets. +6 ruby_r2_spec.
-- v70: RUBY R1 CONSTANT-RECEIVER KEYING. `Foo.bar`/`A::B.baz`
               -- key to the SINGLETON `Receiver.method` (qualify_call) and
               -- exact-match the class-method def; receiver evidence is
               -- exact-or-nothing (exact_only_key) — no promiscuous tail
               -- collision onto an unrelated `X#bar` (arc trap #1). Def-side
               -- fix: a `def m` inside `class << self` is keyed singleton
               -- `Owner.m`, not instance `Owner#m`. rails/activesupport
               -- +75 (12.5→13.4%); discourse app+lib +2851 resolved edges
               -- (app 5.6→8.9%, lib 9.2→12.4%). Ruby-only (gated on the spec).
-- v69: CLASS FIELD-ARROWS + function()/()=>{} `this` SEMANTICS.
               -- (1) `class C { m = () => {} }` / `private m = async () =>` field-
               -- arrows are keyed C.m like methods (per-grammar `fields` query;
               -- qualify unwraps the field def) → this.m() resolves. (2) node.arrow
               -- marks arrow fns; B3 this-typing WALKS UP through arrows (which
               -- inherit `this` lexically) to the establishing class member, but
               -- STOPS at a regular function (which REBINDS this → dynamic, not
               -- typed). matrix-react-sdk: +588 this/field resolutions, agreement
               -- 93.06→93.90%, 0 new error class. Inert on pre-ES6/non-class JS.
-- v68: LOCAL-SHADOW — DESTRUCTURED PARAMS. fn_locals also
               -- captures destructured object/array PARAMS (`({onFocus}) =>`,
               -- `([a,b]) =>`): unlike a POSITIONAL param (an AMD dep, ungated) a
               -- destructured param is never AMD → unambiguously local, gated like
               -- a localdecl. +20 shadow fixes on matrix-react-sdk (→93.06%); AMD
               -- positional params + non-JS still byte-identical.
-- v67: LOCAL-SHADOW FIX (from the TS harvest) — a JS/TS bare
               -- callee bound by an in-function const/let/var (incl. destructured
               -- `const [x,setX]=useState()` hook setters) with NO same-file def
               -- no longer name-matches a cross-file GLOBAL of that name — the
               -- local shadows it → refused fn-value. fn_locals captures the
               -- bindings (new node.locals field); the gate is localdecl-only with
               -- a same-file-def escape (a `const f=()=>{}` still resolves plain),
               -- so params (AMD `define(function(dep))`) + lua df-locals + non-JS
               -- are untouched. matrix-react-sdk: 95 shadow bugs fixed, 0
               -- regressions (agreement 91.97→92.87%).
-- v66: REACT .tsx/.jsx (pivot A3) — .tsx parses under the tsx
               -- grammar (new `tsx` spec = typescript spec under the tsx parser),
               -- .jsx under the JS grammar (JSX-capable). Both fold to the
               -- javascript RESOLUTION family (elang_for) so .js/.jsx/.ts/.tsx are
               -- one language; parse_lang_for keeps the real grammar per file. The
               -- full JS/TS OOP arc (class-key/extends/this/proto/ctor) applies to
               -- React components verbatim. matrix-react-sdk/src: 652→1312 modules
               -- (the .tsx were skipped before). Inert on non-jsx/tsx corpora.
-- v65: TS TYPE ALIASES & NAMESPACES (A1-tail remainder) —
               -- `type Id = …` (ctype='type') and `namespace NS {}` (ctype=
               -- 'namespace') extract as browse-only TYPE nodes, like interface/
               -- enum. PURELY ADDITIVE (new .ts nodes, zero resolution change).
               -- Namespace MEMBER qualification (NS.helper) banked; import type
               -- already makes an import edge (the "region" is normal top-level
               -- behavior, not a bug); decorators negligible (9/0) → banked.
-- v64: JS/TS CTOR-TYPING V2 — `const o = new C(...)` binds o to
               -- class C (ctor_query on new_expression), so o.member resolves to
               -- C.member walking C's extends chain (resolve_local_ctor CUT 3:
               -- callee IS the class, elang-gated). `new C()` is precisely a C
               -- instance → sound. three.js +695 (784 ctor-typed local.member
               -- resolutions, 99.75% on the class chain). Closes the last JS
               -- receiver-typing gap (the synjs obj.calc answer-key flips to →C.calc).
-- v63: JS/TS PROTOTYPE METHODS (pivot B4) — pre-ES6
               -- `X.prototype.m = function` is captured (structural #eq?
               -- "prototype" gate) and keyed `X.m` (qualify collapse), the same
               -- shape B1 gives ES6 methods, so B3 this-typing / resolve_super
               -- treat a prototype "class" identically. SOUND + GENERAL but
               -- MEASURED ~0 reach on the current corpora (jquery/mootools/three/
               -- prototype.js moved to ES6 classes / framework factories) → inert,
               -- gate corpora byte-identical; correct for node-style / older JS.
               -- Framework factories (Class.create / new Class / jQuery .fn
               -- object-literal) BANKED as narrow per-adapter cuts (WoW lesson).
-- v62: JS/TS THIS-TYPING (pivot B3) — `this.member()` inside a
               -- class method resolves to the enclosing class's member, walking
               -- the extends chain (B2) for inherited ones. `this` typed
               -- LEXICALLY from the method's `C.member` key (B1); ~-tier (JS this
               -- can be rebound / virtual dispatch → honest hedge). Gated to a
               -- genuine object (owner owns >=2 methods) + unique chain hit; a
               -- nested non-method fn's `this` has no class owner → skipped.
               -- JS/TS only, independent of the lua self machinery. three.js:
               -- +982 this.member resolutions (664 own / 318 inherited),
               -- 99.85% on the enclosing class's own/ancestor chain.
-- v61: JS/TS CLASS EXTENDS (pivot B2) — `class C extends B` now
               -- emits a data.extends child→parent edge (js super_query on
               -- class_heritage; ts on the extends_clause; dotted `ns.Base`
               -- captures the tail). resolve_super consumes it: inherited static
               -- calls `C.s()` AND `super.m()` (head rewritten to the enclosing
               -- class via the call's fn owner) walk the chain to the nearest
               -- ancestor defining the method. three.js: 397 extends edges,
               -- +250 super.method resolutions, all ancestor-correct (0 off-chain).
               -- Populates the inheritance graph B3 (this-typing) rides.
-- v60: TS INTERFACES & ENUMS (pivot A1-tail) — interface/enum
               -- declarations now extract as browse-only TYPE nodes (kind='var'
               -- + ctype=interface/enum, like a C struct/enum: excluded from
               -- value resolution by the var_named gate), plus their members:
               -- interface method signatures = DECL methods `Iface.method`
               -- (decl=true → excluded from the global index, never a call target,
               -- like a C prototype); interface property signatures + enum members
               -- = browse-only `Owner.member` vars (ctype field/enumMember).
               -- PURELY ADDITIVE (new nodes on .ts only, zero resolution/edge
               -- change) via a typescript-only `interface` query → handle_iface.
-- v59: JS/TS CLASS-KEYING (pivot B1) — ES6 `class C { m(){} }`
               -- methods now carry their class as `C.m` (js `qualify` hook; JS
               -- analog of lua `C:m` / php `C::m`). A method_definition is a class
               -- member iff its parent is class_body (object-literal methods stay
               -- bare); anon class exprs borrow the binding var name. `.` separator:
               -- a `ClassName.m()` reference exact-matches; the tail index still
               -- catches `x.m()`. SEPARATES the module-fn vs class-method namespaces
               -- that bare-keying conflated — three.js +640 resolutions, 0 fabricated
               -- (soundprobe OTHER=0). Non-JS byte-identical (js-only hook); jquery/
               -- mootools identical (pre-ES6); synjs pure rename, answer-key PASS.
-- v58: LUA PARSE-ERROR RESILIENCE — lua defs are self-contained
               -- (`function X.prototype:m` carries its own qualifier), so torn_by_node:
               -- tear only defs whose OWN subtree holds the error, not everything after
               -- the first error ROW. One invalid-escape string (`"[^\.]+"` at Waterfall-
               -- 1.0.lua:370) otherwise torned ~2000 downstream defs → all its widget
               -- prototypes invisible as call targets. Measured 481 clean defs recovered
               -- corpus-wide (19 error-files) vs 2 genuinely-in-error kept torn. Fixes the
               -- Baggins SetText/Clear harvest conflicts at their real (extraction) root.
-- v57: PROTOTYPE-OOP self-typing (GAP-2) — resolve_self now types self
               -- to the FULL DOTTED owner (`Widget.prototype:Refresh` → `Widget.prototype`,
               -- was truncated to `Widget`) and OVERRIDES a FOREIGN promiscuous self:member
               -- match (all `Waterfall*.prototype:SetText` had landed on the unrelated
               -- `FuBarPlugin:SetText`). Receiver-type beats name-match, gated on the
               -- genuine-object contract (owner owns >=2 colon-methods). MEASURED zero
               -- override on non-dotted owners (1104 already correct) → no regression of
               -- correct self:member; corrects 20 + fills 37 dotted-owner sites.
-- v56: REASSIGNMENT-OVERRIDE (value-flow resolution) — a table slot
               -- `Owner.field` written by >=2 UNCONDITIONAL top-level defs resolves
               -- to the LAST-in-load-order (runtime-effective) def, not the first
               -- separator/name match: the monkey-patch idiom `function T:m … end;
               -- T.m = function … end` calls the reassignment. resolve_reassign,
               -- gated on a new node.top marker (def reaches chunk with no `block`
               -- ancestor). Branch-selected slots (`if X then function k:m … else …`)
               -- have no load-order winner → left as name-matched (no false redirect).
               -- New node field `top`; same-file resolution semantics change.
-- v55: MODULE-ALIAS BINDING-OVER-NAME-MATCH — a call `alias.m` where
               -- alias=require("M") now resolves to M's OWN export m even when a
               -- FOREIGN file's `alias.m = …` (a test mock / monkey-patch of the
               -- imported module) had wrongly won the corpus name-match. resolve_
               -- module_alias corrects a foreign resolution when M's file uniquely
               -- defines m; re-exports (M lacks m) + extensions are untouched.
-- v54: REGISTRY CLASS-OWNER FIX — a register line `local Lib,
               -- oldminor = :NewLibrary("X")` gives both vars start.char 0, so
               -- resolve_registry's leftmost-var tiebreak was a pairs()-order
               -- coin-flip (LibStub("AceConsole-3.0") could resolve to `oldminor`).
               -- Now prefers the CLASS-owner var (owns methods) → correct + stable
               -- retrieve target + ref edge. WoW-only idiom → inert elsewhere.
-- v53: flow rows carry a sparse `rmw` column (read-modify-write LHS
               -- reads `a = a + …` the df contract drops from `use`); reaching_cfg
               -- consumes it so a self-read reaches (flow-precision-gaps #1).
-- v52: STRING-KEYED REGISTRY LINKER (stage 3) — a retrieval keyed
               -- by a string literal (LibStub("X") fn-call form + :GetLibrary/
               -- :GetModule/:GetAddon("X")) resolves to the :NewLibrary/:NewModule/
               -- :NewAddon-registered table (the bound local), SCOPED to the addon
               -- (.toc) so it never crosses the sharing boundary. Keys are folded
               -- literals (const-fold v50). Emits a ref edge + c.registry (~).
               -- INERT on non-WoW corpora (no such idioms) → gate corpora unmoved.
-- v51: ANONYMOUS CALLBACK FNS (df-strangler B) — a JS arrow/
               -- function_expression passed as a call ARGUMENT is now extracted
               -- as its own fn node (synthetic name `<callee>#cb`, NOT in the
               -- name-resolution index). Its body gets its own df/flow and its
               -- inner calls/defs attribute to IT (fn_at) — closing the v49
               -- regression where defs inside nested callbacks were invisible to
               -- df (resolve_local_callable starved → captured fn-value callees
               -- dropped silent instead of refused 'fn-value'). Purely ADDITIVE
               -- (enclosing fns' flow already stopped at the arrow boundary). New
               -- fn nodes on JS corpora; df-parity census recalibrated. PAIRED
               -- with resolve_local_callable now walking the ENCLOSING-fn chain
               -- (a param/local CAPTURED from an outer scope and called inside a
               -- callback is no longer orphaned by the callback's new fn boundary
               -- — stays refused higher-order/fn-value, not silent).
-- v50: CONST-FOLD ladder step 1 — a call argument that is a bare
               -- identifier (argv k='local') is upgraded to a literal (k='lit')
               -- when the name folds to a same-file SET-ONCE scalar-STRING const
               -- (constfold.lua; index built in handle_var, baked into calls
               -- pre-return). String-only + symmetric poisoning = sound; the
               -- register-side registry-key idiom (local MAJOR="X";
               -- LibStub:NewLibrary(MAJOR)) now carries the folded key. argv
               -- content changes (some k='local' → k='lit', v set, cf=true).
-- v49: DF-STRANGLER STEP 6 — df is now a COARSE PROJECTION of
               -- flow, DERIVED at extract (n.df = flow.coarse(fl), no separate
               -- dfreg walk) — the step-4 double build retired. `defr` binder
               -- tags dropped everywhere (fully unconsumed since trace +
               -- extract.plan moved to flow.reaching_cfg): gone from
               -- collect_mentions, the df.fold r0/rdi/rtag columns, and the
               -- store.ingest transplant. The legacy dfreg df survives ONLY
               -- under opts.legacy_df (bench.extract), the parity oracle path.
               -- Extraction output changes (df loses defr, is flow-sourced).
-- v48: SHORT-NAME HONESTY — resolve()'s #name<3 gate now
               -- applies to CROSS-FILE matching only: a 1-2-char callee
               -- with a SAME-FILE def resolves through the same-file tier
               -- (was a SILENT drop — the synjs min.js q3 key witness,
               -- want='silent' flipped to want='to' in the same commit);
               -- free short names stay noise-gated. New same-file edges
               -- on corpora with short-named fns.
-- v47: PARALLEL PARITY — calls mark a rounds-SYNTHESIZED
               -- qualification (c.rtfull) so the parallel audit can null it
               -- with the resolution it rode (a kept one changed relink's
               -- question and minted edges inline never had, nondeterministic
               -- with slice boundaries); the audit also nulls the stale tinf
               -- verdict, the merge carries implements/beans/ctorbinds/
               -- smtclasses (everything after extends had been DROPPED — F1
               -- redirects were silently missing from parallel extracts), and
               -- chunks merge back into CANONICAL fileset order before
               -- audit/relink (worker completion order leaked into resolution).
-- v46: HONESTY PASS (resolve_local_callable) — a bare call whose
               -- callee is a PARAM (higher-order) or a LOCAL df-def of the
               -- enclosing fn no longer drops SILENTLY: a param refuses
               -- ('higher-order'), a local resolves to a unique same-file fn def
               -- (INFERRED — the forward-decl/short-name `nm`/`go` the <3 name
               -- gate blocked; bound-ness not length) else refuses ('fn-value').
-- v45: GENERIC Class<T> RETURN (graph-VM) — a method summary now
               -- carries `retclass` (the arg index of a Class<T> param binding
               -- the return var); the return-type rounds bind `<T> T get(Class<T>)`
               -- from the call's `X.class` literal, so `Services.get(IFoo.class).m()`
               -- types as IFoo::m (→ service-marker gate). argv gains k='class'.
-- v44: SERVICE-MARKER GATE — resolve_interface resolves a call on
               -- a service-locator marker interface (extends ISingletonService/
               -- IMultitonService/IService, the metasfresh Services.get idiom) to
               -- its unique implementer WITHOUT bean-gating (F1 sibling gate).
-- v43: @Qualifier NARROWING — a call's receiver field @Qualifier
               -- bean name rides on c.qualifier + beans carry their explicit
               -- @Service("name"); resolve_interface narrows an AMBIGUOUS
               -- interface (>1 impl) to the named bean impl.
-- v42: INTERFACE→IMPL (F1) — Java `implements`/interface-`extends`
               -- captured to data.implements + @stereotype beans to data.beans;
               -- resolve_interface REDIRECTS an interface-stub call `I::m` to its
               -- unique bean impl `C::m` (SET semantics: >1 or 0 → leave honest).
-- v41: INHERITANCE PATTERN B — `local Sub = setmetatable({},
               -- {__index = Base})` (anonymous first arg, the common subclass
               -- idiom) now emits extends Sub->Base, completing the inheritance
               -- graph (StoreBand/FoldBand->Band etc.). Improves V0/V1/V3 chain
               -- resolution. [[cartograph-linker]] V0 Pattern B.
               -- v40: FRAMEWORK-INVOKED self (V3) — a colon-method M:foo on a
               -- genuine object M (>=2 colon-methods) with NO in-corpus call
               -- site (framework-invoked: Ace3 modules, widget mixins, event
               -- handlers) types self=M by the OO/framework contract, self:member
               -- chain-walked. Fires only where V1's call-site fixpoint hedged;
               -- unique-hit, inferred ~. [[cartograph-linker]] V3.
               -- v39: CONSTRUCTOR RETURN-CLASS (V2 cut 2) — a constructor's
               -- return-class = the class its in-body setmetatable points at
               -- (a setmetatable-extends edge inside the fn's range). Types
               -- `local obj = anyCtor()` from the RETURN, bypassing the `.new`
               -- naming convention. [[cartograph-linker]] V2 cut 2.
               -- v38: CONSTRUCTOR-TYPED LOCALS (V2) — `local obj = C.new(...)`
               -- / `C:new(...)` (C a class) → obj:member resolves through C's
               -- extends chain (data.ctorbinds, single-assignment gated,
               -- inferred ~). Widens V1's receiver typing. [[cartograph-linker]] V2.
               -- v37: SOUND self:member (V1) — `self` (param-0 of a colon-
               -- method) typed by the JOIN of receiver types over the method's
               -- resolved call sites (backward), then self:member resolved
               -- through the extends chain. Hedges when undetermined (any
               -- untypeable call site poisons to hedge) — never the lexical
               -- owner. Bounded fixpoint; inferred (~). [[cartograph-linker]] V1.
               -- v36: LUA INHERITANCE (V0) — `setmetatable(X, {__index = P})`
               -- emits an extends edge X->P (data.extends), so resolve_super
               -- resolves ambiguous inherited `X:m()`/`X.m()` calls to the
               -- ancestor that defines m. resolve_super separator generalized
               -- (:: php/java, :/. lua). The receiver-typing foundation
               -- ([[cartograph-linker]] V0). New inherited-method ref edges.
               -- v35: nvim-plugin REPO SHAPE — a corpus with a `lua/` package
               -- layout resolves `require 'foo.bar'` → lua/foo/bar.lua (marker-
               -- gated). Unblocks module-alias (v34) on self: self's own
               -- `require 'cartograph.X'` now resolve → import edges + binds →
               -- alias.member calls resolve. A v34 cache lacks the lua/ root.
               -- v34: MODULE-ALIAS resolution (receiver-typing rung 1) — a
               -- still-refused `alias.member(...)` where `alias = require('mod')`
               -- (the import edge's bind) now resolves to mod's `member` export,
               -- inferred (~). Lua-only (only lua captures import_bind); shifts
               -- refused↓/ref-edges↑ on lua corpora. A v33 cache lacks it.
               -- v33: FLOW rows carry a control-transfer LABEL (`s.label`) —
               -- break/continue TARGET, goto target, labeled-loop / C-label
               -- DEFINITION. successors resolves labeled break/continue to the
               -- named loop + goto to its label row. Sparse (rare) — folds as a
               -- side map. def/use unchanged (coarse parity intact). v32 lacks it.
               -- v32: FLOW ROWS gain a start COLUMN (`c`, 1-based) — same-line
               -- entities (minified/generated blobs, chained one-liners) become
               -- ordered + jump-locatable by (l,c). Folds as one more column
               -- (u16, auto-u32 for extreme minified lines). A v31 cache lacks it.
               -- v31: FLOW ROWS — eager per-fn fine flow (df-strangler step 4).
               -- Every body_field-lang function node now carries `flow`
               -- ({stmts,params}), folded to a shape-interned columnar store at
               -- ingest. A v30 cache lacks it → re-extract. (df untouched: flow
               -- rides ALONGSIDE, its coarse projection == df, the parity oracle.)
               -- v30: C/C++ BARE-DECLARATION DEFS — a declaration with no
               -- initializer (no init_declarator) now defs its name via the
               -- `declaration` node's own declarator field(s): `int x;`,
               -- `Foo *p;`, multi `int a, b;`, `unique_ptr<T> arr[N];`. A v29
               -- cache miscounts these as uses;
               -- v29: C/C++ POINTER-DECLARATOR DEFS — df def/use now defs the
               -- inner name through pointer_declarator / reference_declarator /
               -- array_declarator (incl nested `**`), instead of miscounting it
               -- as a use (`Type *p = f()` DEFs p). ~20% of cpp declarations;
               -- fixes reaching/write-axis/reorder on cpp. Mirrors flow.du;
               -- a v28 cache miscounts cpp pointer decls;
               -- v28: PURITY INPUTS — fns carry pw (indexes of own params
               -- written through: the lua/js reference-semantics fact) and
               -- use edges carry flds (per-field packed rw+gw, ''=whole-var);
               -- a v27 cache lacks both;
               -- v27: PARAM PREDICATES + scalar argv — use edges carry gp
               -- (±param index: all writes fire only when that param is
               -- truthy/falsy; skip-direction sound), argv classifies
               -- boolean/nil/number literals as k='scalar' (dischargeable
               -- flags); a v26 cache lacks both;
               -- v26: GUARD SUMMARIES — write occurrences classify their
               -- guard (unguarded/guarded/SET-ONCE, AST-hardened conjunct-
               -- sound absence tests + else-arm + or/??= idioms); use edges
               -- carry gw = min over writes; a v25 cache lacks it;
               -- v25: the WRITE AXIS — lua/php use edges carry rw
               -- (1 read / 2 write / 3 both; ABSENT = no classifier ran,
               -- mode unknown); a v24 cache lacks the mode;
               -- v24: type-inferred TIER — graph-VM return-type-resolved
               -- calls/edges carry tinf (the honesty ladder's middle rung,
               -- fold flag bit 4); a v23 cache lacks the distinction;
               -- v23: kwargs classified — argv entries carry kw=<name>
              -- (value classified like a positional; dispatch through
              -- keyword args now visible) and spreads mark k='spread'
              -- (positions after one are unknowable);
              -- v22: js imports see CommonJS require('...') and dynamic
              -- import('...') — node corpora gain their module graph
              -- (a v21 cache lacks the edges);
              -- v21: typed strings v1 — argv distinguishes interpolated
              -- strings (k='lit' means KNOWN; heads become k='concat',
              -- "$var" becomes k='local'), sink-typed calls carry c.strarg
              -- and eval heads ride c.traced;
              -- v20: module nodes carry APERTURE witnesses (eval sites)
              -- and bash resolution refuses namespaced defless calls with
              -- rule='aperture' + witness — a v19 cache lacks both, and
              -- torn-by-node/literal-names (same arc) moved bash graphs;
              -- v19: df def entries carry sparse BINDER TAGS (s.defr —
              -- decl-row of the resolved binder) for shadow-ambiguous
              -- names (scope-model phase 2); a v18 cache lacks them and
              -- trace would silently fall back to name matching;
              -- v18: order-independent resolution — cbarg marks move to a
              -- pre-scan (same-file tiers no longer depend on call order;
              -- ~10 server edges gain confidence) and settled chains keep
              -- their rt provenance (calls carry rt after resolution);
              -- v17: the scope-model arc changed resolution semantics AND
              -- shapes — lexical-first id pass (bound names never cross the
              -- file boundary: cached graphs hold since-removed false use
              -- edges), return-type rounds (+15% java ref edges; calls carry
              -- rt, defs carry ret), shadow hedges (c.hedge; edges capped ~).
              -- A v16 cache would warm-open a silently pre-scope-model graph;
              -- v16: the top-level-statement node kind is `region` (was
              -- `block`; id `file::region@line`) — `block` now names the
              -- browser view you descend a compound statement into;
              -- v15: top-level statement blocks are bounded runs again —
              -- fnDefLines flushing (node identity did not survive iter_matches
              -- vs iter_children, so every file was one giant block);
              -- v14: C/C++ #include <angled> paths resolve too (was quoted-
              -- only) — a project's own headers reached via -Iinclude now
              -- link, so the include tree populates (external system headers
              -- resolve to nothing, as before);
              -- v13: C/C++ header interface extracted — prototypes (decl),
              -- macros (fn-like callable + object consts), struct/union/enum/
              -- typedef (var, ctype); a header browses as its interface;
              -- v12: scheme define/lambda signature is not a call (no
              -- more bogus fn-is-its-own-caller self-edges);
              -- v11: lua top-level GLOBAL assignments are var nodes too
              -- (X = ...), not just `local` — flat globals modules now
              -- populate; multi-assign deduped;
              -- v10: refused calls carry their refusal (rule+candidates);
              -- v9: lua module nodes carry load-time effects;
              -- v8: import edges carry their local binding (bind);
              -- v7: php oo/loaders/torn defs (receiver-aware calls,
              -- PSR-4 suffixes, error-gated indexing);
              -- v6: containers (vue/svelte) + js/ts one resolution family;
              -- v5: any stamped source (manifest carries provider);
              -- v4: per-file shards; v3: binary codec; v2: data.names

-- The codec is the cache's speed floor. string.buffer (LuaJIT) is
-- near-memcpy; vim.mpack is the fallback. Either way binary-safe (the
-- \31-packed name index rides untouched) and faithful to Lua tables —
-- no vim.NIL artifacts. A file written by one codec and read by a
-- build with the other simply misses (decode fails -> cold extract).
local has_sb, sb = pcall(require, 'string.buffer')

function M.encode(t)
    return has_sb and sb.encode(t) or vim.mpack.encode(t)
end

function M.decode(s)
    if has_sb then
        local ok, v = pcall(sb.decode, s)
        if ok then return v end
    end
    local ok, v = pcall(vim.mpack.decode, s)
    if ok then return v end
    return nil
end

--- Cache directory for a project root (root normalized like extract
--- does). Layout: <dir>/manifest.bin + <dir>/<file-key>.bin shards.
function M.path(root)
    local base = vim.fn.stdpath('cache') .. '/cartograph'
    vim.fn.mkdir(base, 'p')
    if root:match('^%w+://') then
        -- URI roots (mcp://pg) are stable identities, not paths
        root = root:gsub('/+$', '')
    else
        root = vim.fn.fnamemodify(vim.fn.expand(root), ':p'):gsub('/+$', '')
    end
    return base .. '/' .. root:gsub('[/\\:]', '%%') .. '.d', root
end

--- Remove a root's cache entirely (shards, manifest, legacy flat files).
function M.wipe(root)
    local dir = M.path(root)
    vim.fn.delete(dir, 'rf')
    for _, ext in ipairs({ '.bin', '.meta', '.json' }) do
        vim.fn.delete((dir:gsub('%.d$', ext)))
    end
end

local function fkey(rel)
    return rel:gsub('[/\\:]', '%%') .. '.bin'
end

local function file_of(id)
    return id:match('^(.-)::') or id
end

local function read_decoded(file)
    local fd = io.open(file, 'rb')
    if not fd then return nil end
    local txt = fd:read('a')
    fd:close()
    return M.decode(txt)
end

local function write_encoded(file, t)
    local fd = io.open(file, 'wb')
    if not fd then return false end
    local bytes = M.encode(t)
    fd:write(bytes)
    fd:close()
    return #bytes
end

-- the manifest is the COMMIT POINT: written to a temp file and renamed
-- into place, so a crash mid-write can only ever leave the old one
local function write_manifest(dir, m)
    local tmp = dir .. '/manifest.tmp'
    if not write_encoded(tmp, m) then return false end
    return pcall(vim.uv.fs_rename, tmp, dir .. '/manifest.bin')
end

local function read_manifest(root)
    local dir, nroot = M.path(root)
    local m = read_decoded(dir .. '/manifest.bin')
    if type(m) == 'table' and m.version == M.VERSION and m.root == nroot
        and type(m.stamps) == 'table' then
        return m, dir
    end
    return nil, dir
end

-- bucket a graph into per-file shard tables (nil want = all files)
local function build_shards(data, want)
    -- synthetic ids: never persisted (their edges either) — sql entities
    -- and db-linked tables re-derive as post-passes, landings re-search
    local synth = {}
    for _, n in ipairs(data.nodes) do
        if n.id:sub(1, 5) == 'sql::' or n.unparsed or n.db or n.dj then
            synth[n.id] = true
        end
    end
    local shards = {}
    for f in pairs(want) do
        shards[f] = { nodes = {}, edges = {}, calls = {},
            stamp = data.stamps[f],
            names = data.names and data.names[f] or nil }
    end
    for _, n in ipairs(data.nodes) do
        local s = not synth[n.id] and shards[n.file]
        if s then s.nodes[#s.nodes + 1] = n end
    end
    for _, e in ipairs(data.edges) do
        if not (synth[e.from] or synth[e.to]) then
            local s = shards[file_of(e.from)]
            if s then s.edges[#s.edges + 1] = e end
        end
    end
    for _, c in ipairs(data.calls or {}) do
        local s = shards[c.file]
        if s then s.calls[#s.calls + 1] = c end
    end
    return shards
end

local function manifest_of(data, sizes)
    return { version = M.VERSION, root = data.root, schema = data.schema,
        provider = data.provider, -- which source: dispatch key for diff/refresh
        stamps = data.stamps, unparsed = data.unparsed,
        capabilities = data.capabilities, no_parser = data.no_parser,
        sizes = sizes } -- per-shard byte lengths: truncation detector
end

--- Sweep shard files the manifest no longer references. Deletion is a
--- TOMBSTONE BY OMISSION: load() reads only manifest-referenced shards,
--- so garbage is inert — reclaiming it is never on the hot path.
--- Deferred by default; { sync = true } runs now and returns the count.
M._gc_pending = {}
function M.gc(root, opts)
    local function sweep()
        M._gc_pending[root] = nil
        local m, dir = read_manifest(root)
        if not m then return 0 end
        local keep = { ['manifest.bin'] = true, ['manifest.tmp'] = true }
        for f in pairs(m.stamps) do keep[fkey(f)] = true end
        local removed = 0
        local it = vim.uv.fs_scandir(dir)
        while it do
            local name = vim.uv.fs_scandir_next(it)
            if not name then break end
            if not keep[name] then
                vim.fn.delete(dir .. '/' .. name)
                removed = removed + 1
            end
        end
        return removed
    end
    if opts and opts.sync then return sweep() end
    if M._gc_pending[root] then return end
    M._gc_pending[root] = true
    vim.defer_fn(sweep, 2000)
end

--- Persist a raw graph, synchronously. `dirty` (list of rels) limits the
--- write to those files' shards — the caller owes an HONEST account of
--- every file whose contribution changed (splice reports one); nil
--- writes everything. Deletions need no unlink: the manifest omits them
--- (tombstone), gc reclaims the files later. Post-pass artifacts (sql::
--- entities, frontier landings) are stripped — they re-derive; unparsed
--- bundle modules live in the manifest and are synthesized at load.
function M.save(data, dirty)
    if require('cartograph.config').cache == false then return end
    -- persistable <=> stamps: the source supplied wire-free validity
    -- keys, whatever it is. Samples (no stamps) never persist.
    if not (data and data.provider and data.stamps) then return end
    local dir = M.path(data.root)
    vim.fn.mkdir(dir, 'p')
    M._bg_cancel(data.root) -- a sync save supersedes an in-flight one

    local want = {}
    if dirty then
        for _, f in ipairs(dirty) do
            if data.stamps[f] then want[f] = true end
        end
    else
        for f in pairs(data.stamps) do want[f] = true end
    end
    -- sizes for untouched shards carry over from the previous manifest
    local old = dirty and read_manifest(data.root) or nil
    local sizes = {}
    for f in pairs(data.stamps) do
        sizes[f] = old and old.sizes and old.sizes[f] or nil
    end
    for f, s in pairs(build_shards(data, want)) do
        local n = write_encoded(dir .. '/' .. fkey(f), s)
        if not n then
            return vim.notify('cartograph: cannot write cache shard for ' .. f,
                vim.log.levels.WARN)
        end
        sizes[f] = n
    end
    -- manifest LAST: the commit point (any skew re-splices at next diff)
    write_manifest(dir, manifest_of(data, sizes))
    M.gc(data.root)
end

-- Background full save: ENCODE NOW (immutable strings — post-passes may
-- mutate the live graph the moment we return, encoded bytes can't lie),
-- write on a timer, manifest last. Cancelling (a newer save for the same
-- root) simply never writes the manifest: the old one stands, and any
-- shard file already overwritten re-splices at the next diff — the
-- commit-point discipline makes partial background work harmless.
M._bg = {}
function M._bg_cancel(root)
    local t = M._bg[root]
    if t then
        M._bg[root] = nil
        pcall(function () t:stop(); t:close() end)
    end
end

function M.saving(root)
    local _, nroot = M.path(root)
    return M._bg[nroot] ~= nil
end

function M.save_bg(data)
    if require('cartograph.config').cache == false then return end
    if not (data and data.provider and data.stamps) then return end
    local dir = M.path(data.root)
    vim.fn.mkdir(dir, 'p')
    M._bg_cancel(data.root)

    local want = {}
    for f in pairs(data.stamps) do want[f] = true end
    local jobs, sizes = {}, {}
    for f, s in pairs(build_shards(data, want)) do
        local bytes = M.encode(s)
        jobs[#jobs + 1] = { file = dir .. '/' .. fkey(f), bytes = bytes }
        sizes[f] = #bytes
    end
    local manifest = manifest_of(data, sizes)

    local i, root = 1, data.root
    local timer = vim.uv.new_timer()
    M._bg[root] = timer
    timer:start(0, 15, vim.schedule_wrap(function ()
        if M._bg[root] ~= timer then return end -- superseded
        local stop = math.min(i + 255, #jobs)
        while i <= stop do
            local fd = io.open(jobs[i].file, 'wb')
            if fd then
                fd:write(jobs[i].bytes)
                fd:close()
            end
            i = i + 1
        end
        if i > #jobs then
            write_manifest(dir, manifest)
            M._bg_cancel(root)
            M.gc(root)
        end
    end))
end

-- the empty shell a load fills: manifest metadata, no graph body yet
local function empty_data(m)
    return { schema = m.schema or 1, root = m.root,
        provider = m.provider or 'treesitter', capabilities = m.capabilities,
        no_parser = m.no_parser, stamps = m.stamps,
        nodes = {}, edges = {}, calls = {}, names = {} }
end

-- read one shard iff intact (present, untruncated per the manifest length,
-- decodable, shaped) — else nil, which the caller treats as a changed file
local function read_shard(dir, f, m)
    local path = dir .. '/' .. fkey(f)
    local want = m.sizes and m.sizes[f]
    local st = vim.uv.fs_stat(path)
    if not (st and (not want or st.size == want)) then return nil end
    local s = read_decoded(path)
    if type(s) == 'table' and type(s.nodes) == 'table' then return s end
    return nil
end

-- concat one shard's contribution into the growing graph
local function absorb(data, f, s)
    for _, n in ipairs(s.nodes) do data.nodes[#data.nodes + 1] = n end
    for _, e in ipairs(s.edges or {}) do data.edges[#data.edges + 1] = e end
    for _, c in ipairs(s.calls or {}) do data.calls[#data.calls + 1] = c end
    if s.names then data.names[f] = s.names end
end

-- frontier bundles: modules synthesized from the manifest roster
local function synth_unparsed(data, m)
    if not (m.unparsed and #m.unparsed > 0) then return end
    data.unparsed = m.unparsed
    for _, f in ipairs(m.unparsed) do
        data.nodes[#data.nodes + 1] = { id = f, name = f, kind = 'module',
            file = f, unparsed = true, order = -1,
            range = { start = { line = 0, char = 0 },
                ['end'] = { line = 0, char = 0 } } }
    end
end

--- Load a cached graph for `root`: manifest + every shard, concatenated
--- in sorted order (deterministic). A CORRUPTED SHARD (truncated —
--- caught by the manifest's byte length — undecodable, or misshapen)
--- costs exactly that file: it is skipped and reported in the `bad`
--- list, and the caller re-extracts it like any changed file.
--- Extraction is a pure function of file content, so the repair is
--- exact. Only a bad MANIFEST misses the whole cache.
--- Returns (data, bad) or nil.
function M.load(root)
    if require('cartograph.config').cache == false then return nil end
    local m, dir = read_manifest(root)
    if not m then return nil end
    local data = empty_data(m)
    local files, bad = {}, {}
    for f in pairs(m.stamps) do files[#files + 1] = f end
    table.sort(files)
    for _, f in ipairs(files) do
        local s = read_shard(dir, f, m)
        if s then
            absorb(data, f, s)
        else
            bad[#bad + 1] = f
            data.stamps[f] = nil -- its content is NOT represented
            data.names[f] = nil
        end
    end
    synth_unparsed(data, m)
    return data, bad
end

--- Load asynchronously: the manifest read is sync (a few KB), but the shards
--- DECODE IN BACKGROUND CHUNKS on a timer, so a big corpus never blocks the
--- editor the way a whole-cache read would. Returns the file roster
--- synchronously (so the caller can stub the browser at once) or nil if there
--- is no manifest. on_chunk(data, done, total) fires as shards land (data
--- grows in place); on_done(data, bad) fires once at the end. Deterministic:
--- same sorted concat as M.load, just spread across ticks.
function M.load_async(root, on_chunk, on_done)
    if require('cartograph.config').cache == false then return nil end
    local m, dir = read_manifest(root)
    if not m then return nil end
    local data = empty_data(m)
    local files, bad = {}, {}
    for f in pairs(m.stamps) do files[#files + 1] = f end
    table.sort(files)
    local i, finished, per = 0, false, 64
    -- yield the decode out of active-typing windows (a keystroke is human
    -- input — vim.on_key never fires for our own edits), bounded by MAX_HOLD so
    -- we never stall; the per-tick shard count adapts to keep each block small.
    local QUIET_MS, MAX_HOLD, TARGET = 80, 1200, 8
    local last_input, hold_start = 0, nil
    local okk, kid = pcall(vim.on_key, function () last_input = vim.uv.hrtime() end)
    local timer = vim.uv.new_timer()
    -- a shard tick can outlast the 12ms interval on a big cache, so libuv fires
    -- again and schedule_wrap QUEUES extra callbacks. Once we reach the end and
    -- close, those queued callbacks must NOT re-enter (double close + double
    -- on_done) — the `finished` latch drops them.
    timer:start(0, 12, vim.schedule_wrap(function ()
        if finished then return end
        -- a key landed within QUIET_MS and we haven't held too long: skip this
        -- decode tick, keep the editor instant; the repeating timer retries
        local since = (vim.uv.hrtime() - last_input) / 1e6
        local held = hold_start and ((vim.uv.hrtime() - hold_start) / 1e6) or 0
        if i < #files and since < QUIET_MS and held < MAX_HOLD then
            hold_start = hold_start or vim.uv.hrtime()
            return
        end
        hold_start = nil
        local t0 = vim.uv.hrtime()
        local stop = math.min(i + per, #files)
        while i < stop do
            i = i + 1
            local f = files[i]
            local s = read_shard(dir, f, m)
            if s then
                absorb(data, f, s)
            else
                bad[#bad + 1] = f
                data.stamps[f] = nil
                data.names[f] = nil
            end
        end
        -- keep each decode block near TARGET ms so it can't hitch a keystroke
        local ms = (vim.uv.hrtime() - t0) / 1e6
        if ms > TARGET * 1.5 then per = math.max(16, math.floor(per / 2))
        elseif ms < TARGET / 2 then per = math.min(512, per * 2) end
        if i >= #files then
            finished = true
            if not timer:is_closing() then timer:stop(); timer:close() end
            if okk then pcall(vim.on_key, nil, kid) end
            synth_unparsed(data, m)
            on_done(data, bad)
        elseif on_chunk then
            on_chunk(data, i, #files)
        end
    end))
    return files
end

-- The warm/cold decision, from the MANIFEST alone (a few KB — no shard
-- reads). Returns (m, changed, deleted) when a warm open is worth it, or
-- (nil, note). A warm open must never lose to a cold one: the splice
-- re-extracts changed files SEQUENTIALLY, while cold is parallel and streams,
-- so past the break-even (≈ total/workers) we step aside WITHOUT reading a
-- shard. note is nil for "no cache" (silent cold) and a string for a
-- deliberate step-aside (diff unavailable / too many changed).
local function warm_decision(root)
    local m = read_manifest(root)
    if not m then return nil end
    local src = require 'cartograph.source'
    local p = src.provider(m)
    -- warm-openable <=> the source can diff and re-extract slices
    if not (p and p.diff and p.refresh_slice) then return nil end
    local changed, deleted = p.diff(m)
    if not changed then
        return nil, 'diff unavailable (' .. tostring(deleted) .. ') — cold'
    end
    local cfg = require 'cartograph.config'
    local total = vim.tbl_count(m.stamps)
    if m.provider == 'treesitter' or not m.provider then
        local would_parallel = cfg.parallel ~= false
            and total >= (cfg.parallel_threshold or 300)
        local limit = cfg.cache_max_diff or math.max(32,
            math.floor(total
                / require('cartograph.parallel').default_workers()))
        if (would_parallel or cfg.cache_max_diff) and #changed > limit then
            return nil, ('%d files changed (warm limit %d) — cold extract'
                .. ' is faster, going parallel'):format(#changed, limit)
        end
    end
    return m, changed, deleted
end

-- Bring a freshly-loaded warm graph up to date: fold corrupted shards into
-- the changed set, splice the diff, persist exactly the dirtied shards
-- (deleted files tombstoned by manifest omission; gc reclaims). Returns the
-- honest note. Shared by the sync and streamed opens.
local function finalize_warm(data, bad, changed, deleted, total, tag)
    if bad and #bad > 0 then
        local seen = {}
        for _, f in ipairs(changed) do seen[f] = true end
        for _, f in ipairs(bad) do
            if not seen[f] then changed[#changed + 1] = f end
        end
        table.sort(changed)
    end
    if #changed == 0 and #deleted == 0 then
        return ('%s — %d files unchanged'):format(tag, total)
    end
    local stats = require('cartograph.refresh').splice(data, changed, deleted)
    M.save(data, stats.dirty)
    return ('%s — %d re-extracted, %d deleted, %d shards rewritten, rest'
        .. ' untouched%s'):format(tag, #changed, #deleted, #(stats.dirty or {}),
        (bad and #bad > 0)
            and ('; %d corrupted shard(s) repaired'):format(#bad) or '')
end

--- The incremental open: cached graph brought up to date, or nil (cold).
--- Returns (data, note) — note says what happened, honestly. This is the
--- BLOCKING path: it reads and decodes every shard before returning. For a
--- large corpus prefer M.open_async (init picks per warm_streamable).
function M.open(root)
    if require('cartograph.config').cache == false then return nil end
    local m, changed, deleted = warm_decision(root)
    if not m then return nil, changed end -- changed carries the note (or nil)
    -- committed to warm: NOW read the shards. Corrupted ones cost exactly
    -- their own file — they join the changed set and re-extract.
    local data, bad = M.load(root)
    if not data then return nil end
    local note = finalize_warm(data, bad, changed, deleted,
        vim.tbl_count(m.stamps), 'warm open')
    return data, note
end

--- Would a warm open of `root` be big enough to stream? True iff there is a
--- manifest, its source is treesitter (the only source with a parallel cold
--- path to mirror), and the roster clears the parallel threshold. A cheap
--- manifest read — the caller uses it to choose M.open (sync) vs open_async.
function M.warm_streamable(root)
    if require('cartograph.config').cache == false then return false end
    local cfg = require 'cartograph.config'
    if cfg.parallel == false then return false end
    local m = read_manifest(root)
    if not m then return false end
    if not (m.provider == 'treesitter' or not m.provider) then return false end
    return vim.tbl_count(m.stamps) >= (cfg.parallel_threshold or 300)
end

--- The incremental open, STREAMED: identical result to M.open, but the shards
--- decode in background chunks so the editor never blocks. The warm/cold
--- decision is made synchronously from the manifest; on a warm commit the
--- caller's cb.on_stub(files) fires at once (browser opens on module stubs),
--- cb.on_chunk(data, done, total) as shards land, and cb.on_done(data, note)
--- when the splice has brought it up to date. Returns true when it went warm
--- (async in flight), or (false, note) when the caller should go cold.
function M.open_async(root, cb)
    if require('cartograph.config').cache == false then return false end
    local m, changed, deleted = warm_decision(root)
    if not m then return false, changed end
    local total = vim.tbl_count(m.stamps)
    local files = M.load_async(root, cb.on_chunk, function (data, bad)
        cb.on_done(data, finalize_warm(data, bad, changed, deleted, total,
            'warm open (streamed)'))
    end)
    if not files then return false end
    if cb.on_stub then cb.on_stub(files) end
    return true
end

return M
