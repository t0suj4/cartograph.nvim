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

local segment = require 'cartograph.segment'
local callrec = require 'cartograph.callrec'
local dfmod = require 'cartograph.df'    -- raw materializer for the disk boundary (df.get)
local flowmod = require 'cartograph.flow' -- raw materializer for the disk boundary (flow.record)
-- fields the call SEGMENT carries; everything else on a call rides the residual
local CALL_SCALAR = {}
for _, g in ipairs({ segment.CALL_SCHEMA.strs, segment.CALL_SCHEMA.ints,
    segment.CALL_SCHEMA.flags }) do
    for _, f in ipairs(g) do CALL_SCALAR[f] = true end
end
-- range fields the segment carries WHEN table-valued (a non-table value — a
-- folded index — falls back to the residual, so both stay lossless)
local CALL_RANGE = {}
for _, f in ipairs(segment.CALL_SCHEMA.ranges or {}) do CALL_RANGE[f] = true end

-- pack a shard's calls → columnar segment (scalars) + residual (the non-scalar
-- fields: detail tables argv/at/refused + any field the schema doesn't name),
-- replacing shard.calls. LOSSLESS by construction — the residual carries
-- whatever the segment doesn't. ~50% smaller call bytes ([[cartograph-record-
-- fold-arc]] step 4); the raw detail tables still dominate the residual (step-4
-- A folds those). Round-trip is graphdiff-empty (extraction unchanged).
local function pack_calls(shard)
    local calls = shard.calls
    if not calls then return end
    shard.callseg = segment.encode(calls, segment.CALL_SCHEMA)
    local resid = {}
    for i = 1, #calls do
        local t = {}
        for k, v in pairs(calls[i]) do
            -- residual = non-scalar fields, EXCEPT a range the segment claims
            -- (table-valued); a non-table range value stays here as fallback
            if not CALL_SCALAR[k] and not (CALL_RANGE[k] and type(v) == 'table') then
                t[k] = v
            end
        end
        resid[i] = t
    end
    shard.calltab = resid
    shard.calls = nil
end

-- inverse (the load seam): reconstruct shard.calls from callseg + calltab
local function unpack_calls(shard)
    if not shard.callseg then return end
    local recs = segment.decode(shard.callseg, segment.CALL_SCHEMA)
    local tab = shard.calltab or {}
    for i = 1, #recs do
        local t = tab[i]
        if t then for k, v in pairs(t) do recs[i][k] = v end end
    end
    shard.calls = recs
    shard.callseg, shard.calltab = nil, nil
end

