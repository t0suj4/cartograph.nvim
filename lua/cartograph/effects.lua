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

-- EFFECT-SIGNATURE REGISTRY: contracts for callees resolution can never
-- see inside (stdlib, runtime APIs) — without them every table.insert /
-- math.floor is an honest-but-useless hedge in the purity fixpoint.
-- Vocabulary per signature (absence of a signature = UNKNOWN, never pure):
--   pure = true      no module-state or world effect
--   w = {i,...}      writes its 1-based args (through references)
--   calls = {i,...}  HIGHER-ORDER: invokes its args — the passed fn's
--                    summary is inherited at the site (pcall costs what
--                    its argument costs)
--   io = true        writes the WORLD (editor/game/files) — modeled as a
--                    write to the '\1io' pseudo-var so commute/ordering
--                    machinery treats world-order for free
--   nondet = true    effect-free but not referentially transparent
--                    (os.time, math.random) — matters for idempotence
--   reads = {i,...} / returns_arg = i   parsed, INERT in v1 (read
--                    modeling and aliasing land with their consumers)
-- THREE TIERS, per the hedge census (2026-07-11):
--   exact/prefix     shipped packs, curated where the documentation lives
--   methods          receiver-untyped method names (~): s:gsub, no callee
--                    table reaches these — name-matched honesty
--   asserted         config.effects (user contracts): APPLIED but every
--                    use also HEDGES with the assertion named — user
--                    knowledge is unreliable; claims through assertions
--                    stay visibly conditional
local P = { pure = true }
local IO = { io = true }
local ND = { pure = true, nondet = true }
M.SIGS = {
    lua = {
        exact = {
            -- language core
            pairs = P, ipairs = P, next = P, type = P, tostring = P,
            tonumber = P, select = P, rawget = P, rawequal = P, rawlen = P,
            unpack = P, error = P, assert = P, getmetatable = P,
            rawset = { w = { 1 } }, setmetatable = { w = { 1 }, returns_arg = 1 },
            pcall = { calls = { 1 } }, xpcall = { calls = { 1 } },
            print = IO, require = IO, collectgarbage = IO,
            ['math.random'] = ND, ['math.randomseed'] = IO,
            ['os.time'] = ND, ['os.clock'] = ND, ['os.date'] = ND,
            ['os.getenv'] = ND,
            ['table.insert'] = { w = { 1 } }, ['table.remove'] = { w = { 1 } },
            ['table.sort'] = { w = { 1 }, calls = { 2 } },
            ['table.move'] = { w = { 5 } }, ['table.concat'] = P,
            ['table.unpack'] = P,
            ['string.gsub'] = { calls = { 3 } }, -- repl may be a fn; strings/tables pure
            ['coroutine.wrap'] = { calls = { 1 } },
            ['coroutine.create'] = { calls = { 1 } },
            -- WoW's documented global ALIASES (the census's "opaque" bucket)
            tinsert = { w = { 1 } }, tremove = { w = { 1 } }, wipe = { w = { 1 } },
            strsub = P, strlen = P, strfind = P, strlower = P, strupper = P,
            strsplit = P, strjoin = P, format = P, gsub = P, strmatch = P,
            getglobal = P, tostringall = P,
        },
        prefix = {
            ['math.'] = P, ['string.'] = P, ['bit.'] = P,
            ['io.'] = IO, ['os.'] = IO, -- os.* not listed above: world
            ['vim.api.'] = IO, ['vim.fn.'] = IO, ['vim.uv.'] = IO,
            ['vim.cmd'] = IO, ['vim.notify'] = IO, ['vim.schedule'] = { calls = { 1 } },
            ['vim.inspect'] = P, ['vim.deepcopy'] = P, ['vim.split'] = P,
            ['vim.tbl_'] = P, ['vim.startswith'] = P, ['vim.endswith'] = P,
            ['vim.treesitter.'] = P, -- parse allocates, mutates nothing of ours
            ['vim.json.'] = P, ['vim.mpack.'] = P,
            -- game runtimes (the user's real targets)
            ['game.'] = IO, ['script.'] = IO, ['rendering.'] = IO, -- factorio
            ['Map.'] = IO, ['Game.'] = IO,                          -- desynced
            ['C_'] = IO,                                            -- wow C_*
        },
        methods = { -- receiver-untyped (~): overwhelmingly string methods
            gsub = P, sub = P, find = P, match = P, gmatch = P, format = P,
            rep = P, upper = P, lower = P, byte = P, len = P,
        },
    },
    php = {
        exact = {
            sort = { w = { 1 } }, rsort = { w = { 1 } }, usort = { w = { 1 }, calls = { 2 } },
            ksort = { w = { 1 } }, asort = { w = { 1 } }, arsort = { w = { 1 } },
            array_push = { w = { 1 } }, array_pop = { w = { 1 } },
            array_shift = { w = { 1 } }, array_unshift = { w = { 1 } },
            array_splice = { w = { 1 } }, settype = { w = { 1 } },
            preg_match = { w = { 3 } }, preg_match_all = { w = { 3 } },
            array_map = { calls = { 1 } }, array_filter = { calls = { 2 } },
            array_walk = { w = { 1 }, calls = { 2 } },
            call_user_func = { calls = { 1 } },
            strlen = P, substr = P, str_replace = P, implode = P, explode = P,
            sprintf = P, count = P, in_array = P, array_keys = P,
            array_values = P, array_merge = P, trim = P, strtolower = P,
            strtoupper = P, intval = P, is_array = P, is_string = P,
            is_numeric = P, isset = P, json_encode = P, json_decode = P,
            time = ND, rand = ND, mt_rand = ND,
            echo = IO, printf = IO, file_get_contents = IO,
            file_put_contents = IO, fopen = IO, fwrite = IO,
        },
        prefix = {},
        methods = {},
    },
}

