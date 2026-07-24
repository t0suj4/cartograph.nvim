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

--- Near-clone PAIRS across the store's functions. Returns a list of pairs, each
--- { dist, shared, a = {name,file,id,lines,keys}, b = {…}, ops }, sorted by
--- (shared desc, dist asc). opts.max_dist (default 2), opts.min_rows (default 6),
--- opts.min_shared (default 3).
function M.near(store, opts)
    local max_dist = (opts and opts.max_dist) or 2
    local min_rows = (opts and opts.min_rows) or 6
    local min_shared = (opts and opts.min_shared) or 3
    -- 1. per-fn canonical row-key lists
    local fns = {}
    for _, n in ipairs(store.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.file then
            local ok, eo = pcall(expr.of, store, n.id)
            if ok and eo then
                local keys, lines, _, exprs, locals = fn_row_keys(eo)
                if keys and #keys >= min_rows then
                    fns[#fns + 1] = { id = n.id, name = n.name, file = n.file,
                        keys = keys, lines = lines, exprs = exprs, locals = locals }
                end
            end
        end
    end
    -- 2. inverted index of distinctive row-keys → candidate pairs
    local post = {}
    for i, f in ipairs(fns) do
        local seen = {}
        for _, k in ipairs(f.keys) do
            if not seen[k] then seen[k] = true; post[k] = post[k] or {}; post[k][#post[k] + 1] = i end
        end
    end
    local shared = {} -- packed pair key → count of shared distinctive keys
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
    -- 3. align each candidate pair, keep near-clones (distance 1..max_dist)
    local out = {}
    for pk, cnt in pairs(shared) do
        if cnt >= min_shared then
            local fa, fb = fns[math.floor(pk / 1000000)], fns[pk % 1000000]
            local dist, ops = align(fa.keys, fb.keys)
            if dist >= 1 and dist <= max_dist then
                local nmatch = 0
                for _, o in ipairs(ops) do if o.op == 'match' then nmatch = nmatch + 1 end end
                if nmatch >= min_rows then
                    out[#out + 1] = { dist = dist, shared = nmatch, a = fa, b = fb, ops = ops }
                end
            end
        end
    end
    table.sort(out, function (x, y)
        if x.shared ~= y.shared then return x.shared > y.shared end
        return x.dist < y.dist
    end)
    return out
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
    if e1.k ~= e2.k then holes[#holes + 1] = { kind = 'struct' }; return false end
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
    local holes, insdel = {}, 0
    for _, o in ipairs(pair.ops) do
        if o.op == 'sub' then
            anti_unify_row(pair.a.exprs[o.i], pair.b.exprs[o.j], pair.a.locals, pair.b.locals, holes)
        elseif o.op == 'ins' or o.op == 'del' then
            insdel = insdel + 1
        end
    end
    local structural = insdel > 0
    for _, h in ipairs(holes) do if h.kind == 'struct' then structural = true end end
    -- dedupe value holes by (kind, a, b) — one parameter per distinct varying leaf
    local params, seen = {}, {}
    for _, h in ipairs(holes) do
        if h.kind ~= 'struct' then
            local key = h.kind .. '\31' .. tostring(h.a) .. '\31' .. tostring(h.b)
            if not seen[key] then seen[key] = true; params[#params + 1] = h end
        end
    end
    local kind = structural and 'structural' or (#params == 0 and 'exact' or 'value')
    return { kind = kind, holes = params, insdel = insdel }
end

--- Human-readable report for M.near pairs. `store` is used to show the differing
--- (hole) source lines — the parameters the two copies would factor into.
function M.near_report(pairs_, store)
    if #pairs_ == 0 then return { 'near-clones: none' } end
    local L = { ('near-clones — %d pair(s)'):format(#pairs_),
        '(row sequences differing by ≤ max_dist edits; matched rows = shared template, differing rows = holes/params)', '' }
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
    for _, p in ipairs(pairs_) do
        local a = M.analyze_pair(p)
        L[#L + 1] = ('■ %d edit(s), %d shared statement(s) — %s:')
            :format(p.dist, p.shared, TAG[a.kind])
        L[#L + 1] = ('    %s  %s:%d'):format(p.a.name, p.a.file, p.a.lines[1] or 0)
        L[#L + 1] = ('    %s  %s:%d'):format(p.b.name, p.b.file, p.b.lines[1] or 0)
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
