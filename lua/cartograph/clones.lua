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
    if k == 'table' then return 'T' end
    if k == 'fn' then return 'Fn' end
    if k == 'vararg' then return 'V' end
    local parts = {}
    for _, c in ipairs(e.kids or {}) do parts[#parts + 1] = canon(c, locals, slots, ctr) end
    return '?' .. (e.t or '') .. '(' .. table.concat(parts, ',') .. ')'
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

--- The alpha-invariant structural signature of a function's body: (nparams, {row_key…}).
--- `eo` is the result of expr.of(store, id). Returns (sig_string, nrows) or nil when the
--- body has no harvestable rows.
function M.signature(eo)
    local stmts = eo and eo.fl and eo.fl.stmts
    if not stmts or #stmts == 0 then return nil end
    -- locals = params ∪ every df-def name across the body
    local locals = {}
    for _, p in ipairs(eo.fl.params or {}) do locals[p] = true end
    for _, s in ipairs(stmts) do
        for _, d in ipairs(s.def or {}) do locals[d] = true end
    end
    local slots, ctr = {}, { n = 0 }
    local keys = {}
    for _, s in ipairs(stmts) do
        keys[#keys + 1] = s.expr and row_key(s.expr, locals, slots, ctr) or '~'
    end
    return ('p%d|%s'):format(#(eo.fl.params or {}), table.concat(keys, '\n')), #stmts
end

--- Exact-structural clone GROUPS across the store's functions. Returns a list of groups,
--- each { nrows = N, [1..] = {id, name, file, line} }, sorted by (size desc, nrows desc).
--- opts.min_rows (default 3) filters trivial bodies; opts.on_progress(done,total) optional.
function M.exact(store, opts)
    local min_rows = (opts and opts.min_rows) or 3
    local groups = {}
    local fns = {}
    for _, n in ipairs(store.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.file then
            fns[#fns + 1] = n
        end
    end
    for i, n in ipairs(fns) do
        local ok, eo = pcall(expr.of, store, n.id)
        if ok and eo then
            local sig, nrows = M.signature(eo)
            if sig and nrows >= min_rows then
                local g = groups[sig]
                if not g then g = { nrows = nrows }; groups[sig] = g end
                g[#g + 1] = { id = n.id, name = n.name, file = n.file,
                    line = n.range and (at.sl(n.range) + 1) or 0 }
            end
        end
        if opts and opts.on_progress then opts.on_progress(i, #fns) end
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
            local best
            for _, sub in pairs(grow) do
                if #sub >= 2 and (not best or #sub > #best) then best = sub end
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

--- Human-readable report lines for M.blocks groups.
function M.blocks_report(groups)
    if #groups == 0 then return { 'block-structural clones: none' } end
    local L = { ('block-structural clones — %d group(s)'):format(#groups),
        '(contiguous statement runs shared across/within functions; window-local alpha-invariance)', '' }
    for _, g in ipairs(groups) do
        L[#L + 1] = ('■ %d copies, %d-statement block:'):format(#g, g.len)
        for _, m in ipairs(g) do
            L[#L + 1] = ('    %s  %s:%d-%d'):format(m.name, m.file, m.from_line, m.to_line)
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

return M
