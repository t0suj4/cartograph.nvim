-- df / flow PARITY CHECK — the shared core behind tools/dfgate.lua (the
-- per-corpus CLI gate) and tools/guards.lua (the dogfood run, which checks the
-- SELF corpus inline on its already-extracted data). Pure: operates on an
-- already-extracted `data` table, no extraction or exit of its own.
--
-- ── THE ORACLE IS A REAL TWO-IMPLEMENTATION CHECK, AND HERE IS WHY IT STILL IS ──
-- Read df.lua alone and this looks circular: "since df-strangler step 6 df IS
-- flow.coarse, derived at extract with no separate build". Comparing coarse(flow)
-- against a df that IS coarse(flow) would prove nothing.
-- IT IS NOT CIRCULAR, and the reason lives in the CALLERS, not here: every caller
-- extracts with `legacy_df = true` — tools/dfgate.lua:66, tools/matrix.lua:216,
-- tools/guards.lua:39 — which builds the INDEPENDENT `dfreg` df alongside flow. So
-- `df.get(n)` under those extracts is the independent builder's answer and
-- `flow.coarse(flow.record(n))` is the derived one, and the two really are separate
-- implementations of the same contract.
-- STATED HERE BECAUSE check() CANNOT SHOW IT: this module just reads df.get(n), so
-- which df that is depends entirely on how the caller extracted. Anyone reading only
-- check() plus df.lua concludes the gate is vacuous — I did, and had to be corrected
-- by matrix.lua's own comment ("comparing production df to flow.coarse would be
-- circular. legacy_df builds the INDEPENDENT dfreg"). A NEW CALLER THAT FORGETS
-- `legacy_df` SILENTLY TURNS THIS GATE VACUOUS: it would compare coarse(flow) with
-- itself, report near-parity, and pass forever.
--
-- Three things it guards, in descending order of what they would catch:
--   1. THE PARITY CONTRACT — coarse(flow) reproduces the independent dfreg's
--      per-statement def/use, MODULO the labelled classes below.
--   2. THE CFG INVARIANT SWEEP — `flow-invariant-errors` counts functions where
--      successors / liveness / reaching_cfg THROW, over every function in a corpus.
--      A whole-corpus crash sweep of the CFG algorithms that no other gate performs,
--      and it gates even where the census is uncalibrated (matrix.lua:223). It was a
--      side number in the summary line; it deserves naming.
--   3. THE GRANULARITY RESIDUAL, pinned per corpus and EXPLAINED below rather than
--      merely tolerated.
--
-- ── WHY A RESIDUAL SURVIVES, and it is granularity rather than disagreement ──
-- The two are INDEXED differently. dfreg's row is per-OUTER-FUNCTION and absorbs names
-- from NESTED closures; flow.record(n) is per-NODE, and a nested closure is its own
-- node with its own flow. Verified on
-- jquery (df-over-collects=12): at event.js:750
--     jQuery.each( { focus: "focusin", … }, function( type, delegateType ) {
--         function focusMappedHandler( nativeEvent ) { … }
-- df's def set for the outer row carries `event, handle` and flow's does not, because
-- those belong to the inner function. Same shape at ajax.js:91/294. So the residual is
-- a permanent GRANULARITY difference, not a leak and not drift — which is exactly why
-- the gate pins exact counts rather than a budget: a real one-sided regression has the
-- same set-shape and only the COUNT distinguishes it.
--
-- Every divergence class is LABELLED and the full per-corpus census is PINNED
-- (M.EXPECTED); the gate fails on ANY class-count delta. Exact counts, not a
-- residual budget: a one-sided regression (a fix in flow.du but not df, or vice
-- versa) has the SAME set-shape as a flow-more-correct class, so only the COUNT
-- moving is a reliable signal.
--
-- Use from a headless driver (over an already-extracted `data` table — no
-- extraction/exit of its own; the CLI wrapper is tools/dfgate.lua):
--   local dfp = dofile('tools/dfparity.lua')
--   local r = dfp.check(data)              -- { cats, instances } — the census
--   print(dfp.census(r.cats))             -- one-line labelled count
--   local delta = dfp.diff(r.cats, dfp.EXPECTED[name])  -- {} = parity, else classes
--   -- inspect one class: dfp.show_instances(r.instances[class] or {}, class)

local ts = require 'cartograph.providers.treesitter'
local flow = require 'cartograph.flow'
local df = require 'cartograph.df'
local store = require 'cartograph.store'
local atr = require 'cartograph.at'

local M = {}

-- per-corpus EXPECTED census (calibrated on a known-good rev). A deliberate
-- flow/df change recalibrates the affected entry (review the delta first),
-- exactly like the structure gate's --save. Uncalibrated corpus → nil.
-- (calibrated with PER-FILE language detection: each file checked under its own
-- grammar, matching extraction. This removed mis-parse artifacts that a single
-- corpus-lang produced — e.g. cpp's .sh files and libs' native .rs/.cpp.)
-- RECALIBRATED 2026-07-12 when flow moved to the STORED source (df-strangler
-- step 4): the census now compares the ACTUAL extracted+folded flow vs df, with
-- NO re-parse node-resolution. This DISSOLVED a class of harness artifacts —
-- `partition-mismatch`/`disjoint` and re-parse-induced flow-over-collects/OTHER
-- collapsed to ~0 (they were the walk mis-picking minified/nested-JS fns sharing
-- a start position, + the .ts-under-JS boundary), and `df-over-collects` (the
-- REAL closure-leak divergences) rose as leaks got attributed to the right node.
-- Net: cleaner, truer censuses. (self churns with cartograph's own code.)
-- PINNED CENSUS, PER CORPUS. Only a corpus with a pinned `rev` can hold one; a LIVING
-- corpus changes under the pin, so `self` deliberately has NO entry here (CART-0024
-- diagnosed it years-of-commits ago: "self is a LIVING corpus … so it can never hold a
-- fixed baseline"). tools/dfgate.lua skips a living corpus for the same reason, and
-- tools/guards.lua PRINTS self's census as context without gating on it, which is the
-- right treatment for a number that legitimately moves.
M.EXPECTED = {
    -- ★★ RECALIBRATED 2026-08-10 (CART-0381): THE DEF/USE CHECK NOW RUNS ON EVERY FUNCTION.
    -- It used to be the ELSE BRANCH of the partition check, so a function whose coarse
    -- partition had moved was never def/use-compared at all -- and moving the partition is
    -- exactly what opening a control form does. The gate stopped looking at a function
    -- precisely when the change most likely broke it, which is how a collection loop's
    -- variable shipped as a FREE USE (CART-0363). Statements are now paired by LINE, so a
    -- partition change DEGRADES the comparison instead of skipping it, and what cannot be
    -- paired is COUNTED and PRINTED as `unpaired=` beside the compared count -- "0
    -- divergences" must never be readable as "we compared nothing".
    -- The counts below rose because COVERAGE rose, not because anything regressed:
    --   libs      stmts 22225 -> 26491 compared (+4266), df-over-collects 1727 -> 1814,
    --             flow-over-collects 300 -> 312, unpaired 2388
    --   synjs     269 -> 283 · php 33 -> 35 · mootools 28/28 -> 29/29 · jquery 26 -> 27
    -- NO new CLASS appeared anywhere -- no binding-as-use, no disjoint -- and the newly
    -- visible instances were sampled: enhanced-for LOOP VARIABLES flow defs and the legacy
    -- df walk does not, and lambda CLOSURE LEAKS df attributes to the enclosing statement.
    -- Both are the known flow-correct classes.

    -- NO `self` ENTRY, DELIBERATELY. It had one, and its comment trail had grown to 25
    -- lines recording ~30 separate recalibrations — "+11 df-over @ v50 const-fold, +4/+1
    -- @ v51 anon-fns, … +2 @ v57 proto-OOP self-typing" — each one us analysing our own
    -- newly-written source. That log IS the proof the pin cannot hold: every cut moved
    -- it, so a delta never meant a regression, and CART-0024 diagnosed exactly that
    -- ("self is a LIVING corpus … it can never hold a fixed baseline"). Removed rather
    -- than recalibrated once more: tools/dfgate.lua now skips a living corpus,
    -- tools/matrix.lua reports it as `~` (its own rule — gated where EXPECTED is
    -- calibrated, reported elsewhere), and tools/guards.lua prints self's census as
    -- context. The census for self is still WORTH LOOKING AT; it is just not a verdict.
    -- ★★ RECALIBRATED 2026-08-10 (CART-0363) — `partition-mismatch` IS NOW EXPECTED ON
    -- NINE CORPORA, and the number is a MEASUREMENT of how much more granular flow is than
    -- the legacy independent df walk, not a defect count. TWO changes contributed:
    --   1. part A's FOR-INIT SIBLING ROW (v124): a three-part `for` emits its init as a row
    --      BEFORE the head, because the init runs ONCE and the head runs per-iteration.
    --      That splits one coarse statement into two in EVERY language with `for_statement`
    --      — which is why this appears on cpp/go/php/js as well as java.
    --   2. this ticket's cpp `for_range_loop` + the JAVA CONTROL COMPLEX (enhanced-for,
    --      switch_expression/switch_block/switch_rule, synchronized, try-with-resources).
    --      Java switches were 100% opaque; opening them repartitions those bodies, and
    --      try-with-resources emits its ACQUISITION as a row before the head, like a for-init.
    --   3. ★ THE LOOP VARIABLE OF A COLLECTION LOOP IS NOW A DEF, not a use (flow's LOOPVAR).
    --      It never was — java `for (String s : xs)`, cpp `for (auto &x : v)` and js
    --      `for (const x of xs)` all reported `def={} use={s,xs}`, a READ of a variable
    --      nothing defines. That is what moved `flow-over-collects` (libs 5 -> 300, jquery
    --      0 -> 26, mootools 0 -> 28) and `df-over-collects` with it: the same single fact
    --      counted on two axes, because the name left `use` as it entered `def`.
    --      `disjoint` = 2 and `OTHER` = 3 on libs are RELABELLINGS of pre-existing closure
    --      leaks, not new divergences: flow's def set was EMPTY before (a subset of df's,
    --      hence `df-over-collects`), and a correct `{config}` simply stops being a subset.
    --      Every sampled instance is flow-correct. The libs STRUCTURE gate also moved and was
    --      re-saved: 10 calls `unresolved -> refused (fn-value)` in ScaleFunctionTests, all
    --      on the enhanced-for variable `k` — nodes/edges/refs IDENTICAL, only call
    --      disposition, and a named refusal beats the unknown bucket.
    -- ★ THE DIRECTION WAS CHECKED, NOT ASSUMED, because "the gate moved" is not evidence of
    -- which side is right. Every instance on cpp (993), libs (1064), go (22), php (29) and
    -- synjava (5) has flow > df; flow < df occurs ZERO times. flow never LOSES a statement,
    -- it only refuses to fold two into one. 969 of libs' 1064 differ by exactly +1.
    -- ★ AND THIS SHIPPED RED. Part A landed in 929c35f/8b2d982 without recalibrating here, so
    -- MATRIX/dfgate has been FAIL on main for every corpus with a three-part `for` since —
    -- the second time this repo has carried an untracked red matrix (CART-0232 was the
    -- first). The `struct`/`counts`/`fold`/`cache`/`par` columns stayed OK throughout, which
    -- is why nothing else noticed: this moves the coarse PARTITION and nothing else.
    php = { ['df-over-collects'] = 35, ['flow-over-collects'] = 13, ['partition-mismatch'] = 29 },
    -- cpp/go line-skew = the control-transfer LABEL unwrap (v33): a labeled loop /
    -- C label target now heads its own coarse row at the LOOP's line rather than
    -- the label's line — a 1-line cosmetic label difference, def/use unchanged.
    cpp = { ['line-skew'] = 8, ['partition-mismatch'] = 993 }, -- line-skew 11->8: a for-init row now heads the coarse stmt at the INIT's line, which is the loop's own line
    go = { ['df-over-collects'] = 34, ['flow-over-collects'] = 6, ['OTHER'] = 1,
        ['line-skew'] = 17, ['partition-mismatch'] = 22 }, -- +3 @ v51 anon-callback fns (alpinejs); +line-skew (labels);
    -- df-over-collects=27 closure-leaks; partition-mismatch=21 was the re-parse
    -- artifact (minified vendored JS), gone with stored flow.
    -- rust: all flow-MORE-correct — flow.du captures let/for/if-let bindings df
    -- misses (flow-over-collects), df leaks closure names (df-over-collects),
    -- and bare bindings swap def/use (binding-as-use). 0 flow-invariant errors.
    rust = { ['binding-as-use'] = 363, ['df-over-collects'] = 1980,
        ['flow-over-collects'] = 1988 },
    python = { ['df-over-collects'] = 4, ['flow-over-collects'] = 1 }, -- closure-leak/dedup, + ONE js file (django-oscar ships oscar/ui.js): `for (var level in …)` now DEFS `level`
    -- recalib 2026-08-07 (CART-0308, flow's nested-fn stop became per-language):
    -- 0 -> 2, both at active_support/deprecation/constant_accessor.rb:9 and both the
    -- SAME site — `extension = Module.new do … def const_missing … end`. Ruby's `method`
    -- / `singleton_method` were never in flow's stop-set (a hardcoded union built around
    -- lua/js/php names), so a `def` nested inside a block folded its whole body into the
    -- enclosing method's row. It stops now, and the body's rows live on the nested
    -- method's OWN node — which exists, because ruby's `functions` query mints
    -- method/singleton_method unconditionally. So this is the documented GRANULARITY
    -- class (dfreg indexes per OUTER function and absorbs; flow.record is per NODE), the
    -- same shape jquery has carried at 12 for years — NOT a leak.
    -- VERIFIED by reading both the source and the sets: df carries const_missing,
    -- class_variable_get, deprecate_constant … (the names DEFINED inside the block) and
    -- flow carries only `new`. Rows RELOCATED, not lost — and that distinction is the
    -- whole ticket, because a stop at an UNMINTED type deletes them instead. Measured
    -- when the two were conflated: ghost 6986 -> 28406, go 30 -> 1772.
    ruby = { ['df-over-collects'] = 45, ['flow-over-collects'] = 31,
        ['partition-mismatch'] = 5, ['line-skew'] = 22 }, -- recalib @ CART-0386: ruby `begin`/`rescue`/`ensure` was 100% OPAQUE (one row, body and handler with no rows at all) and now opens. flow-over-collects 0->31 = the EXCEPTION VARIABLE, which flow binds (`rescue E => e` defs `e`) and the legacy df walk does not; df-over-collects 15->45 is the SAME fact on the other axis, because `e` left `use` as it entered `def`. line-skew 1->22 and partition-mismatch 0->5 = a method-level `ensure` (`def … ensure … end`, no explicit begin) whose statements now get rows at THEIR OWN lines instead of folding into the `ensure` keyword's row. Direction checked: flow > df in 5/5, flow < df zero times. Prior: 2->15 @ part A (ruby's control OPENED, so df's flat walk under-collects inside opened bodies). Was {} (perfect parity)
    -- ghost = the JS scale corpus; df-over-collects (closure-leak) dominates. The
    -- old partition/disjoint/flow-over-collects residual was the re-parse .ts-
    -- under-JS + node-resolution artifact — gone with stored flow (OTHER=3 left).
    -- v51 anon-callback fns: their bodies (previously covered by NO fn) now get
    -- their own df/flow, surfacing catalogued closure-leak (df-over-collects) +
    -- pre-existing flow/dfreg diffs (OTHER) in now-covered code. ferr=0 (additive).
    -- recalib 2026-07-19: 6982→6986 (+4 df-over-collects) = v52-v88 JS/TS-pivot
    -- closure-leak catch-up, never re-gated (matrix couldn't complete pre-P1;
    -- dfpar is matrix-only). df/flow extraction untouched by P0/P1; ferr=0,
    -- categories unchanged. Same prior-work debt as ghost's count recalib.
    -- recalib 2026-08-02: 6986→7094 (+108 df-over-collects), ATTRIBUTED BY BISECT to
    -- b73d63e (v104, "JS/TS: a member-target function literal is a def") — the ONLY cut
    -- that moves it. Measured on the pinned checkout, one run per rev:
    --     b73d63e~1  fns=26141 stmts=99679  df-over-collects=6986   <- the old pin, exact
    --     b73d63e    fns=26425 stmts=101616 df-over-collects=7094
    --     969cd67~1 / 969cd67 (v107 module-level owner)  7094, unchanged
    -- So `X.y = function(){}` becoming a def added 284 functions and 1937 statements to
    -- ghost's df-bearing population, and the extra rows carry the SAME catalogued
    -- closure-leak — the mechanism the v51 note above describes ("their bodies, previously
    -- covered by NO fn, now get their own df/flow"). New fns leak a little above average
    -- (108/284 = 0.38 vs the corpus's 0.267 per fn), which is what function LITERALS should
    -- do: they are the callbacks. ferr=0, OTHER and receiver unchanged, so additive
    -- coverage and not a regression. v104 re-saved pinned counts and struct baselines for
    -- six corpora but not this table — the same "dfpar is matrix-only" debt as the line
    -- above, and the reason CART-0232 found the sweep already red.
    -- jquery/mootools/synjs/libs re-checked at the same time: all OK, so this was the only
    -- stale entry.
    ghost = { ['df-over-collects'] = 7094, ['OTHER'] = 9, ['receiver'] = 1 },
    jquery = { ['df-over-collects'] = 36, ['flow-over-collects'] = 27, ['OTHER'] = 2,
        ['partition-mismatch'] = 35 },
    mootools = { ['df-over-collects'] = 29, ['flow-over-collects'] = 29,
        ['partition-mismatch'] = 36 }, -- was {} (perfect parity, js archaeology tier)
    -- libs = elasticsearch: java + native rust/cpp, each checked under its own
    -- grammar. All flow-more-correct (closure-leak + bindings df misses).
    libs = { ['df-over-collects'] = 1814, ['flow-over-collects'] = 312, ['OTHER'] = 3,
        ['disjoint'] = 2, ['partition-mismatch'] = 1064 },
    -- nio: the annotated-lua tier (CART-0240). Calibrated on arrival rather than
    -- left reporting `~`, because it is PINNED and a pinned corpus can hold a
    -- baseline — an uncalibrated row is a note forever and gates nothing.
    nio = { ['binding-as-use'] = 9, ['df-over-collects'] = 105 }, -- @ 21f5324
    -- synthetic corpora (tools/gen.lua): deterministic content, so these
    -- censuses are exact for (GEN_VERSION, seed) — recalibrate on gen bumps
    synlua = { ['df-over-collects'] = 49 }, -- closure-leak, flow-correct (@ gen v5)
    synjava = { ['df-over-collects'] = 2, ['flow-over-collects'] = 2,
        ['partition-mismatch'] = 6 }, -- recalib @ gen v6 (CART-0377). It used to show ONLY the for-init split, because the generated java fixture contained ZERO switch / enhanced-for / synchronized / try-with-resources — the java GATE CORPUS could not have caught that java switches were 100% opaque. Ctrl.java now plants all 13 forms the grammar has, so the +1 partition-mismatch is try-with-resources' acquisition row and the flow-over-collects pair is the LOOP VARIABLE of an enhanced-for, which flow defs and the legacy df walk does not. Direction checked: flow > df in 6/6, flow < df zero times. Was {} (perfect parity) before part A.
    synjs = { ['df-over-collects'] = 283, ['flow-over-collects'] = 2,
        ['partition-mismatch'] = 8 }, -- closure-leak (arrows), flow-correct; 294->267 @ part A (for-of opened); +2/+2 @ gen v6 (CART-0377) = ctrl.js, whose for-of/for-in loop variables flow defs and df does not. ★ synjs held NO for_in_statement at all until v6, which is why the loop-variable def/use bug shipped through this gate untouched.
}

M.ORDER = { 'binding-as-use', 'df-over-collects', 'flow-over-collects',
    'receiver', 'df-empty-name', 'OTHER', 'disjoint', 'partition-mismatch', 'line-skew' }

local FN = { function_definition = true, method_declaration = true,
    function_declaration = true, method = true, function_item = true,
    method_definition = true, arrow_function = true }

local function toset(t) local s = {} for _, v in ipairs(t) do s[v] = true end return s end
local function sortset(s) local o = {} for k in pairs(s) do o[#o + 1] = k end table.sort(o) return table.concat(o, ',') end
local function eqset(a, b)
    for k in pairs(a) do if not b[k] then return false end end
    for k in pairs(b) do if not a[k] then return false end end
    return true
end
local function subset(a, b) for k in pairs(a) do if not b[k] then return false end end return true end
local function empty(a) return next(a) == nil end

-- label a per-axis divergence by its flow-vs-df set relationship (for humans;
-- gating is on the pinned census, not the label)
local function classify_axis(fs, ds)
    if eqset(fs, ds) then return nil end
    local sd = {}
    for k in pairs(fs) do if not ds[k] then sd[k] = true end end
    for k in pairs(ds) do if not fs[k] then sd[k] = true end end
    local only_empty, only_recv = true, true
    for k in pairs(sd) do
        if k ~= '' then only_empty = false end
        if k ~= 'this' and k ~= 'self' then only_recv = false end
    end
    if only_empty then return 'df-empty-name' end        -- df emits an empty name
    if only_recv then return 'receiver' end              -- this/self policy
    if subset(fs, ds) then return 'df-over-collects' end -- closure-leak / dedup (flow correct)
    if subset(ds, fs) then return 'flow-over-collects' end -- catch-bind / bare-local (flow correct)
    if not empty(fs) and not empty(ds) then
        for k in pairs(fs) do if ds[k] then return 'OTHER' end end
        return 'disjoint'
    end
    return 'OTHER'
end

--- Run the parity check over already-extracted `data`. Language is detected
--- PER FILE (ts.lang_of) — the same way extraction does — so a mixed-language
--- corpus (e.g. elasticsearch/libs = java + native rust/cpp) is each checked
--- under its own grammar, not a single nominal corpus lang.
--- Returns { cats = {class -> count}, ferr, nfn, nstmt, instances }. When
--- `collect` (a set {class=true}) is given, `instances[class]` gathers the
--- divergence instances (file/line/axis/flow/df/src) — the fix-side explorer
--- behind `dfgate --show <class>`.
function M.check(data, collect)
    local byfile = {}
    for _, n in ipairs(data.nodes or {}) do
        if (n.kind == 'function' or n.kind == 'method') and n.file and df.present(n) then
            byfile[n.file] = byfile[n.file] or {}
            table.insert(byfile[n.file], n)
        end
    end
    local cats, ferr, nfn, nstmt, nskip, instances = {}, 0, 0, 0, 0, {}
    local function record(c, info)
        if not c then return end
        cats[c] = (cats[c] or 0) + 1
        if collect and collect[c] then
            local l = instances[c]; if not l then l = {}; instances[c] = l end
            l[#l + 1] = info
        end
    end
    for file, nodes in pairs(byfile) do
        local lang = ts.lang_of(file)
        local spec = lang and ts.spec[lang]
        local ok_read, lines = false, nil
        if spec then ok_read, lines = pcall(vim.fn.readfile, store.abs_in(data, file)) end
        if ok_read and spec then
            local src = table.concat(lines, '\n')
            local okp, parser = pcall(vim.treesitter.get_string_parser, src, lang)
            if okp then
                local root = parser:parse()[1]:root()
                local byline = {}
                local function rec(nd)
                    if FN[nd:type()] then local sl = select(1, nd:range()); byline[sl] = byline[sl] or nd end
                    for c in nd:iter_children() do if c:named() then rec(c) end end
                end
                rec(root)
                for _, n in ipairs(nodes) do
                    local af = byline[atr.sl(n.range)]
                    -- SOURCE flow from the STORED graph (df-strangler step 4): the
                    -- eager-extracted + folded flow IS the shipped artifact, and
                    -- flow.record(n) is unambiguously node n's flow — no re-parse
                    -- node-resolution guesswork (which mis-picked minified/nested-JS
                    -- fns sharing a start position → false divergences). This makes
                    -- the census validate the ACTUAL stored flow vs df (the fusion
                    -- gate is now the census itself). Fall back to a fresh build only
                    -- for df fns WITHOUT stored flow (haskell's custom-df model).
                    local fl
                    if flow.present(n) then fl = flow.record(n)
                    elseif af then fl = select(2, pcall(flow.build, af, src, {
                        pfield = spec.params_field, df_ids = spec.df_ids, regime = spec.regime,
                        method = spec.is_method and spec.is_method(n.name or '', af) or false })) end
                    if fl then
                        do
                            nfn = nfn + 1
                            if not pcall(function () flow.successors(fl); flow.liveness(fl); flow.reaching_cfg(fl) end) then
                                ferr = ferr + 1
                            end
                            local co = flow.coarse(fl)
                            local dfs = df.get(n).stmts
                            -- ── STRUCTURAL signals: index-aligned, unchanged ──────────────
                            if #co ~= #dfs then
                                record('partition-mismatch', { file = file, l = atr.sl(n.range) + 1,
                                    note = ('%s: flow %d stmts vs df %d'):format(n.name or '?', #co, #dfs) })
                            else
                                for i, cs in ipairs(co) do
                                    if cs.l ~= dfs[i].l then
                                        record('line-skew', { file = file, l = cs.l,
                                            note = ('flow L%d vs df L%d'):format(cs.l, dfs[i].l) })
                                    end
                                end
                            end
                            -- ★★ AND THE DEF/USE COMPARISON RUNS REGARDLESS (CART-0381).
                            -- It used to be the ELSE BRANCH of the partition check, so the
                            -- moment a change altered a function's coarse PARTITION — which
                            -- is exactly what opening a control form does — that function's
                            -- def/use stopped being compared at all. The gate stopped looking
                            -- at a function precisely when the change most likely broke it,
                            -- and that is how `for (const x of xs)` shipped with the loop
                            -- variable as a FREE USE: dfparity had already classified those
                            -- functions partition-mismatch and moved on. An outer check
                            -- answering "different" is not a reason to stop asking the inner
                            -- question — it is a reason to ask it differently.
                            -- PAIR BY LINE, not by index, so a partition change DEGRADES the
                            -- comparison instead of skipping it: statements that exist on
                            -- both sides are still checked. A line that is not unique on both
                            -- sides is UNPAIRABLE (minified code puts several statements on
                            -- one line) and is COUNTED rather than silently dropped — an
                            -- absence rendered as a clean number is the defect this fixes.
                            local fbyl, dbyl, fdup, ddup = {}, {}, {}, {}
                            for _, cs in ipairs(co) do
                                if fbyl[cs.l] then fdup[cs.l] = true else fbyl[cs.l] = cs end
                            end
                            for _, ds in ipairs(dfs) do
                                if dbyl[ds.l] then ddup[ds.l] = true else dbyl[ds.l] = ds end
                            end
                            for _, cs in ipairs(co) do -- IN ORDER, so --show is deterministic
                                local ds = dbyl[cs.l]
                                if (not ds) or fdup[cs.l] or ddup[cs.l] then
                                    nskip = nskip + 1
                                else
                                    nstmt = nstmt + 1
                                    local fd, fu = toset(cs.def), toset(cs.use)
                                    local dd, du = toset(ds.def), toset(ds.use)
                                    local srcline = lines[cs.l]
                                    if eqset(fd, dd) and eqset(fu, du) then
                                        -- agree
                                    elseif eqset(fd, du) and eqset(fu, dd)
                                        and (not empty(fd) or not empty(fu)) then
                                        record('binding-as-use', { file = file, l = cs.l, src = srcline,
                                            axis = 'def/use swap', flow = sortset(fd) .. ' / ' .. sortset(fu),
                                            df = sortset(dd) .. ' / ' .. sortset(du) })
                                    else
                                        record(classify_axis(fd, dd), { file = file, l = cs.l, src = srcline,
                                            axis = 'def', flow = sortset(fd), df = sortset(dd) })
                                        record(classify_axis(fu, du), { file = file, l = cs.l, src = srcline,
                                            axis = 'use', flow = sortset(fu), df = sortset(du) })
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return { cats = cats, ferr = ferr, nfn = nfn, nstmt = nstmt, nskip = nskip,
        instances = instances }
end

--- Render collected instances of a class as report lines (the `--show` output).
function M.show_instances(list, class, cap)
    cap = cap or 40
    local n = list and #list or 0
    local L = { ('%s: %d instance(s)%s'):format(class, n, n > cap and (' (showing first ' .. cap .. ')') or ''), '' }
    for i = 1, math.min(n, cap) do
        local it = list[i]
        L[#L + 1] = ('%s:%d'):format(it.file, it.l)
        if it.note then L[#L + 1] = '    ' .. it.note end
        if it.src then L[#L + 1] = '    | ' .. it.src:gsub('^%s+', ''):sub(1, 76) end
        if it.flow or it.df then
            L[#L + 1] = ('    [%s]  flow={%s}  df={%s}'):format(it.axis or '', it.flow or '', it.df or '')
        end
    end
    return L
end

--- Census one-liner (the labelled divergence counts, stable order).
function M.census(cats)
    local seen, parts = {}, {}
    for _, k in ipairs(M.ORDER) do
        if cats[k] then parts[#parts + 1] = k .. '=' .. cats[k]; seen[k] = true end
    end
    for k, v in pairs(cats) do if not seen[k] then parts[#parts + 1] = k .. '=' .. v end end
    return #parts > 0 and table.concat(parts, ' ') or 'NONE'
end

--- Diff actual `cats` vs `expected` census → sorted list of "class e→a" strings
--- for every class whose count moved (empty = in parity).
function M.diff(cats, expected)
    local allk, diffs = {}, {}
    for k in pairs(cats) do allk[k] = true end
    for k in pairs(expected) do allk[k] = true end
    for k in pairs(allk) do
        local a, e = cats[k] or 0, expected[k] or 0
        if a ~= e then diffs[#diffs + 1] = ('%s %d→%d'):format(k, e, a) end
    end
    table.sort(diffs)
    return diffs
end

return M
