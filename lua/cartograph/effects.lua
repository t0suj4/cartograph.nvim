-- EFFECTS: what does calling this function DO to module state — the write
-- axis + guard summaries + param predicates, discharged per call site.
-- The first consumer of the analysis ladder's facts ([[cartograph-write-axis]]):
--   rw = does the fn read/write the var        (the write axis)
--   gw = are ALL its writes guarded/set-once   (guard summaries)
--   gp = writes fire only when param |gp| is truthy(+)/falsy(−)
-- and gp DISCHARGES against the call's argv literals (the argv fold's
-- scalar/lit kinds): f(x, true) vs f(x) resolve the predicate statically.
--
-- Honesty: gp is sound in the SKIP direction only — a falsy flag proves
-- the write cannot fire; a truthy flag proves nothing extra (other guards
-- may still gate). Verdicts never claim beyond that:
--   'skips'       the predicate discharges FALSE: provably no write here
--   'writes'      unguarded writes exist (gw 1 or no gw)
--   'writes-guarded' / 'writes-once'  all writes guarded / set-once
--   'may-write'   predicate undischargeable at this site (non-literal arg)
-- Missing args discharge to falsy ONLY for lua (nil); php parameters may
-- carry defaults the graph doesn't track — those stay 'may-write'.

local argv = require 'cartograph.argv'

local M = {}

-- BUILTIN effect table: stdlib callees that write their arguments — the
-- fact resolution can never discover (builtins resolve to no node), and
-- without which every table.insert would be an honest-but-useless
-- "may write anything" in the purity fixpoint. w = 1-based arg indexes
-- written. Curated, deliberately small; absence means UNKNOWN, not pure.
M.BUILTINS = {
    lua = {
        ['table.insert'] = { w = { 1 } },
        ['table.remove'] = { w = { 1 } },
        ['table.sort'] = { w = { 1 } },
        ['table.move'] = { w = { 5 } }, -- a2 (defaults to a1: conservative)
        ['setmetatable'] = { w = { 1 } },
        ['rawset'] = { w = { 1 } },
    },
    php = {
        sort = { w = { 1 } }, rsort = { w = { 1 } }, usort = { w = { 1 } },
        ksort = { w = { 1 } }, asort = { w = { 1 } }, arsort = { w = { 1 } },
        array_push = { w = { 1 } }, array_pop = { w = { 1 } },
        array_shift = { w = { 1 } }, array_unshift = { w = { 1 } },
        array_splice = { w = { 1 } },
        preg_match = { w = { 3 } }, preg_match_all = { w = { 3 } },
        settype = { w = { 1 } },
    },
}

-- literal truthiness by language family (nil = unknown)
local function truthy_of(a, lang)
    if not a then return nil end
    if a.k == 'scalar' then
        local v = a.v
        if lang == 'lua' then
            return v ~= 'false' and v ~= 'nil'
        end
        -- php: false/null/0/0.0 are falsy
        return not (v == 'false' or v == 'null' or v == 'NULL'
            or tonumber(v) == 0)
    end
    if a.k == 'lit' then -- a string literal
        if lang == 'lua' then return true end -- every string is truthy
        return a.v ~= '' and a.v ~= '0'      -- php's falsy strings
    end
    return nil -- local/expr/func/…: not a literal, unknown at this site
end

local function lang_of(file)
    return file:match('%.lua$') and 'lua'
        or file:match('%.php$') and 'php' or nil
end

--- The verdict for ONE use edge, at ONE call site of the edge's function.
--- `u` is a store.var_uses record ({to, rw, gw, gp}) or an edge; `c` is
--- the call; `file` the callee's file (for language semantics).
function M.verdict(u, c, file)
    if not u.rw or u.rw == 1 then return 'reads' end
    if u.gp and c then
        local i = u.gp > 0 and u.gp or -u.gp
        local lang = file and lang_of(file)
        local truthy
        if i > argv.n(c) then
            -- missing argument: nil in lua — php may have a default
            -- (explicit if: `and false or nil` collapses to nil)
            if lang == 'lua' then truthy = false end
        else
            truthy = truthy_of(argv.at(c, i), lang)
        end
        if truthy ~= nil then
            local fires = (u.gp > 0) == truthy
            if not fires then return 'skips' end
            -- the predicate passes: other guards may still gate — fall
            -- through to the gw-tier verdict, never a stronger claim
        else
            return 'may-write'
        end
    end
    if u.gw == 3 then return 'writes-once' end
    if u.gw == 2 then return 'writes-guarded' end
    return 'writes'
end

