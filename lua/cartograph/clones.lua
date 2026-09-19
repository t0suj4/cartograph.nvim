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
local shortlist = require 'cartograph.shortlist'

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
    -- ★ A TYPE KEYS BY ITS NAME OR EVERY TYPE IS THE SAME TYPE (CART-0742). A
    -- bare named type has NO KIDS, so without this `new Foo()` and `new Bar()`
    -- canon IDENTICALLY. Present in all THREE structural keys in this file,
    -- because they are three copies of one function and a kind added to two of
    -- them is a silent disagreement about what "the same expression" means.
    if k == 'type' then
        local kp = {}
        for _, c in ipairs(e.kids or {}) do kp[#kp + 1] = canon(c, locals, slots, ctr) end
        return 'Y' .. (e.n or (e.prim and '#prim') or '') .. '(' .. table.concat(kp, ',') .. ')'
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
-- ⚠ ON THE STORE, NOT A MODULE UPVALUE (CART-0822). A module-level cache is
-- INVISIBLE to session.capture()/restore(), which iterate the store's own
-- fields, so two bands whose per-band generations collided read each other's
-- answer. A store field listed in store.BAND_TRANSIENT is dropped on every band
-- swap, with no registration beyond that one line.
-- ★ ON THE AGENT PATH TOO (agent.lua requires cartograph.clones), and this is
-- the ticket's named instance: build_index returning the PREVIOUS root's
-- function set, which every clone tier then reports pairs over.
local INDEX_FLOOR = 2

local function build_index(store)
    local c = store._clone_idx
    if c and c.gen == store.generation then
        return c.fns, c.post
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
    store._clone_idx = { gen = store.generation, fns = fns, post = post }
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
-- ★★★ HOW MUCH DO TWO ROW KEYS AGREE? The COMMON PREFIX LENGTH, and that is READ
-- OFF `rcanon`'s FORMAT rather than invented: rcanon writes a key HEAD-FIRST — the
-- kind letter, then the callee/operator, then the children — so a shared prefix IS
-- shared top-level structure, and two rows that are different statements diverge
-- within a couple of characters. Measured on the pair that motivated this
-- (CART-0875):
--     a[7] =CFNvim.notify(Lstr:'cartograph: focus a function first',…WARN)
--     b[7] =CFNvim.notify(Lstr:'cartograph: focus a method first',…WARN)   -> ~40
--     a[8] =CNmat_df(L,FL.file)          against b[7] above                ->   2
-- ⚠ It is a TIE-BREAK ONLY. It never enters the DP, so the edit DISTANCE is
-- untouched and every `max_dist` threshold, tier count and baseline is unchanged.
local function keysim(x, y)
    if not x or not y then return -1 end
    local n = math.min(#x, #y)
    local i = 1
    while i <= n and x:byte(i) == y:byte(i) do i = i + 1 end
    return i - 1
end

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
        elseif i > 0 and j > 0 and d[i][j] == d[i - 1][j - 1] + 1
            -- ★★★ A TIE MUST NOT DEFAULT TO `sub` (CART-0875). Several branches can
            -- satisfy the same DP cell, and the FIRST LISTED WINS, so an unconditional
            -- `sub` here meant the aligner would always rather PAIR TWO UNRELATED ROWS
            -- than leave an insertion. Measured cost of that: for every near pair where
            -- one side inserts a row NEXT TO a row that also differs, analyze_pair
            -- reported a parameter between two rows that have nothing to do with each
            -- other — `n.file ⇄ vim.log.levels.WARN` on 7 of the 22 structural pairs
            -- carrying dependent holes, and any extract built on those params would
            -- have taken a `store` where a message belongs.
            -- ⚠ THE TWO ALIGNMENTS COST THE SAME. It was never a cheaper path winning;
            -- it was an arbitrary order deciding. So the fix belongs HERE and not in
            -- the cost function: giving `sub` a cost of 2 (the Levenshtein→LCS variant)
            -- would also fix it and would move `dist` for EVERY pair, changing what
            -- `max_dist` means and every near-tier count with it.
            -- ONE STEP OF LOOKAHEAD IS ENOUGH: if the row this `sub` would consume on
            -- one side agrees BETTER with the other side's NEXT row, take the deletion
            -- (or insertion) and let the better pairing happen.
            and not (d[i][j] == d[i - 1][j] + 1 and keysim(a[i - 1], b[j]) > keysim(a[i], b[j]))
            and not (d[i][j] == d[i][j - 1] + 1 and keysim(a[i], b[j - 1]) > keysim(a[i], b[j]))
        then
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
    -- ★ A TYPE KEYS BY ITS NAME OR EVERY TYPE IS THE SAME TYPE (CART-0742). A
    -- bare named type has NO KIDS, so without this `new Foo()` and `new Bar()`
    -- canon IDENTICALLY. Present in all THREE structural keys in this file,
    -- because they are three copies of one function and a kind added to two of
    -- them is a silent disagreement about what "the same expression" means.
    if k == 'type' then
        local kp = {}
        for _, c in ipairs(e.kids or {}) do kp[#kp + 1] = rcanon(c, locals, acc) end
        return 'Y' .. (e.n or (e.prim and '#prim') or '') .. '(' .. table.concat(kp, ',') .. ')'
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
-- ⚠ ON THE STORE, NOT A MODULE UPVALUE (CART-0822). A module-level cache is
-- INVISIBLE to session.capture()/restore(), which iterate the store's own
-- fields, so two bands whose per-band generations collided read each other's
-- answer. A store field listed in store.BAND_TRANSIENT is dropped on every band
-- swap, with no registration beyond that one line.
local function rel_post(store, fns)
    local c = store._clone_relpost
    if c and c.gen == store.generation then return c.post end
    local post = {}
    for i, f in ipairs(fns) do
        local ks = rel_keys(f)
        local seen = {}
        for _, k in ipairs(ks) do
            if not seen[k] then seen[k] = true; post[k] = post[k] or {}; post[k][#post[k] + 1] = i end
        end
    end
    store._clone_relpost = { gen = store.generation, post = post }
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

--- ★★★ WHICH LOCALS DOES THIS SUBTERM ACTUALLY READ? That list IS the signature of
--- the helper parameter the hole would become (CART-0876; NEARBINDERS.md ran exactly
--- this over these pairs). A hole reading NO local is a VALUE parameter — hand it a
--- value. A hole reading locals is a FUNCTION parameter applied to them: the
--- prototype writes it `Y(c) : c.line = callrec.line(c)`, ONE parameter with EIGHT
--- sites, and that dependency list is what the extract verb must put in the helper's
--- argument list.
--- ⚠ IT NARROWS TO WHAT IS USED, not what is in scope (the prototype's `Sol` does the
--- same). A subterm sitting under ten locals but reading one takes one argument.
--- ★ `is_local` is the SAME predicate `anti_unify` uses, so a name counted here is a
--- name that function alpha-collapsed — not a second notion of localness.
local function local_deps(node, locals)
    local out = {}
    if not node or not locals then return out end
    local seen = {}
    expr.walk(node, function (n)
        if n.k == 'name' and is_local(n.n, locals) and not seen[n.n] then
            seen[n.n] = true; out[#out + 1] = n.n
        end
    end)
    table.sort(out)
    return out
end

-- "nameA / nameB" for a pair, for report headers
local function p_name(pair) return ('%s / %s'):format(pair.a.name, pair.b.name) end

-- descend e1,e2 in lockstep; append {kind,a,b} per divergence to `holes`.
-- returns true iff structurally alignable (no struct hole below here).
--- ★★★ DOES ONE SIDE KEEP SOMETHING THE OTHER ALSO HAS? That is the question a
--- `kind` struct hole cannot answer from its own tag, and it is the difference
--- between ENCLOSURE and REPLACEMENT:
---     c.line   against   callrec.line(c)   share `c`   -> the wrapper's argument
---     require 'x'  against  transport      share nothing -> a whole-term swap
--- Exactly computable from the two nodes the hole already carries, using the
--- canonical walker and the canonical key — no new traversal, no new authority.
--- ⚠ IT USES `expr.key`, WHICH KEEPS REAL NAMES, not `rcanon`'s alpha-collapsed
--- form. That is deliberate and it is the conservative direction: two DIFFERENT
--- locals will not be mistaken for a shared base. The cost is that a genuinely
--- shared base which was RENAMED between the copies reads as unshared.
local function shares_subterm(x, y)
    if not x or not y then return false end
    local seen = {}
    expr.walk(x, function (n) seen[expr.key(n)] = true end)
    local hit = false
    expr.walk(y, function (n) if seen[expr.key(n)] then hit = true end end)
    return hit
end

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
        --
        -- ★ AND THE TWO NODES THEMSELVES — `xn`/`yn`, CART-0766 step B. A hole
        -- carries STRINGS AND SPANS, which is everything `M.drift` and the reports
        -- need; classifying a divergence in the CENSUS's vocabulary needs NODES,
        -- because `dc_size`, `dc_kids` and `rcanon` each take one. Attaching them
        -- where both are already in hand is the alternative to a second traversal
        -- of this same shape, and a second traversal is the copied-walker bug
        -- (CART-0746, wrong in both directions in one day).
        -- ⚠ LIVE REFERENCES into the expression tree, not copies. Holes are
        -- ephemeral — nothing persists them and no cache version is involved — but
        -- a consumer must not mutate through them.
        holes[#holes + 1] = { kind = 'struct', a_k = e1.k, b_k = e2.k,
            a = e1.k == 'lit' and tostring(e1.v) or nil, a_ty = e1.ty,
            b = e2.k == 'lit' and tostring(e2.v) or nil, b_ty = e2.ty,
            at_a = e1.at, at_b = e2.at, xn = e1, yn = e2, why = 'kind' }
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
        holes[#holes + 1] = { kind = 'struct', xn = e1, yn = e2, why = 'localglobal' }
        return false -- local vs global
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
        if #(e1.a or {}) ~= #(e2.a or {}) then
            holes[#holes + 1] = { kind = 'struct', xn = e1, yn = e2, why = 'arity' }; return false
        end
        local ok = anti_unify(e1.f, e2.f, la, lb, holes)
        for i = 1, #(e1.a or {}) do ok = anti_unify(e1.a[i], e2.a[i], la, lb, holes) and ok end
        return ok
    elseif k == 'un' then
        -- ⚠ THE SPAN OF AN OPERATOR HOLE IS THE ENCLOSING EXPRESSION, NOT THE
        -- TOKEN — the IR gives `un`/`bin` a range and the operator no node of its
        -- own. That makes it a sound positional KEY (every node's span is unique)
        -- and NOT a substitution site: writing the payload there would replace the
        -- operands too. `at_encloses` says so at the point of use, so a renderer
        -- (CART-0766 step C) refuses rather than silently overwriting. Measured on
        -- our own lua tree: 56 of 11,614 template holes are this kind, and they
        -- were the ONLY value holes carrying no span at all.
        if e1.op ~= e2.op then
            holes[#holes + 1] = { kind = 'operator', a = e1.op, b = e2.op,
                at_a = e1.at, at_b = e2.at, at_encloses = true }
        end
        return anti_unify(e1.e, e2.e, la, lb, holes)
    elseif k == 'bin' then
        if e1.op ~= e2.op then
            holes[#holes + 1] = { kind = 'operator', a = e1.op, b = e2.op,
                at_a = e1.at, at_b = e2.at, at_encloses = true }
        end
        local o1 = anti_unify(e1.l, e2.l, la, lb, holes)
        return anti_unify(e1.r, e2.r, la, lb, holes) and o1
    else -- table / fn / vararg / ? fallback: compare kid lists
        local k1, k2 = e1.kids or {}, e2.kids or {}
        if #k1 ~= #k2 then
            if #k1 > 0 or #k2 > 0 then
                holes[#holes + 1] = { kind = 'struct', xn = e1, yn = e2, why = 'arity' }; return false
            end
            return true
        end
        local ok = true
        for i = 1, #k1 do ok = anti_unify(k1[i], k2[i], la, lb, holes) and ok end
        return ok
    end
end

-- A hole's POSITION, as a string. `at` is either a packed integer or the
-- {start,end} table depending on where the node came from, so it goes through
-- the `at` accessors rather than being indexed — the seam `guards.lua` fences,
-- and the one `findings.record_lint` was written past.
local function span_key(a)
    if not a then return nil end
    return ('%d:%d-%d:%d'):format(at.sl(a), at.sc(a), at.el(a), at.ec(a))
end

--- THE ELEMENT TEMPLATE OF A CONTAINER — what its members have in common, and
--- where they differ (CART-0766). The first half of the insert verb's
--- disambiguation, and useful on its own: "what shape are this table's members"
--- is the question `instrumentcensus` had to answer by hand when it met a table
--- built by a loop.
---
--- ★★ THERE IS NO NEW REPRESENTATION HERE, WHICH IS THE POINT. A template IS
--- (a DONOR member, the holes across all members). `anti_unify` already records
--- every divergence with `at_a`/`at_b` — the SOURCE SPANS — so the donor's text
--- plus the hole spans is a complete substitution recipe, and rendering never has
--- to emit source from the IR (which is lossy about surface).
---
--- ⚠ `alignable = false` IS A FIRST-CLASS ANSWER, not a failure. A `struct` hole
--- means the members do not share a shape at all — measured at 6-31% of
--- containers depending on language — and a caller must be told that rather than
--- handed a template built from one arbitrary member.
--- ★★ AND `varying` IS WHAT MAKES `M.match` DISCRIMINATE (CART-0766 step B). A
--- template's holes are the positions where the members ALREADY DISAGREE, so a
--- payload diverging THERE is instantiating the template, while a payload
--- diverging anywhere ELSE is a different shape wearing the same outline. Without
--- that split every divergence binds, the template matches everything, and
--- matching everything disambiguates nothing — `leaf-vs-tree` one layer up: a
--- predicate that fires on every shape has stopped being a predicate.
---
--- ★ THE POSITION KEY IS THE DONOR'S SOURCE SPAN, and it costs no new plumbing.
--- Every hole records `at_a` in the LEFT side's coordinates, the left side is
--- always `ms[1]`, and `M.match` walks that same donor — so `at_a` already IS
--- positional identity. MEASURED BEFORE RELYING ON IT (probe, our own lua tree,
--- 2405 containers with n>=2): 7760 of 7760 VALUE holes carry a span. The only
--- spanless ones were 85 `struct` — refusals, which need no key — and 56
--- `operator`, now given the enclosing node's span. The alternative, threading a
--- path through `anti_unify`, touches fifteen recursion sites in a walker that
--- four other flows share, to recompute a key the data already carries.
---@param container table  an expr node (`k == 'table'`)
---@return table { n, alignable, donor, holes, varying, unkeyed, why? }
function M.element_template(container)
    if type(container) ~= 'table' or container.k ~= 'table' then
        return { n = 0, alignable = false, why = 'not a container' }
    end
    local ms = container.kids or {}
    if #ms == 0 then return { n = 0, alignable = false, why = 'no members' } end
    -- ★ ONE MEMBER IS ALIGNABLE AND TEACHES NOTHING. A template needs a second
    -- instance to have any holes at all, so say so rather than imply a shape was
    -- confirmed: `holes` is empty either way and the two cases are not the same.
    if #ms == 1 then
        return { n = 1, alignable = true, donor = ms[1], holes = {},
            varying = {}, unkeyed = 0,
            why = 'a single member is a shape, not yet a template' }
    end
    local holes, alignable = {}, true
    for i = 2, #ms do
        -- ⚠ EMPTY LOCALS MAPS: a container's members are declarations, not a
        -- function body, so nothing here is alpha-renameable. Passing a locals
        -- map would silently equate two DIFFERENT names as "both local".
        if not anti_unify(ms[1], ms[i], {}, {}, holes) then alignable = false end
    end
    local varying, unkeyed = {}, 0
    for _, h in ipairs(holes) do
        if h.kind ~= 'struct' then
            local key = span_key(h.at_a)
            -- ⚠ COUNTED, NOT SWALLOWED. A value hole with no span is a position
            -- `M.match` cannot recognise, and a template that quietly forgets one
            -- would report a legitimate instantiation as a mismatch. `M.match`
            -- refuses on a non-zero count rather than guessing; the probe above
            -- says the count is zero today, and this is what would tell us it
            -- stopped being.
            --
            -- ★ THE SPAN IS KEPT, NOT JUST THE KIND (CART-0766 step C). `M.match`
            -- only ever asks whether a key is present, but `M.render` has to
            -- SUBSTITUTE at that position, so it needs the range back — and
            -- re-deriving it from the key string would be parsing a key we
            -- formatted, which is the pattern CART-0746 cost a day to.
            if key then
                varying[key] = { kind = h.kind, at = h.at_a, encloses = h.at_encloses }
            else
                unkeyed = unkeyed + 1
            end
        end
    end
    return { n = #ms, alignable = alignable, donor = ms[1], holes = holes,
        varying = varying, unkeyed = unkeyed }
end

-- anti-unify two whole rows ({lhs, rhs, cond}); lists of differing length are structural.
--- ★★★ THE POSITIONS A RESOLVER READS AS A LITERAL — and lifting one to a VALUE
--- parameter destroys the fact it carries. Two shapes today, both the import seam:
---     require('cartograph.narrow')            the path argument
---     require('cartograph.narrow').report     the selector on the result
--- Turn either into a parameter and `require(mod)[fn]` resolves to NOTHING: the
--- import edge and the reference to the report function both stop existing.
---
--- ★★ MEASURED, ON OUR OWN TREE, BEFORE THIS EXISTED (CART-0878). Extracting six
--- command callbacks with the module and report as STRING parameters took
--- commands/analysis.lua from 17 import edges to 11, and three report functions
--- (`report_blocks`, `param_report`, `devirt_report`) became unreferenced. The same
--- six extracted with the call passed as a FUNCTION cost nothing and removed exactly
--- the same duplication — 32 near-clone pairs to 7 either way. Cross-checked by the
--- algebra's scope graph, whose `module` resolution class went 31 -> 25 -> 31 over
--- the same three variants: two analysers, different IRs, the same six facts.
---
--- ⚠ SO THIS IS NOT A REFUSAL. A hole here is still extractable; what it costs is
--- known, and the cost is zero if it is lifted as a function rather than a value.
--- The proposal says so and leaves the choice — a rule source may only refuse, and
--- this is not a rule, it is a price.
---
--- ⚠ AND IT IS THE SPEC'S `import_call`, NOT THE STRING `require`. lua says
--- `require`, ruby says `require_relative`, php declares none and gets nothing —
--- which is honest: php's import edges come from `import_query`, a shape this test
--- does not model, so it reports no cost rather than a wrong one.
local function literal_dep_sites(r, imp, out)
    local function scan(e)
        if type(e) ~= 'table' then return end
        if e.k == 'call' and e.f and e.f.k == 'name' and e.f.n == imp then
            local a1 = e.a and e.a[1]
            if a1 and a1.k == 'lit' and a1.at then out[#out + 1] = { at = a1.at, why = 'an import path' } end
        elseif e.k == 'field' and e.at and e.b and e.b.k == 'call'
            and e.b.f and e.b.f.k == 'name' and e.b.f.n == imp then
            out[#out + 1] = { at = e.at, why = 'a member of an import' }
        end
    end
    for _, e in ipairs(r.lhs or {}) do expr.walk(e, scan) end
    for _, e in ipairs(r.rhs or {}) do expr.walk(e, scan) end
    if r.cond then expr.walk(r.cond, scan) end
end

local function same_at(x, y)
    if not x or not y then return false end
    return at.sl(x) == at.sl(y) and at.sc(x) == at.sc(y)
        and at.el(x) == at.el(y) and at.ec(x) == at.ec(y)
end

local function anti_unify_row(r1, r2, la, lb, holes, imp)
    local row_start = #holes
    if not r1 or not r2 then holes[#holes + 1] = { kind = 'struct' }; return false end
    if #(r1.lhs or {}) ~= #(r2.lhs or {}) or #(r1.rhs or {}) ~= #(r2.rhs or {}) then
        holes[#holes + 1] = { kind = 'struct' }; return false
    end
    local ok = true
    -- ★★★ WHICH SIDE A HOLE CAME FROM, RECORDED WHERE IT IS FREE (CART-0941).
    -- This function already separates the two loops; until now it threw the
    -- distinction away, and a divergent field SELECTOR on an assignment TARGET
    -- reached `cloneextract` as an ordinary value hole. It substitutes them, so
    -- `self.alpha = alpha` became `hp1 = alpha` and THE FIELD WRITE WAS LOST —
    -- reproduced end to end, valid Lua, past the `parses` gate.
    --
    -- ⚠ TAGGED BY RANGE, NOT BY THREADING A PARAMETER. `anti_unify` appends to
    -- `holes` from fifteen recursion sites; passing a side through all of them to
    -- set one field is the change this codebase keeps paying for (CART-0928's two
    -- stop lists, CART-0932's two set-builders). The loop knows the answer for
    -- every hole it produced, so it marks the range it just appended.
    --
    -- ★ AND THE DESTINATION KIND COMES FROM THE ROW, NOT FROM THE HOLE. `r1.lhs[i]`
    -- IS the destination expression and its `k` is the kind — `name`, `field` or
    -- `index`. MEASURED on our own tree (3000 functions): 14406 name, 4822 index,
    -- 1214 field, so 29.5% of writes are not plain names. `dest` carries it so a
    -- consumer can DISPATCH rather than only refuse: a differing selector on a
    -- `field` destination factors as `self[hp] = v`, while a differing key on an
    -- `index` destination is already a value and substitutes correctly today.
    --
    -- ★★★ AND `side` ALONE OVER-REFUSES, WHICH IS WHY `target` EXISTS. Every hole
    -- BELOW a destination is on the write side, but only the one that IS the
    -- destination is dangerous: substituting `t[k] = v`'s differing KEY is correct
    -- today (the key is already an expression), while substituting `self.alpha`
    -- replaces the target and the write is gone. A refusal keyed on `side` would
    -- forbid the first along with the second.
    --
    -- ⚠ IT IS DERIVED FROM THE TWO DESTINATION NODES, NOT BY MATCHING SPANS. The
    -- obvious test -- "the hole's `at_a` IS the destination's `at`" -- fails exactly
    -- where it is needed most: a method-call `field` node carries NO span at all
    -- (CART-0940), so in ruby and php both sides would be nil and every hole would
    -- compare equal to the destination. The divergence that produces the
    -- destination's own hole is computable from `d1`/`d2` directly, and that is
    -- the same condition `anti_unify` itself uses one level down.
    for i = 1, #(r1.lhs or {}) do
        local before = #holes
        local d1, d2 = r1.lhs[i], r2.lhs[i]
        ok = anti_unify(d1, d2, la, lb, holes) and ok
        -- does the TARGET ITSELF diverge, and in what
        local tk, tn1, tn2
        if d1 and d2 and d1.k == d2.k and (d1.k == 'field' or d1.k == 'name')
            and d1.n ~= d2.n then
            tk, tn1, tn2 = d1.k, d1.n, d2.n
        end
        for j = before + 1, #holes do
            holes[j].side = 'lhs'
            holes[j].dest = d1 and d1.k or nil
            -- ★ MATCHED BY VALUE, AND THE NESTED CASES WERE MEASURED RATHER THAN
            -- REASONED ABOUT -- the first cut of this comment claimed a nested
            -- repeat would tag both holes, and it does not. Three two-level
            -- destinations, run end to end:
            --   self.c.c / self.x.c   INNER differs  -> target=nil, PLANS, and the
            --                         result is `hp1.c = v`: the BASE is the
            --                         parameter and the write survives. Correct.
            --   self.b.c / self.b.d   OUTER differs  -> target=true, refused
            --   self.c.c / self.c.d   outer differs, inner name REPEATS the outer's
            --                         old value -> target=true, refused, and the
            --                         inner position is not tagged (it has no hole:
            --                         `c` faces `c` there)
            -- ⇒ The tuple matched is (kind, d1.n, d2.n), and a hole only carries
            --   BOTH of those when it is the destination's own divergence.
            if tk and holes[j].kind == tk and holes[j].a == tn1 and holes[j].b == tn2 then
                holes[j].target = true
            end
        end
    end
    for i = 1, #(r1.rhs or {}) do ok = anti_unify(r1.rhs[i], r2.rhs[i], la, lb, holes) and ok end
    if r1.cond or r2.cond then ok = anti_unify(r1.cond, r2.cond, la, lb, holes) and ok end
    -- ★ TAGGED BY RANGE, the same way `side` is, and for the same reason: the cost is
    -- a property of WHERE the hole sits, the row knows every hole it just produced,
    -- and threading a sixth parameter through `anti_unify`'s fifteen recursion sites
    -- is the change this file keeps paying for.
    if imp then
        local sites = {}
        literal_dep_sites(r1, imp, sites)
        if #sites > 0 then
            for j = row_start + 1, #holes do
                for _, sd in ipairs(sites) do
                    if same_at(holes[j].at_a, sd.at) then holes[j].literal_dep = sd.why; break end
                end
            end
        end
    end
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
    -- the language's import verb, for the literal-dependency price (see
    -- `literal_dep_sites`). A language that declares none simply gets no price.
    local imp
    do
        local lang = pair.a.file and expr.lang_of(pair.a.file)
        if lang then
            local oks, sp = pcall(require, 'cartograph.spec.' .. lang)
            imp = oks and type(sp) == 'table' and sp.import_call or nil
        end
    end
    for _, o in ipairs(pair.ops) do
        if o.op == 'sub' then
            -- per-ROW hole lists, then merged. The drift test below needs to know that a
            -- row diverges in exactly ONE place, which a single shared list cannot say.
            local rh = {}
            anti_unify_row(pair.a.exprs[o.i], pair.b.exprs[o.j], pair.a.locals, pair.b.locals, rh, imp)
            rows[#rows + 1] = rh
            for _, h in ipairs(rh) do holes[#holes + 1] = h end
        elseif o.op == 'ins' or o.op == 'del' then
            insdel = insdel + 1
        end
    end
    -- ★★★ "structural (needs a human)" IS TWO DIFFERENT ANSWERS WEARING ONE LABEL
    -- (CART-0881 rung 2). Measured by the prototype algebra against these very pairs
    -- (~/tools/templates NEARCLONES.md, 2026-09-10): ALL 31 structural pairs have a
    -- template. Eleven are pure row insertion/deletion — a HEDGE variable and nothing
    -- else. Twenty contain a WRAPPER: one side encloses what the other has bare, which
    -- is a CONTEXT variable, and it is typically SHARED ACROSS SITES (`c.line` against
    -- `callrec.line(c)` at eight sites = ONE accessor migration, stated once).
    -- Their sentence for it: "The verdict does not distinguish them; the template does."
    --
    -- ⚠ AND THE SIGNAL WAS ALREADY COMPUTED HERE AND THROWN AWAY. `holes` carries the
    -- struct entries; `params` below drops them (`if h.kind ~= 'struct'`), so the count
    -- reached no caller and the two classes rendered identically. Counting it is the
    -- whole change — nothing new is derived.
    --
    -- WHAT EACH SIGNAL MEANS, and they are independent:
    --   insdel  a WHOLE ROW exists on one side only            -> a hedge/repetition hole
    --   nstruct a row diverges in SHAPE, not in a leaf value   -> a wrapper candidate
    -- ★★★ A STRUCT HOLE ALREADY KNOWS WHY IT FIRED — the BRANCH that emitted it is
    -- the cause — and it used to throw that away, which is the third time in this
    -- arc a computed fact reached no caller (the struct COUNT, the row-pairing
    -- tie-break, this). The four sites are not one population:
    --     'arity'        a call or kid list of differing LENGTH. A hedge inside the
    --                    list; it encloses nothing, so NEVER a wrapper.
    --     'localglobal'  a local facing a global. The binder pass measured all 13
    --                    such holes as function PARAMETERS, not wrappers.
    --     'kind'         the two nodes have different kinds. GENUINELY AMBIGUOUS —
    --                    a call wrapping a field IS enclosure, a call facing a bare
    --                    name is a whole-term replacement.
    --
    -- ⚠ MEASURED AGAINST THE ALGEBRA over the 21 over-reports, and it corrected a
    -- prediction I had just made from a single witness ("most will be arity",
    -- reasoning from a vendored library that added a parameter):
    --     kind         13     <- the MAJORITY, and the ambiguous one
    --     arity         7
    --     localglobal   1
    -- So tagging the cause fences 8 of 21 soundly and leaves 13 needing the real
    -- question: does one side CONTAIN what the other has bare? One witness is not a
    -- population, even when it is the right witness.
    local nstruct, why_arity, why_kind, why_lg, kind_shared = 0, 0, 0, 0, 0
    local structs = {}
    for _, h in ipairs(holes) do
        if h.kind == 'struct' then
            nstruct = nstruct + 1
            structs[#structs + 1] = h
            -- the helper signature this hole would carry, per side
            h.deps_a = local_deps(h.xn, pair.a.locals)
            h.deps_b = local_deps(h.yn, pair.b.locals)
            if h.why == 'arity' then why_arity = why_arity + 1
            elseif h.why == 'localglobal' then why_lg = why_lg + 1
            else
                why_kind = why_kind + 1
                -- measured only, so far: the verdict below still reads `struct > 0`
                if shares_subterm(h.xn, h.yn) then kind_shared = kind_shared + 1 end
            end
        end
    end
    local structural = insdel > 0 or nstruct > 0
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
            -- ⚠ A PARAMETER IS ON THE WRITE SIDE IF **ANY** OF ITS SITES IS, and the
            -- grouping is by (kind, a, b) — so one parameter can hold a read site and
            -- a write site at once (`self.X = X` is exactly that shape when the two
            -- tokens group together). Taking the FIRST site's side, the way `at_a`
            -- does, would report the pair as read-only whenever the read came first.
            if h.side == 'lhs' then p.side = 'lhs'; p.dest = p.dest or h.dest end
            if h.target then p.target = true end
            -- ★ A PARAMETER IS PRICED IF **ANY** OF ITS SITES IS, the same rule `side`
            -- uses: the grouping is by (kind, a, b), so one parameter can hold a priced
            -- site and a free one, and lifting it pays for the priced one regardless.
            if h.literal_dep then p.literal_dep = p.literal_dep or h.literal_dep end
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
    -- ★ `shape` REFINES `kind`, IT DOES NOT REPLACE IT. Every existing consumer reads
    -- `kind` and keeps reading the same three values; a new field cannot break one.
    -- Only meaningful when kind == 'structural'.
    --   'rows'    pure insert/delete, no shape divergence — the cheapest class: a hedge
    --             hole is the whole story, and nothing is wrapped.
    --   'wrapper' a row diverges in shape — one side encloses the other. The class the
    --             extract/hoist verbs want, and the one worth a human's attention.
    --   'mixed'   both, so neither reading is complete on its own.
    -- ⚠ A STRUCT HOLE IS NOT THE ONLY WRAPPER SIGNAL, and my first cut said it was.
    -- Measured against the prototype's independent classification: struct-only gave
    -- 12 wrappers where it found 20. The rest are in plain sight — their finding is
    -- that "cartograph's field and operator holes ARE context variables": a field
    -- hole is `X(base)` with `field:a(◦)` against `field:b(◦)`, an operator hole is
    -- `X(l, r)`. Both are a wrapper around a base this code keeps, not a leaf value.
    -- ★ AND THEIR RULE IS NOW CLEANER THAN WHEN THEY MEASURED IT: they had 26 of 30
    -- and attributed the 4 exceptions to the row-pairing artefact, which is the bug
    -- fixed in CART-0875 — so those four were never wrappers failing the rule, they
    -- were pairings that should not have existed.
    -- ⇒ AND THAT IS NOW MEASURED, NOT ASSERTED. Scoring this rule against their
    --   oracle with the tie-break REVERTED and then restored, same pinned corpus:
    --        pre-fix aligner   agree 25 / 31
    --        post-fix aligner  agree 29 / 31
    --   The four that moved are #54 #55 #57 #58 — one family, all ctx=0 — which are
    --   EXACTLY the "other four" their write-up names. Their tree alignment had
    --   already seen through cartograph's bad row pairing, so THE ORACLE AGREED WITH
    --   THE FIX BEFORE THE FIX EXISTED: two independent routes to the same pairing.
    --
    -- ★★★ SCORED PAIR-BY-PAIR AGAINST THEIR CLASSIFICATION, on a WORKTREE PINNED to
    -- the commit they measured (so the corpus is identical, not merely similar —
    -- 59 pairs both sides, 31 structural both sides, ZERO disagreements about which
    -- pairs those are). Their per-pair context-variable count is the oracle:
    --      struct > 0 OR field/op   agree 29   disagree 2   <- this rule
    --      field/op alone           agree 21   disagree 10
    --      struct alone             agree 23   disagree 8
    -- NEITHER SIGNAL SUFFICES; the disjunction is not a hedge, it is the measured
    -- best of the three. (I shipped it before scoring the alternatives — the scoring
    -- is what makes it a choice rather than a guess.)
    --
    -- ⚠ THE TWO IT STILL GETS WRONG ARE BOTH OVER-REPORTS, AND BOTH HAND-READ:
    --   #34 `tp = tp or require 'cartograph.transport'` vs `tp = tp or transport`
    --       — a CALL against a NAME sharing no subterm. A whole-term replacement,
    --         so a plain node hole; nothing encloses anything.
    --   #47 `rec(node)` vs `rec(node, true)`
    --       — an ARITY difference in the argument list, which is a hedge INSIDE the
    --         list, not a wrapper around it.
    -- So `struct` conflates three things and only the third is a wrapper: differing
    -- list arity (hedge), a kind change with no shared subterm (plain hole), and one
    -- side ENCLOSING the other (context variable).
    -- ⇒ AND NO COUNTING RULE SEPARATES THEM: #33 has struct=1, insdel=0 and no
    --   field/op exactly like those two, and IS a wrapper. The discriminator is
    --   whether one side CONTAINS what the other has bare, which is the context
    --   variable itself — rung 3+, not a threshold that can be tuned here. 29/31 is
    --   the ceiling for a signal-counting rule and this sits on it.
    --
    -- ★★★ CONFIRMED ON A SECOND CORPUS the prototype never touched (wow addons,
    -- 2.27M lines, functions far larger than cartograph's own), by driving
    -- `A.vertical` over a strided sample so the ranked list was not read off its
    -- expensive end (tools/algebradrive.lua --rigid --stride):
    --        lua   structural  31   agree  29   93.5%
    --        wow   structural 288   agree 269   93.4%
    --        both  structural 319   agree 298   93.4%
    -- The accuracy is the same to a tenth of a point on two corpora three orders of
    -- magnitude apart in size, which is a stronger statement than either alone.
    --
    -- ★★★ AND EVERY ONE OF THE 21 ERRORS IS IN THE SAME DIRECTION: this rule said
    -- wrapper/mixed where the algebra found ctx = 0. ZERO UNDER-REPORTS — across 319
    -- structural pairs it never once MISSED a wrapper.
    -- ⇒ SO `shape` IS AN UPPER BOUND, NOT AN ESTIMATE, and that is how a consumer
    --   must read it: `wrapper`/`mixed` is a SUPERSET of the true wrappers, `rows`
    --   is trustworthy negatively. Same discipline as `tier.licenses` — an upper
    --   bound a consumer may only weaken. A caller that needs certainty a wrapper
    --   EXISTS has to run the context variable; a caller that needs to know one
    --   does NOT exist can trust `rows` today.
    --
    -- ★★★ AND THE TWO SIGNALS ARE NOT EQUALLY GOOD — ALL 21 ERRORS ARE THE STRUCT
    -- ONE. Broken down by which half of `struct > 0 OR field/op` fired:
    --        lua  2 of 2  STRUCT hole only
    --        wow 19 of 19 STRUCT hole only
    --   ⇒ THE FIELD/OP SIGNAL HAS PRODUCED ZERO FALSE POSITIVES IN 319 STRUCTURAL
    --     PAIRS. It is exact and incomplete (field/op alone scored 21 of 31 on lua,
    --     i.e. 10 wrappers it cannot see). `struct` is the RECALL half and carries
    --     100% of the error. Precision and recall live in different signals here.
    --
    -- ⚠ AND THE OVER-REPORTS HAVE A POPULATION, not just a mechanism. On wow they
    -- are overwhelmingly VENDORED LIBRARY COPIES AT DIFFERENT VERSIONS — the same
    -- AceDB-3.0 / AceGUI-3.0 file carried into many addons. Hand-read witness:
    --     LootPlan  DBObjectLib:ResetProfile(noChildren)
    --     MySales   DBObjectLib:ResetProfile(noChildren, noCallbacks)
    -- One library version added a parameter. Version drift adds parameters and
    -- statements, which is ARITY AND INSERTION — hedge territory — and never
    -- enclosure. So the struct signal over-fires exactly where a corpus vendors its
    -- dependencies, which is most Lua addon corpora.
    --
    -- ⇒ THE AVAILABLE IMPROVEMENT, not taken here: `wrapper` could be split by
    --   which signal fired — field/op is a CONFIRMED wrapper, struct alone is a
    --   POSSIBLE one. Rendering an exact signal and a heuristic one identically is
    --   the same fault this shape field was introduced to fix, one level down.
    -- ★★ THE TWO SIGNALS ARE KEPT APART BECAUSE THEY ARE NOT THE SAME CLAIM.
    -- A SELECTOR hole (field/operator) IS the wrapper: `X(base)` with `field:a(◦)`
    -- against `field:b(◦)`, the base kept on both sides. A STRUCT hole only says
    -- the two rows differ in SHAPE, which is necessary but not sufficient — the
    -- same evidence is produced by a differing list arity and by a kind change
    -- with no shared subterm, neither of which encloses anything.
    -- Merging them into one verdict renders an exact signal and a heuristic
    -- identically, which is the fault `shape` itself was introduced to fix.
    local selector = false
    for _, h in ipairs(params) do
        if h.kind == 'field' or h.kind == 'operator' then selector = true end
    end
    local wrapping = nstruct > 0 or selector
    local shape, evidence
    if kind == 'structural' then
        if not wrapping then shape = 'rows'
        elseif insdel == 0 then shape = 'wrapper'
        else shape = 'mixed' end
        -- ⚠ `evidence` IS THE FIELD A CONSUMER SHOULD GATE ON, not `shape`.
        -- MEASURED over 319 structural pairs on two corpora, against the algebra's
        -- own context variable (tools/algebradrive.lua --rigid):
        --   'selector'  a field/operator hole fired — ZERO false positives. When
        --               both signals fire this still reads `selector`, and that is
        --               measured too: no disagreement ever involved field/op.
        --   'shape'     a struct hole and nothing else — carries ALL 21 over-reports
        --               (lua 2 of 2, wow 19 of 19). On a corpus that VENDORS its
        --               dependencies this fires often and means little: two copies
        --               of one library at different versions differ by an added
        --               parameter or statement, which is arity and insertion.
        --
        -- ★★★ SCORED, and this is why the split is worth a field:
        --        rows       196 / 196   100%
        --        selector    30 /  30   100%     (0 errors — a modest sample, stated)
        --        shape       72 /  93    77.4%   (every measured error lives here)
        --        ---------------------------------------------------------------
        --        merged     298 / 319    93.4%   <- what ONE verdict reported
        -- THE MERGED FIGURE IS A BLEND OF A PERFECT SIGNAL AND A 77% ONE, and it
        -- misleads in BOTH directions: a consumer acting on "93%" is too cautious
        -- about `selector` and far too trusting of `shape`. An average over two
        -- populations with different reliability is not a property of either.
        -- ★★★ THREE RUNGS, NOT TWO, AND THE VERDICT IS NOT NARROWED.
        -- Containment on the `kind` bucket was built and scored against the algebra
        -- (tools/algebradrive.lua): as a NARROWING it takes 93.4% -> 96.9% and
        -- fixes 13 of the 21 over-reports — but it costs 2 UNDER-reports where
        -- there were none, and an under-report means a `rows` verdict HIDING a
        -- wrapper. That trades a sound bound for an accuracy gain, which is the one
        -- trade this codebase consistently refuses (`tier.licenses`, "a profile can
        -- only subtract, a false guarantee is unsound").
        -- ⇒ SO THE SIGNAL IS REPORTED, NOT ACTED ON: nothing is demoted to `rows`,
        --   the upper bound survives, and the reader gets the precision as a RUNG.
        if shape ~= 'rows' then
            if selector then evidence = 'selector'          -- 30/30 measured
            elseif why_kind > 0 and kind_shared == 0 then
                evidence = 'shape-unshared'                 -- the weakest: the two
                -- sides of every `kind` hole share NO subterm, so nothing is kept
                -- across the divergence and enclosure is unlikely. 13 of the 21
                -- measured over-reports are here.
                -- SCORED against the algebra's context variable:
                --      evidence          lua          wow           both
                --      selector        10/10  100%   20/20  100%   30/30  100%
                --      shape            5/6    83%   61/68   90%   66/74   89%
                --      shape-unshared   5/6    83%    1/13    8%    6/19   32%
                -- ⚠⚠ AND THE BOTTOM RUNG DISAGREES WITH ITSELF ACROSS CORPORA —
                -- 83% right on lua, 92% WRONG on wow. n=6 on lua is small enough
                -- that this may be noise, but it is NOT yet a stable property and
                -- must not be quoted as "32% reliable" as though that were one
                -- number. What IS stable: the rung is where the over-reports
                -- concentrate, and `selector` is exact on both.
                --
                -- ★★★ AND THE CHEAP TEST LEAVES NOTHING ON THE TABLE, which is why
                -- this rung uses it. The algebra's OWN instrument was run on the two
                -- diverging nodes -- `vertical` at NODE scale rather than function
                -- scale -- and scored beside this subterm test:
                --      node-scale vertical vs the function-scale oracle  85/90  94.4%
                --      as a narrowing, on wow:  both  280 agree / 7 over / 1 under
                -- IDENTICAL AT SCALE. On 288 pairs a canonical-key subterm test is
                -- indistinguishable from running the alignment algebra locally; the
                -- single lua pair that separated them was noise.
                --
                -- ★★ THE FINDING WORTH CARRYING: the node-scale answer reproduces the
                -- function-scale one 94% of the time. DECIDING whether a wrapper
                -- exists is affordable; only DESCRIBING it needs the function-wide
                -- alignment (0.2-12 s/pair, half of wow outside the guard).
                --
                -- ⇒ NEITHER CANDIDATE SHIPS AS A NARROWING: both still cost an
                --   under-report, so the residual is not a missing instrument. It is a
                --   boundary where node-scale evidence and function-scale alignment
                --   legitimately disagree -- which is what an evidence rung is for and
                --   a verdict change is not.
            else evidence = 'shape' end
        end
    end
    return { kind = kind, holes = params, insdel = insdel, drift = drift,
        struct = nstruct, shape = shape, evidence = evidence,
        struct_why = { arity = why_arity, kind = why_kind, localglobal = why_lg,
            kind_shared = kind_shared },
        -- ★ THE STRUCT HOLES THEMSELVES, which this function has always computed and
        -- always dropped (`params` excludes them). Exposed so a consumer can ask the
        -- question the counts cannot answer — what do the two diverging sides
        -- actually have in common. FOURTH computed-and-discarded fact in this arc.
        -- ⚠ `xn`/`yn` are LIVE REFERENCES into the expression tree, not copies, and
        -- carry the same contract as the holes list: read, never mutate through them.
        structs = structs }
end

--- does any hole of this analysis stand where the assignment TARGET is? One place,
--- because two readers want it and a second copy of the loop is the two-lists defect.
local function target_hole(a)
    for _, h in ipairs((a and a.holes) or {}) do if h.target then return h end end
    return nil
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
    -- ★★★ SAY WHICH KIND OF STRUCTURAL, because the one label covered two answers with
    -- different owners and different costs (CART-0881 rung 2). "needs a human" was never
    -- true of all of them: every structural pair HAS a template, and what differs is what
    -- the template needs — a hedge hole, or a context variable.
    -- ★ THE VERDICT NAMES ITS EVIDENCE, because the two are not equally good and a
    -- reader deciding where to spend attention needs to know which one they have.
    -- `selector` has zero measured false positives; `shape` carries every one.
    local SHAPE = {
        rows = 'structural: ROWS ONLY (inserted/deleted statements — a repetition hole)',
        ['wrapper/selector'] = 'structural: A WRAPPER (one side encloses the other — a context hole)',
        ['wrapper/shape'] = 'structural: MAYBE A WRAPPER (shape divergence only — may be an arity difference)',
        ['wrapper/shape-unshared'] = 'structural: PROBABLY NOT A WRAPPER (the diverging sides share nothing)',
        ['mixed/shape-unshared'] = 'structural: ROWS, and probably not a wrapper (the diverging sides share nothing)',
        ['mixed/selector'] = 'structural: WRAPPER + ROWS (one side encloses the other, and rows differ)',
        ['mixed/shape'] = 'structural: ROWS, and MAYBE a wrapper (shape divergence only)',
    }
    for i, p in ipairs(pairs_) do
        local a = M.analyze_pair(p)
        local pos = band_lo[i] == band_hi[i] and ('#%d'):format(band_lo[i])
            or ('#%d-%d'):format(band_lo[i], band_hi[i])
        L[#L + 1] = ('■ %s of %d · %d edit(s), %d shared statement(s) — %s:')
            :format(pos, #pairs_, p.dist, p.shared,
                (a.shape and (SHAPE[a.shape .. '/' .. tostring(a.evidence)] or SHAPE[a.shape]))
                -- ★★★ `value-parameterizable` IS A CLAIM AND IT CAN BE FALSE. A hole that
                -- IS an assignment target cannot become a parameter -- substituting it
                -- deletes the write (CART-0941) -- so the verb refuses and this line
                -- must not promise otherwise. It read `TAG[a.kind]` alone, which is
                -- exactly the surface a new data field does not reach on its own.
                or (target_hole(a) and 'value-shaped, but the divergence is an'
                    .. ' assignment TARGET — not parameterizable')
                or TAG[a.kind])
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
            L[#L + 1] = ('      param (%s): %s  ⇄  %s%s'):format(h.kind,
                tostring(h.a), tostring(h.b),
                h.literal_dep and ('   ★ PRICED: this is ' .. h.literal_dep
                    .. ' — as a VALUE it costs the resolution') or '')
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
        -- ★★★ "EXTRACT BY HAND" THREW AWAY A SIGNATURE IT COULD HAVE DERIVED
        -- (CART-0876). A structural pair is not one thing: its struct holes carry the
        -- two diverging subterms, and the LOCALS each subterm reads ARE the helper's
        -- argument list. Measured on cartograph's own tree, 14 of the 31 structural
        -- pairs carry such a hole — the prototype's binder pass, run on these same
        -- pairs, put the figure at fifteen once its row-misalignment artefact (the
        -- bug fixed in CART-0875) was discounted.
        -- ⚠ THIS STILL DOES NOT CLAIM EXTRACTABILITY. Rows present on one side only
        -- mean the bodies genuinely differ in statements, and no single helper covers
        -- that. What changes is that the reader is told WHAT THE HELPER WOULD TAKE and
        -- WHAT STILL BLOCKS IT, instead of one sentence that ends the conversation.
        local L = { ('%s differ structurally (%d inserted/deleted statement(s), %d shape'
            .. ' divergence(s)) — not a clean value-parameterization.')
            :format(p_name(pair), a.insdel, a.struct or 0) }
        local fn_params = {}
        for _, h in ipairs(a.structs or {}) do
            local d = (#(h.deps_a or {}) >= #(h.deps_b or {})) and h.deps_a or h.deps_b
            if d and #d > 0 then fn_params[#fn_params + 1] = { h = h, deps = d } end
        end
        if #a.holes > 0 or #fn_params > 0 then
            L[#L + 1] = '  the helper this WOULD take, derived:'
            for i, h in ipairs(a.holes) do
                L[#L + 1] = ('    p%d  a VALUE (%s):  %s  /  %s')
                    :format(i, h.kind, tostring(h.a), tostring(h.b))
            end
            for i, f in ipairs(fn_params) do
                -- a hole reading locals is a FUNCTION of them, not a value
                L[#L + 1] = ('    f%d  a FUNCTION of (%s)   [%s divergence]')
                    :format(i, table.concat(f.deps, ', '), tostring(f.h.why or 'kind'))
            end
        end
        L[#L + 1] = ('  what blocks a single helper: %s'):format(
            a.insdel > 0 and ('%d row(s) on one side only'):format(a.insdel)
            or 'a shape divergence the value-parameterization cannot cross')
        return L
    end
    local L = {
        ('helper extraction proposal — %s'):format(p_name(pair)),
        ('  value-parameterizable: %d shared statement(s), %d parameter(s)')
            :format(pair.shared, #a.holes),
        ('  copies: %s:%d  and  %s:%d'):format(pair.a.file, pair.a.lines[1] or 0,
            pair.b.file, pair.b.lines[1] or 0),
        '  parameters (the varying leaves — one per hole):',
    }
    local priced = 0
    for _, h in ipairs(a.holes) do if h.literal_dep then priced = priced + 1 end end
    for i, h in ipairs(a.holes) do
        L[#L + 1] = ('    p%d (%s):  %s  in %s   /   %s  in %s')
            :format(i, h.kind, tostring(h.a), pair.a.name, tostring(h.b), pair.b.name)
        if h.literal_dep then
            L[#L + 1] = ('         ★ PRICED — this leaf is %s. Passed as a VALUE the'
                .. ' resolver stops seeing it;'):format(h.literal_dep)
            L[#L + 1] = '           passed as a FUNCTION the call site keeps its literal and it costs nothing.'
        end
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
    -- ★★★ THE PRICE THE CLONE TIER CANNOT SEE (CART-0876/0878). Both shapes of this
    -- extraction remove exactly the same duplication; only one of them keeps the graph
    -- we analyse ourselves with. Measured on our own commands/analysis.lua: six
    -- callbacks lifted with STRING parameters took it from 17 import edges to 11 and
    -- left three report functions unreferenced; the same six lifted with the call as a
    -- FUNCTION cost nothing, and the near tier moved 32 -> 7 pairs either way.
    if priced > 0 then
        L[#L + 1] = ('  ★ FACT PRICE: %d of the %d parameter(s) above carry a resolution.')
            :format(priced, #a.holes)
        L[#L + 1] = '    Lifting them as VALUES makes the resolver lose what they name; lifting the'
        L[#L + 1] = '    whole call as a FUNCTION keeps every literal at its call site and costs nothing.'
        L[#L + 1] = '    Same duplication removed either way — this is a price, not a refusal.'
    end
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
    -- ★ A TYPE KEYS BY ITS NAME OR EVERY TYPE IS THE SAME TYPE (CART-0742). A
    -- bare named type has NO KIDS, so without this `new Foo()` and `new Bar()`
    -- canon IDENTICALLY. Present in all THREE structural keys in this file,
    -- because they are three copies of one function and a kind added to two of
    -- them is a silent disagreement about what "the same expression" means.
    if k == 'type' then
        local kp = {}
        for _, c in ipairs(e.kids or {}) do kp[#kp + 1] = bcanon(c, locals, slots, ctr, st) end
        return 'Y' .. (e.n or (e.prim and '#prim') or '') .. '(' .. table.concat(kp, ',') .. ')'
    end
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
-- ── divergence census: WHICH HOLE KINDS ARE WE MISSING? ──────────────────────
-- analyze_pair names exactly two kinds of divergence — a VALUE hole (a clean
-- parameter) and a STRUCT hole (give up). Everything the template language
-- cannot express lands in the second bucket undifferentiated, so the question
-- "what else should a template be able to say?" has no evidence behind it.
--
-- This censuses that bucket. For every divergence the named kinds cannot take,
-- it records the node-kind pair and a set of derived FEATURES, so a further
-- hole kind is FOUND rather than guessed. CART-0349 already did this once by
-- hand — it noticed `lit` facing `name` was a class of its own and named it
-- DRIFT — and the census re-discovers that class, which is the only validation
-- available for a method like this.
--
-- ★ FEATURES, NOT KIND NAMES, ARE THE ROBUST OUTPUT. The kind-pair table is
-- contaminated wherever the expression IR falls back to `?<tree-sitter type>`
-- for a construct it does not model: on a mixed corpus (elasticsearch/libs
-- carries 28 .cc + 6 .h) that fallback dominates the table and measures IR
-- COVERAGE rather than a missing hole kind. The feature table keys on shape and
-- does not have that problem. Read features first.
--
-- ★ RETURNS ROWS, NOT STRINGS ([[cartograph-interactive-reports]] / CART-0698):
-- the caller formats. A census that renders is a census that cannot be diffed.
local function dc_kids(e)
    local o, k = {}, e.k
    if k == 'field' then o[1] = e.b
    elseif k == 'index' then o[1] = e.b; o[2] = e.i
    elseif k == 'call' then o[1] = e.f; for _, a in ipairs(e.a or {}) do o[#o + 1] = a end
    elseif k == 'un' then o[1] = e.e
    elseif k == 'bin' then o[1] = e.l; o[2] = e.r
    elseif k == 'assign' then o[1] = e.t; o[2] = e.v
    elseif k == 'table' then for _, c in ipairs(e.kids or {}) do o[#o + 1] = c end
    else
        -- ★ EVERY OTHER KIND, AND THIS WAS THE BUG. The closed schema models
        -- six shapes; everything else is a GENERIC node carrying `.kids` (see
        -- rcanon's fallback, which prints them). This branch did not exist, so
        -- dc_kids returned NOTHING for a generic node and `leaf-vs-tree` — "a
        -- bare local facing the expression it was assigned from" — fired on
        -- every generic-vs-modelled divergence instead.
        --
        -- IT IS WORST EXACTLY WHERE THE CENSUS WAS RUN. On java a method call
        -- is `?method_invocation`, not `k == 'call'` (the expression IR is a
        -- LUA IR — CART-0224), so the single largest class of java expressions
        -- read as LEAVES. The witnesses were unmistakable once printed:
        --     A ?method_invocation(L,NgetCentroidDP,?argument_list())
        --     B B*(?decimal_integer_literal(),L)
        -- tagged `leaf-vs-tree`, i.e. "extract local", for a pair that is two
        -- different distance formulas. Three of three hand-read witnesses were
        -- misclassified. See CART-0737.
        for _, c in ipairs(e.kids or {}) do o[#o + 1] = c end
    end
    local r = {}
    for _, c in ipairs(o) do if c then r[#r + 1] = c end end
    return r
end

local function dc_size(e)
    if type(e) ~= 'table' then return 0 end
    local n = 1
    for _, c in ipairs(dc_kids(e)) do n = n + dc_size(c) end
    return n
end

-- the argument/element LIST a node carries, if any — where a repetition hole
-- would sit
local function dc_list(e)
    if not e then return nil end
    if e.k == 'call' then return e.a or {} end
    if e.k == 'table' then return e.kids or {} end
    return nil
end

local function dc_align(x, y, la, lb)
    if not x or not y then return false end
    local h = {}
    return anti_unify(x, y, la, lb, h)
end

-- a repetition hole is only honest if the list's elements are instances of ONE
-- template; a heterogeneous list is not a repetition, it is unrelated content
local function dc_homogeneous(list, la, lb)
    if #list < 2 then return true end
    for i = 2, #list do if not dc_align(list[1], list[i], la, lb) then return false end end
    return true
end

-- does one side NEST the other (the recursion case)? Bounded depth: this is a
-- census, not a solver, and an unbounded search would dominate its cost.
local DC_WRAP_DEPTH = 2
local function dc_wraps(outer, inner, la, lb, depth)
    depth = depth or DC_WRAP_DEPTH
    if depth <= 0 then return false end
    for _, c in ipairs(dc_kids(outer)) do
        if dc_align(c, inner, la, lb) then return true end
        if dc_wraps(c, inner, la, lb, depth - 1) then return true end
    end
    return false
end

--- CLASSIFY ONE DIVERGENCE in the census's own vocabulary — extracted VERBATIM
--- from `divergence_census`'s `record`, which was its only caller until CART-0766
--- step B gave it a second one.
---
--- ★★ THE EXTRACTION IS THE POINT, NOT A TIDY-UP. `M.match` must say WHY a
--- payload failed to fit a container's members, and the honest vocabulary for
--- that already exists — it was measured, argued down twice (`call-vs-expr` was
--- ~half artifact, bare `arity` is not a refactoring) and every caveat lives in
--- the comments below. A SECOND implementation of these predicates would be the
--- copied-walker bug at the level of a taxonomy: two vocabularies drifting apart,
--- with the census's calibration attached to only one of them.
---
--- ⚠ IT IS NOT A COMPLETE VOCABULARY FOR EVERY POPULATION, and the difference
--- matters more here than it did for the census. These features were tuned on
--- NEAR-CLONE PAIRS OF FUNCTION BODIES; pointed at (container member, payload)
--- some transfer and some have no population at all — `call_arity` measured 0.0%
--- on four of five corpora. `M.match` therefore RANKS what this returns by the
--- target language and leaves the rest unranked; it does not filter it, because a
--- classification is honest even where a ranking has nothing to say. See
--- CART-0766's calibration notes for the table.
---@return string[] feature names, never empty ('(no feature)' is an answer)
local function dc_features(x, y, la, lb)
    local kx = x and x.k or 'NIL'
    local ky = y and y.k or 'NIL'
    local f = {}
    if not x or not y then
        f[#f + 1] = 'one-side-absent'
    else
        local sx, sy = dc_size(x), dc_size(y)
        local cx, cy = rcanon(x, la or {}, {}), rcanon(y, lb or {}, {})
        if cx == cy then f[#f + 1] = 'canon-equal(alpha)' end
        -- one side literally contains the other: a guard/conjunct was added,
        -- or a value was wrapped
        if cx:find(cy, 1, true) or cy:find(cx, 1, true) then f[#f + 1] = 'containment' end
        -- a bare local facing the expression it was assigned from: EXTRACT LOCAL
        if (#dc_kids(x) == 0) ~= (#dc_kids(y) == 0) then f[#f + 1] = 'leaf-vs-tree' end
        -- CART-0349's class, re-found by the census
        if (kx == 'lit' and ky == 'name') or (kx == 'name' and ky == 'lit') then
            f[#f + 1] = 'drift(lit/name)'
        end
        -- a call facing something that is not one: EXTRACT/INLINE A CALL
        if (kx == 'call' or ky == 'call') and kx ~= ky then f[#f + 1] = 'call-vs-expr' end
        -- ★★ THE SAME CALLEE WITH A DIFFERENT NUMBER OF ARGUMENTS: AN
        -- OPTIONAL-ARGUMENT HOLE (CART-0742 item 4). Neither CART-0729 nor
        -- CART-0730 named this — they concluded the missing kinds were
        -- REPETITION and RECURSION — and it is a third thing: the callee
        -- agrees, only the argument LIST length differs, which is the
        -- add-parameter / remove-parameter refactoring seen from outside.
        --
        -- ★★ IT READS THE NODES, NOT THE KEY, AND THAT IS THE POINT. The
        -- prototype for this measured the class by pulling the callee out of
        -- a canon STRING with `^C([%w_%.]+)%(` — a greedy pattern that knows
        -- nothing about nesting, so a chained call `CMCMNa.b().c(x,y)` read
        -- as callee `MCMNa.b` with the arguments `).c(x,y`. A zero-argument
        -- php getter came back with TWELVE ARGUMENTS, and 88% of grocy's
        -- class was that artifact. A STRUCTURAL KEY IS A LANGUAGE AND A LUA
        -- PATTERN IS NOT A PARSER FOR IT — here the nodes are in hand, so
        -- there is nothing to parse (CART-0746).
        --
        -- ⚠ THE CALLEE IS COMPARED ALPHA-RENAMED, like every other test in
        -- this function, so `a.f(x)` and `b.f(x, y)` with `a`/`b` both local
        -- DO match. That is deliberate — it is the same receiver role — and
        -- it is also why this is a CANDIDATE, not a confirmed refactoring.
        --
        -- ⚠ AND IT CANNOT FIRE WHERE THE TAXONOMY ALREADY SPEAKS. `walk`
        -- reaches `record` for an arity difference only when the longer
        -- argument list is NOT homogeneous; a homogeneous one is a
        -- REPETITION HOLE and never gets here.
        if kx == 'call' and ky == 'call'
            and rcanon(x.f, la or {}, {}) == rcanon(y.f, lb or {}, {})
            and #(x.a or {}) ~= #(y.a or {}) then
            f[#f + 1] = 'arity'
            -- ...and the STRONG form: the shorter argument list is an
            -- alpha-canon PREFIX of the longer, so the extra arguments were
            -- APPENDED. `f(a,b)` vs `f(a,b,delta)` is an optional argument;
            -- `f(a,b)` vs `f(x,y,z)` shares only a name. MEASURED at 36% of
            -- the class on java, 4% on C++, 0% on php.
            --
            -- ⚠⚠ AND THE PREFIX IS ALPHA-RENAMED, SO A PREFIX OF BARE
            -- LOCALS AGREES BY CONSTRUCTION. `rcanon` maps EVERY local to
            -- `L` — not to a position — so `f(a)` and `f(x, y)` are an
            -- "appended" match because `L` == `L`. MEASURED on libs: 108 of
            -- the 130 strong divergences rest on an all-locals prefix and
            -- only 22 (9 signatures) have a prefix carrying structure the
            -- canon can tell apart. The tag does NOT distinguish them, so
            -- READ 130 AS 130 CANDIDATES, NOT 130 FINDINGS. The class's own
            -- best witness sits in the weak bucket and is real anyway —
            -- `assertScoresEquals(L,L)` ⇄ `(L,L,Ndelta)` x95 over 6 owners,
            -- where `Ndelta` is a NON-local name — which is why this is not
            -- filtered here: the split is a REFINEMENT to make when someone
            -- acts on the class, not a reason to hide two thirds of it.
            -- ⚠ THE LOCALS MAP TRAVELS WITH ITS SIDE. Putting the shorter
            -- list first means swapping `la`/`lb` WITH it — the first cut
            -- swapped only the argument lists, so a right-longer pair was
            -- canonicalised with the other side's locals and a name that is
            -- local on one side read as a global on the other. It cost ONE
            -- divergence on libs, which is exactly why it is worth a
            -- comment: a silent 1-in-130 is the kind of wrong that survives.
            local sa, sb, ma, mb = x.a or {}, y.a or {}, la or {}, lb or {}
            if #sa > #sb then sa, sb, ma, mb = sb, sa, mb, ma end
            local pre = true
            for i = 1, #sa do
                if rcanon(sa[i], ma, {}) ~= rcanon(sb[i], mb, {}) then
                    pre = false; break
                end
            end
            if pre then f[#f + 1] = 'arity(appended)' end
        end
        local mx, my, ox, oy = {}, {}, {}, {}
        for i, c in ipairs(dc_kids(x)) do local k2 = rcanon(c, la or {}, {}); mx[k2] = (mx[k2] or 0) + 1; ox[i] = k2 end
        for i, c in ipairs(dc_kids(y)) do local k2 = rcanon(c, lb or {}, {}); my[k2] = (my[k2] or 0) + 1; oy[i] = k2 end
        local same = true
        for k2, v in pairs(mx) do if my[k2] ~= v then same = false; break end end
        if same then for k2, v in pairs(my) do if mx[k2] ~= v then same = false; break end end end
        local ordered = #ox == #oy
        if ordered then for i = 1, #ox do if ox[i] ~= oy[i] then ordered = false; break end end end
        if same and #ox > 1 and not ordered then f[#f + 1] = 'reorder' end
        if math.max(sx, sy) > 0 and math.min(sx, sy) / math.max(sx, sy) < 0.34 then
            f[#f + 1] = 'size-skew'
        end
    end
    if #f == 0 then f[1] = '(no feature)' end
    return f
end

-- ── match: does a payload instantiate a container's element template? ─────────
-- The DUAL of anti-unification, and CART-0766's step B. `anti_unify` GENERALISES
-- two instances into a skeleton plus holes; `M.match` SPECIALISES — does this one
-- expression fit the skeleton, and what does each hole bind to. Same traversal,
-- opposite direction, and it reuses that traversal rather than writing a second
-- one: a copied walker is a copied bug (CART-0746), and here the copy would also
-- fork the hole vocabulary the reports and `M.drift` already read.
--
-- ★★ THE REFUSAL IS THE MOST USEFUL ANSWER THIS PRODUCES. A match that succeeds
-- confirms what the caller already intended; a match that fails is the only thing
-- that says what the container actually holds. So the failure path is where the
-- work is: it is LOCATED (which position), CLASSIFIED (in the census's measured
-- vocabulary), and where the gap is trivially derivable it carries the PREMISE
-- that would close it — a question with an exact cost, in the shape
-- [[cartograph-hedge-resolution-writes]] names.

-- ⚠⚠ THE ORDER IS PER-LANGUAGE AND THE FEATURE SET IS SHARED — measured, and it
-- overturned the ranking this arc first wrote from one corpus. Share of
-- CONTAINERS in which the feature has at least one instance (CART-0766's
-- calibration notes hold the full table and the method):
--
--   * `containment` was ranked LAST on our own lua tree at 0.6% and is 29.1% on
--     java, the single highest figure in the table — a java array_initializer is
--     full of members that structurally contain one another and a lua spec table
--     is not.
--   * `size-skew` is 31% on php and js against ~10% on java, c++ and lua:
--     dynamic-language literals are heterogeneous.
--   * `leaf-vs-tree` is the only feature EVERY corpus supports (6-25%), which is
--     why it leads the default.
--   * C++ is uniformly thin (11/10/3/0/2.5), so a refusal there will often land
--     in `(no feature)`. That is a fact about how much this verb can say in C++,
--     and it should say that rather than reach for a feature.
--
-- ⚠⚠ TWO FEATURES ARE DELIBERATELY IN NO RANKING, FOR TWO DIFFERENT REASONS, and
-- collapsing them into one bullet is how this comment read on its first cut:
--   * `arity` — the census's CALL arity, same callee with a different argument
--     count — HAS NO POPULATION HERE. 0.0% on four calibration corpora of five,
--     0.5% on the fifth, and it did not fire ONCE across 14,184 cross-matches on
--     three languages. Container members are almost never calls. Nothing to rank.
--   * `call-vs-expr` — a call facing something that is not one — DOES have a
--     population here (8.8% of lua refusals, 10.6% php, 0.3% js) and is unranked
--     anyway, because CART-0741 measured this feature ~HALF ARTIFACT: a statement
--     wrapper made `?` face `call` and minted 1491 divergences that were not one.
--     It is classified honestly and never promoted, which is the only defensible
--     place for a feature whose own population has not been re-adjudicated on
--     THIS one. Ranking it would be the mistake this arc has now made three
--     times: promoting a feature on its name rather than on its witnesses.
--
-- ⚠ THE TABLE IS FIVE CORPORA AND FOUR LANGUAGES. Every ranking below is
-- `ranked-open` and says so in the shortlist it rides in; a language absent from
-- the table gets DEFAULT_RANK and is told that the order came from a default
-- rather than from a measurement of it.
local REFUSAL_RANK = {
    -- ★ THE LUA ROW WAS WRONG ON ITS FIRST CUT AND A SECOND CORPUS CAUGHT IT.
    -- It was built from `synlua`, where `containment` and `table-arity` both
    -- measure 0.0%, so both were dropped — and on our own lua tree they fire 278
    -- and 142 times across 11,531 refusals. A synthetic gate corpus is a corpus,
    -- and one corpus is a property of that corpus (the standing lesson, a fourth
    -- time). Both are back, ranked last, which is what 0.6% earns.
    lua        = { 'leaf-vs-tree', 'size-skew', 'drift(lit/name)', 'containment', 'table-arity' },
    java       = { 'containment', 'leaf-vs-tree', 'drift(lit/name)', 'size-skew' },
    php        = { 'size-skew', 'leaf-vs-tree', 'containment', 'drift(lit/name)', 'table-arity' },
    cpp        = { 'leaf-vs-tree', 'size-skew', 'drift(lit/name)', 'containment' },
    javascript = { 'size-skew', 'leaf-vs-tree', 'containment', 'drift(lit/name)', 'table-arity' },
}
local DEFAULT_RANK = { 'leaf-vs-tree', 'size-skew', 'containment', 'drift(lit/name)', 'table-arity' }

-- the literal-string keys a table-shaped node declares, for the PREMISE below
local function lit_keys(e)
    local out, order = {}, {}
    if not e or e.k ~= 'table' then return out, order end
    for _, m in ipairs(e.kids or {}) do
        if m.k == 'pair' and m.key and m.key.k == 'lit' and m.key.ty == 'str' then
            local s = tostring(m.key.v)
            if not out[s] then order[#order + 1] = s end
            out[s] = true
        end
    end
    return out, order
end

--- Does `payload` instantiate `tmpl`, and if not, why not.
---@param tmpl table    an `M.element_template` result
---@param payload table an expr node — the member a caller proposes to add
---@param opts table|nil { lang = 'lua'|'java'|… — ranks the refusal vocabulary }
---@return table {
---   ok, bindings, distance, weak?,
---   refusal = { why, features (a shortlist), mismatches, structs, premise? } }
function M.match(tmpl, payload, opts)
    opts = opts or {}
    -- ⚠ NO `vim.*` HERE. This module is plain Lua — its one `vim` reference was
    -- this line, and a module that runs outside an editor is worth keeping that
    -- way (the sharded-index and fold flows load it headless).
    local function no(why, extra)
        local r = { why = why }
        for k, v in pairs(extra or {}) do r[k] = v end
        return { ok = false, distance = math.huge, refusal = r }
    end
    if type(tmpl) ~= 'table' or not tmpl.donor then
        return no(tmpl and tmpl.why or 'no template')
    end
    if type(payload) ~= 'table' or not payload.k then
        return no('the payload is not an expression node')
    end
    -- ⚠ A NON-ALIGNABLE TEMPLATE IS NOT A TEMPLATE, and matching against its
    -- arbitrary first member would answer a question nobody asked. MEASURED on
    -- our own lua tree: 1731 of 2452 containers with two or more members
    -- (70.6%) are non-alignable — a spec table is `{ a = 1, b = {…}, c = function … }`,
    -- three shapes under one name. For those, "what shape should a new member
    -- take" HAS NO ANSWER, and saying so is the answer.
    if not tmpl.alignable then
        return no('the container\'s members do not share a shape', { n = tmpl.n })
    end
    if (tmpl.unkeyed or 0) > 0 then
        return no('the template has holes with no source span, so a position '
            .. 'cannot be told from a mismatch', { unkeyed = tmpl.unkeyed })
    end

    local holes = {}
    anti_unify(tmpl.donor, payload, {}, {}, holes)

    -- THE SPLIT THIS VERB EXISTS FOR: a divergence at a position the members
    -- already vary at is a BINDING; the same divergence anywhere else is a
    -- MISMATCH; a shape divergence is neither and stops the walk.
    local bindings, mismatches, structs = {}, {}, {}
    for _, h in ipairs(holes) do
        if h.kind == 'struct' then
            structs[#structs + 1] = h
        elseif tmpl.varying[span_key(h.at_a) or ''] then
            bindings[#bindings + 1] = { hole = h.kind, from = h.a, to = h.b,
                at = h.at_a, at_payload = h.at_b,
                -- an operator hole's span is its ENCLOSING expression, so it
                -- identifies a position and is NOT a place to write (step C)
                site = not h.at_encloses }
        else
            mismatches[#mismatches + 1] = { hole = h.kind, expected = h.a,
                got = h.b, at = h.at_a, at_payload = h.at_b }
        end
    end

    local distance = #mismatches + #structs
    if distance == 0 then
        return { ok = true, bindings = bindings, distance = 0,
            -- ★ n == 1 MATCHES ON ZERO HOLES BY CONSTRUCTION — `varying` is
            -- empty, so anything that differs is a mismatch. That is the right
            -- strictness, but the caller must be able to tell "fits a shape
            -- confirmed by five members" from "is identical to the only one
            -- there is", which is weaker evidence for a different reason.
            weak = tmpl.n == 1 and 'template from a single member' or nil }
    end

    -- CLASSIFY, in the vocabulary the census measured. Only STRUCT holes get a
    -- feature: they are the ones carrying both nodes, and the features are all
    -- defined on nodes. A value mismatch needs no vocabulary — "members agree on
    -- `foo` here and you supplied `bar`, at this span" IS the explanation, and
    -- [[cartograph-explaining-a-finding]]'s rule is that an explanation is the
    -- offending nodes rather than a sentence about them.
    local seen, names = {}, {}
    local function add(n) if not seen[n] then seen[n] = true; names[#names + 1] = n end end
    for _, h in ipairs(structs) do
        if h.xn and h.yn then
            for _, f in ipairs(dc_features(h.xn, h.yn, {}, {})) do
                if f ~= '(no feature)' then add(f) end
            end
            -- ★ `table-arity` IS COMPUTED HERE AND NOT IN `dc_features`, on
            -- purpose. It is not a census feature — adding it there would change
            -- the census's output and break the byte-identical gate by
            -- construction — and it is this population's OWN analogue of
            -- `arity`: two nested tables with different member counts, measured
            -- at 1.8% of member pairs where the CALL form measured 0.0%. Same
            -- intuition, different predicate; a REDEFINITION, not a transfer,
            -- and the calibration is what told the two apart.
            if h.xn.k == 'table' and h.yn.k == 'table'
                and #(h.xn.kids or {}) ~= #(h.yn.kids or {}) then
                add('table-arity')
            end
        end
    end

    local lang = opts.lang
    local rank = lang and REFUSAL_RANK[lang]
    local order = rank or DEFAULT_RANK
    local pos = {}
    for i, n in ipairs(order) do pos[n] = i end
    -- ranked features first in the measured order, then everything else in the
    -- order it was found — unranked is a real state and is labelled as one
    table.sort(names, function (a, b)
        local pa, pb = pos[a], pos[b]
        if pa and pb then return pa < pb end
        if pa then return true end
        if pb then return false end
        return a < b
    end)
    local rows = {}
    for _, n in ipairs(names) do
        rows[#rows + 1] = { feature = n, ranked = pos[n] ~= nil }
    end

    local flist = shortlist.new{
        subject = 'why the payload does not fit this container\'s members',
        scope = ('%d divergence(s) classified, ranked for %s'):format(
            distance, rank and lang or (lang and (lang .. ' (unmeasured — default order)')
                or 'no language given (default order)')),
        -- ⚠ NEVER EXHAUSTIVE, EVEN FOR A MEASURED LANGUAGE. The ranking rests on
        -- five corpora and four languages; the feature SET is what the census
        -- happens to name, and the census's own largest class is `(no feature)`.
        complete = shortlist.RANKED_OPEN,
        rows = rows,
    }

    -- THE PREMISE THAT WOULD MAKE IT MATCH — computed only where it is a lookup
    -- rather than a synthesis: both sides are keyed tables, so the missing and
    -- surplus keys are a set difference. Anywhere else this field is absent,
    -- because a plausible-sounding premise nobody checked is the fabrication
    -- failure in nicer clothes.
    local premise
    if tmpl.donor.k == 'table' and payload.k == 'table' then
        local dk, dorder = lit_keys(tmpl.donor)
        local pk = lit_keys(payload)
        local missing, surplus = {}, {}
        for _, k in ipairs(dorder) do if not pk[k] then missing[#missing + 1] = k end end
        for k in pairs(pk) do if not dk[k] then surplus[#surplus + 1] = k end end
        table.sort(surplus)
        if #missing > 0 or #surplus > 0 then
            premise = { missing = missing, surplus = surplus }
        end
    end

    return { ok = false, bindings = bindings, distance = distance,
        weak = tmpl.n == 1 and 'template from a single member' or nil,
        refusal = {
            why = #structs > 0 and 'the payload has a different shape'
                or 'the payload differs where every member agrees',
            features = flist, mismatches = mismatches, structs = structs,
            premise = premise,
        } }
end

-- ── render: instantiate a template by SUBSTITUTING INTO THE DONOR'S TEXT ──────
-- CART-0766 step C, and the cheap half of the whole design. The expression IR is
-- documented as LOSSY ABOUT SURFACE, so instantiating a template by EMITTING from
-- it is the transliteration problem — quote style, indentation, trailing comma,
-- alignment, every one of them guessed. Substituting into a real member's own
-- source text guesses none of them: the donor IS the surrounding style rather
-- than an imitation of it, and every hole already carries the exact span to write
-- at. Nothing new is needed but the slicing.
--
-- ⚠ THE SPAN CONVENTION IS DERIVED FROM ITS IMPLEMENTATION, NOT ASSUMED. Measured
-- against a known snippet: lines and columns are 0-BASED and the end is
-- EXCLUSIVE, so a span slices as `line:sub(sc + 1, ec)` — which agrees with
-- `txn.edit_file`'s `l:sub(1, sc) .. to .. l:sub(ec + 1)`. The check took one
-- throwaway render and would have been a silent off-by-one either way.

-- text is 1-based lines (as `store.content` returns) or one string
local function as_lines(src)
    if type(src) == 'table' then return src end
    if type(src) ~= 'string' then return nil end
    local out, i = {}, 1
    while true do
        local j = src:find('\n', i, true)
        if not j then out[#out + 1] = src:sub(i); return out end
        out[#out + 1] = src:sub(i, j - 1); i = j + 1
    end
end

-- the source text a span covers, or nil if the lines do not reach it
local function slice(lines, a)
    if not a then return nil end
    local sl, sc, el, ec = at.sl(a), at.sc(a), at.el(a), at.ec(a)
    if not lines[sl + 1] or not lines[el + 1] then return nil end
    if sl == el then return lines[sl + 1]:sub(sc + 1, ec) end
    local out = {}
    for ln = sl, el do
        local l = lines[ln + 1]
        if ln == sl then out[#out + 1] = l:sub(sc + 1)
        elseif ln == el then out[#out + 1] = l:sub(1, ec)
        else out[#out + 1] = l end
    end
    return table.concat(out, '\n')
end

-- does span `inner` sit inside span `outer`? (used to drop holes a wider slice
-- already carries — a `field` hole's span CONTAINS its base's holes by
-- construction, so nesting here is normal, not a malformed template)
local function spans_contain(outer, inner)
    local osl, osc, oel, oec = at.sl(outer), at.sc(outer), at.el(outer), at.ec(outer)
    local isl, isc, iel, iec = at.sl(inner), at.sc(inner), at.el(inner), at.ec(inner)
    local after_start = isl > osl or (isl == osl and isc >= osc)
    local before_end = iel < oel or (iel == oel and iec <= oec)
    return after_start and before_end and not (isl == osl and isc == osc and iel == oel and iec == oec)
end

--- The substitution map a SUCCESSFUL match implies — TOTAL over the template's
--- varying positions, sliced from real source on both sides.
---
--- ★★ THE REPLACEMENT TEXT MUST BE SLICED, NOT TAKEN FROM THE BINDING. A hole's
--- `a`/`b` are `tostring(e.v)` — the stored VALUE, not the source text.
--- ⚠ AND THE WITNESS IS NUMERIC, WHICH IS NOT WHERE THIS WAS FIRST LOOKED FOR. A
--- string literal's `v` DOES carry its quotes (`'AA'`, `"BB"`, `[[CC]]`), so a
--- string-only fixture PASSES with the binding spliced directly and proves
--- nothing — the break that should have failed did not, which is what sent me to
--- read the builder instead of trusting the claim. A NUMBER is normalised:
--- `0x1F` is stored as `31`, so splicing the value renders `31` where the source
--- wrote `0x1F`. That is a real corruption of intent for flags, masks and
--- colours, and across languages it is worse than cosmetic — go's `0755` is octal
--- 493 and rust's is decimal 755. The payload's own SPAN is the only honest
--- source of the payload's text.
---
--- ★★ AND IT MUST BE TOTAL, WHICH IS THE MISTAKE THIS FUNCTION MADE FIRST. A
--- match's BINDINGS are the positions where THIS payload differs from the donor;
--- a template's VARYING set is every position where ANY member does. Those are
--- not the same set, and a "map of what differs" is not a "map of what to write":
--- where a payload happens to agree with the donor the hole still has to be
--- filled, with the donor's own text. Rendering without that refused 37 of 1184
--- otherwise-valid instantiations, and the refusal read as a bug in the caller.
---@param tmpl table     an `M.element_template` result
---@param m table        an `M.match` result with `ok == true`
---@param payload_src string|table the payload's source (string or lines)
---@param donor_src string|table   the donor's source (string or lines)
---@return table|nil subs, string|nil why
function M.subs_of(tmpl, m, payload_src, donor_src)
    if type(tmpl) ~= 'table' or not tmpl.varying then return nil, 'no template' end
    if type(m) ~= 'table' or not m.ok then return nil, 'the match did not succeed' end
    local plines, dlines = as_lines(payload_src), as_lines(donor_src)
    if not plines then return nil, 'no payload source' end
    if not dlines then return nil, 'no donor source' end
    local bykey = {}
    for _, b in ipairs(m.bindings or {}) do
        -- ⚠ AN OPERATOR BINDING CANNOT BE RENDERED, and says so by name rather
        -- than arriving downstream as a mysteriously unfilled hole. Its span is
        -- the ENCLOSING expression (step B's `at_encloses`), so writing there
        -- would replace the operands along with the operator.
        if b.site == false then
            return nil, 'an operator binding has no substitution site — its span '
                .. 'is the enclosing expression'
        end
        bykey[span_key(b.at)] = b
    end
    local subs = {}
    for key, v in pairs(tmpl.varying) do
        local b = bykey[key]
        local text = b and slice(plines, b.at_payload) or slice(dlines, v.at)
        if text == nil then
            return nil, 'a source does not reach one of its own spans (' .. key .. ')'
        end
        subs[key] = text
    end
    return subs
end

--- Render a NEW member from the template, by substituting into the donor's text.
---@param tmpl table    an `M.element_template` result
---@param subs table    span key (from `tmpl.varying`) -> replacement SOURCE TEXT
---@param donor_src string|table the donor's file source (string or lines)
---@param opts table|nil {
---   verify = function(text) -> expr node|nil   -- reparse the rendered member
---   unverified = true  -- render WITHOUT reparsing; display only, never a write
--- }
---@return string|nil rendered, string|nil why, table|nil detail
function M.render(tmpl, subs, donor_src, opts)
    opts = opts or {}
    if type(tmpl) ~= 'table' or not tmpl.donor or not tmpl.donor.at then
        return nil, 'no template with a located donor'
    end
    if not tmpl.alignable then
        return nil, 'the container\'s members do not share a shape'
    end
    if (tmpl.unkeyed or 0) > 0 then
        return nil, 'the template has holes with no source span'
    end
    -- ⚠⚠ AN UNVERIFIED RENDER IS A GUESS ABOUT SURFACE, so this refuses rather
    -- than relying on a caller to remember. See THE BRACKET BUG below for what
    -- the guess costs; the opt-out exists for display, where nothing is written.
    if not opts.verify and not opts.unverified then
        return nil, 'render needs `opts.verify` (a reparse) or an explicit '
            .. '`opts.unverified` — substituting into text is not a proof that '
            .. 'the result parses to the shape it was built from'
    end
    local lines = as_lines(donor_src)
    if not lines then return nil, 'no donor source' end
    subs = subs or {}

    -- EVERY VARYING HOLE MUST BE SUPPLIED. Carrying the donor's own value through
    -- an unfilled hole is not a safe default: for a KEYED container the varying
    -- position IS the key, so the render would emit a member with the donor's key
    -- and the caller's value — a DUPLICATE KEY, a bug the caller asked for and
    -- never saw. Refusing names the holes instead. (`M.subs_of` is total over
    -- exactly this set, so a match-derived render never trips it.)
    local reps, unfilled = {}, {}
    for key, v in pairs(tmpl.varying) do
        local text = subs[key]
        if text == nil then
            unfilled[#unfilled + 1] = ('%s at %s'):format(v.kind, key)
        elseif v.encloses then
            return nil, 'a hole whose span is its ENCLOSING expression cannot be '
                .. 'written to (operator holes)', { at = v.at, kind = v.kind }
        elseif at.sl(v.at) ~= at.el(v.at) then
            -- ⚠ FIRST-CUT REFUSAL, with its population measured rather than
            -- assumed small: a multi-line hole span. The splice below rebases a
            -- span into the donor's own coordinates and rewrites ONE line, which
            -- is exactly the assumption `txn.edit_file` makes and never states.
            return nil, 'a hole spanning more than one line is not renderable yet',
                { at = v.at, kind = v.kind }
        else
            reps[#reps + 1] = { at = v.at, to = text, kind = v.kind, key = key }
        end
    end
    if #unfilled > 0 then
        table.sort(unfilled)
        return nil, 'unfilled hole(s): ' .. table.concat(unfilled, ', '),
            { unfilled = unfilled }
    end

    -- ★ NESTED HOLES: THE WIDER SPAN SUBSUMES THE NARROWER, and that is a rule
    -- rather than a preference. A `field` hole's span CONTAINS its base's holes
    -- by construction, so nesting here is normal. `varying` deliberately keeps
    -- both — dropping the inner one would make `M.match` call a payload that
    -- differs only at the base a MISMATCH, when the members demonstrably vary
    -- there — so the pruning belongs at render, where "what do I write" is the
    -- question. The subsumed keys are reported, never silently dropped.
    local subsumed = {}
    local outer = {}
    for _, r in ipairs(reps) do
        local covered = false
        for _, o in ipairs(reps) do
            if o ~= r and spans_contain(o.at, r.at) then covered = true end
        end
        if covered then subsumed[#subsumed + 1] = r.key else outer[#outer + 1] = r end
    end
    reps = outer

    -- REBASE INTO THE DONOR'S OWN COORDINATES, then splice. Cutting the donor out
    -- FIRST and rebasing is what keeps this correct: applying the replacements to
    -- the file and cutting afterwards would need the donor's end column, which the
    -- replacements have just moved.
    local dsl, dsc, del = at.sl(tmpl.donor.at), at.sc(tmpl.donor.at), at.el(tmpl.donor.at)
    local dtext = slice(lines, tmpl.donor.at)
    if not dtext then return nil, 'the donor source does not reach the donor span' end
    local dlines = as_lines(dtext)
    for _, r in ipairs(reps) do
        local l = at.sl(r.at) - dsl
        if l < 0 or l > del - dsl then
            return nil, 'a hole lies outside its own donor', { key = r.key }
        end
        local off = (at.sl(r.at) == dsl) and dsc or 0
        r.line, r.sc, r.ec = l, at.sc(r.at) - off, at.ec(r.at) - off
    end
    -- ★ RIGHTMOST-FIRST, AND THE REASON IS WORTH KEEPING: two replacements on one
    -- line applied left to right have the first shift the second's columns and
    -- corrupt it. `txn.edit_file` carries the same rule and the same comment; this
    -- is a deliberate second, small splicer rather than a reuse, because
    -- `edit_file` splits with `vim.split` (this module is plain Lua, and the
    -- headless index flows load it) and assumes single-line reps without saying
    -- so. The oracle below verifies this one far past that.
    table.sort(reps, function (a, b)
        if a.line ~= b.line then return a.line > b.line end
        return a.sc > b.sc
    end)
    for _, r in ipairs(reps) do
        local l = dlines[r.line + 1]
        if not l then return nil, 'a hole lies outside its own donor', { key = r.key } end
        dlines[r.line + 1] = l:sub(1, r.sc) .. r.to .. l:sub(r.ec + 1)
    end
    local out = table.concat(dlines, '\n')
    local detail = { subsumed = subsumed, verified = false }

    -- ★★★ THE BRACKET BUG, AND WHY VERIFICATION IS NOT OPTIONAL POLISH.
    -- Substituting into the donor's text buys the surface OUTSIDE the holes for
    -- free — indentation, quote style, trailing comma — because the donor IS the
    -- surrounding style. It buys NOTHING about surface the IR erased INSIDE a
    -- hole, and there is at least one such erasure in every language here.
    -- MEASURED on our own tree: `{ start = {...}, ['end'] = {...} }` — a
    -- BRACKETED key beside an unbracketed one, because `end` is a lua keyword.
    -- The IR records both as a `lit` str key, so they anti-unify as ONE shape
    -- with ONE hole, `match` says ok, and the render substitutes `start` -> 'end'
    -- to produce
    --       'end' = { line = 9 }
    -- which is not valid Lua at all. The brackets belong to neither span. 63 of
    -- 1184 renders on our own tree (5.3%) were this, and EVERY ONE of them looked
    -- perfectly well-formed as a string.
    --
    -- ★★ THE FIX IS NOT A BRACKET RULE. Special-casing lua keys would leave the
    -- same class open in every other language and in every other erasure. Emit,
    -- REPARSE, and require the result to fit the template it was built from —
    -- which is `M.match` applied to the render's own output, so step C is
    -- verified by step B. Holes come back keyed by the DONOR's spans (the left
    -- side of `anti_unify` is always the donor), so a fresh parse in snippet
    -- coordinates compares correctly. This is the round-trip oracle the
    -- transliteration arc already relies on, and it needs no calibration: the two
    -- sides share the walk and nothing else.
    if opts.verify then
        local ok, ir = pcall(opts.verify, out)
        if not ok or not ir then
            return nil, 'the rendered member did not reparse — the substitution '
                .. 'produced text the grammar does not accept', { rendered = out }
        end
        local back = M.match(tmpl, ir)
        if not back.ok then
            return nil, 'the rendered member reparsed to a DIFFERENT shape than '
                .. 'the template it was built from', { rendered = out, refusal = back.refusal }
        end
        detail.verified = true
    end
    return out, nil, detail
end

--- Census the divergences the current hole taxonomy cannot name.
--- Scans NEAR-clone pairs beyond `below` (default: the shipped max_dist, so the
--- population is exactly what the tool declines to report today) and classifies
--- every divergence that is neither a value hole, nor a homogeneous repetition,
--- nor a bounded nesting.
---@param store table
---@param opts table|nil { max_dist = 32, below = 2, min_rows = nil, witnesses = true }
---@return table { features, kindpairs, witnesses, pairs_scanned, divergences }
-- THE THREE FEATURES THAT ARE REFACTORING RELATIONS, not structural variants
-- (CART-0732's headline). Each names a NAMING BOUNDARY THAT MOVED:
--   leaf-vs-tree   a bare name facing the expression it stands for — EXTRACT LOCAL
--   call-vs-expr   a call facing what it computes    — EXTRACT / INLINE A CALL
--   containment    one side literally inside the other — AN ADDED GUARD
-- ⚠ EACH IS A PROXY AT CENSUS GRADE AND MUST NOT BE READ AS A CONFIRMED
-- REFACTORING. rcanon ALPHA-RENAMES a local to 'L'; it does not substitute the
-- name's binding, so `leaf-vs-tree` says "a leaf faces a tree", not "this leaf
-- IS that tree". Confirming it needs the local's assignment row, which the
-- rollup below does not look up. Kept honest by name: these are CANDIDATES.
-- ★★ `arity(appended)` JOINS THEM AND BARE `arity` DOES NOT, WHICH IS THE
-- OPPOSITE OF HOW THIS WAS FIRST BUILT (CART-0742 item 4). Add-parameter is a
-- refactoring; "the same function called with a different number of arguments"
-- is not, and the witnesses settle it. The strong form:
--     assertScoresEquals(a, b)  ⇄  assertScoresEquals(a, b, delta)     x95
-- The weak form, on the same corpus:
--     arena.allocate(n * Integer.BYTES)  ⇄  arena.allocate(ADDRESS.byteSize() * k, …)
-- — same callee, one more argument, and NOTHING in common. That is an overload
-- or a varargs call, not a refactoring half-applied, and putting it here would
-- inflate `explained` with pairs no refactoring relates. THAT IS EXACTLY THE
-- `call-vs-expr` ERROR ONE ITEM EARLIER: a feature whose population was half
-- something else, promoted on its name rather than on its witnesses.
-- MEASURED: the strong form is 36% of the class on java, 4% on C++, 0% on php.
-- The `side` rule below needs no case for either — its generic branch picks the
-- SHORTER canon, which for an arity divergence is the side with fewer arguments.
local DC_RELATION = { ['leaf-vs-tree'] = true, ['call-vs-expr'] = true,
                      ['containment'] = true, ['arity(appended)'] = true }

function M.divergence_census(store, opts)
    local max_dist = (opts and opts.max_dist) or 32
    local below = (opts and opts.below) or 2
    -- forwarded so a caller can widen the population; M.near's default (6) is
    -- tuned for reporting, and a census may legitimately want a smaller floor
    local min_rows = opts and opts.min_rows
    local want_wit = not (opts and opts.witnesses == false)
    -- PER-PAIR ROLLUP (opt-in). The feature counts answer "which divergence
    -- classes exist"; they cannot answer "which PAIRS are fully explained by a
    -- refactoring relation", which is the actionable question and a different
    -- accumulator over the same walk. Off by default so the census's own
    -- numbers are untouched.
    local want_pairs = opts and opts.by_pair
    -- SIGNATURE COUNTS (rides the pair rollup). ★ THE PAIR IS THE WRONG UNIT
    -- FOR "ONE THING DONE TWO WAYS": the same disagreement recurs across many
    -- pairs — `Float.BYTES` facing a bare literal, `x.size()` facing a constant
    -- — and counted per pair it reads as a handful of unrelated rows. Counted
    -- per SIGNATURE it is one finding with N sites, which is the form a reader
    -- diving into an unfamiliar codebase can act on.
    local sigs = {}
    local features, kindpairs, witnesses, bypair = {}, {}, {}, {}
    local cur -- the pair being walked, when want_pairs
    local ndiv, npairs = 0, 0
    local function bump(t, k) t[k] = (t[k] or 0) + 1 end

    local function record(x, y, la, lb)
        ndiv = ndiv + 1
        local kx = x and x.k or 'NIL'
        local ky = y and y.k or 'NIL'
        local a, b = kx, ky
        if a > b then a, b = b, a end
        bump(kindpairs, a .. ' | ' .. b)
        -- the feature vocabulary now lives in `dc_features` — CART-0766 step B
        -- needed the same classification for a refusal, and one definition read
        -- twice beats two definitions drifting apart
        local f = dc_features(x, y, la, lb)
        for _, n in ipairs(f) do bump(features, n) end
        if cur then
            cur.div = cur.div + 1
            -- ★ EVERY DIVERGENCE GETS A SIGNATURE, not just the tagged ones.
            -- The first cut of this recorded only relation-tagged rows — 3623
            -- of 16198 on libs — which silently excluded `(no feature)`, the
            -- LARGEST class (52.8%) and the one nothing has ever looked at. A
            -- census that samples only what the taxonomy can already name
            -- cannot tell you what the taxonomy is missing.
            if x and y then
                local ca = rcanon(x, la or {}, {})
                local cb = rcanon(y, lb or {}, {})
                local s1, s2 = ca, cb
                if s1 > s2 then s1, s2 = s2, s1 end
                local key = s1 .. '  ⇄  ' .. s2
                local e = sigs[key]
                if not e then
                    e = { n = 0, where = {}, owners = {}, nowners = 0, tag = table.concat(f, '+') }
                    sigs[key] = e
                end
                e.n = e.n + 1
                -- ★ DISTINCT OWNERS, not sites. A disagreement spanning eight
                -- classes says something a codebase-wide; eight sites inside one
                -- function is a local habit. Ranking by count conflates them.
                for _, nm in ipairs({ cur.an, cur.bn }) do
                    local ow = tostring(nm):match('^(.*)::[^:]+$') or tostring(nm)
                    if not e.owners[ow] then e.owners[ow] = true; e.nowners = e.nowners + 1 end
                end
                if #e.where < 4 then
                    e.where[#e.where + 1] = (cur.an or '?') .. ' / ' .. (cur.bn or '?')
                end
            end
            local rel = false
            for _, n in ipairs(f) do
                if DC_RELATION[n] then
                    rel = true
                    bump(cur.tags, n)
                    -- WHICH SIDE HOLDS THE SHORTER FORM: for a leaf-vs-tree it
                    -- is the side that is a leaf, for call-vs-expr the side
                    -- that IS the call, for containment the side CONTAINED.
                    -- A pair pulling both ways is a murkier story than one
                    -- refactoring half-applied, and says so.
                    local side
                    if n == 'leaf-vs-tree' then
                        side = #dc_kids(x) == 0 and 'a' or 'b'
                    elseif n == 'call-vs-expr' then
                        side = kx == 'call' and 'a' or 'b'
                    else
                        local cx2 = rcanon(x, la or {}, {})
                        local cy2 = rcanon(y, lb or {}, {})
                        side = #cx2 <= #cy2 and 'a' or 'b'
                    end
                    if cur.dir == nil then cur.dir = side
                    elseif cur.dir ~= side then cur.dir = 'both' end
                end
            end
            if rel then
                cur.explained = cur.explained + 1
                -- ONE WITNESS PER PAIR, the canon of both sides. A pair-level
                -- verdict nobody can hand-read is the census's own mistake one
                -- level up: the tags are proxies and only the text says whether
                -- the proxy is right here.
                if not cur.wit then
                    cur.wit = { a = rcanon(x, la or {}, {}), b = rcanon(y, lb or {}, {}) }
                end
            end
        end
        if want_wit then
            local tag = table.concat(f, '+')
            if not witnesses[tag] and x and y then
                witnesses[tag] = { a = rcanon(x, la or {}, {}), b = rcanon(y, lb or {}, {}) }
            end
        end
    end

    local function walk(x, y, la, lb)
        if x == nil and y == nil then return end
        if x == nil or y == nil then record(x, y, la, lb); return end
        local lx, ly = dc_list(x), dc_list(y)
        if x.k == y.k and lx and ly and #lx ~= #ly then
            -- a list-length divergence IS a repetition hole when the elements are
            -- one template; only the heterogeneous case is unnamed
            if not dc_homogeneous(#lx > #ly and lx or ly, la, lb) then record(x, y, la, lb) end
            local n = math.min(#lx, #ly)
            for i = 1, n do walk(lx[i], ly[i], la, lb) end
            return
        end
        if x.k ~= y.k then
            if not (dc_wraps(x, y, la, lb) or dc_wraps(y, x, lb, la)) then record(x, y, la, lb) end
            return
        end
        local kx, ky = dc_kids(x), dc_kids(y)
        if #kx ~= #ky then record(x, y, la, lb); return end
        for i = 1, #kx do walk(kx[i], ky[i], la, lb) end
    end

    for _, p in ipairs(M.near(store, { max_dist = max_dist, min_rows = min_rows })) do
        if p.dist > below then
            npairs = npairs + 1
            if want_pairs then
                cur = { a = p.a.id, b = p.b.id, an = p.a.name, bn = p.b.name,
                    dist = p.dist, div = 0, explained = 0, tags = {} }
            end
            for _, o in ipairs(p.ops) do
                if o.op == 'sub' then
                    local r1, r2 = p.a.exprs[o.i], p.b.exprs[o.j]
                    if r1 and r2 then
                        for _, side in ipairs({ 'lhs', 'rhs' }) do
                            local l1, l2 = r1[side] or {}, r2[side] or {}
                            local n = math.min(#l1, #l2)
                            -- a ROW's lhs/rhs length mismatch is repetition at
                            -- STATEMENT level (anti_unify_row records it as a bare
                            -- struct hole, which is why it was invisible)
                            if #l1 ~= #l2
                                and not dc_homogeneous(#l1 > #l2 and l1 or l2, p.a.locals, p.b.locals) then
                                record(l1[n + 1] or l2[n + 1], nil, p.a.locals, p.b.locals)
                            end
                            for i = 1, n do walk(l1[i], l2[i], p.a.locals, p.b.locals) end
                        end
                        if r1.cond or r2.cond then walk(r1.cond, r2.cond, p.a.locals, p.b.locals) end
                    end
                end
            end
            if cur then
                -- A ZERO-DIVERGENCE PAIR IS NOT A FINDING, it is an exact
                -- template clone the clone lint already owns; including it here
                -- would double-report. Only pairs that DIVERGED and whose every
                -- divergence carries a relation tag are candidates.
                if cur.div > 0 then bypair[#bypair + 1] = cur end
                cur = nil
            end
        end
    end
    table.sort(bypair, function (m, n)
        if m.explained ~= n.explained then return m.explained > n.explained end
        return (m.a or '') < (n.a or '')
    end)
    return { features = features, kindpairs = kindpairs, witnesses = witnesses,
        pairs_scanned = npairs, divergences = ndiv,
        by_pair = want_pairs and bypair or nil,
        sigs = want_pairs and sigs or nil }
end

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

--- ★★★ NEAR-CLONE FAMILIES: partition each connected component of the near-graph
--- into families by DESCRIPTION LENGTH, through the proven algebra (CART-0888).
---
--- WHY THIS EXISTS. `near` returns PAIRS and `extract_proposal` derives ONE
--- helper per pair, so a component of N near-clones yields up to C(N,2) helper
--- proposals for what is often ONE family -- and they disagree with each other,
--- measured at 84% of wow's examined components. A family is the unit a human
--- would actually extract; a pair is an artifact of how the index finds them.
---
--- ★★ A COMPONENT IS NOT AUTOMATICALLY A FAMILY, AND THE CHEAP TEST FOR THAT IS
--- WRONG. The obvious proxy -- "is the component a clique in the near-graph" --
--- calls 87% of wow's components CHAINS and would split them. MEASURED, that
--- proxy OVER-SPLITS: on factorio all 8 components partition into ONE family
--- with 57-94 shared fixed nodes and 1-3 holes, chains included. The chain-ness
--- is an artifact of `near`'s OWN admission filter (two members 3 row-edits
--- apart are refused at max_dist=2) and says nothing about whether they are one
--- family. So the split is decided by MDL, never by graph shape.
---
--- ★★ AND MDL NEEDS AN ADMISSIBILITY FLOOR, which the algebra supplies as
--- `min_fixed`: without it, unrelated instances are "one family" under a bare
--- hole because that pays one family cost instead of N. ⚠ THE RETRACTION LAW
--- CANNOT SUBSTITUTE -- a bare-hole template retracts to every instance
--- trivially, which is how a guard meant to catch exactly this sat DEAD and
--- never fired (CART-0888).
---
--- ★★★ THE PROXY IS MEASURED, NOT ARGUED (wow, 152 components):
---       cliques 20, chains 132
---       CHAIN and ONE family      93   <- the proxy would split all of these
---       CHAIN and split           39   <- it agrees, but cannot say INTO WHAT
---       clique and ONE family     19
---       clique and split           1
---   ⇒ the clique proxy agrees with MDL on 58 of 152 = 38.2%. It is not a cheap
---   approximation of this answer; it is a different answer. And MDL is not a
---   no-op either: it SPLITS 40 of 152 (26%), so the component is neither
---   automatically one family nor reliably several.
---
--- COST, measured, and it is the reason this can be a verb at all: `generalize`
--- is ~0.001 s typical / 0.112 s worst (a simultaneous descent), and greedy
--- `partition` 0.032 s at n=8, agreeing with the brute-force optimum on 8 of 8.
--- ⚠ NOT to be confused with `vertical`'s 0.2-12 s alignment DP; they are
--- different complexity classes, and citing one for the other is what made this
--- look unaffordable before it was timed.
---
--- ⚠ BUT THE GREEDY IS O(n^3) IN THE COMPONENT, AND THAT IS THE REAL BOUND:
--- on wow the worst single component cost 15.8 s and all 152 cost 111 s total.
--- THIS IS A BATCH VERB, NOT AN INTERACTIVE ONE. `max_family` (default 40) is
--- what keeps it bounded, and components skipped by it are COUNTED in the
--- result rather than silently dropped -- wow's largest is 28, so the default
--- skips nothing there and the figure above is the whole population.
---
--- @return table|nil result, string|nil why
--- result = { families = { { members, template, values, dl, fixed, holes,
---            origin, via } }, components, examined, skipped, population }
function M.families(store, opts)
    opts = opts or {}
    local alg = require 'cartograph.algebra'
    local A, why = alg.load()
    -- ⚠ REFUSE BY NAME, NEVER FALL BACK TO THE CLIQUE PROXY. It over-splits, so
    -- a silent degrade would hand back MORE families that look like a finer
    -- answer. Absence renders as a plausible positive unless it is said aloud.
    if not A then return nil, 'algebra unavailable: ' .. tostring(why) end

    local maxn = opts.max_family or 40
    local pairs_ = M.near(store, opts)

    local up, rec = {}, {}
    local function find(x) while up[x] and up[x] ~= x do x = up[x] end return x end
    for _, p in ipairs(pairs_) do
        rec[p.a.id], rec[p.b.id] = p.a, p.b
        up[p.a.id] = up[p.a.id] or p.a.id
        up[p.b.id] = up[p.b.id] or p.b.id
        local ra, rb = find(p.a.id), find(p.b.id)
        if ra ~= rb then up[ra] = rb end
    end
    local comp = {}
    for id in pairs(up) do
        local r = find(id)
        comp[r] = comp[r] or {}
        comp[r][#comp[r] + 1] = id
    end

    local out, ncomp, examined, skipped = {}, 0, 0, 0
    local roots = {}
    for r in pairs(comp) do roots[#roots + 1] = r end
    table.sort(roots)                       -- ★ determinism: `pairs` order is not stable
    for _, r in ipairs(roots) do
        local ids = comp[r]
        ncomp = ncomp + 1
        if #ids < 2 then                    -- nothing to partition
        elseif #ids > maxn then
            skipped = skipped + 1           -- counted, never silently dropped
        else
            table.sort(ids)
            local terms = {}
            for i, id in ipairs(ids) do terms[i] = alg.fn_term(rec[id]) end
            local okp, part = pcall(A.partition, terms, opts.partition)
            if okp and part then
                examined = examined + 1
                for _, f in ipairs(part.families) do
                    local members = {}
                    for _, k in ipairs(f.members) do members[#members + 1] = rec[ids[k]] end
                    local nh = 0
                    for _ in pairs(f.template.holes or {}) do nh = nh + 1 end
                    out[#out + 1] = {
                        members = members, template = f.template, values = f.values,
                        dl = f.dl, holes = nh,
                        fixed = alg.fixed_nodes(f.template.body),
                        collapsed = alg.is_collapsed(f.template),
                        -- ⚠ THESE ARE NOT GRAPH RECORDS, so `validate.check` never
                        -- sees them and these two fields are DESCRIPTIVE here, not
                        -- enforced. They use the registered vocabulary on purpose:
                        -- if a family ever becomes a node, the contract already
                        -- matches instead of being retrofitted.
                        origin = 'derived', via = 'algebra.partition',
                    }
                end
            end
        end
    end
    return {
        families = out, components = ncomp, examined = examined, skipped = skipped,
        -- ★ THE POPULATION RIDES WITH THE ANSWER. Every count here inherits
        -- `near`'s admission filter AND the MDL constants; a family count without
        -- them is not a property of the corpus.
        population = {
            max_dist = opts.max_dist or 2, min_rows = opts.min_rows or 6,
            min_shared = opts.min_shared or 2, max_family = maxn,
            min_fixed = (opts.partition and opts.partition.min_fixed) or 1,
            family_cost = (opts.partition and opts.partition.family_cost) or 1,
        },
    }
end

--- ★ THE FOCUSED QUERY: the family containing ONE function, without partitioning
--- the whole store. `families` is a BATCH verb (9 s on factorio, minutes on wow
--- -- it partitions every component); an interactive command cannot pay that to
--- answer a question about one function. `near_of` enumerates just one
--- function's candidate partners over the generation-cached index, so growing
--- the focus's component by BFS over it costs a handful of those instead.
---
--- ⚠ THE BFS IS BOUNDED AND SAYS SO. `max_family` stops the growth; a component
--- larger than that returns `nil` with a reason rather than a family built from
--- an arbitrary prefix of it -- a truncated component would partition into
--- confident, wrong families.
---
--- @return table|nil family, string|nil why
function M.family_of(store, fn_id, opts)
    opts = opts or {}
    local alg = require 'cartograph.algebra'
    local A, why = alg.load()
    if not A then return nil, 'algebra unavailable: ' .. tostring(why) end

    local maxn = opts.max_family or 40
    local seen, order, queue = { [fn_id] = true }, {}, { fn_id }
    local rec = {}
    while #queue > 0 do
        local id = table.remove(queue, 1)
        order[#order + 1] = id
        for _, p in ipairs(M.near_of(store, id, opts)) do
            for _, side in ipairs({ p.a, p.b }) do
                rec[side.id] = rec[side.id] or side
                if not seen[side.id] then
                    seen[side.id] = true
                    queue[#queue + 1] = side.id
                    if #order + #queue > maxn then
                        return nil, ('component larger than max_family=%d'):format(maxn)
                    end
                end
            end
        end
    end
    if #order < 2 then return nil, 'no near-clone within the admission filter' end

    table.sort(order)                    -- ★ determinism, as in `families`
    local terms = {}
    for i, id in ipairs(order) do terms[i] = alg.fn_term(rec[id]) end
    local okp, part = pcall(A.partition, terms, opts.partition)
    if not okp or not part then return nil, 'partition failed: ' .. tostring(part) end

    for _, f in ipairs(part.families) do
        for _, k in ipairs(f.members) do
            if order[k] == fn_id then
                local members, values = {}, {}
                for j, mk in ipairs(f.members) do
                    members[j] = rec[order[mk]]; values[j] = f.values[mk]
                end
                local nh = 0
                for _ in pairs(f.template.holes or {}) do nh = nh + 1 end
                return { members = members, template = f.template, values = values,
                    dl = f.dl, holes = nh,
                    fixed = alg.fixed_nodes(f.template.body),
                    collapsed = alg.is_collapsed(f.template),
                    origin = 'derived', via = 'algebra.partition' }
            end
        end
    end
    return nil, 'the focused function landed in no family'
end

--- EVERY occurrence of every hole, as the DONOR's own subterm at that position.
---
--- ★★★ A HOLE IS NOT A POSITION, AND READING `values[i][h]` AS ONE SHIPS A
--- SILENTLY WRONG HELPER. `values` holds ONE value per hole per member -- the
--- thing the members disagree on -- but the template body may mention that hole
--- SEVERAL TIMES. MEASURED on our own lua tree before this existed: 8 of 25
--- holes (32%) occur more than once, up to 4 times, across 5 of 14 families
--- (36%). The witness was `ansible.lua`'s `map_of`/`seq_of`: two functions
--- differing in FOUR positions, a template with TWO holes, and a render that
--- parameterized the first `if` and left `'block_mapping'` HARD-CODED inside the
--- loop -- a helper that returns the wrong node for half its callers and looks
--- perfectly reasonable.
---
--- So the spans come from walking the template ALONGSIDE the donor's own term,
--- which is what `values_at` does in the prototype: wherever the template has a
--- hole, the donor's subterm at that position is what occupies it, and it
--- carries the span. Arity or kind disagreeing means the donor is not an
--- instance of this template, which is a refusal and never a partial answer.
---
--- ★ AND THAT IS WHERE THE HEDGE FAMILIES GO. MEASURED on our own tree after the
--- co-walk landed: 9 families render and 5 refuse -- 3 on arity, 1 on shape, 1
--- on a repetition hole. A REPETITION hole stands for a VARIABLE number of kids,
--- so a template carrying one does not align positionally with any single
--- instance, and its SIBLINGS then read as an arity disagreement. This is the
--- same boundary the prototype states for `transplant` ("transplant over a hedge
--- family waits on classify over repetition holes"), reached from the other
--- side: positional substitution and hedge structure are what does not compose.
--- It is a refusal here rather than a mis-cut.
---@return table|nil sites  { [hole] = { term, ... } }
---@return string|nil why
local function hole_sites(tmpl, inst)
    local sites = {}
    local function walk(t, i)
        if t == nil or i == nil then return 'the donor does not reach the template' end
        if t.k == 'hole' then
            -- a repetition/context hole does not stand for ONE subterm, so there
            -- is no single span to write to -- `render` refuses these one
            -- altitude down for the same reason.
            if t.rep or t.ctx then return 'a repetition or context hole has no single site' end
            sites[t.h] = sites[t.h] or {}
            sites[t.h][#sites[t.h] + 1] = inst and i or i
            return nil
        end
        if t.k ~= i.k then return 'the donor diverges from the template shape' end
        local tk, ik = t.kids or {}, i.kids or {}
        if #tk ~= #ik then return 'the donor and the template disagree on arity' end
        for n = 1, #tk do
            local why = walk(tk[n], ik[n])
            if why then return why end
        end
        return nil
    end
    local why = walk(tmpl, inst)
    if why then return nil, why end
    return sites
end

--- a family's hole names in the order its PARAMETERS are numbered. Shared with
--- `family_proposal` so `p3` means the same hole in the listing and the text --
--- `pairs` over the hole map really did come out `h5 h4 h2 h1 h3`.
local function sorted_holes(tmpl)
    local hk = {}
    for h in pairs((tmpl and tmpl.holes) or {}) do hk[#hk + 1] = h end
    table.sort(hk, function (x, y)
        local nx, ny = tonumber(x:match('%d+')), tonumber(y:match('%d+'))
        if nx and ny and nx ~= ny then return nx < ny end
        return x < y
    end)
    return hk
end

--- ★★★ ONE HELPER PROPOSAL PER FAMILY, not one per pair (CART-0888, the
--- `generalize` half). `extract_proposal` takes a PAIR and derives a signature
--- from it; over a component of N that yields up to C(N,2) proposals which
--- DISAGREE WITH EACH OTHER (84% of wow's components). A family already carries
--- ONE template and one valuation per member -- `partition` computed both -- so
--- this reads that result rather than generalizing again.
---
--- ★★ THE PER-MEMBER SPANS ARE WHAT MAKE IT ACTIONABLE, and they exist only
--- because a span rides through every arrow untouched (`rebuild` carries
--- non-child fields, `eq` ignores them -- see cartograph.algebra). The TEMPLATE
--- body has no `at` (a generalized root is in no single file); each
--- `values[i][hole]` has the span IN MEMBER i. That is N call sites for one
--- helper, and it is the whole reason the adapter carries `at` at all.
---
--- ⚠⚠ THE ALPHA-COLLAPSE BOUNDARY, AND IT MUST BE SAID OUT LOUD. The adapter
--- maps EVERY local to one symbol (mirroring `anti_unify`'s alpha rule), so a
--- hole whose value is that sentinel says "a local" and NOTHING about WHICH.
--- Reading the source at the hole's span recovers the NAME AT THAT USE -- which
--- is honest and useful -- but two members both showing a local at the same hole
--- MAY BE READING UNRELATED VARIABLES. Binding identity was erased on the way
--- in and no amount of span-reading restores it. So this reports the names it
--- found and claims no relation between them; a caller that wants "the same
--- variable in both" needs a binder pass this path does not have.
---
--- ⚠ `row~` IS THE OTHER SENTINEL: `fn_term` substitutes it for a row the
--- adapter could not build, and `fixed_nodes` counts it like any other node --
--- so a family's `fixed` is inflated by exactly the number of them. Reported,
--- never quietly folded in. (Measured 0 of 30 on factorio; not zero by
--- construction.)
---
--- @return table lines   same string-list contract as `extract_proposal`
function M.family_proposal(fam, store)
    local alg = require 'cartograph.algebra'
    local n = #fam.members

    -- ★ `pairs` over the hole map is UNORDERED -- it really came out `h5 h4 h2
    -- h1 h3` -- and a proposal whose parameters are numbered differently on
    -- every run cannot be diffed or reviewed. Sorted by the NUMERIC suffix, so
    -- h10 follows h9 rather than h1.
    local hk = sorted_holes(fam.template)

    local rt = 0
    local function count_rt(t)
        if t == nil then return end
        if t.k == 'row~' then rt = rt + 1 end
        for _, k in ipairs(t.kids or {}) do count_rt(k) end
    end
    count_rt(fam.template.body)

    local srccache = {}
    --- the SOURCE TEXT at a hole's span in one member — this is what turns the
    --- alpha-collapse sentinel back into a readable name
    local function text_at(m, rng)
        if not rng then return nil end
        local lines = srccache[m.id]
        if lines == nil then
            local nd = store and store.node and store.node(m.id)
            lines = (nd and store.content and store.content(nd)) or false
            srccache[m.id] = lines
        end
        if not lines then return nil end
        local sl, el = at.sl(rng), at.el(rng)
        if sl ~= el then return nil end            -- multi-line: not a token
        local line = lines[sl + 1]
        if not line then return nil end
        return line:sub(at.sc(rng) + 1, at.ec(rng))
    end

    --- a hole's value as the reader should see it: the recovered name where the
    --- term only says "a local", the term's own symbol otherwise
    local function shown(v, m)
        if v == nil then return '(absent)' end
        local txt = text_at(m, v.at)
        local sym = v.n or v.v or v.k
        if type(sym) == 'string' and sym:find('\1local') then
            return txt and (txt .. '  [a local]') or 'a local'
        end
        return txt or tostring(sym)
    end

    -- ⚠ A SINGLETON IS NOT "IDENTICAL COPIES", AND THE FIRST CUT SAID IT WAS.
    -- `partition`'s `family_of` gives a ONE-MEMBER family a template with NO
    -- HOLES by construction (`M.template(M.copy(instance))`), which lands in the
    -- same `#hk == 0` branch as a genuine hole-free family. Reporting "1 copies
    -- are IDENTICAL after alpha-renaming" would be nonsense, and it is exactly
    -- the kind of sentence a reader believes. A singleton means MDL refused to
    -- merge this member with anything -- a finding about the component, not an
    -- extraction.
    if n == 1 then
        local m = fam.members[1]
        return { ('%s (%s:%d) joined NO family — the partition found no'
            .. ' description-length gain in merging it with its near-clones.')
            :format(m.name, m.file, (m.lines or {})[1] or 0) }
    end

    if #hk == 0 then
        -- ★ ZERO HOLES ACROSS TWO OR MORE MEMBERS: nothing varies, so there is no
        -- parameter to lift and the verb is MERGE, not extract-helper.
        --
        -- ⚠⚠ "IDENTICAL" HERE MEANS IDENTICAL AS THE ADAPTER SEES THEM, WHICH IS
        -- WEAKER THAN IDENTICAL. `near` admitted these members at row-distance
        -- 1-2, so their canonical ROW KEYS differ while their TERMS do not --
        -- the term is lossy relative to `rcanon` somewhere. The known mechanism
        -- is `expr.children` SKIPPING NIL CHILDREN instead of holding them as
        -- slots (CART-0882): kids (x, nil, z) and (x, z, nil) flatten to the
        -- same (x, z). That is right for a walk and wrong for a position lens.
        -- ⇒ SO THIS POINTS AT MERGE, IT DOES NOT CERTIFY IT. :CartographMerge
        -- does its own equivalence check; this must not be read as having done
        -- one. Measured 46 of 298 families on wow, 0 on factorio.
        local L = { ('%d copies have NO varying part under this analysis — nothing'
            .. ' to parameterize. :CartographMerge is the verb, and it re-checks'
            .. ' equivalence itself; the term model here is coarser than the row'
            .. ' keys that admitted them.'):format(n) }
        for _, m in ipairs(fam.members) do
            L[#L + 1] = ('    %s  %s:%d'):format(m.name, m.file, (m.lines or {})[1] or 0)
        end
        return L
    end

    local L = {
        ('helper extraction proposal — ONE helper for %d copies'):format(n),
        ('  %d shared fixed node(s), %d parameter(s), description length %s')
            :format(alg.fixed_nodes(fam.template.body) - rt, #hk, tostring(fam.dl)),
        '  the copies:',
    }
    for _, m in ipairs(fam.members) do
        L[#L + 1] = ('    %s  %s:%d'):format(m.name, m.file, (m.lines or {})[1] or 0)
    end
    L[#L + 1] = '  parameters (one per hole; each line is one call site):'
    for i, h in ipairs(hk) do
        L[#L + 1] = ('    p%d:'):format(i)
        for k, m in ipairs(fam.members) do
            local v = fam.values[k] and fam.values[k][h]
            local where = ''
            if v and v.at then
                where = ('   at %s:%d:%d'):format(m.file, at.sl(v.at) + 1, at.sc(v.at) + 1)
            end
            L[#L + 1] = ('      %s  =  %s%s'):format(m.name, shown(v, m), where)
        end
    end
    if rt > 0 then
        L[#L + 1] = ('  ⚠ %d statement(s) the extractor cannot rebuild (row~) sit in the'
            .. ' shared body — the helper is NOT complete as shown'):format(rt)
    end
    -- ★ THE HELPER AS TEXT. Everything above says WHAT varies; this says what you
    -- would actually write. It is the DONOR'S OWN SOURCE with each hole replaced
    -- by its parameter -- never a term printed back out, which the term model
    -- cannot do (see the term -> text header).
    -- ⚠ `as_lines`, not `vim.split`: this module is plain Lua and the headless
    -- index flows load it, the same reason `render` carries its own splicer.
    local body, rwhy = M.family_helper_text(fam, store)
    if body then
        L[#L + 1] = ('  the helper body, from the donor %s (%s):')
            :format(fam.members[1].name, fam.members[1].file)
        for _, line in ipairs(as_lines(body) or {}) do L[#L + 1] = '    ' .. line end
        -- ★ THE VERDICT RIDES WITH THE TEXT (CART-0893). Three answers, and the
        -- middle one is the reason this is not a boolean: a donor whose span is
        -- an anonymous function is an EXPRESSION, so its own text does not parse
        -- standalone and the oracle cannot speak either way. Printing that as a
        -- failure would be a false alarm; printing nothing would let an
        -- unverified render read exactly like a verified one.
        local vok, vwhy, vd = M.family_verify(fam, store)
        if vok then
            L[#L + 1] = '  ✓ VERIFIED: the text above reparses to exactly this template with'
            L[#L + 1] = '    each parameter at its own hole — emitted, read back, compared.'
        elseif vd and vd.verifiable == false then
            L[#L + 1] = '  ⚠ NOT VERIFIABLE: ' .. tostring(vwhy):gsub('^not verifiable: ', '')
        else
            L[#L + 1] = '  ⚠ NOT VERIFIED: ' .. tostring(vwhy)
        end
        L[#L + 1] = '  ⚠ The signature shown is the DONOR\'s, which the extraction would'
        L[#L + 1] = '    have to rename; nothing here rewrites a call site.'
    else
        -- a named refusal, because a proposal that silently omits the body reads
        -- as one where the body was not worth showing
        L[#L + 1] = ('  no helper body rendered: %s'):format(tostring(rwhy))
    end

    -- the boundary, carried with the answer rather than left to the reader
    L[#L + 1] = '  note: a parameter shown as [a local] is SOME local at that site;'
    L[#L + 1] = '        the analysis does not claim the copies read the SAME variable.'
    return L
end

-- ── TERM → TEXT AT FUNCTION ALTITUDE ────────────────────────────────────────
--
-- ★★★ A TERM IS A SELECTOR, NOT A SOURCE, so nothing here EMITS from a term.
-- The term model is lossy by construction and it was measured from both ends on
-- 2026-09-13: `algebra.term` collapses every local to one sentinel, so a term
-- cannot say WHICH variable to write (CART-0890); `row_term`, exactly like
-- `row_key`, carries no statement kind, so a term cannot say whether to write
-- `if` or `while` (CART-0892). Printing a term would have to invent both.
--
-- ⇒ THE TEXT COMES FROM THE DONOR; THE TERM ONLY SAYS WHERE TO CUT. That is
-- `M.render`'s contract one altitude down: it renders a CONTAINER member by
-- substituting at the members' varying spans, and this renders a FUNCTION by
-- substituting at a family's hole spans. The splicer, the rightmost-first rule,
-- the subsumption rule and every refusal are REUSED WHOLE — what follows is a
-- SHAPE ADAPTER, not a second renderer. `element_template` produces
-- `{donor, varying, unkeyed, alignable}` and so does this.
--
-- ★★ THE SPAN IS THERE BECAUSE `A.rebuild` CARRIES EVERY NON-CHILD FIELD and
-- `A.eq` compares only `k`/`v`/`n`/`kids`. So `at` rides through anti-unification
-- untouched: `template.body` has no spans (it is the SHARED shape, belonging to
-- no one member) but `values[i][hole]` carries member i's own span. The donor is
-- therefore a MEMBER, never the template.
--
-- ★ SYNTHETIC `seq` NODES HAVE NO SPAN, AND THE HULL RECOVERS MOST OF THEM.
-- MEASURED (our own lua tree: 14 families with holes, 25 holes) — 16 values
-- carried `at`, 9 did not, and 7 of those 9 were `seq`, the wrapper `term` and
-- `row_term` build for an lhs/rhs list. A seq is not a source node, but its
-- extent IS its kids' extent. The hull is taken ONLY when every kid yields a
-- span: a partial hull would cut a region narrower than the construct and leave
-- fragments of it behind, which reads as a successful render.
-- ⚠ The hull is a RAW range table on purpose — `at.lua` interns ranges at
-- ingest and states that post-fold arrivals stay raw and read through the same
-- accessors. There is no range constructor to call.
--
-- ⚠⚠ IT REFUSES RATHER THAN TRUSTING THE CALLER. `M.render` verifies by
-- reparsing and calling `M.match(tmpl, ir)`, which takes the `element_template`
-- shape and not this one. THE FUNCTION-ALTITUDE ORACLE IS NOW `M.family_verify`
-- (CART-0893): reparse through `expr.of_text` -> `algebra.fn_term`, then compare
-- STRUCTURALLY against the template with each hole plugged by its own parameter.
-- It caught a real one on factorio-mods the first time it ran: a hole spanning a
-- whole call statement renders as `if not f then p1 end`, which reads fine and
-- is not valid Lua -- THE BRACKET BUG's class, one altitude up. So this path
-- still passes `unverified` to `render` (that verifier cannot take this shape)
-- and the verification happens in `family_verify` instead; a caller on a WRITE
-- path must go through it, never through the raw text.

--- The source extent of a term: its own span, or the HULL of its kids'.
--- Returns nil when ANY kid is spanless — a partial hull would name a region
--- narrower than the construct, and cutting there leaves fragments behind while
--- reporting success.
--- A `row~` (the sentinel for a row the adapter could not build) has neither a
--- span nor kids, so it yields nil -- which is the right answer, and the reason
--- callers that RENDER refuse it earlier rather than discovering it here.
---@param t table|nil a prototype term
---@return table|nil range  a RAW range (post-fold arrivals stay raw, see at.lua)
function M.term_extent(t)
    if t == nil then return nil end
    if t.at then return t.at end
    local kids = t.kids or {}
    if #kids == 0 then return nil end
    local sl, sc, el, ec
    for _, c in ipairs(kids) do
        local a = M.term_extent(c)
        if not a then return nil end
        local csl, csc, cel, cec = at.sl(a), at.sc(a), at.el(a), at.ec(a)
        if sl == nil or csl < sl or (csl == sl and csc < sc) then sl, sc = csl, csc end
        if el == nil or cel > el or (cel == el and cec > ec) then el, ec = cel, cec end
    end
    if sl == nil or el == nil then return nil end
    return { start = { line = sl, char = sc }, ['end'] = { line = el, char = ec } }
end

--- Adapt one `M.families` family into the shape `M.render` accepts, with one
--- member chosen as the DONOR whose text will be spliced.
---@param fam table   a family from `M.families` / `M.family_of`
---@param store table
---@param opts table|nil { donor = index into fam.members (default 1) }
---@return table|nil tmpl, string|nil why
function M.family_template(fam, store, opts)
    opts = opts or {}
    if type(fam) ~= 'table' or type(fam.members) ~= 'table' then
        return nil, 'not a family'
    end
    if #fam.members < 2 then
        return nil, 'a one-member family has no holes to parameterize'
    end
    local body = fam.template and fam.template.body
    if body == nil then return nil, 'the family carries no template body' end

    -- ⚠ A `row~` IS A STATEMENT THE ADAPTER COULD NOT BUILD, and rendering the
    -- donor's text would silently HARD-CODE the donor's version of it. Whether
    -- that statement varies across the members is precisely what the term model
    -- failed to say, so the output would assert something nothing checked. The
    -- proposal WARNS about this (it is prose beside a list); a text artifact
    -- reads as finished, so here it refuses.
    local rt = 0
    local function count_rt(t)
        if t == nil then return end
        if t.k == 'row~' then rt = rt + 1 end
        for _, k in ipairs(t.kids or {}) do count_rt(k) end
    end
    count_rt(body)
    if rt > 0 then
        return nil, ('%d statement(s) in the shared body are `row~` — the adapter'
            .. ' could not build them, so rendering the donor would hard-code its'
            .. ' version of a statement nothing compared'):format(rt)
    end

    local di = opts.donor or 1
    local donor = fam.members[di]
    if not donor then return nil, 'no such donor member' end
    local nd = store and store.node and store.node(donor.id)
    local drng = nd and nd.range
    if not drng then return nil, 'the donor function has no source range' end

    local hk = sorted_holes(fam.template)
    if #hk == 0 then
        return nil, 'the family has no holes — nothing varies, so there is'
            .. ' nothing to parameterize (the verb is merge, not extract)'
    end

    -- ★ the donor's OWN term, walked against the template, so a hole mentioned
    -- N times yields N spans. Rebuilt rather than taken from `fam.values`,
    -- which holds one value per hole and cannot express an occurrence.
    --
    -- ⚠ THE SAME NAMED REFUSAL `families`/`family_of` OWE. A family record only
    -- exists if the algebra loaded, so this is unreachable through the shipped
    -- verbs -- but a FABRICATED family reaches it (the spec builds several), and
    -- an absent algebra must never surface as a traceback from `fn_term`.
    local alg = require 'cartograph.algebra'
    local aok, awhy = alg.available()
    if not aok then return nil, 'algebra unavailable: ' .. tostring(awhy) end
    local sites, swhy = hole_sites(body, alg.fn_term(donor))
    if not sites then return nil, swhy end

    local varying, by_hole, params = {}, {}, {}
    local unkeyed, spanless = 0, {}
    for i, h in ipairs(hk) do
        params[h] = ('p%d'):format(i)
        by_hole[h] = {}
        local occs = sites[h] or {}
        if #occs == 0 then
            unkeyed = unkeyed + 1
            spanless[#spanless + 1] = ('%s (no occurrence in the body)'):format(params[h])
        end
        for _, v in ipairs(occs) do
        local ext = M.term_extent(v)
        if not ext then
            unkeyed = unkeyed + 1
            spanless[#spanless + 1] = ('%s (%s)'):format(params[h], v and tostring(v.k) or 'no value')
        else
            -- A span outside the donor would splice text from another function
            -- entirely. `render` rebases and catches it too; catching it here
            -- names the PARAMETER rather than a rebased line offset.
            if at.sl(ext) < at.sl(drng) or at.el(ext) > at.el(drng) then
                return nil, ('%s lies outside the donor %s — its span is another'
                    .. ' member\'s'):format(params[h], donor.name or '?')
            end
            local key = span_key(ext)
            -- ⚠ THE SAME PARAMETER AT THE SAME SPAN IS NOT A COLLISION, and the
            -- first cut refused it. `row_term` mirrors `row_key`, which writes a
            -- conditional row as `lhs=rhs;C:cond` -- the CONDITION APPEARS TWICE,
            -- once as the row's value and once as its guard. So an `if` whose
            -- condition varies yields two occurrences of one hole at ONE span,
            -- and refusing there killed the render for every conditional in the
            -- corpus. Writing the same text twice into one region is what would
            -- corrupt it, so the occurrence is DROPPED, not refused.
            if varying[key] then
                if varying[key].param ~= params[h] then
                    return nil, ('%s and %s share one span in the donor, so one'
                        .. ' substitution would silently win')
                        :format(varying[key].param, params[h])
                end
            else
                varying[key] = { at = ext, kind = (v and v.k) or 'value',
                    hole = h, param = params[h] }
                by_hole[h][#by_hole[h] + 1] = key
            end
        end
        end
    end

    return {
        n = #fam.members,
        alignable = true,
        donor = { at = drng, id = donor.id, file = donor.file, name = donor.name },
        varying = varying, by_hole = by_hole, params = params, order = hk,
        unkeyed = unkeyed, spanless = spanless,
    }
end

--- The helper body as TEXT: the donor's own source, with every hole replaced by
--- its parameter name. DISPLAY ONLY — see the `unverified` note above.
---@param fam table
---@param store table
---@param opts table|nil { donor = index, subs = { [hole] = text } }
---@return string|nil text, string|nil why, table|nil detail
function M.family_helper_text(fam, store, opts)
    opts = opts or {}
    local tmpl, why = M.family_template(fam, store, opts)
    if not tmpl then return nil, why end
    if tmpl.unkeyed > 0 then
        -- `render` refuses this too, by count; naming the parameters and the term
        -- kind that lost the span is what tells a reader whether it is a `seq`
        -- the hull could not close or a hole with no value at all.
        return nil, ('%d parameter(s) have no source span in the donor: %s')
            :format(tmpl.unkeyed, table.concat(tmpl.spanless, ', '))
    end
    local nd = store and store.node and store.node(tmpl.donor.id)
    local src = nd and store.content and store.content(nd)
    if not src then return nil, 'the donor source is not available' end

    -- ★★★ THE IDENTITY RENDER, a -> a. Substitute every hole with the DONOR'S
    -- OWN text and the result must be the donor's source, byte for byte. There
    -- is no expected value to calibrate: the answer IS the input, which is the
    -- same property the transliteration round-trip oracle relies on (emit,
    -- reparse, identical IR) and the reason it needs no tuning.
    -- ⚠ WHAT IT DOES AND DOES NOT TEST. Replacing a span with the text OF that
    -- span is identity for ANY span inside the donor, so this cannot see a hole
    -- pointing at the wrong place. It exercises the parts that have offsets in
    -- them and therefore can be off by one: the rebase into donor coordinates,
    -- the rightmost-first ordering when two holes share a line, and the donor
    -- slice itself. Mutating either of those two is caught. SPAN CORRECTNESS
    -- needs the reparse oracle (CART-0893), which does not exist here.
    -- ⚠ `render`'s NESTED-SPAN SUBSUMPTION is inherited but UNREACHABLE from
    -- this caller, measured 0 of 9 renders on our own tree — and structurally
    -- so: `hole_sites` stops descending AT a hole, so two recorded spans come
    -- from disjoint template subtrees and cannot nest. It earns its keep one
    -- altitude down, where a `field` hole's span contains its base's.
    -- MEASURED: 9/9 on our own tree and 15/15 on factorio-mods reproduce their
    -- donor byte for byte.
    local ident = opts.identity and as_lines(src) or nil
    local subs = {}
    for h, keys in pairs(tmpl.by_hole) do
        for _, key in ipairs(keys) do
            if ident then
                local own = slice(ident, tmpl.varying[key].at)
                if own == nil then
                    return nil, ('the donor does not reach its own span for %s')
                        :format(tmpl.params[h])
                end
                subs[key] = own
            else
                subs[key] = (opts.subs and opts.subs[h]) or tmpl.params[h]
            end
        end
    end
    return M.render(tmpl, subs, src, { unverified = true })
end

--- ★★★ THE REPARSE ORACLE AT FUNCTION ALTITUDE (CART-0893). Render the helper,
--- READ IT BACK, and require it to match the template it was built from — step C
--- checked by step B, which is `M.render`'s own discipline one altitude down and
--- the same round-trip the transliteration arc rests on. It needs no
--- calibration: the two sides share the walk and nothing else.
---
--- ⚠ WHY IT IS NOT OPTIONAL POLISH. Substituting into the donor's text buys the
--- surface OUTSIDE the holes for free and NOTHING about surface the IR erased
--- INSIDE one. THE BRACKET BUG (see `M.render`) was 63 of 1184 renders on our own
--- tree — 5.3% — and every one of them looked perfectly well-formed as a string.
--- The identity render (`opts.identity`) cannot see this class at all: replacing
--- a span with the text OF that span is identity for any span, so it checks the
--- splicer and says nothing about whether the cut was in the right place.
---
--- ★ TWO CHECKS, AND THE SECOND IS THE ONE ABOUT SPANS. `match.ok` says the
--- rendered text still has the template's SHAPE. It does NOT say each parameter
--- landed where the template says its hole is — a render that wrote `p2` at
--- `p1`'s position still matches, with the values swapped. So every hole must
--- come back holding ITS OWN parameter name. That is the check the span
--- correctness of `hole_sites` actually rides on.
---@param fam table
---@param store table
---@param opts table|nil { donor = index }
---@return boolean|nil ok, string|nil why, table|nil detail
function M.family_verify(fam, store, opts)
    local tmpl, why = M.family_template(fam, store, opts)
    if not tmpl then return nil, why end
    local text, twhy = M.family_helper_text(fam, store, opts)
    if not text then return nil, twhy end

    local lang = expr.lang_of(tmpl.donor.file)
    if not lang then
        return nil, ('no expression spec for %s — the helper cannot be read back')
            :format(tostring(tmpl.donor.file))
    end
    -- ★★★ THE CONTROL, AND WITHOUT IT THIS ORACLE LIES. The donor's span is not
    -- always a standalone chunk: an ANONYMOUS function (`function (a, b) … end`)
    -- is an EXPRESSION, and a file containing only one is a syntax error in Lua.
    -- MEASURED before this existed: 4 of 9 rendered helpers "did not reparse",
    -- every one of them for that reason and none because the render was wrong.
    -- Reporting those as defects would have been a false alarm at 44%.
    --
    -- ⇒ Parse the DONOR'S OWN TEXT through the identical path first — which is
    --   exactly the identity render. If the control cannot parse, the frame is
    --   at fault and this family is NOT VERIFIABLE, which is a different answer
    --   from "the render is broken". If the control parses and the rendered text
    --   does not, the parameters broke the grammar and that IS the defect this
    --   oracle exists to catch.
    -- ⚠ THE METHOD FLAG MUST CROSS TOO. `expr.of` sets `method` from the node's
    -- kind, and the flow layer harvests a lua method differently (the implicit
    -- receiver). Reparsing without it harvests the SAME TEXT under a DIFFERENT
    -- config, and the mismatch would be reported against the render. Found by
    -- mutation: forcing the flag broke no test, because nothing verified a
    -- method donor.
    local dn = store and store.node and store.node(tmpl.donor.id)
    local topts = { method = (dn and dn.kind == 'method') and lang == 'lua' }

    local control = M.family_helper_text(fam, store,
        { donor = opts and opts.donor, identity = true })
    -- ⚠ NOT `control and expr.of_text(...)`: an `and` expression yields ONE
    -- value, so the second return is discarded and every refusal below reported
    -- the fallback reason instead of the real one.
    local ceo, cwhy
    if control then ceo, cwhy = expr.of_text(control, lang, topts)
    else cwhy = 'the donor produced no identity render' end
    if not ceo then
        return nil, ('not verifiable: the donor\'s own text does not reparse'
            .. ' standalone (%s) — an anonymous function body is an expression,'
            .. ' not a chunk'):format(tostring(cwhy or 'no identity render')),
            { rendered = text, control = control, verifiable = false }
    end

    local eo, ewhy = expr.of_text(text, lang, topts)
    if not eo then
        return nil, ('the rendered helper did not reparse though the donor\'s own'
            .. ' text does: %s'):format(tostring(ewhy)), { rendered = text }
    end
    local keys, _, _, exprs, locals = fn_row_keys(eo)
    if not keys then
        return nil, 'the reparsed helper has no harvestable rows', { rendered = text }
    end

    local alg = require 'cartograph.algebra'
    local A = alg.load()
    if not A then return nil, 'algebra unavailable' end
    local term = alg.fn_term { exprs = exprs, locals = locals }

    -- ⚠ NOT `A.match`, AND THE REASON IS A DOMAIN. The template's holes carry
    -- DERIVED domains — where every member held a literal, the hole is
    -- `kinds{lit}` — and a helper's parameter is a NAME. So `match` refuses the
    -- render with "kind name not in {lit}", which is a true statement about the
    -- domain and says nothing about whether the text is right. MEASURED: 3 of 14
    -- families failed this way before the comparison moved.
    --
    -- ⇒ Compare STRUCTURALLY against the template with each hole plugged by its
    --   own parameter. That is exactly what the render claims to have produced,
    --   it needs no domain to hold, and it subsumes BOTH checks: a parameter
    --   written at the wrong hole makes the terms differ, where `match.ok` would
    --   have passed with the values merely swapped.
    -- the SAME resolution the render used, or the oracle compares the text
    -- against something the caller never asked for. ⚠ Only meaningful for
    -- identifier-like substitutions: a sub of `x + 1` reparses to a tree, not a
    -- name, and would be reported as a mismatch it is not.
    local function sub_of(h)
        return (opts and opts.subs and opts.subs[h]) or tmpl.params[h]
    end
    local function plug(t)
        if t == nil then return nil end
        if t.k == 'hole' then return A.name(sub_of(t.h) or ('?' .. tostring(t.h))) end
        local kids = {}
        for i, c in ipairs(t.kids or {}) do kids[i] = plug(c) end
        return A.rebuild(t, kids)
    end
    local want = plug(fam.template.body)
    if not A.eq(term, want) then
        return nil, 'the rendered helper reparsed to a DIFFERENT term than the'
            .. ' template it was built from',
            { rendered = text, got = A.show(term), want = A.show(want) }
    end
    return true, nil, { rendered = text, rows = #keys, holes = #tmpl.order }
end

-- ── the MEET: two templates, not a template and a payload (CART-0879 item 1) ──
--
-- ★★★ WHAT CARTOGRAPH COULD NOT ASK. `M.match` is ONE-SIDED — a template against
-- a payload — so "does this snippet instantiate that claim" had an answer and
-- "do these two claims OVERLAP" had none. Templates under instantiation form a
-- generality order: `generalize`/`join` compute the least template ABOVE two
-- (the lgg, absorbed already), and nothing computed the most general template
-- BELOW them, or said that none exists. That is unification (Martelli &
-- Montanari 1982), and the prototype exports it as `A.unify`.
--
-- ★★ THE ADAPTER IS THE REAL WORK, AND IT LIGHTS UP MORE THAN UNIFY.
-- `element_template` produces cartograph's OTHER template shape —
-- `{donor, varying, holes}`, keyed by the donor's source spans — which no
-- algebra arrow can take. `template_of` turns it into a prototype template, and
-- once a stored claim is a template record, `join`, `migrate`, `classify` and
-- `instance_of` all become askable of it, not only `unify`.
--
-- ★ IT USES `A.abstract`, NOT A HAND-BUILT RECORD. The prototype builds a
-- template from an instance plus hole SITES (paths), and going through its own
-- constructor is what keeps the domains, origins and edit log in the shape every
-- other arrow expects. Hand-assembling `{body, holes, edits}` here would be a
-- second authority for what a template IS.
--
-- ⚠ THE PATHS COME FROM THE TERM, NOT THE EXPR. `algebra.term` already carries
-- `e.at` onto the term node (the span licence), so the varying positions can be
-- located by walking the finished term — no parallel descent, and no second copy
-- of the adapter to keep in step.

--- A container's `element_template` as a PROTOTYPE template.
---@param et table an `M.element_template` result
---@return table|nil template, string|nil why
function M.template_of(et)
    local alg = require 'cartograph.algebra'
    local A, why = alg.load()
    if not A then return nil, 'algebra unavailable: ' .. tostring(why) end
    if type(et) ~= 'table' or not et.donor then return nil, 'not an element template' end
    if not et.alignable then
        return nil, 'the container\'s members do not share a shape'
    end
    if (et.n or 0) < 2 then
        return nil, 'a single member is a shape, not yet a template'
    end
    if (et.unkeyed or 0) > 0 then
        return nil, ('%d hole(s) carry no source span, so their position in the'
            .. ' term cannot be located'):format(et.unkeyed)
    end

    -- ⚠ NO LOCALS MAP, and `element_template` states why: a container's members
    -- are DECLARATIONS, not a function body, so nothing here is alpha-renameable
    -- and a locals map would silently equate two different names as "both local".
    local body = alg.term(et.donor)
    if not body then return nil, 'the donor does not adapt to a term' end

    -- ★ ONLY THE OUTERMOST VARYING SPANS BECOME HOLES, which is `M.render`'s own
    -- subsumption rule rather than a new one. `varying` deliberately keeps BOTH
    -- a field hole and its base's holes — dropping the inner one would make
    -- `M.match` call a payload that differs only at the base a mismatch — so the
    -- pruning belongs here, where "what is a hole" is the question.
    local outer = {}
    for key, v in pairs(et.varying) do
        local covered = false
        for k2, v2 in pairs(et.varying) do
            if k2 ~= key and spans_contain(v2.at, v.at) then covered = true end
        end
        if not covered then outer[key] = v end
    end

    local H, n, found = {}, 0, 0
    local function walk(t, path)
        local key = t.at and span_key(t.at)
        if key and outer[key] then
            n = n + 1
            H[('h%d'):format(n)] = { sites = { { path = path } },
                domain = A.open(), origin = 'derived' }
            found = found + 1
            return                      -- a hole's insides are not the template's
        end
        for i, c in ipairs(t.kids or {}) do
            local p = {}
            for _, x in ipairs(path) do p[#p + 1] = x end
            p[#p + 1] = i
            walk(c, p)
        end
    end
    walk(body, {})

    -- ⚠ A VARYING POSITION WITH NO NODE IN THE TERM IS A REFUSAL, NOT A SMALLER
    -- TEMPLATE. The adapter drops expression kinds it does not model, and a
    -- template missing one of the positions its members demonstrably vary at
    -- claims agreement where none was checked — the same failure `unkeyed`
    -- exists to prevent, one layer along.
    local want = 0
    for _ in pairs(outer) do want = want + 1 end
    if found < want then
        return nil, ('%d of %d varying position(s) have no node in the term — the'
            .. ' adapter does not model that expression kind'):format(want - found, want)
    end
    if want == 0 then
        return nil, 'the members vary nowhere the term can express'
    end
    return A.abstract(body, H)
end

--- Normalise whatever a caller has into a prototype template. THREE SHAPES
--- reach these verbs and they are distinguishable by construction:
---   * a PROTOTYPE TEMPLATE     — carries `.body`
---   * an `element_template`    — carries `.donor` and span-keyed `.varying`
---   * an EXPR NODE (a payload) — carries `.k`, and becomes a GROUND template,
---     which is what makes "what would this template have to become to admit
---     this payload" expressible at all.
--- Shared by `template_meet` and `template_join` deliberately: two copies of a
--- shape test is how the two verbs start disagreeing about what they accept.
local function as_template(x, side)
    local alg = require 'cartograph.algebra'
    local A = alg.load()
    if not A then return nil, 'algebra unavailable' end
    if type(x) ~= 'table' then return nil, side .. ' is not a template or a payload' end
    if x.body then return x end
    if x.donor ~= nil or x.varying ~= nil then
        local t, w = M.template_of(x)
        if not t then return nil, side .. ': ' .. tostring(w) end
        return t
    end
    if x.k ~= nil then
        local t = alg.term(x)
        if not t then return nil, side .. ': the payload does not adapt to a term' end
        return A.template(t)
    end
    return nil, side .. ' is neither a template, an element template, nor an expr node'
end

--- The MEET of two container templates: the most general template that is an
--- instance of BOTH, or a named reason there is none.
---@param a table an `M.element_template` result, or a prototype template
---@param b table likewise
---@return table|nil meet { template, left, right, renamed, fresh, free }
---@return string|nil why
function M.template_meet(a, b, opts)
    local alg = require 'cartograph.algebra'
    local A, why = alg.load()
    if not A then return nil, 'algebra unavailable: ' .. tostring(why) end
    local T1, w1 = as_template(a, 'left');  if not T1 then return nil, w1 end
    local T2, w2 = as_template(b, 'right'); if not T2 then return nil, w2 end
    local ok, r, uwhy = pcall(A.unify, T1, T2, opts)
    if not ok then return nil, 'unify failed: ' .. tostring(r) end
    if not r then return nil, tostring(uwhy) end
    return r
end

--- The JOIN: the least template ABOVE both — the dual of `template_meet`, and
--- the other half of the lattice CART-0879 said cartograph lacked.
---
--- ★★★ THE CONSUMER IS A REFUSAL THAT BECOMES AN ANSWER. `M.match` says a
--- payload does not instantiate a template and stops there. `join(T, payload)`
--- says what the template would have to BECOME to admit it, and the deltas say
--- exactly what moved:
---     kept      holes that survived unchanged, by NAME, so stored values follow
---     split     one hole that faced different partners and became several
---     widened   a hole whose domain had to grow
---     new       fixed structure that stopped being fixed
--- A widening you can read is a correctable claim; a refusal is not.
---
--- ⚠ NOT `generalize`. `generalize({instances})` rebuilds a family from scratch
--- and would not keep hole names, domains, or the operator edits a user made —
--- so every stored value would be orphaned. `join` moves a STORED template up by
--- exactly what the newcomer forces. That distinction is the whole reason this
--- is a separate arrow rather than a re-derivation.
---@param a table template | element_template | expr node
---@param b table likewise
---@return table|nil join { template, left, right, kept, split, widened, new, ... }
---@return string|nil why
function M.template_join(a, b, opts)
    local alg = require 'cartograph.algebra'
    local A, why = alg.load()
    if not A then return nil, 'algebra unavailable: ' .. tostring(why) end
    local T1, w1 = as_template(a, 'left');  if not T1 then return nil, w1 end
    local T2, w2 = as_template(b, 'right'); if not T2 then return nil, w2 end
    local ok, r, jwhy = pcall(A.join, T1, T2, opts)
    if not ok then return nil, 'join failed: ' .. tostring(r) end
    if not r then return nil, tostring(jwhy) end
    return r
end

-- ── EDITING A FAMILY'S TEMPLATE, AND CARRYING ITS VALUES (CART-0879) ─────────
--
-- ★★★ WHAT `templates.lua` EXISTS FOR AND COULD NOT DO. Its own header: "a
-- template you cannot point at cannot be CORRECTED. If the mining
-- over-generalises — a hole wider than it should be, two holes that are really
-- one — there is nothing to narrow." Storing the template made it a CLAIM; what
-- was missing is the operation that narrows it AND says who falls out.
--
-- ⚠ THE EDIT IS THE EASY HALF. Every edit moves the template in the generality
-- order, and the direction decides what can go wrong:
--     pin    narrow a hole to one value     DOWN — members CAN drop out
--     merge  two holes become one           DOWN — non-linear; members can drop
--     dig    a fixed subtree becomes a hole  UP  — nobody should drop
--     split  one site of a hole splits off   UP  — nobody should drop
--     open   undo a pin                      UP  — bounded to pinned holes
-- `A.migrate` is what makes an edit safe: it follows every member's values from
-- T0 to T1 along the edits T1 recorded beyond T0's, and returns `dropped` with a
-- REASON PER MEMBER. An edit verb without it silently keeps a family whose
-- members no longer instantiate their own template.
--
-- ★ THE DROPPED LIST IS THE ANSWER, not an error path. "Narrow this hole to
-- `nil` and three of nineteen members stop matching, here they are" is the
-- finding; the edited template alone is not.

--- Apply ONE edit to a family's template and migrate every member's values.
---@param fam table a family from `M.families` / `M.family_of`
---@param op table { edit = 'pin'|'open'|'dig'|'merge'|'split', h=, h2=, value=, path=, site= }
---@param opts table|nil { env = }
---@return table|nil result { template, values, kept, dropped, direction }
---@return string|nil why
function M.family_edit(fam, op, opts)
    opts = opts or {}
    local alg = require 'cartograph.algebra'
    local A, why = alg.load()
    if not A then return nil, 'algebra unavailable: ' .. tostring(why) end
    if type(fam) ~= 'table' or type(fam.template) ~= 'table' or not fam.template.body then
        return nil, 'not a family with a template'
    end
    if type(op) ~= 'table' or type(op.edit) ~= 'string' then
        return nil, 'no edit named'
    end

    -- ⚠ THE DIRECTION IS DECLARED HERE, NOT INFERRED. A caller that does not
    -- know whether an edit can lose members cannot read the result honestly,
    -- and the prototype states the direction per operator in its own headers.
    local DOWN = { pin = true, merge = true }
    local UP = { open = true, dig = true, split = true }
    if not (DOWN[op.edit] or UP[op.edit]) then
        return nil, ('unknown edit `%s` (pin, open, dig, merge, split)'):format(op.edit)
    end

    local T0 = fam.template
    local T1, ewhy
    if op.edit == 'pin' then
        if op.value == nil then return nil, 'pin needs a value' end
        T1, ewhy = A.pin(T0, op.h, op.value)
    elseif op.edit == 'open' then
        T1, ewhy = A.open_hole(T0, op.h)
    elseif op.edit == 'dig' then
        if type(op.path) ~= 'table' then return nil, 'dig needs a path' end
        T1, ewhy = A.dig(T0, op.path, op.h, op.domain)
    elseif op.edit == 'merge' then
        T1, ewhy = A.merge(T0, op.h, op.h2)
    else
        if type(op.site) ~= 'number' then return nil, 'split needs a site index' end
        T1, ewhy = A.split(T0, op.h, op.site, op.h2)
    end
    if not T1 then return nil, ('%s: %s'):format(op.edit, tostring(ewhy)) end

    -- the members' value maps, in member order
    --
    -- ⚠⚠ THE RESULT IS SPARSE, AND `open` DOES NOT WALK IT BACK. `migrate`
    -- returns `values` for the KEPT members only, still keyed by the ORIGINAL
    -- index, so feeding a result back in drops the already-dropped again.
    --
    -- ★★★ AND THE EDIT LOG CANNOT UNDO IT, WHICH IS NOT OBVIOUS. The template
    -- journals its edits (`T.edits`, replayable by `A.replay_edit`), so `open`
    -- restores exactly what `pin` SUPPLIED. But `migrate` ends by RE-DERIVING
    -- DOMAINS over the surviving members, and with one survivor every column
    -- holds one value — so holes nobody edited close too. MEASURED on a 3-member
    -- family, pinning h1:
    --
    --     ORIGINAL            h1={lit}    h2={lit}
    --     after A.pin(h1)     h1=="num:1" h2={lit}        <- the edit alone
    --     after migrate       h1=="num:1" h2=="str:1"     <- h2 was never edited
    --
    -- Re-opening h1 then leaves h2 closed, and a dropped member is refused on
    -- H2 — a hole no edit ever touched. The journal is complete for SUPPLIED
    -- narrowing and silent about DERIVED narrowing, because a re-derivation is
    -- not a move in the order.
    --
    -- ★ THIS IS THE PROTOTYPE'S STATED DESIGN, NOT A DEFECT (DOMAINS.md, which
    -- uses pin-then-open as its own illustration): "a derived closed domain
    -- never refuses an OBSERVATION; it widens on the next one". `match` is a
    -- strict test and refuses; `adjoin` is an observation and widens — which is
    -- why `family_adopt` takes the dropped member back.
    --
    -- ⇒ The values are NOT gone: the original family still holds them. To undo,
    --   re-edit the ORIGINAL. To bring a dropped member back into an edited
    --   family is an ADOPTION (a match), which the prototype names `adjoin` —
    --   "migration carries the family it is given and never adopts".
    local Vs, n = {}, #(fam.members or {})
    for i = 1, n do Vs[i] = (fam.values or {})[i] or {} end

    local okm, mig = pcall(A.migrate, T0, T1, Vs, opts.env)
    if not okm or not mig then
        return nil, 'migrate failed: ' .. tostring(mig)
    end

    -- ★ NAME THE MEMBERS THAT FELL OUT. `migrate` reports indices; a caller
    -- reading a report needs the function and the file, and resolving it here
    -- is what makes the dropped list usable rather than merely correct.
    local dropped = {}
    for _, d in ipairs(mig.dropped or {}) do
        local m = (fam.members or {})[d.i]
        dropped[#dropped + 1] = {
            i = d.i, why = d.why, op = d.op,
            name = m and m.name, file = m and m.file,
            line = m and (m.lines or {})[1],
        }
    end
    return {
        template = mig.template, values = mig.values,
        kept = mig.kept, dropped = dropped,
        direction = DOWN[op.edit] and 'down' or 'up',
        edit = op.edit,
    }
end

--- ADOPTION: a newcomer joins a family, and the family's values follow.
---
--- ★★★ THIS IS THE ARROW `family_edit` HAD NO RECOVERY PATH WITHOUT (CART-0896).
--- `migrate` carries the family it is GIVEN and never adopts, so a member
--- dropped by a narrowing edit cannot migrate back in — "adoption is a match,
--- not a migration". This is that match.
---
--- ★★ AND IT ENFORCES THE OBSERVED/SUPPLIED DISTINCTION THE CHARTER ALREADY
--- CARRIES. A newcomer is an OBSERVATION: it may widen a DERIVED domain (the
--- family simply turns out to be broader than the members seen so far) and it
--- may NOT override a SUPPLIED one — a pin is a premise, and an observation
--- does not get to overrule a premise by arriving. The refusal names the hole
--- and offers the two honest routes: open the pin, or adopt with `force`.
---
--- ⚠ WHEN THE NEWCOMER ALREADY FITS, THE TEMPLATE IS UNCHANGED. That is what
--- makes this ADOPTION rather than a re-derivation: `generalize` over the old
--- members plus the newcomer would rename every hole and orphan every stored
--- value, and a family that re-derived on every arrival would never be stable
--- enough to correct.
---@param fam table a family from `M.families` / `M.family_of`
---@param payload table a member record (`.exprs`) or an expr node
---@param opts table|nil { force = true to override a supplied domain }
---@return table|nil result { template, values, adopted, widened, join }
---@return string|nil why
function M.family_adopt(fam, payload, opts)
    opts = opts or {}
    local alg = require 'cartograph.algebra'
    local A, why = alg.load()
    if not A then return nil, 'algebra unavailable: ' .. tostring(why) end
    if type(fam) ~= 'table' or type(fam.template) ~= 'table' or not fam.template.body then
        return nil, 'not a family with a template'
    end

    -- ⚠ TWO PAYLOAD SHAPES, AND THEY ARE NOT INTERCHANGEABLE. A member record
    -- carries `.exprs` (a function's rows) and becomes a FUNCTION term; an expr
    -- node carries `.k` and becomes a single expression. Adapting one as the
    -- other yields a term of the wrong ARITY, which then fails as a mismatch
    -- against the family rather than as a bad argument.
    -- ⚠ THE ORDER IS DEFENSIVE, NOT LOAD-BEARING, and mutation says so: swapping
    -- the two branches breaks no test, because a member record has no `.k` and
    -- the shapes are disjoint TODAY. It is written `.exprs` first anyway — that
    -- is the field only one of them can have — so a record that later grows a
    -- `.k` is still read as what it is.
    local I
    if type(payload) ~= 'table' then
        return nil, 'the newcomer is not a member record or an expr node'
    elseif payload.exprs ~= nil then
        I = alg.fn_term(payload)
    elseif payload.k ~= nil then
        I = alg.term(payload)
    else
        return nil, 'the newcomer is neither a member record (.exprs) nor an expr node (.k)'
    end
    if not I then return nil, 'the newcomer does not adapt to a term' end

    local Vs, n = {}, #(fam.members or {})
    for i = 1, n do Vs[i] = (fam.values or {})[i] or {} end

    local okj, r, awhy = pcall(A.adjoin, fam.template, Vs, I, opts)
    if not okj then return nil, 'adjoin failed: ' .. tostring(r) end
    if not r then return nil, tostring(awhy) end

    -- ★ ADOPTED vs WIDENED is the answer, not a detail. "It already fitted" and
    -- "the family had to grow to take it" are different facts about the claim,
    -- and only the second one changed what the template says.
    local j = r.join or {}
    local widened = #(j.new or {}) + #(j.split or {}) + #(j.widened or {})
    return {
        template = r.template, values = r.values, join = j,
        adopted = widened == 0, widened = widened,
        new = j.new, split = j.split, grew = j.widened,
    }
end

-- ── THE PER-MEMBER VERDICT: who in this family can be extracted, and why not ──
--
-- ★★★ REFUSE-WHOLE IS TOO COARSE WHEN A HUMAN IS CHOOSING (user, 2026-09-13).
-- The N-way prereqs are the pair verb's, applied to every member, and one
-- failure currently sinks the family. MEASURED before building this — families
-- that a refuse-whole plan would reject:
--
--     self  3   factorio  2   wow  22
--     of wow's 22:  7 are "all but 1"   15 are systematic (<2 admissible)
--     biggest single loss: 0 of 25 members (AceConfigDialog:SelectGroup)
--
-- So a third of rejections lose almost a whole family to one member.
--
-- ⚠ AND THE MERGE PRECEDENT DOES NOT TRANSFER, which is why partial is even on
-- the table. `clonemerge` refuses whole because "a partial merge rewrites the
-- callers of a twin that still exists" — skipping a member there leaves
-- DANGLING REFERENCES. Extraction has no such failure: the helper exists, the
-- admissible bodies delegate to it, and a skipped member keeps its own body.
-- Nothing dangles, it parses, behaviour is identical. INCOMPLETE IS NOT UNSOUND.
--
-- ⇒ So this verb does not decide. It reports the verdict PER MEMBER and lets
--   the caller choose whole or partial — an interactive surface can say "25 of
--   26; member 14 is nested and captures `opts`" where a plan could only say no.
--
-- ⚠ COST: one `expr.of` per member (a whole-file reparse each). This is a
-- FOCUSED query about ONE family, not a corpus sweep; `families` over wow is
-- 298 families and this would reparse thousands of files.

--- Per-member extraction admissibility for one family.
---@param fam table a family from `M.families` / `M.family_of`
---@param store table
---@return table|nil verdict {members, admissible, refused, params, files, xfile, body}
---@return string|nil why  a FAMILY-level refusal (nothing per-member to report)
function M.family_admissibility(fam, store, opts)
    opts = opts or {}
    if type(fam) ~= 'table' or type(fam.members) ~= 'table' then
        return nil, 'not a family'
    end
    if #fam.members < 2 then
        return nil, 'a one-member family has nothing to share'
    end

    local un = require 'cartograph.untangle'
    local hc = require 'cartograph.hoistclosure'

    -- ★ THE FAMILY-LEVEL GATE FIRST, because it is not a member's fault. If the
    -- template cannot render a helper body at all there is no extraction to be
    -- partial ABOUT, and reporting per-member verdicts would imply otherwise.
    local body, bwhy = M.family_helper_text(fam, store)

    local out, files, nfiles = {}, {}, 0
    local counts = {}
    for i, m in ipairs(fam.members) do
        local v = un.body_extractable(store, m.id)
        local rec = {
            i = i, id = m.id, name = m.name, file = m.file,
            line = (m.lines or {})[1],
            ok = v.ok and true or false,
            reason = v.ok and nil or v.reason,
            nested = v.nested and true or false,
            nparams = v.ok and #(v.params or {}) or nil,
        }
        -- ★ WHAT IS CAPTURED, not merely THAT it captures (CART-0904). A name
        -- every member captures is a PARAMETER, indistinguishable in kind from a
        -- hole — the family already agrees on it. Reporting the name is what
        -- lets a caller see that; reporting only `nested` hides it.
        if v.nested then
            local plan, _, detail = hc.plan(store, m.id)
            rec.captures = detail and detail.captures or nil
            -- ★ THE WHOLE SET, because a member capturing two names needs two
            -- parameters and `captures` is only the first. MEASURED: 24 of 60
            -- capturing members on wow capture more than one.
            rec.captured = detail and detail.captured or (rec.captures and { rec.captures }) or {}
            rec.writes = detail and detail.writes or nil
            -- capture-FREE but nested: `body_extractable` refuses on nesting
            -- alone, yet there is nothing to lift — it hoists as it stands.
            rec.capture_free = (plan ~= nil) or nil
        end
        if rec.ok then counts[rec.nparams] = (counts[rec.nparams] or 0) + 1 end
        if not files[m.file] then files[m.file] = true; nfiles = nfiles + 1 end
        out[i] = rec
    end

    -- ⚠ THE PARAMETER COUNT IS A MAJORITY, NOT THE FIRST MEMBER'S. The pair verb
    -- compares two and either agrees or refuses; with N there is a MODE, and
    -- picking member 1's count would make the verdict depend on an ordering
    -- nobody chose.
    local majority, best = nil, -1
    for k, n in pairs(counts) do
        if n > best or (n == best and majority and k < majority) then majority, best = k, n end
    end
    local admissible, refused = {}, {}
    for _, rec in ipairs(out) do
        if rec.ok and majority and rec.nparams ~= majority then
            rec.ok = false
            rec.reason = ('takes %d parameter(s) where the family takes %d')
                :format(rec.nparams, majority)
        end
        if rec.ok then admissible[#admissible + 1] = rec.i
        else refused[#refused + 1] = rec end
    end

    -- ── THE CAPTURE LIFT (CART-0904) ────────────────────────────────────────
    --
    -- ★★★ A NAME EVERY MEMBER CAPTURES IS A PARAMETER, not a blocker. The family
    -- already agrees on it, which is the same evidence a hole rests on, and
    -- `hoistclosure`'s own refusal says so: "parameterize it first
    -- (extract-helper)". The two verbs are inverses; this is the side that can
    -- act.
    --
    -- ⚠ IT IS A SEPARATE VERDICT, NOT A PROMOTION. These members are extractable
    -- ONLY IF the captures are lifted, which changes the helper's signature —
    -- so they ride in `liftable`, not in `admissible`, and the caller decides.
    -- Silently folding them in would be this verb deciding, which is exactly
    -- what the per-member verdict exists not to do.
    --
    -- THE THREE WAYS A LIFT IS REFUSED, each measured on wow (25 families with a
    -- nested member):
    --   a WRITE capture      2   Lua parameters are by VALUE, so a lifted write
    --                            updates a copy — unsound, never lifted.
    --   DIFFERENT sets       5   a helper has ONE signature; a member cannot
    --                            pass a name it does not have in scope.
    --   the same set        14   LIFTABLE.
    --   capture-free         4   nothing to lift; these hoist as they stand.
    local liftable, lifts, lift_why = {}, nil, nil
    do
        local nested, sets, writes, freeonly = {}, {}, nil, true
        for _, rec in ipairs(out) do
            if rec.nested then
                nested[#nested + 1] = rec
                if rec.writes then writes = writes or rec.writes end
                if #rec.captured > 0 then
                    freeonly = false
                    sets[table.concat(rec.captured, '\1')] = rec.captured
                end
            end
        end
        if #nested == 0 then lift_why = nil
        elseif writes then
            lift_why = ('a member WRITES enclosing local `%s` — a lifted write would'
                .. ' update a copy'):format(writes)
        elseif freeonly then
            lifts, lift_why = {}, nil          -- nothing to lift; nesting alone
            for _, rec in ipairs(nested) do liftable[#liftable + 1] = rec.i end
        else
            local n, only = 0, nil
            for _, set in pairs(sets) do n = n + 1; only = set end
            if n > 1 then
                lift_why = ('members capture %d different sets — a helper has one'
                    .. ' signature'):format(n)
            else
                -- every capturing member agrees; a capture-free sibling needs
                -- nothing and rides along
                lifts = only
                for _, rec in ipairs(nested) do liftable[#liftable + 1] = rec.i end
            end
        end
    end

    return {
        members = out, admissible = admissible, refused = refused,
        params = majority, files = nfiles, xfile = nfiles > 1,
        body = body, body_why = body and nil or bwhy,
        -- ★ liftable is NOT admissible: these need the captures lifted first,
        -- and `lifts` names the parameters that would add.
        liftable = liftable, lifts = lifts, lift_why = lift_why,
        -- the numbers a caller decides on
        n = #fam.members, n_admissible = #admissible, n_liftable = #liftable,
    }
end

-- ── an edit on ONE member, propagated by COMMITMENT ─────────────────────────
--
-- ★★★ THE ARROWS ARE `classify` AND `propagate` (PROPAGATE.md). Their design
-- sentence is the user's: an edit lands on one instance; whether the abstraction
-- applies elsewhere is an OPERATOR DECISION; the machinery's job is to cluster
-- the impact and show previews so the decisions are PER CLUSTER, NOT PER MEMBER.
-- Nearest prior art is linked editing of clones (Toomim, Begel, Graham 2004).
--
-- ⚠ THIS VERB REPORTS AND DOES NOT DECIDE, and here that is the arrow's own
-- contract rather than our house style: `propagate` hands back a `commit`
-- CLOSURE and applies nothing until it is called. We carry that closure out
-- instead of calling it, so the decision stays where the design put it.
--
-- ★★ FIVE KINDS, AND ONLY ONE OF THEM PROPAGATES CLEANLY:
--      none       the edited text equals the member's instance
--      value      only values changed; T intact; scopes member / class / all
--      template   the fixed part changed, holes kept; propagates by `migrate`
--      mixed      both; the TEMPLATE part propagates, the value part stays local
--      straddle   the edit crossed a hole boundary; the abstraction must move
--                 first. Only the STORE-LAW straddle carries a PROPOSAL, because
--                 only it converges (split the changed sites, migrate, classify
--                 again); the others carry a HINT, which is a weaker thing and
--                 the prototype says so by name.
--
-- ⚠ AND `unsupported` IS NOT A STRADDLE. A repetition or context hole is outside
-- what classify models at all; rendering the two alike would turn "we do not
-- handle this shape" into "your edit was bad".

--- Classify an edit made to ONE member's text and cluster its impact over the
--- family, without writing anything.
---
--- @param fam table   a family record (`families` / `family_of`)
--- @param i number    the 1-based member index whose text was edited
--- @param text string the member's NEW source text
--- @param store table
--- @param opts table|nil
--- @return table|nil result, string|nil why
--- result = { kind, hint, proposal, holes = { {h, from, to, class, others} },
---            template = { clean, refused = { {why, members} }, drifted },
---            commit = { value = fn(h, scope), template = fn(members) } }
function M.family_propagate(fam, i, text, store, opts)
    opts = opts or {}
    if type(fam) ~= 'table' or type(fam.template) ~= 'table' then
        return nil, 'not a family record'
    end
    local Vs = fam.values
    if type(Vs) ~= 'table' then return nil, 'the family carries no values' end
    if type(i) ~= 'number' or not Vs[i] then
        return nil, ('member %s is not in this family'):format(tostring(i))
    end
    if type(text) ~= 'string' or text == '' then return nil, 'no edited text' end

    local alg = require 'cartograph.algebra'
    local A, why = alg.load()
    if not A then return nil, 'algebra unavailable: ' .. tostring(why) end
    if not (A.classify and A.propagate) then
        return nil, 'this algebra has no classify/propagate'
    end

    -- ⚠ THE EDITED TEXT IS PARSED THROUGH THE SAME PATH `family_verify` READS A
    -- RENDER BACK THROUGH, and for the same reason: a term is a SELECTOR, not a
    -- source, so the only way to turn text into one is to parse it. The member's
    -- own file decides the language -- an edit does not change it.
    local m = fam.members and fam.members[i]
    local file = m and (m.file or (m.ref and m.ref.file))
    local lang = file and expr.lang_of(file)
    if not lang then
        return nil, ('no expression spec for %s -- the edit cannot be read')
            :format(tostring(file))
    end
    local topts = { method = m and m.kind == 'method' or nil }
    local eo, ewhy = expr.of_text(text, lang, topts)
    if not eo then
        return nil, ('the edited text does not parse as %s: %s')
            :format(lang, tostring(ewhy))
    end
    local keys, _, _, exprs, locals = fn_row_keys(eo)
    if not keys then return nil, 'the edited text has no harvestable rows' end
    local I2 = alg.fn_term { exprs = exprs, locals = locals }
    if not I2 then return nil, 'the edited text did not convert to a term' end

    local C = A.classify(fam.template, Vs[i], I2)
    if not C then return nil, 'classify returned nothing' end
    local out = { kind = C.kind, why = C.why, hint = C.hint,
        proposal = C.proposal, region = C.region, hole = C.hole }
    -- ★ THE THREE NON-PROPAGATING KINDS ARE ANSWERS, NOT FAILURES. `none` means
    -- the edit was a no-op against the abstraction; a straddle means the
    -- ABSTRACTION must move first and carries the reason; `unsupported` means
    -- the shape is outside the model. Each is reported with its own word, above.
    --
    -- ⚠ AND THERE IS DELIBERATELY NO EARLY RETURN FOR THEM HERE. The first cut
    -- had one; MUTATION SHOWED IT WAS DEAD — `propagate` guards exactly those
    -- three kinds as its own first statement, so deleting our copy changed
    -- nothing the suite could see, in either direction. A second guard that
    -- cannot fail is a dead predicate, and this repo's rule is that a dead
    -- predicate passes every negative test ever written. The clusters below stay
    -- nil for those kinds because `propagate` returns them nil, which is the
    -- answer we want and the one it is contracted to give.
    local P = A.propagate(fam.template, C, Vs, i)
    if not P then return nil, 'propagate returned nothing' end

    -- the VALUE part: per changed hole, who already holds the old value (the
    -- class) and who holds something else, grouped by what they hold.
    -- ⚠ IT IS `P.values.holes`, NOT `P.holes`. The first cut read the wrong
    -- field and got nil -- which rendered as "a value edit changed no holes", a
    -- coherent-looking answer that is not a possible one. A falsy answer is a
    -- claim about MY ACCESSOR first; the test that asserted the clusters exist
    -- is the only reason it did not ship.
    -- ★ AND THE VALUE PART CARRIES ITS OWN COMMIT, scoped: `member`, `class`,
    -- `all`, or an explicit list. A per-hole commit alone would lose the scope
    -- vocabulary the design is built on.
    local V = P.values
    if V and V.holes then
        -- ⚠ A HOLE CARRIES A `preview`, NOT A COMMIT. There is ONE commit for the
        -- value part and it is SCOPED (member / class / all / a list) -- reading
        -- a per-hole commit off these entries got nil, because committing one
        -- hole for one member is not a decision the design offers.
        out.holes = {}
        out.commit = { values = V.commit }
        for _, h in ipairs(V.holes) do
            out.holes[#out.holes + 1] = { h = h.h, from = h.from, to = h.to,
                class = h.class, others = h.others, preview = h.preview }
        end
        -- the widened template the family would adopt along with the values
        out.widened = V.widened
    end
    -- the TEMPLATE part: migrate over the recorded rewrites. `refused` is
    -- GROUPED BY REASON, which is the whole point of the clustering -- a list of
    -- N refusals is a list; three reasons over N members is a decision.
    if P.template then
        out.template = { clean = P.template.clean, refused = P.template.refused,
            drifted = P.template.drifted, preview = P.template.preview }
        out.commit = out.commit or {}
        out.commit.template = P.template.commit
    end
    return out
end

-- ── the VIRTUAL-STEP LADDER: a SEQUENCE of edits, none of them written ──────
--
-- ★★★ `family_edit` APPLIES ONE EDIT; THIS FOLDS A LOG. The difference is not
-- convenience — it is the thing CART-0920 is missing. A composition needs to ask
-- "what is the state after steps 1..k", and until something folds an edit log
-- there is no such state to ask about: there is a template before, a template
-- after, and nothing in between.
--
-- ★★ THE ARROW IS `replay_edit`, AND IT READS THE ALGEBRA'S OWN LOG FORMAT. Each
-- of the five edits records its op into `T.edits` (`edited(T, op)` copies the
-- template and appends), so an op is a VALUE that can be carried, stored and
-- replayed against a different template. `replay_edit` dispatches SEVEN ops —
-- the five moves plus `rewrite` and `join` — which is two more than
-- `family_edit` can spell, so a log may legitimately contain steps this tree
-- cannot yet author.
--
-- ⚠ THE VALUES MIGRATE AT EVERY STEP, AND THE RESULT IS SPARSE. `migrate` keys
-- kept members by their ORIGINAL index, so the surviving set only ever shrinks
-- and index k means the same member at every rung. Carrying a DENSE list forward
-- would silently renumber the family halfway down the ladder.
--
-- ⚠ AND A REFUSAL STOPS THE FOLD RATHER THAN SKIPPING THE STEP. Step k+1 is
-- defined against the state step k produced; continuing past a refusal would
-- compute a rung that no sequence of edits reaches.

--- Fold a sequence of recorded edits onto a family, returning the state after
--- EACH step. Writes nothing and mutates neither the family nor its template.
---
--- @param fam table   a family record
--- @param ops table   a list of recorded ops (`T.edits` entries: {op=..., ...})
--- @param opts table|nil  { env }
--- @return table|nil steps, string|nil why
--- steps = { { i, op, template, values, kept, dropped, refused, why } }
function M.family_steps(fam, ops, opts)
    opts = opts or {}
    if type(fam) ~= 'table' or type(fam.template) ~= 'table' then
        return nil, 'not a family record'
    end
    -- ★★ A LADDER THAT CLAIMS TO BE SERIALIZED IS GATED; A BARE LIST IS NOT
    -- (CART-0922). An in-process list of ops has no provenance question — it was
    -- built by the caller a moment ago. A table carrying `ops` is an ARTIFACT,
    -- and `replay_edit` EXECUTES what it holds, so it must say which meanings it
    -- was recorded under. ⚠ `ops` present and `version` absent is the dangerous
    -- shape and is refused by name: it LOOKS serialized and cannot prove it.
    if type(ops) == 'table' and ops.ops ~= nil then
        local okv, vwhy = require('cartograph.schema').replayable('ladder', ops.version)
        if not okv then return nil, vwhy end
        ops = ops.ops
    end
    if type(ops) ~= 'table' or #ops == 0 then return nil, 'no edits to replay' end
    local alg = require 'cartograph.algebra'
    local A, why = alg.load()
    if not A then return nil, 'algebra unavailable: ' .. tostring(why) end
    if not A.replay_edit then return nil, 'this algebra has no replay_edit' end

    local T, Vs = fam.template, fam.values
    local steps = {}
    for k, op in ipairs(ops) do
        if type(op) ~= 'table' or op.op == nil then
            return nil, ('step %d is not a recorded edit (no `op` field)'):format(k)
        end
        local T2, rwhy = A.replay_edit(T, op)
        if not T2 then
            -- ★ THE REFUSAL IS A RUNG, NOT AN ERROR. The ladder up to here is
            -- real and the caller may well want it; what it may not do is
            -- pretend step k happened.
            steps[#steps + 1] = { i = k, op = op, refused = true,
                why = ('%s: %s'):format(tostring(op.op), tostring(rwhy)) }
            return steps
        end
        local okm, mig = pcall(A.migrate, T, T2, Vs, opts.env)
        if not okm or not mig then
            steps[#steps + 1] = { i = k, op = op, refused = true,
                why = ('%s: migrate failed: %s'):format(tostring(op.op), tostring(mig)) }
            return steps
        end
        -- name who fell out, on the same terms `family_edit` does: indices are
        -- correct and unusable
        local dropped = {}
        for _, d in ipairs(mig.dropped or {}) do
            local m = (fam.members or {})[d.i]
            dropped[#dropped + 1] = { i = d.i, why = d.why, op = d.op,
                name = m and m.name, file = m and m.file }
        end
        steps[#steps + 1] = { i = k, op = op, template = mig.template,
            values = mig.values, kept = mig.kept, dropped = dropped }
        T, Vs = mig.template, mig.values
    end
    return steps
end

--- Stamp a list of recorded edits as a LADDER, the serializable form
--- `family_steps` will accept back. One place writes the version, so a new
--- writer cannot forget the field (CART-0922).
--- @param ops table a list of recorded ops
--- @return table ladder { version, ops }
function M.ladder(ops)
    return require('cartograph.schema').stamp('ladder', { ops = ops })
end

return M