-- signature lookup: exact → prefix (longest wins not needed; families are
-- disjoint) → method tier (~, only for method-style calls)
function M.sig_of(lang, name, is_method)
    local sl = M.SIGS[lang]
    if not sl or not name then return nil end
    if is_method then
        -- method calls consult the METHOD tier first: an exact entry is a
        -- contract for the GLOBAL of that name (WoW's gsub alias), not for
        -- an arbitrary receiver — the ~ grade must not be laundered away
        local last = name:match('([%w_]+)$')
        local ms = last and sl.methods[last]
        if ms then return ms, 'method~' end
        return nil
    end
    local sig = sl.exact[name]
    if sig then return sig end
    for p, ps in pairs(sl.prefix) do
        if name:sub(1, #p) == p then return ps end
    end
    return nil
end

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

-- world effects ride a pseudo-var key: every conflict/tier machinery
-- (commute, min-merge) treats world-order like state-order for free
local IOKEY = '\1io\31'

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
                    local sig, grade
                    if lang and bname then
                        -- (explicit call: and/or would truncate the
                        -- second return — the grade)
                        sig, grade = M.sig_of(lang, bname, c.method)
                    end
                    local asserted
                    if not sig and bname then
                        local ue = require('cartograph.config').effects
                        sig = ue and ue[bname] or nil
                        asserted = sig ~= nil
                    end
                    if sig then
                        -- apply the contract, at its honesty grade
                        if asserted then
                            s_hedge(sum, ('asserted contract: %s'):format(bname))
                        elseif grade == 'method~' then
                            sum.mh = true -- name-matched method tier (~)
                        end
                        if sig.io then s_add(sum, IOKEY, 1) end
                        if sig.nondet then sum.nd = true end
                        for _, ai in ipairs(sig.w or {}) do
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
                        -- HIGHER-ORDER: the passed fn's summary is this
                        -- call's effect. a.to = the callback upgrade's
                        -- resolved target (resolution already did the work)
                        for _, ai in ipairs(sig.calls or {}) do
                            local a = argv.at(c, ai)
                            local target = a and a.to
                            if not target and a
                                and (a.k == 'local' or a.k == 'callable')
                                and a.name then
                                for _, fn2 in ipairs(store.by_file[c.file] or {}) do
                                    if (fn2.kind == 'function' or fn2.kind == 'method')
                                        and fn2.name == a.name then
                                        target = fn2.id
                                        break
                                    end
                                end
                            end
                            local ts2 = target and sums[target]
                            if ts2 then
                                if ts2.over then sum.over = true end
                                if ts2.h then s_hedge(sum, ts2.h[1]) end
                                if ts2.nd then sum.nd = true end
                                for key, tier in pairs(ts2.w) do
                                    s_add(sum, key, tier)
                                end
                                if ts2.pwx then
                                    s_hedge(sum, ('callback %s mutates its params @%s:%d')
                                        :format(a.name or '?', c.file or '?', c.line or 0))
                                end
                            elseif a then
                                s_hedge(sum, ('%s: callback effects unknown @%s:%d')
                                    :format(bname, c.file or '?', c.line or 0))
                            end
                        end
                        -- sig.pure / sig.reads / sig.returns_arg: no hedge,
                        -- no effect (reads/aliasing land with their consumers)
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

--- Purity label: 'pure' | 'io' (world-only effects) | 'writes' (module
--- state), each with a '~' variant (hedges, overflow, or the ~ method
--- tier). io < writes: a fn that writes state AND world reads 'writes'.
function M.purity(store, fid)
    local sum = M.summaries(store)[fid]
    if not sum then return nil end
    local wmod = sum.over or sum.pwx ~= nil
    if not wmod and sum.nk > 0 then
        for key in pairs(sum.w) do
            if key ~= IOKEY then wmod = true break end
        end
    end
    local world = sum.w[IOKEY] ~= nil
    local hedged = sum.h ~= nil or sum.over or sum.mh
    local base = wmod and 'writes' or world and 'io' or 'pure'
    return hedged and (base .. '~') or base
end

--- The graph's purity census: counts per label.
function M.purity_census(store)
    local counts = { pure = 0, ['pure~'] = 0, io = 0, ['io~'] = 0,
        writes = 0, ['writes~'] = 0 }
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
            conflicts[#conflicts + 1] = key == IOKEY and '(world order)'
                or key:gsub('\31', '.'):gsub('%.$', '')
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