--- All write effects of a resolved call: { {var=id, verdict=...}, ... }.
--- Reads are omitted (they are the use edges' default story).
function M.call_writes(store, c)
    local out = {}
    if not (c and c.to) then return out end
    local fn = store.node(c.to)
    local file = fn and fn.file
    for _, u in ipairs(store.var_uses[c.to] or {}) do
        if u.rw and u.rw > 1 then
            out[#out + 1] = { var = u.to, verdict = M.verdict(u, c, file) }
        end
    end
    return out
end


-- ── the EFFECTS FIXPOINT: transitive write summaries over the CSR ────────
-- One reverse-topological pass over the SCC condensation (effects are a
-- join-semilattice: unions only, no iteration — scc.lua's emission order
-- IS the pass order). A summary per fn:
--   w      { key -> tier }   key = var .. '\31' .. field ('' = whole/
--                            unknown), tier 1 unguarded / 2 guarded /
--                            3 set-once (MIN when merging)
--   gpk    { key -> ±param } the fn's OWN gp-carrying writes: dischargeable
--                            at ITS call sites (deeper predicates are not)
--   pwx    { own param idx -> true } transitive param mutation (pw + pw
--                            reached by passing a param onward)
--   h      { hedge strings, capped } refused/unresolved/opaque-arg — the
--                            summary is honest, not silently optimistic
--   over   true when the write-set blew the cap (coarsened to "many")
-- Purity: 'pure' (no w, no pwx, no h) / 'pure~' / 'writes' / 'writes~'.

local CAP = 200   -- write-set keys per summary before honest coarsening
local HCAP = 4    -- hedges kept per summary

local function s_add(sum, key, tier)
    local w = sum.w
    local cur = w[key]
    if cur then
        if tier < cur then w[key] = tier end
    elseif sum.nk >= CAP then
        sum.over = true
    else
        sum.nk = sum.nk + 1
        w[key] = tier
    end
end

local function s_hedge(sum, why)
    local h = sum.h
    if not h then h = {}; sum.h = h end
    if #h < HCAP then h[#h + 1] = why end
    sum.nh = (sum.nh or 0) + 1
end

-- resolve a call argument to what a callee-side param write would hit:
-- a same-file module var ('var'), the CALLER's own param ('param'), or
-- nothing nameable ('opaque')
local function arg_target(store, c, i, caller)
    local a = argv.at(c, i)
    if not a then return 'opaque' end
    if a.k == 'local' and a.name then
        for _, n in ipairs(store.by_file[c.file] or {}) do
            if n.kind == 'var' and n.name == a.name then
                return 'var', n.id
            end
        end
        local ps = caller and caller.params
        if ps then
            for pi = 1, #ps do
                if ps[pi] == a.name then return 'param', pi end
            end
        end
        return 'opaque' -- a plain local: mutation invisible outside — but
        -- it MAY alias module state; the caller hedges (no alias analysis)
    end
    if a.k == 'scalar' or a.k == 'lit' then return 'value' end -- immutable
    return 'opaque'
end

local VERDICT_TIER = { ['writes-once'] = 3, ['writes-guarded'] = 2,
    ['may-write'] = 2, writes = 1 }

--- Compute (and cache per graph generation) every fn's write summary.
function M.summaries(store)
    if store._fx and store._fxgen == store.generation then return store._fx end
    local scc = require 'cartograph.scc'
    local ids = {}
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'function' or n.kind == 'method' then
            ids[#ids + 1] = n.id
        end
    end
    table.sort(ids)
    local con = scc.condense(store.uses, ids)
    local sums = {}
    for ci = 1, con.n do
        local members = con.members[ci]
        local sum = { w = {}, nk = 0 }
        -- DIRECT effects of every member
        for _, fid in ipairs(members) do
            local fnode = store.node(fid)
            for _, u in ipairs(store.var_uses[fid] or {}) do
                if u.rw and u.rw >= 2 then
                    if u.gp then
                        -- gp is var-level: one dischargeable key
                        local key = u.to .. '\31'
                        s_add(sum, key, u.gw or 1)
                        sum.gpk = sum.gpk or {}
                        sum.gpk[key] = u.gp
                    elseif u.flds then
                        for f, packed in pairs(u.flds) do
                            if packed % 4 >= 2 then
                                local g = (packed - packed % 4) / 4
                                s_add(sum, u.to .. '\31' .. f, g == 0 and 1 or g)
                            end
                        end
                    else
                        s_add(sum, u.to .. '\31', u.gw or 1)
                    end
                end
            end
            if fnode and fnode.pw then
                sum.pwx = sum.pwx or {}
                for _, pi in ipairs(fnode.pw) do sum.pwx[pi] = true end
            end
        end
        -- CALL inheritance (external callees are already summarized:
        -- Tarjan emission order is callees-first)
        for _, fid in ipairs(members) do
            local caller = store.node(fid)
            local file = caller and caller.file
            for _, c in ipairs(store.calls_by_fn[fid] or {}) do
                local to = c.to
                if to and con.comp[to] == ci then
                    -- intra-SCC: members share this summary already
                elseif to and sums[to] then
                    local cs = sums[to]
                    if cs.over then sum.over = true end
                    if cs.h then s_hedge(sum, cs.h[1]) end
                    for key, tier in pairs(cs.w) do
                        local gp = cs.gpk and cs.gpk[key]
                        if gp then
                            local tn = store.node(to)
                            local v = M.verdict(
                                { rw = 2, gw = tier, gp = gp }, c,
                                tn and tn.file)
                            if v ~= 'skips' then
                                s_add(sum, key, VERDICT_TIER[v] or tier)
                            end
                        else
                            s_add(sum, key, tier)
                        end
                    end
                    -- the callee mutates its params: what did WE pass?
                    local tn = store.node(to)
                    if cs.pwx then
                        for pi in pairs(cs.pwx) do
                            local kind, x = arg_target(store, c, pi, caller)
                            if kind == 'var' then
                                s_add(sum, x .. '\31', 1)
                            elseif kind == 'param' then
                                sum.pwx = sum.pwx or {}
                                sum.pwx[x] = true
                            elseif kind == 'opaque' then
                                s_hedge(sum, ('param-mutation via opaque arg -> %s @%s:%d')
                                    :format(tn and tn.name or to, c.file or '?', c.line or 0))
                            end
                        end
                    end
                elseif to then
                    s_hedge(sum, ('callee outside the fn graph: %s'):format(to))
                else
                    local lang = file and (file:match('%.lua$') and 'lua'
                        or file:match('%.php$') and 'php')
                    local bname = c.full or c.callee
                    local b = lang and bname and M.BUILTINS[lang]
                        and M.BUILTINS[lang][bname]
                    if b then
                        for _, ai in ipairs(b.w) do
                            local kind, x = arg_target(store, c, ai, caller)
                            if kind == 'var' then
                                s_add(sum, x .. '\31', 1)
                            elseif kind == 'param' then
                                sum.pwx = sum.pwx or {}
                                sum.pwx[x] = true
                            elseif kind == 'opaque' then
                                s_hedge(sum, ('%s on opaque arg @%s:%d')
                                    :format(bname, c.file or '?', c.line or 0))
                            end
                        end
                    elseif c.refused then
                        s_hedge(sum, ('refused (%s): %s @%s:%d'):format(
                            c.refused.rule or '?', bname or '?',
                            c.file or '?', c.line or 0))
                    elseif not c.dynamic and bname then
                        s_hedge(sum, ('unresolved: %s @%s:%d'):format(
                            bname, c.file or '?', c.line or 0))
                    else
                        s_hedge(sum, ('dynamic call @%s:%d'):format(
                            c.file or '?', c.line or 0))
                    end
                end
            end
        end
        for _, fid in ipairs(members) do sums[fid] = sum end
    end
    store._fx, store._fxgen = sums, store.generation
    return sums
end

--- Purity label of one fn: 'pure' | 'pure~' | 'writes' | 'writes~'.
function M.purity(store, fid)
    local sum = M.summaries(store)[fid]
    if not sum then return nil end
    local writes = sum.nk > 0 or sum.pwx ~= nil or sum.over
    local hedged = sum.h ~= nil or sum.over
    if writes then return hedged and 'writes~' or 'writes' end
    return hedged and 'pure~' or 'pure'
end

--- The graph's purity census: counts per label.
function M.purity_census(store)
    local counts = { pure = 0, ['pure~'] = 0, writes = 0, ['writes~'] = 0 }
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'function' or n.kind == 'method' then
            local l = M.purity(store, n.id)
            if l then counts[l] = counts[l] + 1 end
        end
    end
    return counts
end

--- Do two RESOLVED calls commute? Write-write conflicts only (reads are
--- not summarized — say so, never overclaim): 'commute' | 'conflict' |
--- 'unknown'. Set-once writes to the SAME key commute (both are the
--- absence-guarded init — order irrelevant).
function M.calls_commute(store, c1, c2)
    if not (c1 and c1.to and c2 and c2.to) then
        return 'unknown', 'unresolved call'
    end
    local sums = M.summaries(store)
    local s1, s2 = sums[c1.to], sums[c2.to]
    if not (s1 and s2) then return 'unknown', 'no summary' end
    if s1.over or s2.over or s1.h or s2.h then
        return 'unknown', (s1.h and s1.h[1]) or (s2.h and s2.h[1])
            or 'write-set overflow'
    end
    local conflicts = {}
    for key, t1 in pairs(s1.w) do
        local t2 = s2.w[key]
        if t2 and not (t1 == 3 and t2 == 3) then
            conflicts[#conflicts + 1] = key:gsub('\31', '.'):gsub('%.$', '')
        end
    end
    if s1.pwx or s2.pwx then
        return 'unknown', 'param mutation: argument aliasing not modeled'
    end
    if #conflicts > 0 then
        table.sort(conflicts)
        return 'conflict', table.concat(conflicts, ', ')
    end
    return 'commute', 'write-write clean (reads not modeled)'
end

return M