-- bump when the extractor's OUTPUT shape changes (new node fields,
-- resolution semantics) — a stale-format cache must miss, not mislead
M.VERSION = 127 -- v127: RUBY begin/rescue/ensure was 100% OPAQUE too — one row, body and
               -- handler with no rows at all — and `rescue E => e` now BINDS e (CART-0386).
               -- v126: cpp range-for, JAVA'S WHOLE SWITCH (100% OPAQUE), + A COLLECTION
               -- LOOP'S VARIABLE IS A DEF (it was a free USE in java, cpp AND shipped js)
               -- (CART-0363). flow's CTRL/PRELOOP sets are `*_statement`-shaped — one
               -- language's SPELLING — and a control node absent from them is emitted as a
               -- PLAIN ROW, so du harvests its whole subtree and THE BODY GETS NO ROWS AT
               -- ALL. Not a precision loss: no CFG, no per-statement def/use, nothing for
               -- df / reaching / liveness / LICM / CSE / untangle / extract / the clone
               -- tiers to read. MEASURED before: ghost 594 for-of/for-in sites folded,
               -- jquery 91; ruby opened ZERO control structures (2219 opaque on
               -- rails/activerecord alone).
               -- ★ THREADED FROM THE SPEC, NOT GROWN AS A UNION — the v120 precedent below,
               -- in this same list: a hardcoded cross-language union is how the set came to
               -- hold one language's spelling in the first place. New spec keys `ctrl` and
               -- `preloop`, registered in the CLOSED contract (which caught them missing).
               -- THIS BUMP COVERS js/ts/tsx `for_in_statement` AND RUBY. Ruby needed all
               -- FOUR node classes, which is the finding: its control is `if`/`while`/`case`
               -- (no `_statement` anywhere), its REGIONS are `then`/`do` rather than `block`,
               -- and its sub-regions are `elsif`/`else`/`when`. Adding only `ctrl` opens the
               -- loop and then folds its whole body into one row, because the container is
               -- not recognised as a region — measurably no better than before.
               -- `clause` is a MAP not a set (`{elsif='elseif', when='case'}`) because
               -- clause() dispatches on WHICH kind of sub-region a node is; a bare set would
               -- have needed two more spec keys to say the same thing.
               --   rails/activerecord/lib   opened 0 -> 2624, opaque 2219 -> 2   (100% -> 0%)
               --   rails/actionpack/lib     opened 3 ->  910, opaque  729 -> 3
               -- The modifier forms were the dominant remainder, not a corner: 738 `x if c`
               -- and 311 `x unless c` on activerecord against 1575 the block forms opened.
               -- STILL OUT: `while_modifier`/`until_modifier` (2 and 1 sites; `begin…end
               -- while` is POST-condition and that decision is not made here), cpp
               -- `for_range_loop`, java `enhanced_for_statement`, and ruby `each do` blocks
               -- (call-attached, execution count unknown — a different mechanism, part B).
               -- ★ AND A HEADER PART IS NOT A BODY STATEMENT: a for-of's `left`/`right` are
               -- fielded children that the body fallback would emit as rows appearing to run
               -- each iteration. Scoped to the spec-added types, so no lua/php/python row
               -- moves — verified byte-identical on this tree (exact 76/252, unchanged),
               -- while jquery moves 231/236 -> 233/238 and its blocks 156 -> 162, which is
               -- the point: a JS function's rows are now its statements.
               -- NO GATE RE-SAVE: tools/snapshot.lua projects nodes/edges/calls, and this
               -- repartitions rows WITHIN a function — no node or edge moves.
               -- v124: A THREE-PART `for`'s INIT CLAUSE IS NOT A BODY STATEMENT
               -- (CART-0359). `for (let i = 0; i < n; i++)` emitted its header
               -- initializer as a child of the loop, so it became the FIRST ROW OF THE
               -- BODY — and every consumer asking "what runs each iteration" then got the
               -- wrong answer on js/ts/cpp/java/php. LICM asked whether its value is the
               -- same every iteration (it is — it runs once) and offered hoisting a JS
               -- `let` out of the header, which breaks per-iteration binding: a closure
               -- made in the body then sees the final value ([0,1,2] -> [3,3,3], measured
               -- in node). Offered CERTIFIED and UNHEDGED, the worst presentation.
               -- The init is now an ordinary SIBLING row emitted before the head, which is
               -- what it is — `within()` is structural, so it stops being a loop member
               -- with no special case downstream. Persisted flow rows change ORDER and
               -- PARENT on those five languages, hence the bump.
               -- ★ NO GATE RE-SAVE. The snapshot projection is nodes/edges/calls
               -- (tools/snapshot.lua); `df` is not in it, and no node or edge moves —
               -- this repartitions rows WITHIN a function. Verified byte-identical on both
               -- clone corpora: self 77/253 + 169 blocks, jquery 231/236 + 156 blocks.
               -- ★ IT ALSO BROKE THE LABELED PATH, WHICH IS THE COUPLING WORTH KEEPING IN
               -- MIND: labeled_statement tagged `stmts[before + 1]`, assuming the first row
               -- emitted IS the head. With an init emitted first, `continue outer` began
               -- targeting `let i = 0`. emit() now RETURNS its head row and the label uses
               -- it — caught by the suite, not by reasoning.
               -- ★ SCOPED, and the residual is deliberate: lua's `for_numeric_clause` and
               -- go's `for_clause` are body rows too, and equally wrongly, but they have no
               -- sibling `condition` field so the discriminator does not reach them — and
               -- they escape LICM by row KIND rather than by luck of position. Moving them
               -- would reorder every lua function's rows for no soundness gain. The
               -- INCREMENT stays a body row: it genuinely runs each iteration.
               -- v123: A TEMPLATE THAT REUSES ITS HOST'S EXTENSION IS NOT THAT
               -- LANGUAGE (CART-0347). `x.blade.php` ends in `.php`, so lang_for claimed
               -- 96 Laravel templates per grocy. The php grammar does not ERROR on them —
               -- no `<?php` tag means the whole file is inline text, has_error=false — so
               -- they parsed "successfully" into 192 fabricated nodes named after
               -- template directives, while the 1608 calls they contain stayed invisible.
               -- A spec may now DISCLAIM a compound suffix (ext_disclaim). grocy -192
               -- nodes, Δrefs 0 — nothing referenced them, because they were never real.
               -- v122: THE SAME RUNG, DECLARED FOR THE OTHER LANGUAGES (CART-0344).
               -- Only 2 of 15 specs declared dynamic_callee_types, so measuring dynamic
               -- dispatch on a js/python corpus would have read 0 for lua's old reason.
               -- js `subscript_expression`, python `subscript`, php + the subscript form
               -- alongside its existing `variable_name`; node names verified by parsing
               -- a snippet per grammar rather than guessed. Measured after: python
               -- django-oscar 3 real sites, javascript ZERO across 134k calls — the
               -- indexed-callee form is RARE, and the php/ruby/js intuition is about
               -- NAME-based dispatchers (send, call_user_func) that this field cannot
               -- express.
               -- v121: THE `dynamic` RUNG NEVER FIRED FOR AN INDEXED CALLEE
               -- (CART-0345). `fsm[event]()` selects its callee at run time, so no
               -- static answer exists — that is the `dynamic` rung, "a call the graph
               -- KNOWS IT CANNOT SEE", and it is a different fact from `frontier`,
               -- which says only that WE failed. lua declared no dynamic_callee_types,
               -- so every such call landed in frontier. Measured before: 2 in
               -- bravest-new-world (both the FSM idiom that mod is built on) and 11
               -- here — ZERO of thirteen flagged. A literal key is excluded, because
               -- `handlers['init']()` names its member in the source: 11 literal-keyed
               -- callees against 11 computed ones here, so a bare node-type set would
               -- have been wrong half the time.
               -- ZERO EDGES MOVE — isolated on bnw against a baseline saved at HEAD,
               -- "graphs are identical (per-item)". The call RECORDS change (a flag,
               -- and a dynamic callee keeps its full text as php's already did), which
               -- is why a warm cache must miss rather than serve the old rung.
               -- v120: A FLOW STOP IS ONLY SOUND WHERE A NODE IS MINTED TO RECEIVE
               -- THE ROWS (CART-0308). flow's nested-function stop was a hardcoded
               -- cross-language union, so it lacked ruby `method`, rust `function_item`
               -- and odin `procedure_declaration` — a nested function on those
               -- languages folded its whole body into the ENCLOSING function's rows.
               -- Now threaded per-language from the spec.
               -- ★ AND THE SET IS NOT `fn_types`. "Which function encloses this node?"
               -- and "where does the walk stop?" are DIFFERENT QUESTIONS, and I
               -- conflated them first: stopping at a type the extractor never mints
               -- does not relocate the rows to a better owner, it DELETES them, because
               -- the owner does not exist. Measured by threading fn_types straight
               -- through and reading dfgate: go 30 -> 1772 divergences (`func_literal`),
               -- ghost 6986 -> 28406 (js `function_expression`), python 3 -> 66
               -- (`lambda`). Each spec now declares `fn_unminted` and the stop is
               -- LEGACY ∪ (fn_types \ fn_unminted).
               -- ★★ "MINTED" MEANS *ALWAYS* MINTED. js mints `function_expression` only
               -- as a declarator/pair value, an argument, or an assignment right — never
               -- as an IIFE head, the shape jquery and ghost are built from; and
               -- `method_definition` only when the key is a plain property_identifier,
               -- missing `#private` and `[computed]`. Both are therefore unsound stops,
               -- so JAVASCRIPT GAINS NONE: its def query is POSITIONAL, minting by where
               -- a function SITS rather than what it IS (CART-0313). jquery and mootools
               -- returning to their EXACT pinned censuses is what proved that reading.
               -- MEASURED, the whole point of the change — rows IDENTICAL, only the
               -- absorbed names go: ruby 3771 rows both sides, defs 908 -> 907, uses
               -- 10439 -> 10424; odin 89775 rows both sides, defs 21991 -> 21966, uses
               -- 398053 -> 397708. An unchanged row count with a smaller def/use census
               -- is precisely "relocated, not deleted" — the counterpart of v119's
               -- Δrefs = 0. dfparity: 13 of 14 corpora unmoved, ruby 0 -> 2 (one site,
               -- `Module.new do … def const_missing … end`, verified by reading it).
               -- v119: FIVE LANGUAGES HAD NO ENCLOSING FUNCTION, EVER (CART-0306).
               -- `in_function` — which decides a call's `encl` and its `top` marker
               -- during EXTRACTION — read `spec.fn_types or DEFAULT`, and that default
               -- is { function_definition, function_declaration }. Ruby, java, rust,
               -- odin and scheme have NEITHER node type, so for those five it returned
               -- nil for every node in every file: every call marked top-level, no call
               -- attributed to the function containing it. Go lost its methods, cpp and
               -- python their lambdas, js its generators — and php's declared entry read
               -- `anonymous_function_creation_expression`, a name the grammar had
               -- RENAMED, so php's anonymous functions were dark too. Every spec now
               -- declares fn_types, one accessor answers the question
               -- (ts.fn_types(lang)), and five modules that kept private partial copies
               -- read it instead. MEASURED with expr.of over a sampled def population,
               -- before -> after: jquery js 19% -> 100%, ghost js 31% -> 100% and ts
               -- 27% -> 100%, grocy js 9% -> 100%, server java 82% -> 100%. Controls
               -- behaved as controls: rust 99.5% -> 100% (its `function_item` happened
               -- to be in the union), ruby 90% -> 90% and grocy php 100% -> 100%, both
               -- unchanged BY CONSTRUCTION.
               -- ★ HASKELL STAYED AT 0% AND THAT IS THE INSTRUCTIVE ONE. It had already
               -- declared fn_types, so the prediction was 0 -> 100 — but expr's EXT map
               -- admits a language only if it has `body_field or body_of`, and haskell
               -- sets `body_field = nil` deliberately ("df comes from the custom hook
               -- below"). A SECOND gate, downstream of the one being fixed. Size a
               -- mechanism by the population meeting its precondition, and then check
               -- the CONSUMER's precondition too — the same lesson the previous arc
               -- wrote down and this change did not apply until the census refused it.
               -- ★ WHAT ACTUALLY MOVED IN THE GRAPH: java, rust and cpp — libs -24 nodes
               -- / -65 edges, ripgrep -26 / -25, server -340 / -1496 / +137, v8 -22 /
               -- -256. The predicate is sharp: a language moves iff its `vars` query is
               -- UNROOTED **and** its in_function could not see the enclosing scope.
               -- Unrooted are c, cpp, java, lua, rust, scheme; of those c and lua were
               -- already served by the shared default and scheme is still blind (now
               -- DECLAREDLY). Everyone else roots at `source_file`/`program` and never
               -- needed the predicate at all.
               -- WHAT THE REMOVED NODES WERE, verified by reading them: rust
               -- function-local `static RE` / `const ARGS_GZIP` declarations, java fields
               -- of ANONYMOUS CLASSES inside methods (ReleasableIterator.java's `private
               -- T value` lives in a `new ReleasableIterator<>() { … }` inside a static
               -- method), and cpp declarations inside LAMBDA bodies, which the set had
               -- never named. Each had been published as a MODULE-level variable of its
               -- file; this is fabrication going away, not coverage lost, and Δrefs = 0
               -- on all four corpora is the signature that says so.
               -- ⚠ THE 137 ADDED EDGES ON SERVER ARE NOT A WIN, and should not be read as
               -- one. They are `use` edges from a method to a `var:` in another file
               -- (AbstractGeometryFieldMapper::ignoreMalformed -> CustomTermFreqField's
               -- `var:value`). Removing the fabricated LOCAL variable did not make those
               -- references correct — it removed the local decoy that was absorbing them,
               -- so they fell through to a corpus-wide name match on a name as common as
               -- `value`. Same imprecision, relocated: a wrong local answer became a
               -- wrong global one ([[cartograph-linker]]'s measured ~10% name-match
               -- error). Net is -1359 edges and the removals are the real result; the
               -- additions are residue worth naming rather than counting as progress.
               -- Recalibrated: libs 13886 -> 13862, rust 3264 -> 3238, server 87241 ->
               -- 86901, v8 165859 -> 165837.
               -- ☠ AND I WROTE "java and rust, exactly and only" WHILE THE SWEEP WAS
               -- STILL RUNNING, then v8 came in and refuted it — the SECOND time in two
               -- arcs (7689a3e was the first). A control set chosen by prediction tests
               -- the prediction, not the change. Sweep every corpus, and do not write
               -- "exactly and only" until the last one has reported.
               -- The `top` marker moved on far more languages than that, and NO gate can
               -- see it — snapshot.slim does not project it and graphdiff's coutcome is
               -- resolution-only. Measured on a 3-call ruby file: top=3/not-top=0 before,
               -- top=1/not-top=2 after, with the ruby gate reporting the graphs identical
               -- (CART-0311: the projection a gate keeps is a claim about what matters,
               -- and every field left out of it is a silent exemption).
               -- ★ THE SHAPE OF THE BUG IS THE POINT. A union table is correct for
               -- whichever language you last checked and silently partial for every
               -- other, and the LANGUAGE FENCE cannot see it: a per-language TABLE is
               -- the pattern the fence tells you to move to, and it cannot tell a
               -- complete table from an incomplete one. specaudit now can, from both
               -- directions — every entry must EXIST in the grammar, and every node type
               -- the `functions` query is observed to capture as a def must be NAMED.
               -- v118: ODIN GETS FINE FLOW (CART-0305). Odin labels NEITHER its
               -- procedure body NOR its parameters — a `procedure_declaration` holds a
               -- `procedure` WRAPPER which holds the `parameters` and the `block`, and
               -- odin's whole field list has no `body` — so both field-based readers
               -- came back empty and odin had ZERO flow records: 31955 functions dark,
               -- silently, since a function with no flow record simply yields no
               -- findings. Added `body_of`/`params_of` to the spec capability contract
               -- as the POSITIONAL twins of body_field/params_field (a hook, not a
               -- `body_type` string: the body can nest arbitrarily deep). MEASURED:
               -- odin 0 -> 87736 flow rows / 21384 defs / 394115 uses, and expression
               -- records 0 -> 600 of 600 sampled. Third consumer needed the same hook
               -- (extractor, expr.of) and a FOURTH gate was expr's own hardcoded
               -- FN_TYPES, which lacked `procedure_declaration` — a partial per-language
               -- table the language fence cannot see, since it only flags direct
               -- comparisons (CART-0306).
               -- v117: A COMMENT IS NOT A STATEMENT IN JAVA OR RUST (CART-0304). flow's
               -- six comment skips all matched the single node name `comment`, which is
               -- what lua/ruby/php/python/go/js/c call it — java and rust call theirs
               -- `line_comment`/`block_comment` (+ rust `doc_comment`). So on those two
               -- SHIPPED languages every comment became a flow ROW: a statement with no
               -- def and no use, inflating the row count and the region tree. Folded at
               -- ingest (store.lua flow.fold), hence the bump. MEASURED: elasticsearch/
               -- libs 42766 -> 40354 rows (-5.6%), ripgrep 11906 -> 10955 (-8.0%), and
               -- defs/uses IDENTICAL in both — exactly the signature of phantom EMPTY
               -- rows going away rather than real statements being lost. Found by
               -- tools/langaudit.lua the first time flow.lua declared its @langs; it had
               -- been live in two languages and no test could see it, because the suite
               -- is lua-only. Same commit: ruby's `while (true)` now peels its parens
               -- (`parenthesized_statements`, which the peel did not know).
               -- v116: THE CONFINEMENT WALK RIDES THE MENTION WALK (CART-0236). The
               -- escape fact had its own per-file traversal, MEASURED at 15% of the whole
               -- extract on wow; it now rides the mention DFS, which was already holding
               -- that tree and already computing the one shape (callee) the rule turns on.
               -- Output is IDENTICAL by design and by measurement — per-node facts joined
               -- on identity agree on self/desynced/factorio/wow (4100 confined on wow, to
               -- the node), matrix counts+struct PASS on 29 corpora. The bump is for the
               -- ONE asymmetry the fold exposed: the surviving hook (now only the
               -- index-only front-ends, which never walk mentions) did not skip binding
               -- modifiers, so `local x <const>` counted as a mention of a symbol named
               -- `const` — the v112 fabrication, in the one collector that had kept it.
               -- Unobservable on every corpus here (it needs a file-local named `const`
               -- in a lua 5.4 file), which is precisely why a cache could carry the old
               -- answer without anything looking wrong.
               -- v115: A BINDING IS NOT A NAME MATCH (CART-0244). resolve_module_alias
               -- marked all its resolutions `inferred` (~), but that flag means "resolved
               -- by unique NAME" — the require BINDING pins the file and the call names the
               -- member. MEASURED: 1775 such edges on our own tree, 26.6% of the calls
               -- feeding swallowed-type. Both binding-derived stages (module_alias and
               -- field_alias) are now unhedged on the CALL and the EDGE alike; `inferred`
               -- is persisted, so the tier of those edges changes on disk.
               -- v114: MINTED EXTERNALS SURVIVE THE ROUND-TRIP (CART-0245). A stdlib
               -- symbol minted during resolution lives in a stampless pseudo-file
               -- (`zig-std`), so build_shards made no shard and dropped all 360 of zig's
               -- while KEEPING the 4122 edges into them — a warm graph with 4122 dangling
               -- targets. They ride the manifest now (the synth_unparsed precedent) and are
               -- re-synthesized at load. The bump forces a cold re-extract: a v113 cache
               -- has no `minted` list, so warm-opening it would stay broken.
               -- v113: `local f = mod.field` RESOLVES (CART-0237). New per-file fact
               -- `data.fieldalias` (the member-binding sibling of an import bind) plus a
               -- resolution pass that answers a BARE `f()` through it. +232 calls on
               -- factorio, +122 on our own tree, 0 corrections — the SE witness was 226
               -- calls whose answer sat on line 3 of every caller. New data table AND
               -- resolution semantics.
               -- v112: A BINDING MODIFIER READS NOTHING (CART-0234). lua 5.4's `local x
               -- <const>` parses as `attribute`, which is ALSO python's name for `a.b`, so
               -- the shared node-type maps harvested it as a field access with an empty
               -- name — a read of a variable called `const`. BOTH expr and du fabricated
               -- it, identically, which is why the expr self-gate reported agreement. The
               -- spec now declares `binding_modifiers` and both consumers skip it, so
               -- persisted df/flow `use` sets change on any lua 5.4 file.
               -- v111: SELF-TYPING SURVIVES A VENDORED LIBRARY (CART-0241). chain_lookup
               -- refused any corpus-wide duplicate, so an addon corpus that vendors its
               -- libs (wow: 24 copies of one Ace3 class) had every self:m() into them
               -- refused. It now falls back to same-file then same-scope, the ladder the
               -- main resolver already walks: +234 resolutions on wow. Resolution
               -- semantics, hence the bump.
               -- v110: ONE CANONICAL SOURCE TEXT (CART-0238). Extraction reads through
               -- transport.read_source now, which normalizes \r\n to \n, so a CRLF file
               -- is ONE string for every analysis reader instead of two (the display path
               -- has always stripped the CR — vim.fn.readfile). RANGES are unchanged:
               -- measured 0 of 4186 desynced ranges end past the CR-stripped line,
               -- because no token sits at the trailing CR. But node TEXT, string-literal
               -- VALUES and the frontier hash all change on a CRLF corpus, so a v109
               -- cache would hand back the other string — and on wow the GRAPH itself
               -- grows: a `\` + CRLF string continuation used to raise a parse ERROR and
               -- tear every def after it, so SuperDuperMacro.lua gained 90 nodes, 159
               -- edges and 623 calls.
               -- v109: A CONFINED FILE-LOCAL IS NOT A CALL TARGET (CART-0230). Two
               -- changes, one bump: fn nodes gained `escapes` (a file-local whose name
               -- is never mentioned in a value position in its own file), and both
               -- resolve drivers now REFUSE a cross-file name match into such a def.
               -- Node-field AND resolution-semantics change — 435 edges on our own
               -- tree stop being minted, so a v108 cache would hand back the phantoms.
               -- v108: LUA DECLARES ITS VISIBILITY (CART-0231). spec/lua.lua gained an
               -- `exported_def`, so lua fn nodes now carry exported = true/false where
               -- they carried nil. Every other spec with a visibility concept already
               -- did; lua's absence meant consumers reading the field as a boolean read
               -- ABSENCE AS FALSENESS (lsp hover called `function M.abs` `_local_`).
               -- Node-field change, hence the bump.
               -- v107: MODULE-LEVEL CALLS GET AN OWNER. A call outside any function
               -- resolved fine — target found, call.to set — and the edge was then
               -- dropped because its `from` was nil, so top-level code contributed
               -- nothing to the call graph. Von-Neumann measured 69 region nodes over
               -- 2045 source lines and 0 of its 110 call edges; `createScript`, called
               -- from a top-level `return function() … end`, read as 0 callers AND 0
               -- registrants. The bare-NAME path already kept its top-level evidence as
               -- a registration from the module, so the WEAKER evidence was retained
               -- while an actual CALL was discarded. The edge now hangs off the
               -- enclosing REGION node, which already existed with a name and a range.
               -- Additive by construction (only sites that produced no edge at all), in
               -- both the extract and relink twins. `call.fn` still means "a function" —
               -- consumers read it as one — so only the EDGE changed.
               -- ADDITIVE AS MEASURED over all 29 corpora: +12376 ref edges on the 23
               -- that moved, Δrefs == edges added EXACTLY on every one of them, nodes
               -- unchanged on every one, and 0 edges removed anywhere. It creates no
               -- resolutions — it stops discarding the edges of resolutions that already
               -- existed, so any `~`-tier noise it surfaces was already in the calls.
               -- Shares of the lift track how much of a language lives at file scope:
               -- rspec +2122 (15x — a ruby BLOCK is not a node, `@adef` being
               -- javascript-only, so every call inside describe/it was ownerless), scheme
               -- +2143 (60%, everything is a top-level form), python +244 (django's
               -- module-level get_model), java's region@0 = STATIC FIELD INITIALIZERS
               -- (server +1502, libs +166), zig/odin container scope (+476/+1244), v8's
               -- file-scope X-macro expansions (+549), sylius +1 (php class bodies have
               -- no statement run). jquery is unchanged because its body is one IIFE.
               -- COUPLED with the spec/scheme.lua DECL_FORM rule: a `define-module`
               -- `#:export`/`#:re-export` list was being read as calls, 707 of them in
               -- guile, several RESOLVED to the very function the list exports. Those were
               -- harmless while unowned edges were dropped; without that rule v107 would
               -- have promoted all 707 into fabricated self-call edges.
               -- Worker chunks are exempt (skip_idpass/defs_only/dataflow_only): a
               -- worker's slice-local resolution is PROVISIONAL, relink recomputes it
               -- against the whole graph, and edges are never retracted — attributing in
               -- a worker split the parallel graph from the inline one (haskell 12 vs 10,
               -- caught by the matrix `par` column, invisible to the spec suite).
               -- v106: RECEIVER-PATH AGREEMENT in the name resolver. A call `a.b.m()`
               -- and a candidate named `b.m` agree on the RECEIVER, which the bare tail
               -- `m` says nothing about; where exactly one admitted candidate agrees,
               -- that beats whichever name index answered first. PURELY ADDITIVE as
               -- measured — every changed call was an AMBIGUOUS REFUSAL before, and no
               -- corpus lost or redirected anything: go +69 (`h.PathSpec.RelURL()`, the
               -- embedded-field idiom), v8 +187 (`base::OS::Abort()`), ghost +14
               -- (`this.#MemberLinkClickEvent.create()`), rust +9
               -- (`grep::matcher::LineTerminator::crlf()`); the other 25 corpora are
               -- unchanged. A BARE candidate is deliberately NEUTRAL, never agreeing —
               -- see recv_agrees and tests/recvagree_spec.lua for why the obvious
               -- extension is unsound. New resolutions on disk, so a v105 cache is stale.
               -- v105: THE TWO NAME INDEXES ARE NOT ALTERNATIVES. resolve_module_alias
               -- and resolve_field_chain both wrote `tail[m] or exact[m]`, selecting an
               -- index by whether the tail list is empty ANYWHERE IN THE CORPUS rather
               -- than by whether it answers for THIS module — so the moment any file
               -- defined `<anything>.m`, a module's own BARE `m` went invisible to the
               -- binding-authoritative correction those passes exist to make. MEASURED:
               -- zig +47 resolutions, ghost +290 and 174 REDIRECTS (all sampled are
               -- corrections — `indexnow.listen()`, `registry.registerHelper()` and
               -- friends had been landing on a foreign namesake, one of them a test
               -- file's export), 0 lost on either, every other corpus unchanged.
               -- Resolution output changes, so a v104 cache would serve the old links.
               -- v104: JS/TS MEMBER-TARGET FUNCTION LITERALS ARE DEFS. `X.y = function(){}`
               -- minted nothing while `const f = function(){}` and `X.prototype.m = …` both
               -- did, so every pre-class export (`jQuery.extend`, `module.exports.reload`)
               -- was invisible as a definition. MEASURED first (tools/assigndef.lua: 6.4% of
               -- jquery's unresolved calls, 1.9% of ghost's), then gated: ghost +1844
               -- recovered / +663 out of a refusal / 311 redirected (sampled: corrections)
               -- / 0 lost. New NODES appear in every corpus holding .js — including the
               -- mixed ones (grocy, python, go), so their baselines move too. A v103 cache
               -- would serve graphs missing those defs and every call to them unresolved.
               -- Paired with spec.skip_def, which withholds the def when the receiver is a
               -- function-local object or `this` (see spec/javascript.lua for the four
               -- measured wrong resolutions that forced it).
               -- v103: THE REGISTRY MARK IS THE `reg` EDGE, not a node flag
               -- ([[cartograph-merging-strategies]]). The id pass used to flag a fn `cbarg`
               -- when a module-level mention put it in a dispatch table — the same branch that
               -- mints the `reg` edge, so the flag was a redundant copy. It was also harmful:
               -- cbarg gates the same-file CONFIRMED tier, and being a NODE field it was
               -- indistinguishable from the two classes that legitimately feed that gate (a
               -- table-field def; a callback argument). Because the id pass runs AFTER
               -- resolution, extract resolved before the flag existed and confirmed, while
               -- relink read it off the ingested node and hedged — the entire extract-vs-relink
               -- divergence tools/resolveparity measures (lua-spec 5 → 0). Extract was the side
               -- that was RIGHT, so the class is simply no longer fed to resolution.
               -- Extraction output: nodes that carried ONLY this class lose `cbarg` (lua-spec
               -- 107 → 87; rust/ruby unchanged). Tiers, edges and calls are byte-identical
               -- (three gate corpora per-item identical) — but a v102 cache holds the flags on
               -- disk, and a warm open would feed them straight back into resolution and
               -- resurrect the asymmetry. Hence the bump.
               -- v102: STACK-LANGUAGE ROOTS now open through the token provider
               -- ([[cartograph-stack-languages]]). A forth/postscript root previously extracted to
               -- an EMPTY tree-sitter graph, and that empty graph CACHES — so without a bump the
               -- warm path would keep serving "0 nodes" and the new provider would never run. Only
               -- affects roots that were empty anyway; every tree-sitter root's output is unchanged.
               -- v101: S2 SHAPE-ACTIVATED PACKS ([[cartograph-repo-shapes]]). With no explicit
               -- packs, ts.extract/parallel default them from the project shape (shapes.packs_for
               -- UP-walk) — a Rails app (or a sub-dir of one) auto-activates the `rails` pack, so a
               -- root cached packless pre-S2 is stale. Extraction-behavior change for DEFAULTED
               -- rails-shaped roots only (gate corpora pass explicit packs → counts unchanged) → bump.
               -- v100: PROFILE IDENTITY in the manifest ([[cartograph-repo-shapes]] stamping
               -- gap). manifest_of persists packs + profile + profile_stamp (artifact mtime/size);
               -- read_manifest re-derives the root's CURRENT profile identity and invalidates the
               -- cache on mismatch (shape/registry change activates a different profile, or the
               -- profile .mpack/.lua was edited); empty_data restores packs+profile so a refresh on
               -- a warm graph relinks with the same context. EXTRACTION-NEUTRAL (graph identical,
               -- gates unchanged) — manifest FORMAT change → bump so old manifests re-save clean.
               -- v99: UP-DIRECTION shape/profile activation ([[cartograph-repo-shapes]]).
               -- active_profile_for now walks ancestors (bounded, .git-stopped) so a sub-root
               -- INSIDE a shaped repo inherits its L2 profile — discourse/app/models activates
               -- the ruby-rails profile whose config/application.rb marker is two levels up.
               -- Extraction-behavior change on subdir-scoped rails corpora (rails/rspec now MINT
               -- the framework surface); framework-SOURCE repos (activesupport/lib) correctly stay
               -- inactive (no app marker). → bump + gate re-save (rails/rspec); base ruby unchanged.
               -- v98: RAILS ORM-FINDER receiver typing ([[cartograph-ruby-arc]] R5b-more).
               -- The rails pack's ctor_finders extends the R5 ctor-bind scan to Active-
               -- Record class finders that return a model instance (`x = User.find_by;
               -- x.foo` → User#foo), riding the existing recv-path resolution. Extraction-
               -- behavior change on rails-pack corpora only (+40 refs on rails, base ruby
               -- unaffected — finders are a pack input) → bump + gate re-save (rails/rspec).
               -- v97: RAW df/flow ON DISK (fat-record migration fix). P3 moved the
               -- df/flow fold to extract-end (before cache.save), so shards serialized
               -- the FOLDED form: every node's _df/_flow pointed at the ONE shared store,
               -- and string.buffer.encode duplicated that store per node → the cache blew
               -- to multi-GB (libs 14 GB, server 12 GB) and OOM'd on save. build_shards
               -- now reconstructs the raw per-file df/flow record (to_raw → df.get/
               -- flow.record) and drops the folded fields, restoring the pre-fold shard
               -- shape (raw, compact, per-file). GRAPH-IDENTICAL (dual-mode accessors read
               -- raw back; fold re-runs idempotently at ingest) — extraction unchanged, so
               -- gate-neutral. Format change over v96 (old shards carry the bloated folded
               -- form; a warm load would re-inflate it in memory) → bump invalidates them
               -- so they cold-re-extract compact. [[cartograph-thin-index]] fix (A).
               -- v96: CALL SEGMENT + RANGE columns — `at` (the biggest residual
               -- field, 5.2MB on zig calls) folds into 4 coordinate columns in
               -- the segment (segment.lua ranges) instead of a raw table in the
               -- residual. Cache shrink 58%/69% (self/zig calls). Format change
               -- over v95 (range columns added) → bump. Lossless (graphdiff-
               -- empty), gate-neutral. [[cartograph-record-fold-arc]] step 4 (A).
               -- v95: CALL SEGMENT — a shard's calls persist as a COLUMNAR
               -- segment (segment.lua: pooled strings + freq-varint) + a
               -- residual of the non-scalar fields, instead of full record
               -- tables. Cache-format change (old shards lack callseg) → bump;
               -- LOSSLESS round-trip (graphdiff-empty), extraction UNCHANGED so
               -- gate-neutral. ~50% smaller call bytes (self 1.8×, zig 2.2×;
               -- the raw detail tables argv/at/refused stay in the residual —
               -- step-4 A folds those too). [[cartograph-record-fold-arc]] step 4.
               -- v94: resolution PROVENANCE (the by_prov axis, [[cartograph-
               -- slice-api]] / [[cartograph-provenance-surfacing]]).
               -- run_resolve_passes stamps c.prov = 'base' / <pass name> /
               -- 'stdlib' (first-resolver-wins). New persisted call field →
               -- gate-NEUTRAL (graphdiff coutcome/esig + counts ignore prov),
               -- so no recalibration, but old caches lack the field → bump.
               -- v93: STD-ALIAS node-minting RESOLUTION face ([[cartograph-
               -- stdlib-profile]]). mint_std_nodes turns the std-alias
               -- disposition (c.stdpath) into a real resolution: one synthetic
               -- EXTERNAL node per canonical std symbol (`zig-std::std.mem.eql`),
               -- the call resolved to it, its ref edge stamped the `stdlib` tier
               -- (tier.lua). refs+nodes RISE (external stdlib resolutions);
               -- global+idempotent (inline extract + relink). LSP def/hover now
               -- target a real node.
               -- v92: STD-ALIAS deep-chain rung ([[cartograph-stdlib-profile]]).
               -- recv_root (zig) reads the leftmost id of a MULTI-level receiver
               -- chain (`std.mem.eql()` → "std"), stored as c.recvroot; the
               -- std-alias disposition keys c.recv or c.recvroot, so std written
               -- WITHOUT an alias is caught too. Disposition-only (c.to held);
               -- zig graphdiff moves, refs/nodes unchanged.
               -- v91: STD-ALIAS DISPOSITION ([[cartograph-stdlib-profile]] bucket A).
               -- zig `const assert = std.debug.assert; assert()` — a per-file
               -- name-set bound to the stdlib (spec.std_aliases → data.stdaliases)
               -- lets resolve_std_alias relabel unresolved calls whose ROOT is
               -- std-bound to the `std-alias` external face (self-evidencing: no
               -- profile, no curated free-set). c.to unchanged (refs/nodes hold);
               -- graphdiff structure moves on zig only (no-def/refused→unresolved-
               -- with-std-alias-why). Additive schema field: data.stdaliases.
               -- v90: LOCAL TYPE INFERENCE Z1b ([[cartograph-local-type-inference]],
               -- roadmap top lever). Zig `const x = C.init()/f(); x.m()` — a
               -- set-once local const typed by the callee's declared RETURN
               -- (def_ret → n.ret) → keyed Ret.m via the generalized
               -- resolve_returns (per-lang methodsep). +225 zig calls resolved
               -- (refused→to), 0 regressions, 0 name-mismatches (the free
               -- oracle: inferred method ∈ cands by construction). zig refs
               -- 20242→20404. java (resolve_returns shared) byte-identical.
               -- v89: TOTAL CALL DISPOSITION ([[cartograph-graph-improvements]]
               -- #1, roadmap P0.2). The resolver's SILENT nil returns are now
               -- tagged `c.ext = {disp, why}`: a callee outside the graph is
               -- EXTERNAL (vocab/prefix/exact-key/no-def) or NOISE (short),
               -- and census.disp() derives the one total disposition per call
               -- (resolved|refused|dynamic|external|noise). Additive — COUNTS
               -- UNCHANGED (zig refs 20242, nodes 9408 held); the 40,242 zig
               -- "unresolved" calls now decompose (vocab 13011 · no-def 14087
               -- · short 12081 · exact-key 1063) as a census query, not the
               -- D-bucketer's source regex. (n.src node provenance DEFERRED to
               -- Z1's bump — distributed ~20-site sweep, no present consumer.)
               -- v88: ODIN NODE-LOCAL TEARING (torn_by_node). A proc's key is
               -- `package.proc` and the package comes from the file-top `package`
               -- decl (before any parse error), so a proc after an error hasn't
               -- lost context — tear only defs whose OWN subtree errors, not
               -- everything after the first error line. The Odin grammar errors
               -- in big stdlib files (fmt.odin/io.odin ~L681); the default hid
               -- the most-used procs (fmt.aprintf, io.write_rune, sys/linux).
               -- MEASURED 19.13→20.56% (+2196 gained, 37 CORRECTIONS — platform
               -- variants that had resolved to the WRONG OS now resolve to their
               -- own file). −84 = big procs whose BODY spans the error (torn by
               -- subtree, kept by whole-file); no wrong edges, conservative
               -- refusals. Like bash/lua.
               -- v87: ODIN-R1 PACKAGE-QUALIFIED RESOLUTION. A proc in `package P`
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

-- The active L2 profile IDENTITY for a root: (name, artifact-stamp). Derived the
-- SAME way extraction derives it — shapes.profile_for's bounded ancestor walk
-- (UP-direction, [[cartograph-repo-shapes]]) — so read_manifest can detect when a
-- cached graph's resolution no longer matches: the shape/registry now activates a
-- DIFFERENT profile (or none), or the profile ARTIFACT was edited (stamp changes).
-- Lazy pcall-require (shapes needs only config; no cache cycle). nil,nil = no
-- profile (the common case — most roots), which matches a profileless manifest.
local function profile_id(nroot)
    local ok_s, shapes = pcall(require, 'cartograph.shapes')
    if not ok_s then return nil, nil end
    local pf = shapes.profile_for(nroot)
    if not pf then return nil, nil end
    local ok_p, profmod = pcall(require, 'cartograph.spec.profile')
    local stamp = ok_p and profmod.stamp_of and profmod.stamp_of(pf.profile) or nil
    return pf.profile, stamp
end

--- Was this graph built with a PROFILE OVERRIDE (CART-0217)? True when what the
--- graph records differs from what the root's shape would activate now.
---
--- Such a graph MUST NOT be persisted. read_manifest's gate compares a manifest's
--- profile against the shape-derived one, so an overridden graph could never be
--- served warm anyway — but it would still be WRITTEN, overwriting the shape-derived
--- cache and forcing the next ordinary open to re-extract cold. Refusing the write
--- is what stops an override from poisoning the default path.
---
--- It consults the SAME profile_id the read gate does, deliberately: two functions
--- deciding profile identity by different means is how the stamping gap arose in the
--- first place. Nothing has to be threaded here — the graph already records what it
--- was built with. Shared by BOTH save paths, because a guard on one of two is a
--- guard that will be forgotten.
local function profile_overridden(data)
    local _, nroot = M.path(data.root)
    return data.profile ~= (select(1, profile_id(nroot)))
end

--- Every DECLARATIVE ARTIFACT the graph's resolution consulted, as one key. No
--- longer composed by hand here: each artifact kind registers itself with
--- validity.contribute at load time and this folds whatever registered, so a new
--- kind enters the key with NO edit in this file. That is the recurrence guard —
--- the ecosystem spec once began shaping resolution while this summed only file
--- stamps, VERSION and the profile, and every warm cache went confidently stale.
--- The requires are what pull those registrations in; without them a contributor
--- declared in a module nobody loaded would silently not contribute.
local function artifact_key()
    pcall(require, 'cartograph.spec.profile')
    pcall(require, 'cartograph.spec.ecosystem')
    return require('cartograph.validity').artifact_key()
end

-- exposed for the spec (the `_field` convention), and CONSUMED through M so the
-- seam is live: a test that swaps this must actually change what validity computes,
-- or it proves nothing. A stamp nobody composes is not invalidation.
M._artifact_key = artifact_key

local function read_manifest(root)
    local dir, nroot = M.path(root)
    local m = read_decoded(dir .. '/manifest.bin')
    if type(m) == 'table' and m.version == M.VERSION and m.root == nroot
        and type(m.stamps) == 'table' then
        -- PROFILE IDENTITY gate: the profile the root activates NOW (name + artifact
        -- stamp) must equal what this cache was built with, else its minted/disposed
        -- resolution is stale ([[cartograph-repo-shapes]] stamping gap). A mismatch
        -- = a clean cache miss → cold re-extract. Profileless roots: nil == nil.
        local cur_prof, cur_stamp = profile_id(nroot)
        if m.profile ~= cur_prof or m.profile_stamp ~= cur_stamp then
            return nil, dir
        end
        -- ECOSYSTEM IDENTITY, same gate for the same reason: package-layout rules
        -- (identity, manifest name, precedence) shape resolution too. An OLD
        -- manifest carries no field here, so nil ~= the current stamp and it
        -- invalidates once — correct, and no VERSION bump: extraction output is
        -- unchanged, only what counts as still-valid.
        if m.ecosystem_stamp ~= M._artifact_key() then
            return nil, dir
        end
        return m, dir
    end
    return nil, dir
end

-- df/flow are folded to ONE shared columnar store, referenced by every node
-- (node._df / node._flow = the same store table). Serializing that per node would
-- DUPLICATE the whole store into every shard — string.buffer.encode does not dedup
-- shared table refs — which blew the cache to multi-GB (14 GB on libs) and OOM'd on
-- save. So at the DISK boundary we reconstruct the raw, per-file-LOCAL df/flow record
-- (df.get / flow.record, byte-identical to what extraction produced) and drop the
-- folded fields: shards stay raw + compact + per-file, exactly the pre-fold cache shape,
-- and dual-mode df/flow accessors read them straight back (fold re-runs at ingest,
-- idempotent). This mirrors `at` (folded at ingest, raw on disk) — df/flow were the one
-- fold that reached the save path. The in-memory graph keeps its folded store: to_raw
-- COPIES a folded node, never mutates the live one.
local FOLDED_FIELDS = { '_df', '_df0', '_dfn', '_dfi0', '_dfin',
    '_flow', '_flow0', '_flown', '_flowp0', '_flowpn' }
local function to_raw(n)
    if not (n._df or n._flow) then return n end -- already raw (un-ingested / refresh nodes)
    local out = {}
    for k, v in pairs(n) do out[k] = v end
    if n._df then out.df = dfmod.get(n) end
    if n._flow then out.flow = flowmod.record(n) end
    for _, k in ipairs(FOLDED_FIELDS) do out[k] = nil end
    return out
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
    -- node/edge proxies (nodecols/edgecols flag-on, post-ingest) materialize to
    -- plain records first, same as calls below — pairs() over a proxy yields its
    -- __cc backing (column closures), unserializable. No-op for real records.
    for _, n0 in ipairs(data.nodes) do
        -- __cc proxy → plain record; folded df/flow → raw per-file record (to_raw)
        local n = to_raw(rawget(n0, '__cc') and callrec.record(n0) or n0)
        local s = not synth[n.id] and shards[n.file]
        if s then s.nodes[#s.nodes + 1] = n end
    end
    for _, e0 in ipairs(data.edges) do
        local e = rawget(e0, '__cc') and callrec.record(e0) or e0
        if not (synth[e.from] or synth[e.to]) then
            local s = shards[file_of(e.from)]
            if s then s.edges[#s.edges + 1] = e end
        end
    end
    for _, c0 in ipairs(data.calls or {}) do
        -- a callcols proxy row (flag-on, post-ingest) cannot be packed directly:
        -- pairs() over it yields its __cc backing (column closures) → unserializable.
        -- Materialize it to a plain record first (no-op for a real record).
        local c = rawget(c0, '__cc') and callrec.record(c0) or c0
        local s = shards[c.file]
        if s then s.calls[#s.calls + 1] = c end
    end
    for _, s in pairs(shards) do pack_calls(s) end -- calls → segment + residual
    return shards
end

local function manifest_of(data, sizes)
    -- profile identity: name + artifact stamp (computed here from the name, so a
    -- producer only has to set data.profile). read_manifest re-derives the CURRENT
    -- identity for the root and invalidates on mismatch. packs are persisted so a
    -- warm-loaded graph carries them into a later refresh's relink (they were lost).
    local profile_stamp
    if data.profile then
        local ok, profmod = pcall(require, 'cartograph.spec.profile')
        profile_stamp = ok and profmod.stamp_of and profmod.stamp_of(data.profile) or nil
    end
    -- MINTED EXTERNALS (CART-0245): stdlib symbols minted during resolution live in a
    -- pseudo-file named for the profile (`zig-std`), which has no STAMP — so `want` never
    -- contains it, build_shards makes no shard for it, and all 360 of zig's std nodes were
    -- dropped on save while the 4122 edges INTO them were kept. A warm graph was not merely
    -- thinner: it carried 4122 DANGLING edge targets, and validate does not check
    -- referential integrity, so nothing said so.
    --
    -- THE MANIFEST IS THE RIGHT HOME, not a shard: shards are enumerated from
    -- `m.stamps`, and faking a stamp for a pseudo-file would put a non-file into the
    -- validity-key set every consumer reads for staleness. The precedent is already here —
    -- bundle/unparsed modules ride the manifest and are synthesized at load
    -- (synth_unparsed). And the VALIDITY KEY needs no invention: this manifest already
    -- carries profile + profile_stamp, and read_manifest invalidates the whole cache when
    -- the profile identity changes, which is exactly when a minted set would go stale.
    local minted
    for _, n in ipairs(data.nodes or {}) do
        if n.external and not (data.stamps or {})[n.file] then
            minted = minted or {}
            minted[#minted + 1] = { id = n.id, name = n.name, kind = n.kind,
                file = n.file, ret = n.ret, sig = n.sig }
        end
    end
    return { version = M.VERSION, root = data.root, schema = data.schema,
        minted = minted, -- see above; nil when the graph has none
        provider = data.provider, -- which source: dispatch key for diff/refresh
        ecosystem_stamp = M._artifact_key(), -- layout rules feed resolution
        stamps = data.stamps, unparsed = data.unparsed,
        capabilities = data.capabilities, no_parser = data.no_parser,
        packs = data.packs, profile = data.profile, profile_stamp = profile_stamp,
        -- INDEX-ONLY marker ([[cartograph-thin-index]] warm serving): a thin cache
        -- (defs only, no call graph) MUST stay marked across the round-trip so a warm
        -- reopen still reports is_index_only() — else the honesty guards (LSP caps
        -- withheld, whole-graph verbs refused) silently lapse. Full caches lack it (nil).
        index_only = data.index_only,
        sizes = sizes } -- per-shard byte lengths: truncation detector
end

-- ── THE SELF-TYPE MAP, as a persisted side file ─────────────────────────────
-- ([[cartograph-merging-strategies]], the calls half.) resolve_self's map is derived
-- from RESOLVED CALLS, so a cold thin index cannot compute one — persisting a
-- whole-graph map is the ONLY way a demand open can have it, which makes this
-- load-bearing rather than an optimisation.
--
-- A SIDE FILE, not a manifest field: the manifest is read on EVERY open and is the
-- commit point, while this map reaches 360 KB (wow). Paying that read when nothing
-- will ask for the map taxes the common path; lazily loaded, it costs nothing until a
-- materialization asks.
--
-- VALIDITY IS A STAMP DIGEST, not the cache version alone. The map names method ids
-- and classes from one corpus STATE; if a file changed, a stale map types against
-- classes that may have moved or gone — worse than no map, since it yields confident
-- wrong receivers instead of an honest refusal. The digest covers the exact stamp set
-- the map was derived from, and any drift discards it.
local SELFT_FILE = 'selft.bin'

local function stamp_digest(stamps)
    local fs = {}
    for f in pairs(stamps or {}) do fs[#fs + 1] = f end
    table.sort(fs)
    local parts = {}
    for i = 1, #fs do
        local s = stamps[fs[i]]
        parts[#parts + 1] = fs[i] .. '\31' .. (type(s) == 'table'
            and ((s.mtime or '?') .. ':' .. (s.size or '?')) or tostring(s))
    end
    return vim.fn.sha256(table.concat(parts, '\30'))
end

--- Persist a whole-graph self-type map for `root`. No-op without a map or stamps.
--- The flat form encodes a poisoned entry as `false` and a typed one as a SORTED class
--- array, so the blob is deterministic — a set's pairs() order is not.
function M.save_selft(root, map, stamps)
    if require('cartograph.config').cache == false then return false end
    if not (root and map and next(map) and stamps and next(stamps)) then return false end
    local flat = {}
    for id, v in pairs(map) do
        if v == false then flat[id] = false
        else
            local a = {}
            for c in pairs(v) do a[#a + 1] = c end
            table.sort(a)
            flat[id] = a
        end
    end
    local dir = M.path(root)
    vim.fn.mkdir(dir, 'p')
    local blob = vim.mpack.encode({ version = M.VERSION,
        digest = stamp_digest(stamps), map = flat })
    -- the manifest's temp-then-rename discipline, for the same reason: a half-written
    -- map must never be readable, because a truncated one decodes into a PARTIAL map,
    -- which is exactly the unsound input this artifact exists to prevent
    local tmp = dir .. '/selft.tmp'
    local fd = io.open(tmp, 'wb')
    if not fd then return false end
    fd:write(blob)
    fd:close()
    return (pcall(vim.uv.fs_rename, tmp, dir .. '/' .. SELFT_FILE)) and true or false
end

--- Load it back, or nil when absent / from another cache version / derived from a
--- different corpus state. Rehydrates class arrays into sets, the shape resolve_self
--- seeds from.
function M.load_selft(root, stamps)
    local rec = read_decoded(M.path(root) .. '/' .. SELFT_FILE)
    if type(rec) ~= 'table' or rec.version ~= M.VERSION or type(rec.map) ~= 'table' then
        return nil
    end
    if rec.digest ~= stamp_digest(stamps) then return nil end -- the corpus moved
    local out = {}
    for id, v in pairs(rec.map) do
        if v == false then out[id] = false
        else
            local s = {}
            for _, c in ipairs(v) do s[c] = true end
            out[id] = s
        end
    end
    return out
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
        -- the self-type map is manifest-INDEPENDENT: it must outlive a thin re-save,
        -- which is the entire point, since a partial graph never produces one. So the
        -- sweep must not read "unreferenced" as "garbage" for this file.
        local keep = { ['manifest.bin'] = true, ['manifest.tmp'] = true,
            [SELFT_FILE] = true, ['selft.tmp'] = true }
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
    if profile_overridden(data) then return end -- CART-0217: see profile_overridden
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
    -- the SELF-TYPE MAP, before the manifest and only from a WHOLE graph: a partial
    -- graph's map is the unsound one this artifact exists to displace, so a thin save
    -- must leave any existing map untouched rather than overwrite it with its own.
    if not data.index_only then
        local st = package.loaded['cartograph.store']
        local map = st and st.selft_map and st.selft_map()
        if map then M.save_selft(data.root, map, data.stamps) end
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
    if profile_overridden(data) then return end -- CART-0217: see profile_overridden
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
        -- restore the activation context so a refresh on a warm graph relinks with
        -- the SAME packs/profile it was built with (empty_data dropped both before)
        packs = m.packs, profile = m.profile,
        -- carry the thin-index marker back so is_index_only() holds on a warm reopen
        index_only = m.index_only,
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
    if type(s) == 'table' and type(s.nodes) == 'table' then
        unpack_calls(s) -- segment + residual → shard.calls
        return s
    end
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
-- MINTED EXTERNALS come back from the manifest (CART-0245). Same shape the minting site
-- builds (kind='external', order=-1, a zero range) so a warm node is indistinguishable from
-- a cold one — the cache column's per-item diff is what proves that.
local function synth_minted(data, m)
    if not (m.minted and #m.minted > 0) then return end
    for _, x in ipairs(m.minted) do
        data.nodes[#data.nodes + 1] = { id = x.id, name = x.name,
            kind = x.kind or 'external', file = x.file, external = true, order = -1,
            ret = x.ret, sig = x.sig,
            range = { start = { line = 0, char = 0 },
                ['end'] = { line = 0, char = 0 } } }
    end
end

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
    synth_minted(data, m)
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
            synth_minted(data, m)
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
    -- a FULL open must never consume a thin (index-only) cache: it has no call
    -- graph, so finish() would serve a complete-looking graph with 0 calls. Treat
    -- it as a miss → cold full extract (which overwrites the thin cache).
    if m.index_only then return nil end
    -- committed to warm: NOW read the shards. Corrupted ones cost exactly
    -- their own file — they join the changed set and re-extract.
    local data, bad = M.load(root)
    if not data then return nil end
    local note = finalize_warm(data, bad, changed, deleted,
        vim.tbl_count(m.stamps), 'warm open')
    return data, note
end

--- Warm-open the INDEX-ONLY cache for `root` ([[cartograph-thin-index]] warm symbol
--- serving): reuse the persisted def shards instead of re-parsing the tree (~15x on an
--- unchanged repo). Deliberately CONSERVATIVE — serves warm ONLY from an index_only
--- cache with a CLEAN diff (zero changed/deleted files). A full cache is rejected (it is
--- heavier than the thin-index contract, and the caller wants the cheap symbol index),
--- and ANY change falls back to a cold defs-only re-index. This is because finalize_warm
--- splices changes through refresh.splice, which re-extracts AND relinks FULL — that would
--- pollute the thin graph with a call graph and defeat the point; a per-file defs-only,
--- relink-free incremental splice is the banked refinement. Returns (data, note) or nil.
function M.open_index_only(root)
    if require('cartograph.config').cache == false then return nil end
    local m, changed, deleted = warm_decision(root)
    if not m or not m.index_only then return nil end -- no thin cache / it's a full one → cold
    if (#changed > 0) or (deleted and #deleted > 0) then
        return nil, ('%d changed / %d deleted since the last index — cold re-index')
            :format(#changed, deleted and #deleted or 0)
    end
    local data, bad = M.load(root)
    if not data then return nil end
    if bad and #bad > 0 then return nil end -- a corrupted shard would splice FULL → go cold
    local note = finalize_warm(data, bad, changed, deleted,
        vim.tbl_count(m.stamps), 'warm index-only open')
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
    if m.index_only then return false end -- a thin cache never drives a full streamed open
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

-- exposed for the worker→parent IPC (parallel.lua): a worker packs its chunk's
-- calls to a segment before shipping (smaller chunk file), the parent unpacks on
-- receive — the same columnar codec as the disk cache, on the wire.
M.pack_calls = pack_calls
M.unpack_calls = unpack_calls

return M
