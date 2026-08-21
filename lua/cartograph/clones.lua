-- Exact-structural clone detection ([[cartograph-record-fold-arc]] near-clone arc,
-- the EXACT tier). Rides the shipped expression-IR (cartograph.expr): two functions
-- are exact-structural clones iff their per-row canonical key SEQUENCES are equal.
--
-- The key is ALPHA-INVARIANT on locals: a `name` node whose name is a param or a
-- df-def of the function is renamed to a first-occurrence positional slot (#1, #2, …),
-- numbered over the whole function so a given local is one slot everywhere. Callees,
-- globals, field names, operators, and literals are kept VERBATIM — they are the
-- discriminating signal, so `f(a,b)` and `g(a,b)` never collide (unlike the df-shape
-- signature in greenspun.clones, which sees only def/use counts + deps + callees and
-- needs a heuristic gate to suppress coincidences). This tier is exact — a difference of
-- one statement makes the sequences differ; catching those is the banked NEAR-clone tier
-- (AST anti-unification), which this substrate feeds.
--
-- SCOPE (honest): (1) re-uses expr.of per function (one whole-file re-parse each —
-- ~5ms/fn, fine for an on-demand tool, not a hot path). (2) locals = params ∪ df-defs;
-- a for-loop binder df does not record as a def stays a literal name — a rare
-- under-abstraction, documented, never a false MERGE (it only splits a real clone). (3)
-- FUNCTION-granular; block/window granularity (a clone inside one function, e.g. the
-- provider's resolve logic shared by extract & relink) is the next increment on this
-- same `canon` — sketched in M.blocks but not the first cut.

local expr = require 'cartograph.expr'
local at = require 'cartograph.at'

local M = {}

-- canonical structural key of one expr node, renaming locals to positional slots.
-- Mirrors expr.key but (a) rewrites local `name` nodes via slots/ctr, (b) is otherwise
-- identical so callee/field/literal/operator structure is preserved verbatim.
local function canon(e, locals, slots, ctr)
    if not e then return '_' end
    local k = e.k
    if k == 'name' then
        if locals[e.n] then
            if not slots[e.n] then ctr.n = ctr.n + 1; slots[e.n] = '#' .. ctr.n end
            return slots[e.n]
        end
        return 'N' .. e.n
    end
    if k == 'lit' then return 'L' .. (e.ty or '') .. ':' .. tostring(e.v) end
    if k == 'field' then
        return (e.method and 'M' or 'F') .. canon(e.b, locals, slots, ctr) .. '.' .. e.n
    end
    if k == 'index' then
        return 'I' .. canon(e.b, locals, slots, ctr) .. '[' .. canon(e.i, locals, slots, ctr) .. ']'
    end
    if k == 'call' then
        local parts = {}
        for _, a in ipairs(e.a or {}) do parts[#parts + 1] = canon(a, locals, slots, ctr) end
        return 'C' .. canon(e.f, locals, slots, ctr) .. '(' .. table.concat(parts, ',') .. ')'
    end
    if k == 'un' then return 'U' .. (e.op or '') .. canon(e.e, locals, slots, ctr) end
    if k == 'bin' then
        return 'B' .. (e.op or '') .. '(' .. canon(e.l, locals, slots, ctr)
            .. ',' .. canon(e.r, locals, slots, ctr) .. ')'
    end
    -- ★ A CONSTRUCTOR'S CONTENTS ARE PART OF THE KEY (CART-0357). A bare 'T' says only
    -- "an allocation happened here", so two functions returning DIFFERENT objects key
    -- identically and are reported as exact clones. The schema carries the kids
    -- deliberately (expr.lua: "its field VALUES/keys READ names — carry them as kids");
    -- discarding them here was throwing away content the IR had already harvested.
    -- Measured: on this tree it removes 4 manufactured groups (81 -> 77), and on jquery
    -- it is what keeps 12 unrelated ajax test callbacks from being called one clone.
    if k == 'table' then
        local kp = {}
        for _, c in ipairs(e.kids or {}) do kp[#kp + 1] = canon(c, locals, slots, ctr) end
        return 'T(' .. table.concat(kp, ',') .. ')'
    end
    if k == 'fn' then return 'Fn' end
    if k == 'vararg' then return 'V' end
    -- ★ AN EMBEDDED ASSIGNMENT, and the reason it CRASHED here rather than
    -- keying badly: `t` is the tree-sitter type STRING on every kind except
    -- `assign`, where the schema uses it for the assignment TARGET (a node).
    -- The fallthrough concatenated it. Same collision class as the expr
    -- attribute collision (a field name meaning two things), and unreachable
    -- from a lua corpus BECAUSE LUA HAS NO ASSIGNMENT EXPRESSION -- measured
    -- present in php, c and javascript, absent in python (the walrus builds a
    -- different node). Every clone tier over any of those languages raised
    -- "attempt to concatenate a table value" on the first such body.
    if k == 'assign' then
        return 'A(' .. canon(e.t, locals, slots, ctr) .. ','
            .. canon(e.v, locals, slots, ctr) .. ')'
    end
    local parts = {}
    for _, c in ipairs(e.kids or {}) do parts[#parts + 1] = canon(c, locals, slots, ctr) end
    return '?' .. (type(e.t) == 'string' and e.t or '') .. '('
        .. table.concat(parts, ',') .. ')'
end

-- one row (lhs = rhs [; cond]) canonicalized, sharing the function's slot map
local function row_key(row, locals, slots, ctr)
    local function seq(list)
        local p = {}
        for _, e in ipairs(list or {}) do p[#p + 1] = canon(e, locals, slots, ctr) end
        return table.concat(p, ',')
    end
    local key = seq(row.lhs) .. '=' .. seq(row.rhs)
    if row.cond then key = key .. ';C:' .. canon(row.cond, locals, slots, ctr) end
    return key
end

-- the alpha-invariant per-row canonical keys of a function body, with a SHARED
-- function-global slot map (a local is one slot everywhere). Returns (keys, lines,
-- nparams, exprs, locals) or nil — exprs/locals feed the near-clone anti-unifier.
-- Shared by signature (function tier) and the near-clone tier.
local function fn_row_keys(eo)
    local stmts = eo and eo.fl and eo.fl.stmts
    if not stmts or #stmts == 0 then return nil end
    local locals = {}
    for _, p in ipairs(eo.fl.params or {}) do locals[p] = true end
    for _, s in ipairs(stmts) do
        for _, d in ipairs(s.def or {}) do locals[d] = true end
    end
    local slots, ctr = {}, { n = 0 }
    local keys, lines, exprs = {}, {}, {}
    for _, s in ipairs(stmts) do
        keys[#keys + 1] = s.expr and row_key(s.expr, locals, slots, ctr) or '~'
        lines[#lines + 1] = s.l
        exprs[#exprs + 1] = s.expr
    end
    return keys, lines, #(eo.fl.params or {}), exprs, locals
end

--- The alpha-invariant structural signature of a function's body: (nparams, {row_key…}).
--- `eo` is the result of expr.of(store, id). Returns (sig_string, nrows) or nil when the
--- body has no harvestable rows.
function M.signature(eo)
    local keys, _, nparams = fn_row_keys(eo)
    if not keys then return nil end
    return ('p%d|%s'):format(nparams, table.concat(keys, '\n')), #keys
end

-- The per-fn key index is the costly part of clone detection (one expr.of per function
-- ~5ms → seconds repo-wide). Build it ONCE and cache by store.generation so every tier
-- (exact / block / near) and every focused/repeat query is instant after the first build
-- — the interactivity pattern ([[cartograph-interactive-analysis]]: amortize costly
-- analysis so the on-demand path is cheap). Generation bumps on any graph change (store
-- ingest) → sound eviction. Floored at 2 rows (a 0-1 stmt body can't be any tier's clone);
-- each tier applies its own min_rows over the cached fns. Each fn record carries keys +
-- lines + the row exprs (near anti-unifier) + locals + nparams + def line.
local index_cache
local INDEX_FLOOR = 2

local function build_index(store)
    if index_cache and index_cache.gen == store.generation then
        return index_cache.fns, index_cache.post
    end
    local fns = {}
    for _, n in ipairs(store.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.file then
            local ok, eo = pcall(expr.of, store, n.id)
            if ok and eo then
                local keys, lines, nparams, exprs, locals = fn_row_keys(eo)
                if keys and #keys >= INDEX_FLOOR then
                    fns[#fns + 1] = { id = n.id, name = n.name, file = n.file,
                        keys = keys, lines = lines, exprs = exprs, locals = locals,
                        nparams = nparams, line = n.range and (at.sl(n.range) + 1) or 0 }
                end
            end
        end
    end
    local post = {} -- inverted index of row-keys (key → fn indices)
    for i, f in ipairs(fns) do
        local seen = {}
        for _, k in ipairs(f.keys) do
            if not seen[k] then seen[k] = true; post[k] = post[k] or {}; post[k][#post[k] + 1] = i end
        end
    end
    index_cache = { gen = store.generation, fns = fns, post = post }
    return fns, post
end

--- Exact-structural clone GROUPS across the store's functions. Returns a list of groups,
--- each { nrows = N, [1..] = {id, name, file, line} }, sorted by (size desc, nrows desc).
--- opts.min_rows (default 3) filters trivial bodies. Rides the generation-cached index.
function M.exact(store, opts)
    local min_rows = (opts and opts.min_rows) or 3
    local groups = {}
    local fns = build_index(store)
    for _, f in ipairs(fns) do
        if #f.keys >= min_rows then
            local sig = ('p%d|%s'):format(f.nparams or 0, table.concat(f.keys, '\n'))
            local g = groups[sig]
            if not g then g = { nrows = #f.keys }; groups[sig] = g end
            g[#g + 1] = { id = f.id, name = f.name, file = f.file, line = f.line }
        end
    end
    local out = {}
    for _, g in pairs(groups) do
        if #g >= 2 then
            table.sort(g, function (a, b)
                if a.file ~= b.file then return a.file < b.file end
                return (a.line or 0) < (b.line or 0)
            end)
            out[#out + 1] = g
        end
    end
    table.sort(out, function (a, b)
        if #a ~= #b then return #a > #b end
        return a.nrows > b.nrows
    end)
    return out
end

-- ── block/window tier ───────────────────────────────────────────────────────
-- A block clone is a contiguous run of statements duplicated INSIDE functions
-- (the extract↔relink four-site resolve dup is a block, not a named fn — the
-- function tier is blind to it). Same `canon`, but the slot map is WINDOW-LOCAL:
-- renumbered fresh at each window so two structurally-identical blocks match
-- regardless of what locals their surrounding functions introduced first
-- (function-global numbering would shift the slots and miss the clone).

-- canonical key of rows[s .. s+len-1] with a FRESH slot map (window-local).
local function window_key(rows, locals, s, len)
    local slots, ctr = {}, { n = 0 }
    local parts = {}
    for i = s, s + len - 1 do
        parts[#parts + 1] = rows[i].expr and row_key(rows[i].expr, locals, slots, ctr) or '~'
    end
    return table.concat(parts, '\30')
end

-- collect every function's harvestable rows + its locals set (params ∪ df-defs)
local function collect_fns(store)
    local out = {}
    for _, n in ipairs(store.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.file then
            local ok, eo = pcall(expr.of, store, n.id)
            local stmts = ok and eo and eo.fl and eo.fl.stmts
            if stmts and #stmts > 0 then
                local locals = {}
                for _, p in ipairs(eo.fl.params or {}) do locals[p] = true end
                for _, s in ipairs(stmts) do
                    for _, d in ipairs(s.def or {}) do locals[d] = true end
                end
                local rows = {}
                for _, s in ipairs(stmts) do rows[#rows + 1] = { expr = s.expr, l = s.l } end
                out[#out + 1] = { name = n.name, file = n.file, locals = locals, rows = rows }
            end
        end
    end
    return out
end

--- Block/window clones: contiguous statement runs (≥ opts.min_len, default 4)
--- duplicated across (or within) functions. Seeds at min_len then EXTENDS each
--- matching bucket maximally to the right; contained spans are dropped so a long
--- shared block is reported once at its true length, not as overlapping windows.
--- Returns groups { len = N, [1..] = {name, file, from_line, to_line} }.
function M.blocks(store, opts)
    local min_len = (opts and opts.min_len) or 6
    local fns = collect_fns(store)
    -- seed: bucket every min_len-window by its window-local key
    local buckets = {}
    for fi, f in ipairs(fns) do
        for s = 1, #f.rows - min_len + 1 do
            local key = window_key(f.rows, f.locals, s, min_len)
            buckets[key] = buckets[key] or {}
            buckets[key][#buckets[key] + 1] = { fi = fi, s = s }
        end
    end
    -- extend a seed bucket maximally to the right: at each step re-key the
    -- occurrences one row longer and keep the largest sub-bucket that stays >=2
    local function extend(occ, len)
        while true do
            local grow = {}
            for _, o in ipairs(occ) do
                local f = fns[o.fi]
                if o.s + len <= #f.rows then -- room for one more row
                    local key = window_key(f.rows, f.locals, o.s, len + 1)
                    grow[key] = grow[key] or {}
                    grow[key][#grow[key] + 1] = o
                end
            end
            -- ★ THE TIE MUST BE BROKEN BY THE KEY, NOT BY HASH ORDER. `pairs` visits
            -- `grow` in whatever order the table happens to hash, so with a bare
            -- `#sub > #best` two equally-large extensions are decided by which one came
            -- up first — and that decides which span is maximal, which decides what the
            -- containment pass drops. Measured before this fix: the same tree at
            -- `51e3c4a^` reported 482 groups on three runs and 481 on a fourth, same
            -- code, same input. A detector whose OUTPUT SET moves between identical runs
            -- cannot have a rank quoted against it. Keying the tie makes M.blocks a pure
            -- function of its input again. (CART-0348)
            local best, bestk
            for k, sub in pairs(grow) do
                if #sub >= 2 and (not best or #sub > #best
                    or (#sub == #best and k < bestk)) then best, bestk = sub, k end
            end
            if best then occ, len = best, len + 1 else return occ, len end
        end
    end
    -- extend each seed bucket, collect maximal spans, then drop contained ones
    local spans = {}
    for _, occ in pairs(buckets) do
        if #occ >= 2 then
            local eocc, len = extend(occ, min_len)
            for _, o in ipairs(eocc) do
                spans[#spans + 1] = { fi = o.fi, s = o.s, len = len, group = eocc }
            end
        end
    end
    -- a span is CONTAINED if another span in the same fn covers [s, s+len)
    local keep = {}
    for _, sp in ipairs(spans) do
        local contained = false
        for _, ot in ipairs(spans) do
            if ot ~= sp and ot.fi == sp.fi and ot.s <= sp.s
                and (sp.s + sp.len) <= (ot.s + ot.len) and ot.len > sp.len then
                contained = true; break
            end
        end
        if not contained then keep[sp.group] = sp.len end
    end
    -- one report row per surviving group (dedup groups by identity)
    local out, seen = {}, {}
    for group, len in pairs(keep) do
        if not seen[group] then
            seen[group] = true
            local g = { len = len }
            for _, o in ipairs(group) do
                local f = fns[o.fi]
                g[#g + 1] = { name = f.name, file = f.file,
                    from_line = f.rows[o.s].l,
                    to_line = f.rows[math.min(o.s + len - 1, #f.rows)].l }
            end
            if #g >= 2 then
                table.sort(g, function (a, b)
                    if a.file ~= b.file then return a.file < b.file end
                    return a.from_line < b.from_line
                end)
                out[#out + 1] = g
            end
        end
    end
    table.sort(out, function (a, b)
        if a.len ~= b.len then return a.len > b.len end
        return #a > #b
    end)
    return out
end

--- CLASSIFY block groups by whether they can actually be EXTRACTED, and how narrow the
--- helper's signature would be (CART-0341). Annotates each group in place with
---   g.extract = { ok = bool, iface = #params + #returns, reason = <why not> }
---   g.nfiles  = how many distinct files the copies span
--- and returns `groups`.
---
--- ★ WHY THIS AND NOT A LENGTH FLOOR. blocks_report has tiered on `len >= 10` because
--- length was the only signal the block tier had. Length is the WRONG axis: measured on
--- this repo, the real extractions in its own git history (bytecol's LE-u32 primitives
--- across at/csr/fold, the scratch-window helper, `write` x10 across 14 spec files) are
--- all 5-25 duplicated lines per site — at or UNDER the floor. Meanwhile extractability
--- removes 501 of 586 groups (86%) on its own, which no threshold ever did: a block
--- carrying a return/break, or nested inside a loop, is not a candidate at ANY similarity.
---
--- ★★ AND analyze_pair CANNOT DO THIS JOB, which is worth stating where someone would
--- reach for it: M.blocks buckets windows by an EXACT window_key, so a group's members
--- are structurally identical by construction and the anti-unifier would answer `exact`
--- for every group. The divergence classifier belongs to the NEAR tier; the block tier's
--- question is extractability.
---
--- Needs the store (extract.plan reads df / reaching / file content), which is why it is
--- separate from M.blocks — that stays PURE and store-free.
function M.classify_blocks(store, groups)
    local dfmod = require 'cartograph.df'
    local flowmod = require 'cartograph.flow'
    local extract = require 'cartograph.extract'
    local byname = {}
    for _, n in ipairs(store.data.nodes or {}) do
        if n.kind == 'function' or n.kind == 'method' then
            byname[(n.file or '') .. '\31' .. (n.name or '')] = n
        end
    end
    for _, g in ipairs(groups) do
        local files, nf = {}, 0
        for _, occ in ipairs(g) do
            if not files[occ.file] then files[occ.file] = true; nf = nf + 1 end
        end
        g.nfiles = nf
        -- ★ A REFUSAL MUST NAME ITS REASON, and there are TWO kinds here — the
        -- transport layer's split, one level up. `reason` is the PLANNER declining
        -- ("contains return/break"); `asked` false means we could not even put the
        -- question (no node, no df, no rows). Leaving the second as a nil reason
        -- would render an absence as silence, which is the defect this repo keeps
        -- finding — and this comment exists because the test below caught me doing it.
        local best, reason, asked = nil, nil, false
        for _, occ in ipairs(g) do
            local node = byname[(occ.file or '') .. '\31' .. (occ.name or '')]
            -- ★ NOT `node and pcall(...)`. In Lua an `and` TRUNCATES a multi-value
            -- expression to ONE value, so `local a, b = node and pcall(f)` binds b to
            -- nil however well the call went — every occurrence then looked
            -- unaskable and the whole report came back "could not ask" on 180 of 180
            -- groups. The guard has to be a statement, not an operand.
            local fl, df
            if node then
                local eok, eo = pcall(expr.of, store, node.id)
                fl = eok and eo and eo.fl or nil
                df = dfmod.get(node)
            end
            if fl and df and df.stmts then
                local pok, plan = pcall(extract.plan, {
                    df = df, sel = { first = occ.from_line, last = occ.to_line },
                    fn_start = at.sl(node.range) + 1, body_end = at.el(node.range),
                    file_lines = store.content(node),
                    reaching = flowmod.reaching_cfg(fl),
                    flow_rows = fl.stmts, fn_params = fl.params, name = 'candidate' })
                asked = true
                if pok and plan then
                    if plan.ok then
                        local iface = #(plan.params or {}) + #(plan.returns or {})
                        if not best or iface < best then best = iface end
                    elseif not reason then reason = plan.reason end
                end
            end
        end
        g.extract = { ok = best ~= nil, iface = best,
            reason = best ~= nil and nil
                or reason
                or (asked and 'the planner returned no reason'
                    or 'could not ask: no node, no df or no rows for any copy') }
    end
    return groups
end

--- Human-readable report lines for M.blocks groups.
function M.blocks_report(groups)
    if #groups == 0 then return { 'block-structural clones: none' } end
    -- ── CLASSIFIED: tier by EXTRACTABILITY, not length (CART-0341) ───────────
    -- When the caller has run M.classify_blocks, length stops being the tier and
    -- becomes a detail. A block carrying a return/break, or nested in a loop, is not
    -- a candidate at any similarity — and the narrow-interface short ones the length
    -- floor used to bury are exactly the shape this repo's own extraction commits
    -- have (5-25 duplicated lines per site).
    if groups[1] and groups[1].extract then
        -- ★★ EXTRACTABILITY IS AN ANNOTATION, NOT A SORT KEY — CORRECTED AGAINST THE
        -- ANSWER KEY. Ranking `ok` first sank the very seam this repo's own history
        -- says was real: at `c2a4158^` the LE-u32 pack loop is duplicated across
        -- at.lua / csr.lua / fold.lua, and BOTH groups landed at ranks 183 and 384 of
        -- 479, refused with "the selection contains return/break/goto".
        --
        -- That refusal is CORRECT for its own question and the wrong question here.
        -- extract.plan asks "can this FRAGMENT be lifted out in place", and a `return`
        -- mid-function genuinely cannot. But the duplication here is a whole function
        -- BODY, where the return IS the helper's return — which is exactly what the
        -- human did, moving it into bytecol.M.pack_u32. A seam is duplication worth
        -- sharing; auto-extractability is whether one particular verb can do it for
        -- you. Conflating them hides real seams behind a tool limitation.
        --
        -- So: SPREAD first (a shape repeated across modules is the signal), then how
        -- many copies, and extractability only as a tie-break and a label.
        local NARROW = 3
        table.sort(groups, function (a, b)
            if (a.nfiles or 0) ~= (b.nfiles or 0) then
                return (a.nfiles or 0) > (b.nfiles or 0)
            end
            if #a ~= #b then return #a > #b end
            if a.extract.ok ~= b.extract.ok then return a.extract.ok end
            if a.extract.ok and a.extract.iface ~= b.extract.iface then
                return a.extract.iface < b.extract.iface
            end
            if a.len ~= b.len then return a.len > b.len end
            -- ★ TOTAL ORDER — and the tie band here is WIDER than it looks. `iface` is
            -- only consulted when BOTH groups are extractable, so every DECLINED group
            -- is ordered by (nfiles, copies, len) alone — and most groups are 2 copies
            -- in 2 files. Without this key their relative order is whatever table.sort
            -- happened to do. Same reasoning as sort_pairs: determinism, not opinion.
            local ka = a[1] and ('%s:%d'):format(a[1].file, a[1].from_line or 0) or ''
            local kb = b[1] and ('%s:%d'):format(b[1].file, b[1].from_line or 0) or ''
            return ka < kb
        end)
        local crossfile, auto = 0, 0
        for _, g in ipairs(groups) do
            if (g.nfiles or 0) > 1 then crossfile = crossfile + 1 end
            if g.extract.ok then auto = auto + 1 end
        end
        local L = {
            ('block-structural clones — %d group(s): %d span MORE THAN ONE FILE;'
                .. ' %d the extract verb can lift automatically'):format(#groups,
                crossfile, auto),
            '(ranked by how many files the copies span, then how many copies. LENGTH is',
            ' a detail, not the tier: this repo\'s own extraction commits are 5-25',
            ' duplicated lines per site. And AUTO-EXTRACTABILITY is a label, not a rank —',
            ' the LE-u32 seam it once buried was a whole function body the verb refuses',
            ' and a human lifted in one commit.)',
            '(* = spans >1 file   + = one file   [auto] = the verb can lift it,'
                .. ' ≤' .. NARROW .. ' params   [manual] = a human can, the verb cannot)', '' }
        for _, g in ipairs(groups) do
            local mark = (g.nfiles or 0) > 1 and '*' or '+'
            if g.extract.ok then
                L[#L + 1] = ('%s %d copies in %d file(s), %d-statement block'
                    .. '  [auto, helper takes %d]'):format(mark, #g, g.nfiles or 0,
                    g.len, g.extract.iface)
            else
                L[#L + 1] = ('%s %d copies in %d file(s), %d-statement block'
                    .. '  [manual — the verb declines: %s]'):format(mark, #g,
                    g.nfiles or 0, g.len, g.extract.reason or 'no plan')
            end
            for _, m in ipairs(g) do
                L[#L + 1] = ('    %s  %s:%d-%d'):format(m.name, m.file, m.from_line,
                    m.to_line)
            end
        end
        return L
    end
    -- CONFIDENCE TIER (honesty): block matching is looser than whole-function, so a
    -- SHORT shared run is often coincidental structural rhyme (a guard+loop+return
    -- shape two unrelated functions happen to share). Measured on this codebase, blocks
    -- ≥ SOLID_BLOCK statements are the stable real-duplication signal; shorter ones are
    -- marked `~` (worth a glance, likely coincidence). Groups are already length-sorted.
    local SOLID_BLOCK = 10
    local solid = 0
    for _, g in ipairs(groups) do if g.len >= SOLID_BLOCK then solid = solid + 1 end end
    local L = {
        ('block-structural clones — %d group(s) (%d solid ≥%d stmts, %d shorter ~)')
            :format(#groups, solid, SOLID_BLOCK, #groups - solid),
        '(contiguous statement runs shared across/within functions; window-local alpha-invariance)',
        '(* = solid; ~ = short block, likely coincidental structural rhyme — glance, don\'t trust)', '' }
    for _, g in ipairs(groups) do
        local mark = g.len >= SOLID_BLOCK and '*' or '~'
        L[#L + 1] = ('%s %d copies, %d-statement block:'):format(mark, #g, g.len)
        for _, m in ipairs(g) do
            L[#L + 1] = ('    %s  %s:%d-%d'):format(m.name, m.file, m.from_line, m.to_line)
        end
    end
    return L
end

-- ── near-clone tier (AST anti-unification over row sequences) ────────────────
-- Two functions are NEAR-clones when their canonical row-key sequences differ by
-- only a few edits (Levenshtein ≤ opts.max_dist). The alignment IS the anti-unifier:
-- the matched rows are the shared TEMPLATE, and each substituted / inserted / deleted
-- row is a HOLE — a parameter of the helper the two copies could factor into. Distance
-- 0 is an exact clone (M.exact owns it); this tier reports distance 1..max_dist.
--
-- Candidate pairs come from a shared-distinctive-key inverted index (a key present in
-- ≤ POST_CAP functions is distinctive; a pair sharing ≥ opts.min_shared of them is a
-- candidate), so we run the O(n·m) alignment only on the handful of real candidates,
-- never on all C(nfns,2) pairs. LIMITATION (documented, sound — like the block tier):
-- the row keys use function-global slots, so a near-clone that INSERTS a local used by
-- many later rows renumbers the slots and drifts out of alignment — an honest
-- under-report, never a false merge. Relative (position-independent) local naming is
-- the banked precision refinement.
local POST_CAP = 30

-- Levenshtein distance + backtrace over two arrays of atomic row-keys.
-- Returns (dist, ops) where ops is the alignment [{op, i, j}] in forward order
-- (op ∈ match|sub|del|ins; i indexes a, j indexes b).
local function align(a, b)
    local la, lb = #a, #b
    local d = {}
    for i = 0, la do d[i] = { [0] = i } end
    for j = 0, lb do d[0][j] = j end
    for i = 1, la do
        for j = 1, lb do
            local cost = (a[i] == b[j]) and 0 or 1
            local del, ins, sub = d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost
            d[i][j] = math.min(del, ins, sub)
        end
    end
    local ops, i, j = {}, la, lb
    while i > 0 or j > 0 do
        if i > 0 and j > 0 and a[i] == b[j] and d[i][j] == d[i - 1][j - 1] then
            ops[#ops + 1] = { op = 'match', i = i, j = j }; i = i - 1; j = j - 1
        elseif i > 0 and j > 0 and d[i][j] == d[i - 1][j - 1] + 1 then
            ops[#ops + 1] = { op = 'sub', i = i, j = j }; i = i - 1; j = j - 1
        elseif i > 0 and d[i][j] == d[i - 1][j] + 1 then
            ops[#ops + 1] = { op = 'del', i = i }; i = i - 1
        else
            ops[#ops + 1] = { op = 'ins', j = j }; j = j - 1
        end
    end
    for x = 1, math.floor(#ops / 2) do ops[x], ops[#ops - x + 1] = ops[#ops - x + 1], ops[x] end
    return d[la][lb], ops
end

-- RELATIVE-LOCAL canon: every local → 'L' (so the row shape is independent of how many
-- locals were introduced before it — insertion-stable, unlike the function-global slot
-- numbering, which drifts when a near-clone inserts a local used downstream). Callees,
-- globals, fields, operators, and literals are kept verbatim. `acc` collects the local
-- NAMES in a fixed traversal order so the alignment can later check a consistent local
-- bijection (the soundness guard — see align_relative). [[cartograph-record-fold-arc]]
local function rcanon(e, locals, acc)
    if not e then return '_' end
    local k = e.k
    if k == 'name' then
        if locals[e.n] then acc[#acc + 1] = e.n; return 'L' end
        return 'N' .. e.n
    end
    if k == 'lit' then return 'L' .. (e.ty or '') .. ':' .. tostring(e.v) end
    if k == 'field' then return (e.method and 'M' or 'F') .. rcanon(e.b, locals, acc) .. '.' .. e.n end
    if k == 'index' then return 'I' .. rcanon(e.b, locals, acc) .. '[' .. rcanon(e.i, locals, acc) .. ']' end
    if k == 'call' then
        local p = {}
        for _, a in ipairs(e.a or {}) do p[#p + 1] = rcanon(a, locals, acc) end
        return 'C' .. rcanon(e.f, locals, acc) .. '(' .. table.concat(p, ',') .. ')'
    end
    if k == 'un' then return 'U' .. (e.op or '') .. rcanon(e.e, locals, acc) end
    if k == 'bin' then
        return 'B' .. (e.op or '') .. '(' .. rcanon(e.l, locals, acc) .. ',' .. rcanon(e.r, locals, acc) .. ')'
    end
    if k == 'table' then -- contents are part of the key, as in canon above (CART-0357)
        local kp = {}
        for _, c in ipairs(e.kids or {}) do kp[#kp + 1] = rcanon(c, locals, acc) end
        return 'T(' .. table.concat(kp, ',') .. ')'
    end
    if k == 'fn' then return 'Fn' end
    if k == 'vararg' then return 'V' end
    if k == 'assign' then -- see canon: `t` is the TARGET here, not a type string
        return 'A(' .. rcanon(e.t, locals, acc) .. ',' .. rcanon(e.v, locals, acc) .. ')'
    end
    local p = {}
    for _, c in ipairs(e.kids or {}) do p[#p + 1] = rcanon(c, locals, acc) end
    return '?' .. (type(e.t) == 'string' and e.t or '') .. '('
        .. table.concat(p, ',') .. ')'
end

-- (relative row-keys, per-row local-name sequences) for a fn, memoized on its index entry
local function rel_keys(f)
    if f._rk then return f._rk, f._rseq end
    local keys, seqs = {}, {}
    for i, e in ipairs(f.exprs or {}) do
        local acc = {}
        if e then
            local function seq(list)
                local p = {}
                for _, x in ipairs(list or {}) do p[#p + 1] = rcanon(x, f.locals, acc) end
                return table.concat(p, ',')
            end
            keys[i] = seq(e.lhs) .. '=' .. seq(e.rhs) .. (e.cond and (';C:' .. rcanon(e.cond, f.locals, acc)) or '')
        else
            keys[i] = '~'
        end
        seqs[i] = acc
    end
    f._rk, f._rseq = keys, seqs
    return keys, seqs
end

-- align two fns on RELATIVE keys, then verify matched rows admit a CONSISTENT local
-- bijection; a matched row whose locals conflict is reclassified as a difference (sound —
-- rejects coarse over-matches). Returns (distance, ops, consistent_match_count).
local function align_relative(fa, fb)
    local ak, aseq = rel_keys(fa)
    local bk, bseq = rel_keys(fb)
    local dist, ops = align(ak, bk)
    local mapAB, mapBA = {}, {}
    local nmatch, extra = 0, 0
    for _, o in ipairs(ops) do
        if o.op == 'match' then
            local sa, sb = aseq[o.i], bseq[o.j]
            local ok = #sa == #sb
            if ok then
                for p = 1, #sa do
                    local la, lb = sa[p], sb[p]
                    if (mapAB[la] and mapAB[la] ~= lb) or (mapBA[lb] and mapBA[lb] ~= la) then
                        ok = false; break
                    end
                end
            end
            if ok then
                for p = 1, #sa do mapAB[sa[p]] = sb[p]; mapBA[sb[p]] = sa[p] end
                nmatch = nmatch + 1
            else
                o.op = 'sub'; extra = extra + 1 -- an inconsistent match IS a real difference
            end
        end
    end
    return dist + extra, ops, nmatch
end

-- align one candidate pair; return a near-clone record or nil. Uses relative-local
-- alignment: insertion-stable + bijection-consistent, so a near-clone that inserts a
-- local (which drifted the function-global slots) is found without over-matching.
local function try_pair(fns, i, j, max_dist, min_rows)
    local fa, fb = fns[i], fns[j]
    local dist, ops, nmatch = align_relative(fa, fb)
    if dist < 1 or dist > max_dist then return nil end
    if nmatch < min_rows then return nil end
    return { dist = dist, shared = nmatch, a = fa, b = fb, ops = ops }
end

-- A pair's identity, purely for making the order TOTAL. See sort_pairs.
local function pair_key(p)
    return ('%s:%d\0%s:%d'):format(p.a.file, p.a.lines[1] or 0, p.b.file, p.b.lines[1] or 0)
end

local function sort_pairs(out)
    table.sort(out, function (x, y)
        if x.shared ~= y.shared then return x.shared > y.shared end
        if x.dist ~= y.dist then return x.dist < y.dist end
        -- ★ TOTAL ORDER, or the rank is not a fact. (shared, dist) leaves WIDE ties —
        -- measured on this repo at `51e3c4a^`: 36 pairs, and the (shared=9, dist=1)
        -- band alone holds 5. table.sort is not stable, so the same pair came back at
        -- rank 13 and rank 14 on two runs of the same input. A report that prints an
        -- arbitrary order and calls it a ranking is asserting a comparison it never
        -- made. This last key adds no ranking OPINION — it only makes the tie
        -- deterministic, so "rank N" means the same thing twice. When it decides, the
        -- honest reading is a BAND, which near_report now prints.
        return pair_key(x) < pair_key(y)
    end)
    return out
end

-- inverted index over RELATIVE row-keys (locals abstracted) — the candidate index for
-- near-clone pairing, so an insertion-drifted pair still shares distinctive keys. Memoized
-- alongside the generation-cached fn index (rebuilds when build_index does).
local rel_post_cache
local function rel_post(store, fns)
    if rel_post_cache and rel_post_cache.gen == store.generation then return rel_post_cache.post end
    local post = {}
    for i, f in ipairs(fns) do
        local ks = rel_keys(f)
        local seen = {}
        for _, k in ipairs(ks) do
            if not seen[k] then seen[k] = true; post[k] = post[k] or {}; post[k][#post[k] + 1] = i end
        end
    end
    rel_post_cache = { gen = store.generation, post = post }
    return post
end

--- Near-clone PAIRS across the store's functions. Returns a list of pairs, each
--- { dist, shared, a = {name,file,id,lines,keys}, b = {…}, ops }, sorted by
--- (shared desc, dist asc). opts.max_dist (default 2), opts.min_rows (default 6),
--- opts.min_shared (default 3). The per-fn index is generation-cached (see build_index).
function M.near(store, opts)
    local max_dist = (opts and opts.max_dist) or 2
    local min_rows = (opts and opts.min_rows) or 6
    local min_shared = (opts and opts.min_shared) or 2
    local fns = build_index(store)
    local post = rel_post(store, fns)
    -- candidate pairs = those sharing ≥ min_shared distinctive keys
    local shared = {}
    for _, list in pairs(post) do
        if #list >= 2 and #list <= POST_CAP then
            for x = 1, #list do
                for y = x + 1, #list do
                    local pk = list[x] * 1000000 + list[y]
                    shared[pk] = (shared[pk] or 0) + 1
                end
            end
        end
    end
    local out = {}
    for pk, cnt in pairs(shared) do
        if cnt >= min_shared then
            local p = try_pair(fns, math.floor(pk / 1000000), pk % 1000000, max_dist, min_rows)
            if p then out[#out + 1] = p end
        end
    end
    return sort_pairs(out)
end

--- Near-clone pairs INVOLVING one focused function only — the interactive-scoped query
--- (:CartographExtractHelper). Enumerates just the focus's candidate partners (functions
--- sharing its distinctive statements) instead of all C(nfns,2) pairs. The costly index
--- is generation-cached, so after the first build this is instant.
function M.near_of(store, fn_id, opts)
    local max_dist = (opts and opts.max_dist) or 2
    local min_rows = (opts and opts.min_rows) or 6
    local min_shared = (opts and opts.min_shared) or 2
    local fns = build_index(store)
    local post = rel_post(store, fns)
    local fi
    for i, f in ipairs(fns) do if f.id == fn_id then fi = i; break end end
    if not fi then return {} end
    -- partners = functions sharing the focus's distinctive keys, counted
    local cnt, fseen = {}, {}
    for _, k in ipairs((rel_keys(fns[fi]))) do
        if not fseen[k] then
            fseen[k] = true
            local list = post[k]
            if list and #list <= POST_CAP then
                for _, j in ipairs(list) do
                    if j ~= fi then cnt[j] = (cnt[j] or 0) + 1 end
                end
            end
        end
    end
    local out = {}
    for j, c in pairs(cnt) do
        if c >= min_shared then
            local p = try_pair(fns, math.min(fi, j), math.max(fi, j), max_dist, min_rows)
            if p then out[#out + 1] = p end
        end
    end
    return sort_pairs(out)
end

-- ── anti-unification: refine a near-clone's holes into typed parameters ───────
-- The banked identify→perform close: a near-clone's TEMPLATE is the helper the two
-- copies could factor into, and its HOLES are the helper's parameters. M.near reports
-- holes at ROW granularity (a whole differing statement); anti_unify_row descends the
-- two rows' expression trees in lockstep to pinpoint the DIVERGENT LEAF and classify it:
--   value hole (lit / global-name / field / operator) — a clean parameter, extractable;
--   struct hole (different node kind or arity, or a local-vs-global mismatch) — NOT a
--     value parameter (the shapes differ), so the pair is not a clean auto-extraction.
-- Two local names differing is NOT a hole (alpha-equivalent — the copies just renamed).

local function is_local(n, locals) return locals and locals[n] or false end

-- "nameA / nameB" for a pair, for report headers
local function p_name(pair) return ('%s / %s'):format(pair.a.name, pair.b.name) end

-- descend e1,e2 in lockstep; append {kind,a,b} per divergence to `holes`.
-- returns true iff structurally alignable (no struct hole below here).
local function anti_unify(e1, e2, la, lb, holes)
    if e1 == nil and e2 == nil then return true end
    if e1 == nil or e2 == nil then
        holes[#holes + 1] = { kind = 'struct' }; return false
    end
    if e1.k ~= e2.k then
        -- A struct hole is where the two copies stop having the same SHAPE, and until
        -- now it recorded nothing but that fact. Keep the two sides: a shape divergence
        -- is not always a restructure — when one side is a literal and the other reads a
        -- name, the copies may have DRIFTED rather than been parameterized. M.drift
        -- reads these; nothing else depends on the extra fields. (CART-0349)
        holes[#holes + 1] = { kind = 'struct', a_k = e1.k, b_k = e2.k,
            a = e1.k == 'lit' and tostring(e1.v) or nil, a_ty = e1.ty,
            b = e2.k == 'lit' and tostring(e2.v) or nil, b_ty = e2.ty,
            at_a = e1.at, at_b = e2.at }
        return false
    end
    local k = e1.k
    if k == 'lit' then
        if e1.ty == e2.ty and tostring(e1.v) == tostring(e2.v) then return true end
        -- at_a/at_b (the source span of the diverging leaf, from the expr-IR ranges)
        -- are the exact substitution sites a future extract-helper transaction rewrites.
        holes[#holes + 1] = { kind = 'literal', a = tostring(e1.v), b = tostring(e2.v),
            at_a = e1.at, at_b = e2.at }
        return true
    elseif k == 'name' then
        if e1.n == e2.n then return true end
        local l1, l2 = is_local(e1.n, la), is_local(e2.n, lb)
        if l1 and l2 then return true end -- both locals: alpha-equivalent, no hole
        if not l1 and not l2 then
            holes[#holes + 1] = { kind = 'name', a = e1.n, b = e2.n, at_a = e1.at, at_b = e2.at }
            return true
        end
        holes[#holes + 1] = { kind = 'struct' }; return false -- local vs global
    elseif k == 'field' then
        local ok = anti_unify(e1.b, e2.b, la, lb, holes)
        -- a field-NAME hole lifts as the whole field ACCESS (a value param): e1/e2 ARE
        -- the field nodes, so e1.at/e2.at span `base.name` — the value to pass.
        if e1.n ~= e2.n then
            holes[#holes + 1] = { kind = 'field', a = e1.n, b = e2.n, at_a = e1.at, at_b = e2.at }
        end
        return ok
    elseif k == 'index' then
        local o1 = anti_unify(e1.b, e2.b, la, lb, holes)
        return anti_unify(e1.i, e2.i, la, lb, holes) and o1
    elseif k == 'call' then
        if #(e1.a or {}) ~= #(e2.a or {}) then holes[#holes + 1] = { kind = 'struct' }; return false end
        local ok = anti_unify(e1.f, e2.f, la, lb, holes)
        for i = 1, #(e1.a or {}) do ok = anti_unify(e1.a[i], e2.a[i], la, lb, holes) and ok end
        return ok
    elseif k == 'un' then
        if e1.op ~= e2.op then holes[#holes + 1] = { kind = 'operator', a = e1.op, b = e2.op } end
        return anti_unify(e1.e, e2.e, la, lb, holes)
    elseif k == 'bin' then
        if e1.op ~= e2.op then holes[#holes + 1] = { kind = 'operator', a = e1.op, b = e2.op } end
        local o1 = anti_unify(e1.l, e2.l, la, lb, holes)
        return anti_unify(e1.r, e2.r, la, lb, holes) and o1
    else -- table / fn / vararg / ? fallback: compare kid lists
        local k1, k2 = e1.kids or {}, e2.kids or {}
        if #k1 ~= #k2 then
            if #k1 > 0 or #k2 > 0 then holes[#holes + 1] = { kind = 'struct' }; return false end
            return true
        end
        local ok = true
        for i = 1, #k1 do ok = anti_unify(k1[i], k2[i], la, lb, holes) and ok end
        return ok
    end
end

-- anti-unify two whole rows ({lhs, rhs, cond}); lists of differing length are structural.
local function anti_unify_row(r1, r2, la, lb, holes)
    if not r1 or not r2 then holes[#holes + 1] = { kind = 'struct' }; return false end
    if #(r1.lhs or {}) ~= #(r2.lhs or {}) or #(r1.rhs or {}) ~= #(r2.rhs or {}) then
        holes[#holes + 1] = { kind = 'struct' }; return false
    end
    local ok = true
    for i = 1, #(r1.lhs or {}) do ok = anti_unify(r1.lhs[i], r2.lhs[i], la, lb, holes) and ok end
    for i = 1, #(r1.rhs or {}) do ok = anti_unify(r1.rhs[i], r2.rhs[i], la, lb, holes) and ok end
    if r1.cond or r2.cond then ok = anti_unify(r1.cond, r2.cond, la, lb, holes) and ok end
    return ok
end

--- Anti-unify a near-clone pair (from M.near) into an extraction analysis:
--- { kind = 'value'|'structural'|'exact', holes = {…}, insdel = N }.
---   value      — every divergence is a leaf value (lit/name/field/op); the holes are
---                the parameters of the helper the two copies factor into. EXTRACTABLE.
---   exact      — no real divergence survived anti-unification (the near-distance came
---                from alpha-renaming the function-global slot pass couldn't see through);
---                the pair is actually an EXACT clone → :CartographMerge applies directly.
---   structural — a shape difference or an inserted/deleted statement; not a clean
---                value-parameterization (a callback/restructure, left to the human).
function M.analyze_pair(pair)
    local holes, insdel, rows = {}, 0, {}
    for _, o in ipairs(pair.ops) do
        if o.op == 'sub' then
            -- per-ROW hole lists, then merged. The drift test below needs to know that a
            -- row diverges in exactly ONE place, which a single shared list cannot say.
            local rh = {}
            anti_unify_row(pair.a.exprs[o.i], pair.b.exprs[o.j], pair.a.locals, pair.b.locals, rh)
            rows[#rows + 1] = rh
            for _, h in ipairs(rh) do holes[#holes + 1] = h end
        elseif o.op == 'ins' or o.op == 'del' then
            insdel = insdel + 1
        end
    end
    local structural = insdel > 0
    for _, h in ipairs(holes) do if h.kind == 'struct' then structural = true end end
    -- group value holes by (kind, a, b) — one PARAMETER per distinct varying leaf, but
    -- collect EVERY occurrence's range (sites_a/sites_b) so a leaf that appears more than
    -- once in the body is substituted at all its sites (the extract transaction needs this;
    -- a single-site dedup would leave later occurrences un-parameterized — unsound). at_a/
    -- at_b stay as the FIRST site, for display.
    local params, bykey = {}, {}
    for _, h in ipairs(holes) do
        if h.kind ~= 'struct' then
            local key = h.kind .. '\31' .. tostring(h.a) .. '\31' .. tostring(h.b)
            local p = bykey[key]
            if not p then
                p = { kind = h.kind, a = h.a, b = h.b, at_a = h.at_a, at_b = h.at_b,
                    sites_a = {}, sites_b = {} }
                bykey[key] = p; params[#params + 1] = p
            end
            if h.at_a then p.sites_a[#p.sites_a + 1] = h.at_a end
            if h.at_b then p.sites_b[#p.sites_b + 1] = h.at_b end
        end
    end
    local kind = structural and 'structural' or (#params == 0 and 'exact' or 'value')
    -- ★ DRIFT: one copy HARDCODES what the other one READS. A struct hole says the two
    -- copies stopped having the same shape, and the report has always read that as "a
    -- restructure, left to the human". One shape of it is not a restructure at all:
    -- exactly one side is a LITERAL and the other reads a name / field / call. Then the
    -- copies may have been the same once and one of them was updated — the classic
    -- copy-paste-and-forget. WHAT THIS CLAIMS IS ONLY WHAT IT CHECKED: a literal facing
    -- a reference. It does NOT know the two were ever equal, so it reports a QUESTION.
    -- THREE CONDITIONS, and each one was bought by a false positive on real code:
    --  · the ROW must diverge in exactly one place. `info.isTitle = 1` against
    --    `info.text = CLOSE` (Altoholic) is not one assignment with two values, it is two
    --    different assignments — and the giveaway is that the row carries a FIELD hole as
    --    well. Two holes in a row means the rows are not the same statement.
    --  · exactly one side is a literal, and the other must READ something (name / field /
    --    index / call). Literal against literal is already a clean parameter.
    --  · the literal must not be `nil`. `return nil` against `return e` is one path
    --    yielding nothing, not a constant somebody forgot to update — nil is the absence
    --    of a value, so it is never the thing a name would have supplied.
    local REF = { name = true, field = true, index = true, call = true }
    local drift = {}
    for _, rh in ipairs(rows) do
        local h = #rh == 1 and rh[1] or nil
        if h and h.kind == 'struct' and h.a_k and h.b_k then
            local la, lb = h.a_k == 'lit', h.b_k == 'lit'
            local lty = la and h.a_ty or h.b_ty
            if la ~= lb and REF[la and h.b_k or h.a_k] and lty ~= 'nil' then
                drift[#drift + 1] = { lit = la and h.a or h.b, lit_side = la and 'a' or 'b',
                    other = la and h.b_k or h.a_k, at_a = h.at_a, at_b = h.at_b }
            end
        end
    end
    return { kind = kind, holes = params, insdel = insdel, drift = drift }
end

--- Human-readable report for M.near pairs. `store` is used to show the differing
--- (hole) source lines — the parameters the two copies would factor into.
function M.near_report(pairs_, store)
    if #pairs_ == 0 then return { 'near-clones: none' } end
    -- HONESTY: still a mild LOWER BOUND. Alignment now uses RELATIVE-local naming (locals
    -- abstracted + a bijection-consistency guard), so an inserted local no longer drifts a
    -- pair out of alignment — the main under-report is fixed. Residuals: a for-loop binder
    -- isn't a df-def (stays a literal name), and a pair differing ONLY by local reordering
    -- is left to the exact tier. Never a false match (the consistency guard).
    local L = { ('near-clones — at least %d pair(s)'):format(#pairs_),
        '(row sequences differing by ≤ max_dist edits; relative-local aligned, bijection-consistent)',
        '(matched rows = shared template, differing rows = holes/params; mild lower bound — see loop-binder residual)',
        '(#lo-hi is a rank BAND: the order ranks on (shared, dist) only, so every pair',
        ' sharing those two numbers is genuinely unranked against the others. A range is',
        ' the honest position — a point rank would be an ordering we never computed.)', '' }
    -- the contiguous run of equal (shared, dist) each pair sits in — see the note above
    local band_lo, band_hi = {}, {}
    do
        local i = 1
        while i <= #pairs_ do
            local j = i
            while j < #pairs_ and pairs_[j + 1].shared == pairs_[i].shared
                and pairs_[j + 1].dist == pairs_[i].dist do j = j + 1 end
            for k = i, j do band_lo[k], band_hi[k] = i, j end
            i = j + 1
        end
    end
    local srccache = {}
    local function srcline(f, ln)
        local lines = srccache[f.file]
        if lines == nil then
            local n = store and store.node and store.node(f.id)
            lines = (n and store.content and store.content(n)) or false
            srccache[f.file] = lines
        end
        if not lines then return '' end
        -- store.content is the whole file 1-based; trim to a short preview
        local s = lines[ln]
        return s and (s:gsub('^%s+', ''):sub(1, 68)) or ''
    end
    local TAG = { value = 'value-parameterizable', exact = 'EXACT (mergeable directly)',
        structural = 'structural (needs a human)' }
    for i, p in ipairs(pairs_) do
        local a = M.analyze_pair(p)
        local pos = band_lo[i] == band_hi[i] and ('#%d'):format(band_lo[i])
            or ('#%d-%d'):format(band_lo[i], band_hi[i])
        L[#L + 1] = ('■ %s of %d · %d edit(s), %d shared statement(s) — %s:')
            :format(pos, #pairs_, p.dist, p.shared, TAG[a.kind])
        L[#L + 1] = ('    %s  %s:%d'):format(p.a.name, p.a.file, p.a.lines[1] or 0)
        L[#L + 1] = ('    %s  %s:%d'):format(p.b.name, p.b.file, p.b.lines[1] or 0)
        -- ★ the divergence that may not be a parameter at all — see M.analyze_pair's
        -- drift note. Phrased as a QUESTION, because nothing here established that the
        -- two copies were ever equal; what it checked is a literal facing a read.
        for _, d in ipairs(a.drift or {}) do
            L[#L + 1] = ('      ★ one side HARDCODES %s where the other reads a %s, in an'
                .. ' otherwise identical statement —'):format(tostring(d.lit), d.other)
            L[#L + 1] = '        either that is the parameter, or the hardcoded copy is stale'
        end
        -- the refined holes (the helper's parameters), anti-unified to the leaf
        for _, h in ipairs(a.holes) do
            L[#L + 1] = ('      param (%s): %s  ⇄  %s'):format(h.kind, tostring(h.a), tostring(h.b))
        end
        -- the raw differing rows (source), for the ins/del and structural cases
        for _, o in ipairs(p.ops) do
            if o.op == 'sub' and a.kind == 'structural' then
                L[#L + 1] = ('      differs: %s:%d  «%s»'):format(p.a.file, p.a.lines[o.i], srcline(p.a, p.a.lines[o.i]))
                L[#L + 1] = ('               %s:%d  «%s»'):format(p.b.file, p.b.lines[o.j], srcline(p.b, p.b.lines[o.j]))
            elseif o.op == 'del' then
                L[#L + 1] = ('      only in %s: %d  «%s»'):format(p.a.name, p.a.lines[o.i], srcline(p.a, p.a.lines[o.i]))
            elseif o.op == 'ins' then
                L[#L + 1] = ('      only in %s: %d  «%s»'):format(p.b.name, p.b.lines[o.j], srcline(p.b, p.b.lines[o.j]))
            end
        end
    end
    return L
end

--- An extraction PROPOSAL for a value-parameterizable near-clone pair: the reviewable
--- scaffold for the helper the two copies factor into. Returns report lines, or a single
--- line explaining why the pair isn't a clean value-parameterization. This is the
--- identify→PROPOSE close — a suggestion, not an auto-write: synthesizing the helper's
--- source and threading the parameters through both call sites (with visibility/scope
--- correctness) is a verified transaction of its own, deliberately NOT done here. [[cartograph-record-fold-arc]]
function M.extract_proposal(pair, store)
    local a = M.analyze_pair(pair)
    if a.kind == 'exact' then
        return { ('%s are an EXACT clone after anti-unification (the near-distance was'
            .. ' alpha-renaming) — :CartographMerge applies directly.'):format(p_name(pair)) }
    elseif a.kind == 'structural' then
        return { ('%s differ structurally (%d inserted/deleted statement(s) and/or a shape'
            .. ' change) — not a clean value-parameterization; extract by hand.')
            :format(p_name(pair), a.insdel) }
    end
    local L = {
        ('helper extraction proposal — %s'):format(p_name(pair)),
        ('  value-parameterizable: %d shared statement(s), %d parameter(s)')
            :format(pair.shared, #a.holes),
        ('  copies: %s:%d  and  %s:%d'):format(pair.a.file, pair.a.lines[1] or 0,
            pair.b.file, pair.b.lines[1] or 0),
        '  parameters (the varying leaves — one per hole):',
    }
    for i, h in ipairs(a.holes) do
        L[#L + 1] = ('    p%d (%s):  %s  in %s   /   %s  in %s')
            :format(i, h.kind, tostring(h.a), pair.a.name, tostring(h.b), pair.b.name)
        -- the substitution SITE, from the expr-IR leaf range — where the rewrite lands
        if h.at_a and h.at_b then
            L[#L + 1] = ('         at %s:%d:%d  /  %s:%d:%d'):format(
                pair.a.file, at.sl(h.at_a) + 1, at.sc(h.at_a) + 1,
                pair.b.file, at.sl(h.at_b) + 1, at.sc(h.at_b) + 1)
        end
    end
    L[#L + 1] = ('  → introduce a helper carrying the %d shared statement(s) with the above')
        :format(pair.shared)
    L[#L + 1] = '    leaves as parameters, then replace each body with a call passing its filling.'
    -- body-safety gate (prereq #3): can each whole body be lifted into a same-scope
    -- helper? (top-level, no vararg/recursion, free reads visible to the helper)
    if store then
        local un = require 'cartograph.untangle'
        local va, vb = un.body_extractable(store, pair.a.id), un.body_extractable(store, pair.b.id)
        local xfile = pair.a.file ~= pair.b.file
        if va.ok and vb.ok and not xfile then
            L[#L + 1] = '  body-safe: both bodies are cleanly liftable (top-level, no vararg/recursion).'
        else
            L[#L + 1] = '  ⚠ body lift is NOT yet clean (the parameterization is sound; the mechanical lift is gated):'
            if xfile then
                L[#L + 1] = '      cross-file — the helper needs a shared home + require wiring in both.'
            end
            if not va.ok then L[#L + 1] = ('      %s: %s'):format(pair.a.name, va.reason) end
            if not vb.ok then L[#L + 1] = ('      %s: %s'):format(pair.b.name, vb.reason) end
        end
    end
    L[#L + 1] = '  (proposal only — review the scaffold; the write is not auto-applied.)'
    return L
end

-- ── ROW-DRIFT TIER ──────────────────────────────────────────────────────────
-- The near tier finds drift only INSIDE near-clone functions: two whole bodies within
-- two edits. But "one copy hardcodes what the other reads" is a property of a single
-- STATEMENT, and the two statements need not sit in cloned functions at all. The case
-- that forced this tier is in our own fold.lua, where `Fold:tier` divides by RULE_SHIFT
-- and `Fold:refusals` divides by a literal 2 — different functions, one shared
-- statement, structurally invisible to the near tier, and the near tier found nothing
-- on this repo. (CART-0353)
--
-- ★ THE KEY IS WHAT MAKES OR BREAKS THIS. The first attempt abstracted every literal
-- AND every read, which left pure SHAPE — and `kids['cond'][1]` collided with
-- `calls[i][f]`, 8 findings on this tree, all noise. Here exactly ONE leaf is blanked
-- and everything else stays verbatim, so two rows share a bucket only if they are the
-- same statement differing at that one position.

-- The name a leaf reads a module constant under — a bare name, or the DOTTED path of a
-- table-of-constants field (CART-0355) — or nil if this leaf is not a constant read.
-- ★ BOOLEANS ARE NEVER OFFERED. A `true` in a set-membership table (`KNOWN = {x=true}`)
-- is not a value a literal can be a stale COPY of: every `true` in the tree equals it, so
-- the value half of the gate stops discriminating and only the shape half is left — which
-- the tier's own doc records as far too weak alone. The INDEX still carries booleans (it
-- is a general seam); the refusal belongs to this consumer, whose argument it is.
local function const_read(node, cd)
    if not (node and cd) then return nil end
    local key = (node.k == 'name' and node.n) or (node.k == 'field' and expr.dotted(node)) or nil
    if not key then return nil end
    local v = cd[key]
    if v == nil or type(v) == 'boolean' then return nil end
    return key, v
end

-- canon with the `ord`-th leaf replaced by '?'; st.hit records the leaf it blanked.
-- Locals are NEVER candidate leaves — two copies naming a local differently is
-- alpha-renaming, which is the one divergence that carries no information.
local function bcanon(e, locals, slots, ctr, st)
    if not e then return '_' end
    local k = e.k
    local function leaf(render, kind, node)
        st.ord = st.ord + 1
        if st.all then st.all[st.ord] = { kind = kind, node = node } end
        if st.ord == st.blank then st.hit = { kind = kind, node = node }; return '?' end
        return render
    end
    if k == 'name' then
        if locals[e.n] then
            if not slots[e.n] then ctr.n = ctr.n + 1; slots[e.n] = '#' .. ctr.n end
            return slots[e.n]
        end
        return leaf('N' .. e.n, 'read', e)
    end
    if k == 'lit' then return leaf('L' .. (e.ty or '') .. ':' .. tostring(e.v), 'lit', e) end
    if k == 'field' then
        -- ★ A RESOLVABLE CONSTANT CHAIN IS ONE LEAF, NOT A STRUCTURE. `C.SHIFT` must be
        -- blankable as a whole, exactly as a bare `SHIFT` is: the position it competes
        -- with on the other side is a bare LITERAL, and a literal is one leaf. Descending
        -- here instead would key it as `F<base>.?` against the literal's `?` — different
        -- buckets forever, and the tier would report nothing while looking correct.
        local dot = st.cd and expr.dotted(e)
        if dot and st.cd[dot] ~= nil then return leaf('N' .. dot, 'read', e) end
        local b = bcanon(e.b, locals, slots, ctr, st)
        return (e.method and 'M' or 'F') .. b .. '.' .. leaf(e.n, 'read', e)
    end
    if k == 'index' then
        return 'I' .. bcanon(e.b, locals, slots, ctr, st) .. '[' .. bcanon(e.i, locals, slots, ctr, st) .. ']'
    end
    if k == 'call' then
        local f = bcanon(e.f, locals, slots, ctr, st)
        local p = {}
        for _, a in ipairs(e.a or {}) do p[#p + 1] = bcanon(a, locals, slots, ctr, st) end
        return 'C' .. f .. '(' .. table.concat(p, ',') .. ')'
    end
    if k == 'un' then return 'U' .. (e.op or '') .. bcanon(e.e, locals, slots, ctr, st) end
    if k == 'bin' then
        return 'B' .. (e.op or '') .. '(' .. bcanon(e.l, locals, slots, ctr, st)
            .. ',' .. bcanon(e.r, locals, slots, ctr, st) .. ')'
    end
    if k == 'table' then return 'T' end
    if k == 'fn' then return 'Fn' end
    if k == 'vararg' then return 'V' end
    if k == 'assign' then -- see canon: `t` is the TARGET here, not a type string
        return 'A(' .. bcanon(e.t, locals, slots, ctr, st) .. ','
            .. bcanon(e.v, locals, slots, ctr, st) .. ')'
    end
    local p = {}
    for _, c in ipairs(e.kids or {}) do p[#p + 1] = bcanon(c, locals, slots, ctr, st) end
    return '?' .. (type(e.t) == 'string' and e.t or '') .. '('
        .. table.concat(p, ',') .. ')'
end

local function brow(rw, locals, blank, all, cd)
    local slots, ctr, st = {}, { n = 0 }, { ord = 0, blank = blank, all = all, cd = cd }
    local function seq(list)
        local p = {}
        for _, e in ipairs(list or {}) do p[#p + 1] = bcanon(e, locals, slots, ctr, st) end
        return table.concat(p, ',')
    end
    local key = seq(rw.lhs) .. '=' .. seq(rw.rhs)
    if rw.cond then key = key .. ';C:' .. bcanon(rw.cond, locals, slots, ctr, st) end
    return key, st.ord, st.hit
end

--- ROW-DRIFT: a literal that DUPLICATES the value of a module constant, standing where
--- an otherwise identical statement elsewhere reads that constant by name.
--- Returns findings { name, value, lit_file, lit_line, lit_fn, sites = {…} }.
---
--- TWO CONDITIONS, and NEITHER is sufficient alone — that is the whole design:
---   · the statements must MATCH with one leaf blanked. On its own this is far too
---     weak: measured on this tree it yields 7 candidates of which 1 is real.
---   · the literal must EQUAL the value the name holds. On its own this is far too
---     weak too — with `RULE_SHIFT = 2` in scope, every `2` in the file "equals a
---     constant", which is most of them.
--- Together they say something narrow and checkable: this statement is written
--- elsewhere using the name, and this literal IS that name's value. Measured on this
--- repo: 7 candidates -> 1 finding, and the finding was a real defect (fold.lua:228
--- decoding rule bits by a bare 2 where its two siblings and the encoder use
--- RULE_SHIFT).
---
--- WHAT IT CANNOT SEE, and the near tier can: a literal facing an EXPRESSION rather
--- than a name (`'q'` against `require('cartograph.config').keys.close`) never shares a
--- one-leaf-blanked key, because one side is a whole call chain. The two tiers are
--- complementary, not nested — neither subsumes the other.
---@param store table
---@param opts table|nil  { max_bucket = 5, min_other = 2 }
function M.row_drift(store, opts)
    local max_bucket = (opts and opts.max_bucket) or 5
    local min_other = (opts and opts.min_other) or 2
    local consts = require('cartograph.constfold').literal_index(store)
    local buckets = {}
    for _, f in ipairs(collect_fns(store)) do
        local cd = consts[f.file]
        for _, rw in ipairs(f.rows) do
            if rw.expr then
                local all = {}
                local _, nleaf = brow(rw.expr, f.locals, -1, all, cd)
                -- a statement whose ONLY content is the varying leaf is not evidence
                if nleaf - 1 >= min_other then
                    for i = 1, nleaf do
                        -- ★ ONLY CANDIDATE POSITIONS GET A KEY. A finding needs a literal
                        -- on one side and a read of a KNOWN module constant on the other,
                        -- so any other leaf can never contribute and keying it is pure
                        -- waste. This is not a heuristic — it drops positions that are
                        -- unreachable by construction. Keying every leaf instead cost
                        -- 5.2 GB and had not finished 50 WoW addons after two minutes;
                        -- the work is O(rows x leaves) STRINGS held at once.
                        local lf = all[i]
                        local cand = lf and (lf.kind == 'lit' or const_read(lf.node, cd) ~= nil)
                        if cand then
                            local key, _, hit = brow(rw.expr, f.locals, i, nil, cd)
                            if hit then
                                local b = key .. '\1' .. i
                                buckets[b] = buckets[b] or {}
                                table.insert(buckets[b], { hit = hit, file = f.file, line = rw.l, fn = f.name })
                            end
                        end
                    end
                end
            end
        end
    end
    local out = {}
    for _, rows in pairs(buckets) do
        -- a bucket collecting many sites is a language IDIOM, not a copied statement
        if #rows >= 2 and #rows <= max_bucket then
            local lits, reads = {}, {}
            for _, r in ipairs(rows) do
                if r.hit.kind == 'lit' then lits[#lits + 1] = r else reads[#reads + 1] = r end
            end
            for _, lr in ipairs(lits) do
                local known, lv = expr.eval(lr.hit.node)
                for _, rr in ipairs(reads) do
                    local nm, cv = const_read(rr.hit.node, consts[rr.file])
                    -- ★ THE GATE: the literal must BE the constant's value
                    if known and cv ~= nil and cv == lv then
                        out[#out + 1] = { name = nm, value = cv, lit_file = lr.file,
                            lit_line = lr.line, lit_fn = lr.fn,
                            sites = { { file = rr.file, line = rr.line, fn = rr.fn } } }
                        break
                    end
                end
            end
        end
    end
    table.sort(out, function (a, b)
        if a.lit_file ~= b.lit_file then return a.lit_file < b.lit_file end
        return (a.lit_line or 0) < (b.lit_line or 0)
    end)
    return out
end

--- Human-readable report lines for M.row_drift findings.
function M.row_drift_report(found)
    if #found == 0 then return { 'row-drift: none' } end
    local L = { ('row-drift — %d literal(s) that duplicate a module constant'):format(#found),
        '(the same statement is written elsewhere using the NAME, and this literal IS',
        ' that name\'s value — so the constant exists and this site bypasses it)', '' }
    for _, d in ipairs(found) do
        L[#L + 1] = ('■ %s:%d  in %s'):format(d.lit_file, d.lit_line or 0, d.lit_fn or '?')
        L[#L + 1] = ('    hardcodes %s, which is `%s`'):format(tostring(d.value), d.name)
        for _, s in ipairs(d.sites) do
            L[#L + 1] = ('    the same statement uses the name at %s:%d  in %s')
                :format(s.file, s.line or 0, s.fn or '?')
        end
    end
    return L
end

--- Human-readable report lines for M.exact groups.
function M.report(groups)
    if #groups == 0 then return { 'exact-structural clones: none' } end
    local total = 0
    for _, g in ipairs(groups) do total = total + #g - 1 end
    local L = { ('exact-structural clones — %d group(s), %d redundant definition(s)')
        :format(#groups, total),
        '(alpha-invariant on locals; callees/globals/literals kept — a real clone, not a literal match)', '' }
    for _, g in ipairs(groups) do
        L[#L + 1] = ('■ %d copies, ~%d stmts each:'):format(#g, g.nrows)
        for _, m in ipairs(g) do
            L[#L + 1] = ('    %s  %s:%d'):format(m.name, m.file, m.line or 0)
        end
    end
    return L
end

--- Clone findings as an IN-BUFFER diagnostic list (the interactive surface, [[cartograph-
--- interactive-analysis]]): each finding lands ON the code it concerns, and — crucially —
--- a value-hole finding sits at the hole's exact column (the expr-IR leaf range), so
--- `]d`/`[d` and the quickfix jump straight to the substitution site. Findings are
--- { file (rel), line (1-based), col?, severity, message } — the caller resolves abs.
--- Covers EXACT clones (a merge target) and NEAR-clone functions + their holes (an
--- extract-helper target). Block clones are omitted (function/hole findings are the
--- actionable ones; blocks stay a report). Rides the generation-cached index.
function M.findings(store, opts)
    local out = {}
    -- exact clones: one info finding per member (the whole group is mergeable)
    for _, g in ipairs(M.exact(store, opts)) do
        local names = {}
        for _, m in ipairs(g) do names[#names + 1] = m.name end
        local label = table.concat(names, ', ')
        for _, m in ipairs(g) do
            out[#out + 1] = { file = m.file, line = m.line, severity = 'info',
                message = ('exact clone (%d copies: %s) — :CartographMerge folds them')
                    :format(#g, label) }
        end
    end
    -- near clones: a function-level finding per endpoint, plus a hole finding at each
    -- value-hole's leaf column (the jump target for the extract-helper rewrite)
    for _, p in ipairs(M.near(store, opts)) do
        local a = M.analyze_pair(p)
        local sev = (a.kind == 'value' or a.kind == 'exact') and 'info' or 'hint'
        local action = a.kind == 'structural' and 'extract by hand' or ':CartographExtractHelper'
        for _, s in ipairs({ { f = p.a, other = p.b.name }, { f = p.b, other = p.a.name } }) do
            out[#out + 1] = { file = s.f.file, line = s.f.lines[1] or 0, severity = sev,
                message = ('near-clone of %s — %s, %d edit(s) · %s')
                    :format(s.other, a.kind, p.dist, action) }
        end
        if a.kind == 'value' then
            for _, h in ipairs(a.holes) do
                if h.at_a then
                    out[#out + 1] = { file = p.a.file, line = at.sl(h.at_a) + 1,
                        col = at.sc(h.at_a) + 1, severity = 'hint',
                        message = ('clone hole (%s): %s ⇄ %s — a parameter of the shared helper')
                            :format(h.kind, tostring(h.a), tostring(h.b)) }
                end
                if h.at_b then
                    out[#out + 1] = { file = p.b.file, line = at.sl(h.at_b) + 1,
                        col = at.sc(h.at_b) + 1, severity = 'hint',
                        message = ('clone hole (%s): %s ⇄ %s — a parameter of the shared helper')
                            :format(h.kind, tostring(h.b), tostring(h.a)) }
                end
            end
        end
    end
    return out
end

return M
