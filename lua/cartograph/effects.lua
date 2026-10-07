-- @langs any
-- THE ANALYSIS IS GENERAL; TWO LANGUAGES ARE MODELLED IN MORE DETAIL. rw/gw/gp come
-- off the write axis and the CFG and carry no grammar. What lua and php add is
-- LITERAL TRUTHINESS — the rule that decides whether `f(x, 0)` fires a guarded
-- write — and `lang_of` below names exactly those two. Everything else gets nil,
-- which reads as 'may-write': weaker, and true. See truthy_of's warning for what
-- this looked like when the php branch was the fall-through instead.
--
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
local callrec = require 'cartograph.callrec'

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
        methods = { -- receiver-untyped (~): string methods + the WoW frame
            -- API surface (SetPoint/Fire/… — usually GAME objects: the
            -- call won't resolve in-corpus, but its EFFECT is known world)
            gsub = P, sub = P, find = P, match = P, gmatch = P, format = P,
            rep = P, upper = P, lower = P, byte = P, len = P,
            SetPoint = IO, SetScript = IO, Fire = IO, Show = IO, Hide = IO,
            SetText = IO, SetSize = IO, SetWidth = IO, SetHeight = IO,
            RegisterEvent = IO, UnregisterEvent = IO, SetShown = IO,
            ClearAllPoints = IO, EnableMouse = IO, SetAlpha = IO,
            SetParent = IO, SetFrameStrata = IO, CreateTexture = IO,
            CreateFontString = IO, SetTexture = IO, SetColorTexture = IO,
            GetName = P, GetParent = P, GetWidth = P, GetHeight = P,
            IsShown = P, IsVisible = P, GetText = P, GetPoint = P,
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
--
-- ⚠ EVERY ARM ENDS IN nil, AND IT USED TO END IN PHP (CART-0304). The lua branch
-- was an `if` and php was the FALL-THROUGH, so a language `lang_of` cannot name —
-- ruby, javascript, python, every one but two — was given PHP's falsiness. In ruby
-- `0` and `''` are TRUTHY, so `f(x, 0)` guarding a write returned 'skips': a HARD
-- claim that the write does not happen, about one that does. The unknown answer is
-- the sound one — 'may-write' costs a weaker verdict, a wrong 'skips' costs a
-- missed edge.
-- ★ LATENT, NOT LIVE, AND SAYING WHICH IS THE POINT. Measured 2026-09-20: `gp` rides
-- a var_uses edge, and the write classifier populates those for LUA ALONE today —
-- self 21763 uses / 7 with gp, ruby 0, jquery 0. So the wrong arm was UNREACHABLE
-- through the pipeline and no shipped answer was wrong. It would have fired on the
-- first day the write axis reached a second language, which is a direction this
-- tool is actively going; a defect that is only unreachable by accident is worth
-- the same fix as one that is firing.
local function truthy_of(a, lang)
    if not a then return nil end
    if a.k == 'scalar' then
        local v = a.v
        if lang == 'lua' then
            return v ~= 'false' and v ~= 'nil'
        end
        if lang == 'php' then
            -- php: false/null/0/0.0 are falsy
            return not (v == 'false' or v == 'null' or v == 'NULL'
                or tonumber(v) == 0)
        end
        return nil -- a language whose literal truthiness is not modelled here
    end
    if a.k == 'lit' then -- a string literal
        if lang == 'lua' then return true end -- every string is truthy
        if lang == 'php' then return a.v ~= '' and a.v ~= '0' end -- php's falsy strings
        return nil
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
    for _, u in ipairs(store.topo():var_uses_detail(c.to)) do
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

-- the refusal rules whose candidate lists a call's effect is JOINED over (each a premise: the target is one of them).
-- `ambiguous`: several in-tree definitions fit; `blocked` — the candidates sit across a scope fence — is a different
-- premise and stays off unless asked for
M.JOIN = { ambiguous = true }
local JOIN_ROUNDS = 30 -- passes toward the join's fixpoint (cartograph needs 9, CART-1542)

-- what a pass hands the next — everything `take` reads off a summary — as one string, to compare two passes by
local function keys_of(t)
    local ks = {}
    for k, v in pairs(t or {}) do ks[#ks + 1] = tostring(k) .. '=' .. tostring(v == true or (type(v) == 'table' and '') or v) end
    table.sort(ks)
    return table.concat(ks, ',')
end
local function signature(s)
    return table.concat({ s.nk, tostring(s.over), tostring(s.mh), tostring(s.nd), tostring(s.jp),
        s.h and s.h[1] or '', keys_of(s.w), keys_of(s.gpk), keys_of(s.pwx), keys_of(s.cpo) }, '\0')
end

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

-- is `name` a FRESH local of `fn` — defined in it, and only by statements that read nothing (a literal right side,
-- `local out = {}`)? From the dataflow rows (df.stmts: def/use per statement). Memoized per function node.
local fresh_memo = setmetatable({}, { __mode = 'k' })
local function fresh_local(fn, name)
    local m = fresh_memo[fn]
    if not m then
        m = {}
        fresh_memo[fn] = m
        local ok, stmts = pcall(require('cartograph.df').stmts, fn)
        local seen, stale = {}, {}
        for _, st in ipairs(ok and stmts or {}) do
            for _, d in ipairs(st.def or {}) do
                seen[d] = true
                if #(st.use or {}) > 0 then stale[d] = true end
            end
        end
        for d in pairs(seen) do m[d] = not stale[d] end
    end
    return m[name] == true
end

-- resolve a call argument to what a callee-side param write would hit:
-- a same-file module var ('var'), the CALLER's own param ('param'), a local
-- this call made ('fresh': no effect outside it), or nothing nameable ('opaque')
local function arg_target(store, c, i, caller)
    local a = argv.at(c, i)
    if not a then return 'opaque' end
    -- a LOCAL names the table itself; a FIELD path (`w.order`, `S[k].x`, CART-1560) names a table REACHABLE from its
    -- root, so the write lands in the root's first field (`S.list[i] = x` is recorded the same way by the extractor,
    -- with the same blind spot: no alias analysis; a bracket or unknown first field is the root's whole '' key)
    local name, field = a.name, ''
    if a.k == 'field' and name then name, field = name:match('^([^.]+)%.?(.*)$') end -- ('root.first')
    if (a.k == 'local' or a.k == 'field') and name then
        for _, n in ipairs(store.by_file[callrec.file(c)] or {}) do
            if n.kind == 'var' and n.name == name then
                return 'var', n.id .. '\31' .. field
            end
        end
        local ps = caller and caller.params
        if ps then
            for pi = 1, #ps do
                if ps[pi] == name then return 'param', pi end
            end
        end
        -- a FRESH local (CART-1494): every definition of it in this function reads nothing — `local out = {}` — so it
        -- holds a table made by this call (or an immutable literal) and a write into it is the call's own business.
        -- It can still ESCAPE (stored into module state, handed to a storing callee), but that store is a write of
        -- its own and recorded as one. core's M.keys sorting its own `out` made eq, show and 7 more basis fns `~`.
        -- (never for a FIELD of one: `w.order = p` stores the caller's table into a fresh `w` without defining `w`)
        if a.k == 'local' and caller and fresh_local(caller, a.name) then return 'fresh' end
        return 'opaque' -- a plain local: mutation invisible outside — but
        -- it MAY alias module state; the caller hedges (no alias analysis)
    end
    if a.k == 'scalar' or a.k == 'lit' then return 'value' end -- immutable
    if a.k == 'ctor' then return 'fresh' end -- (`{ … }`: made by the argument list, CART-1547)
    return 'opaque'
end

local VERDICT_TIER = { ['writes-once'] = 3, ['writes-guarded'] = 2,
    ['may-write'] = 2, writes = 1 }

-- world effects ride a pseudo-var key: every conflict/tier machinery
-- (commute, min-merge) treats world-order like state-order for free
local IOKEY = '\1io\31'
M.IOKEY = IOKEY

-- ── HIGHER-ORDER THROUGH A PARAMETER (CART-1495) ──────────────────────────
-- A call `k(x)` where k is a PARAMETER (the resolver's `higher-order` refusal, which names the parameter's OWNER fn
-- and its index) runs whatever a call to the owner passes there. It is a PENDING PAIR (owner, j) in the summary, not
-- a hedge; it travels up through nested closures, and at every CALL TO THE OWNER it is substituted with that call's
-- argument j: an inline function or a named one (its summary inherited), the caller's own parameter (a new pair), a
-- member of the same component (already in the shared summary), else a named hedge. A pair still pending makes the
-- function hedged: it is as pure as what it is handed. (The matcher's CPS `go(…, k)` hedged every basis function
-- that matches: "refused (higher-order): k @match.lua:231".)
local function cp_add(sum, owner, j)
    sum.cpo = sum.cpo or {}
    sum.cpo[owner .. '\0' .. j] = { owner = owner, j = j }
end
-- the TIERS a summary hands whatever folds it in, beside its writes: the overflow, its first hedge, the name-matched
-- method tier, nondet, the join premise. EVERY path folding one summary into another goes through here — a resolved
-- callee, a callback, a substituted pair — because each path that copied them by hand dropped some (CART-1543,
-- CART-1558: oracle.lua's `stop` read plain pure over a joined pcall callback)
local function tiers(sum, ts)
    if ts.over then sum.over = true end
    if ts.h then s_hedge(sum, ts.h[1]) end
    if ts.mh then sum.mh = true end
    if ts.nd then sum.nd = true end
    if ts.jp then sum.jp = true end
end
-- a callee or callback summary folded into `sum`
local function inherit(sum, ts)
    tiers(sum, ts)
    for key, tier in pairs(ts.w) do s_add(sum, key, tier) end
    if ts.pwx then s_hedge(sum, 'a function handed in as an argument mutates its params') end
    for k, p in pairs(ts.cpo or {}) do sum.cpo = sum.cpo or {}; sum.cpo[k] = p end
end
-- the PARAMETER `name` refers to inside `caller`: its own (caller, index), or — when the caller neither declares nor
-- defines it (a closure passing on a captured `k`) — the innermost ENCLOSING function's, by range in the same file
local function param_of(store, caller, name)
    for pi, p in ipairs(caller.params or {}) do if p == name then return caller.id, pi end end
    local ok, stmts = pcall(require('cartograph.df').stmts, caller)
    for _, st in ipairs(ok and stmts or {}) do
        for _, d in ipairs(st.def or {}) do if d == name then return nil end end -- (a local of its own)
    end
    if not caller.range then return nil end
    local at = require 'cartograph.at'
    local cs, ce = at.sl(caller.range), at.el(caller.range)
    local best, bi, bsz
    for _, f in ipairs(store.by_file[caller.file] or {}) do
        if f ~= caller and (f.kind == 'function' or f.kind == 'method') and f.range then
            local fs, fe = at.sl(f.range), at.el(f.range)
            if fs <= cs and ce <= fe and (not bsz or fe - fs < bsz) then
                for pi, p in ipairs(f.params or {}) do
                    if p == name then best, bi, bsz = f, pi, fe - fs end
                end
            end
        end
    end
    if best then return best.id, bi end
end
-- substitute argument j of call `c` (made by `caller`) for a pending pair owned by the callee
local function subst(store, sums, sum, c, caller, j, tname, member)
    if callrec.method(c) then
        s_hedge(sum, ('calls parameter %d of method %s @%s:%d'):format(j, tname, callrec.file(c) or '?', callrec.line(c) or 0))
        return
    end
    local a = argv.at(c, j)
    if not a or a.k == 'lit' or a.k == 'scalar' then return end -- (nothing or a value: calling it raises, no write)
    local target = a.to
    if not target and (a.k == 'local' or a.k == 'callable') and a.name then
        local owner, pi = nil, nil
        if caller then owner, pi = param_of(store, caller, a.name) end
        if owner then cp_add(sum, owner, pi); return end -- (handing on a parameter: the pair moves to its owner)
        for _, fn2 in ipairs(store.by_file[callrec.file(c)] or {}) do
            if (fn2.kind == 'function' or fn2.kind == 'method') and fn2.name == a.name then target = fn2.id; break end
        end
    end
    if target and member(target) then return end -- (its effects are this component's own)
    local ts = target and sums[target]
    if ts then inherit(sum, ts); return end
    s_hedge(sum, ('calls parameter %d of %s with an unknown function @%s:%d')
        :format(j, tname, callrec.file(c) or '?', callrec.line(c) or 0))
end

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
    -- an INLINE callback (`table.sort(out, function (a, b) … end)`, its argv `to` = the minted `sort#cb` node) is no
    -- call edge of its enclosing function, so the condensation could summarize the function BEFORE the callback and
    -- hedge "callback effects unknown" (CART-1494). Order them: the callback is a successor of the function.
    local extra = {}
    for _, c in ipairs(store.data.calls or {}) do
        local fn = callrec.fn(c)
        if fn then
            for ai = 1, argv.n(c) do
                local a = argv.at(c, ai)
                if a and a.k == 'func' and a.to then
                    local l = extra[fn]; if not l then l = {}; extra[fn] = l end
                    l[#l + 1] = a.to
                end
            end
        end
    end
    local adj = store.uses
    if next(extra) then
        local base, memo = store.uses, {}
        adj = setmetatable({}, { __index = function (_, v)
            if memo[v] ~= nil then return memo[v] or nil end
            local u, x = base[v], extra[v]
            local out = u
            if x then
                out = {}
                for _, w in ipairs(u or {}) do out[#out + 1] = w end
                for _, w in ipairs(x) do out[#out + 1] = w end
            end
            memo[v] = out or false
            return out
        end })
    end
    local con = scc.condense(adj, ids)
    -- ONE pass over the condensation, callees first. A JOINED call's candidates are no call edges (ordering by them
    -- would merge every cycle through an ambiguous name into one component — 1674 functions sharing a summary on
    -- this repo), so a candidate may not be summarized yet when its call is reached: the pass takes the PREVIOUS
    -- pass's summary (nothing in the first) and marks itself STALE, and passes repeat to the least fixpoint — the
    -- summaries a pass reads equal the ones it writes. Every effect only grows from pass to pass (union, from
    -- nothing). Past JOIN_ROUNDS a last pass hedges such a join instead: never an answer that is not a fixpoint.
    -- A later pass RECOMPUTES only a component that read a summary which is not the one it read last time (CART-1544):
    -- reads go through a view that records them, and a recomputed summary equal to its previous one keeps that
    -- object, so an unchanged component stays unchanged for everything that reads it. The fixpoint is the pass
    -- that recomputes nothing into something new
    local sums, stale, changed, computed
    local deps = {} -- component -> { [id] = the summary it read, the previous pass's for a join; false: none }
    local function pass(prev)
        local real, reads = {}, nil
        sums = setmetatable({}, { __newindex = real, __index = function (_, k)
            local v = real[k]
            if reads then reads[k] = v or (prev and prev[k]) or false end
            return v
        end })
        stale, changed, computed = false, 0, 0
        for ci = 1, con.n do
            local members = con.members[ci]
            local was = prev and prev[members[1]]
            local dep = was and deps[ci]
            if dep then
                for x, v in pairs(dep) do
                    if (real[x] or prev[x] or false) ~= v then dep = nil; break end
                end
                if dep then -- (every summary it read is the one it read last time: so is its own)
                    for _, fid in ipairs(members) do real[fid] = was end
                    goto reused
                end
            end
            reads = {}
            deps[ci] = reads
            computed = computed + 1
            local sum = { w = {}, nk = 0 }
            -- DIRECT effects of every member
            for _, fid in ipairs(members) do
                local fnode = store.node(fid)
                for _, u in ipairs(store.topo():var_uses_detail(fid)) do
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
            local intra = {} -- (calls between members: their pending pairs are substituted once the summary is whole)
            local function member(id) return con.comp[id] == ci end
            -- callee `to`'s summary, taken at call `c` of `caller`: its writes (a gp write discharged per site), the params
            -- it mutates mapped to what WE passed, its pending pairs substituted, and its TIERS — over, the hedge, the
            -- name-matched method tier, nondet, the join premise — travel with it
            local function take(c, caller, to, cs)
                cs = cs or sums[to]
                tiers(sum, cs)
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
                            s_add(sum, x, 1)
                        elseif kind == 'param' then
                            sum.pwx = sum.pwx or {}
                            sum.pwx[x] = true
                        elseif kind == 'opaque' then
                            s_hedge(sum, ('param-mutation via opaque arg -> %s @%s:%d')
                                :format(tn and tn.name or to, callrec.file(c) or '?', callrec.line(c) or 0))
                        end
                    end
                end
                -- the callee calls ITS parameter j: what did WE pass there? (an outer owner's pair travels on)
                for _, p in pairs(cs.cpo or {}) do
                    if p.owner == to then subst(store, sums, sum, c, caller, p.j, tn and tn.name or to, member)
                    else cp_add(sum, p.owner, p.j) end
                end
            end
            -- an AMBIGUOUS call's effect, when the resolver kept every candidate: the JOIN of theirs (a may-analysis — a
            -- write any candidate makes is one the call may make). It rests on a PREMISE, that the target is one of them
            -- (a receiver the tree does not define — a vim handle's :close() — breaks it): the summary carries `jp`, which
            -- purity renders `~` and calls_commute will not decide on. A candidate not summarized yet (no call edge
            -- orders it first) keeps the hedge; a candidate in this component adds nothing it does not already share
            local function join(c, caller, r)
                if not (M.JOIN[r.rule] and r.cands and r.n and #r.cands == r.n) then return false end
                local whole = true
                for _, id in ipairs(r.cands) do
                    if member(id) then intra[#intra + 1] = { c = c, caller = caller, to = id } -- (its effects are this component's own; its pending pairs are substituted with the rest)
                    elseif sums[id] then take(c, caller, id)
                    elseif prev then -- (not summarized yet in this pass: the previous pass's, or nothing in the first)
                        stale = true
                        if prev[id] then take(c, caller, id, prev[id]) end
                    else whole = false end
                end
                if whole then sum.jp = true end
                M.join_stats[whole and 'whole' or 'cut'] = M.join_stats[whole and 'whole' or 'cut'] + 1
                return whole
            end
            for _, fid in ipairs(members) do
                local caller = store.node(fid)
                local file = caller and caller.file
                for _, c in ipairs(store.topo():sites(fid)) do
                    local to = callrec.to(c)
                    if to and con.comp[to] == ci then
                        -- intra-SCC: members share this summary already
                        intra[#intra + 1] = { c = c, caller = caller, to = to }
                    elseif to and sums[to] then
                        take(c, caller, to)
                    elseif to then
                        s_hedge(sum, ('callee outside the fn graph: %s'):format(to))
                    else
                        local lang = file and (file:match('%.lua$') and 'lua'
                            or file:match('%.php$') and 'php')
                        local bname = callrec.full(c) or callrec.callee(c)
                        local sig, grade
                        if lang and bname then
                            -- (explicit call: and/or would truncate the
                            -- second return — the grade)
                            sig, grade = M.sig_of(lang, bname, callrec.method(c))
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
                                    s_add(sum, x, 1)
                                elseif kind == 'param' then
                                    sum.pwx = sum.pwx or {}
                                    sum.pwx[x] = true
                                elseif kind == 'opaque' then
                                    s_hedge(sum, ('%s on opaque arg @%s:%d')
                                        :format(bname, callrec.file(c) or '?', callrec.line(c) or 0))
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
                                    for _, fn2 in ipairs(store.by_file[callrec.file(c)] or {}) do
                                        if (fn2.kind == 'function' or fn2.kind == 'method')
                                            and fn2.name == a.name then
                                            target = fn2.id
                                            break
                                        end
                                    end
                                end
                                local ts2 = target and sums[target]
                                if ts2 then
                                    tiers(sum, ts2)
                                    for key, tier in pairs(ts2.w) do
                                        s_add(sum, key, tier)
                                    end
                                    if ts2.pwx then
                                        s_hedge(sum, ('callback %s mutates its params @%s:%d')
                                            :format(a.name or '?', callrec.file(c) or '?', callrec.line(c) or 0))
                                    end
                                    -- (a callback calling a parameter of an enclosing function: still pending here)
                                    for _, p in pairs(ts2.cpo or {}) do cp_add(sum, p.owner, p.j) end
                                elseif a then
                                    s_hedge(sum, ('%s: callback effects unknown @%s:%d')
                                        :format(bname, callrec.file(c) or '?', callrec.line(c) or 0))
                                end
                            end
                            -- sig.pure / sig.reads / sig.returns_arg: no hedge,
                            -- no effect (reads/aliasing land with their consumers)
                        elseif c.refused and c.refused.rule == 'higher-order' and c.refused.owner and c.refused.param then
                            cp_add(sum, c.refused.owner, c.refused.param) -- (a call through a parameter: pending, CART-1495)
                        elseif c.refused and join(c, caller, c.refused) then
                            -- (every candidate taken: the call's effect is their join, under the premise `jp`)
                        elseif c.refused then
                            s_hedge(sum, ('refused (%s): %s @%s:%d'):format(
                                c.refused.rule or '?', bname or '?',
                                callrec.file(c) or '?', callrec.line(c) or 0))
                        elseif not c.dynamic and bname then
                            s_hedge(sum, ('unresolved: %s @%s:%d'):format(
                                bname, callrec.file(c) or '?', callrec.line(c) or 0))
                        else
                            s_hedge(sum, ('dynamic call @%s:%d'):format(
                                callrec.file(c) or '?', callrec.line(c) or 0))
                        end
                    end
                end
            end
            -- a member calling a member: substitute its pending pairs, until no new pair appears
            local done = {}
            for _ = 1, 50 do
                local todo = {}
                for _, x in ipairs(intra) do
                    for key, p in pairs(sum.cpo or {}) do
                        if p.owner == x.to and not done[x] then done[x] = {} end
                        if p.owner == x.to and not done[x][key] then done[x][key] = true; todo[#todo + 1] = { x = x, p = p } end
                    end
                end
                if #todo == 0 then break end
                for _, t in ipairs(todo) do
                    local tn = store.node(t.x.to)
                    subst(store, sums, sum, t.x.c, t.x.caller, t.p.j, tn and tn.name or t.x.to, member)
                end
            end
            reads = nil
            -- an OVERFLOWED summary is "many writes" and keeps NO keys: which CAP of them survived would depend on the
            -- order they arrived in (`pairs` over a callee's set), and a summary that differed run to run made the
            -- join's fixpoint nondeterministic — 109 of cartograph's, CART-1545. purity reads `over` as writes,
            -- calls_commute as unknown
            if sum.over then sum.w, sum.nk, sum.gpk = {}, 0, nil end
            if was and signature(sum) == signature(was) then sum = was else changed = changed + 1 end
            for _, fid in ipairs(members) do real[fid] = sum end
            ::reused::
        end
        return real
    end
    local prev = {}
    M.join_stats = { rounds = 0, computed = 0 }
    for round = 1, JOIN_ROUNDS + 1 do
        local js = M.join_stats
        M.join_stats = { rounds = round, whole = 0, cut = 0, computed = js.computed, changed = js.changed or {} }
        prev = pass(round <= JOIN_ROUNDS and prev or nil)
        M.join_stats.computed = M.join_stats.computed + computed
        M.join_stats.changed[round] = changed -- (components recomputed into something new, per pass: a tail or a cycle)
        if not stale or (round > 1 and changed == 0) then break end
    end
    sums = prev
    store._fx, store._fxgen = sums, store.generation
    return sums
end

--- ONE call's effect slice, for statement-level attribution (the reorder
--- report): the callee's summary with the caller's per-site gp discharge,
--- or the signature registry for unresolved callees. Returns
--- { w = {key->tier}, hedges = {...}|nil } (w includes the IOKEY row).
function M.call_effects(store, c, caller_file)
    local out = { w = {} }
    local function hedge(why)
        out.hedges = out.hedges or {}
        out.hedges[#out.hedges + 1] = why
    end
    local to = c.to
    if to then
        local cs = M.summaries(store)[to]
        if not cs then
            hedge('callee outside the fn graph')
            return out
        end
        if cs.over then hedge('write-set overflow in callee') end
        if cs.h then hedge(cs.h[1]) end
        -- (the summary's PREMISES are hedges of this slice too, CART-1558)
        if cs.mh then hedge('a method matched to a builtin by name') end
        if cs.jp then hedge('an ambiguous call joined over its candidates') end
        local tn = store.node(to)
        for key, tier in pairs(cs.w) do
            local gp = cs.gpk and cs.gpk[key]
            if gp then
                local v = M.verdict({ rw = 2, gw = tier, gp = gp }, c,
                    tn and tn.file)
                if v ~= 'skips' then
                    out.w[key] = VERDICT_TIER[v] or tier
                end
            else
                out.w[key] = tier
            end
        end
        if cs.pwx then hedge('callee mutates its params (aliasing unmodeled)') end
        return out
    end
    local lang = caller_file and (caller_file:match('%.lua$') and 'lua'
        or caller_file:match('%.php$') and 'php')
    local bname = c.full or callrec.callee(c)
    local sig
    if lang and bname then sig = M.sig_of(lang, bname, c.method) end
    if sig then
        if sig.io then out.w[IOKEY] = 1 end
        if sig.w then hedge(('%s writes its args (targets unattributed here)')
            :format(bname)) end
        if sig.calls then hedge(('%s invokes a callback'):format(bname)) end
        -- pure: no effect, no hedge
    elseif c.refused then
        hedge(('refused (%s): %s'):format(c.refused.rule or '?', bname or '?'))
    else
        hedge(('unresolved: %s'):format(bname or 'dynamic call'))
    end
    return out
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
    local hedged = sum.h ~= nil or sum.over or sum.mh or sum.jp
        or (sum.cpo ~= nil and next(sum.cpo) ~= nil) -- (calls a function it is handed: as pure as that, CART-1495)
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
    -- (a conflict found under a premise is one; a clean answer resting on one is not decided — the join's, or the
    -- method~ tier's: a builtin matched by NAME, `s:gsub`, is a user table's own method when the receiver is one)
    if s1.jp or s2.jp then
        return 'unknown', 'an ambiguous call joined over its candidates: the target is assumed to be one of them'
    end
    if s1.mh or s2.mh then
        return 'unknown', 'a method matched to a builtin by name: the receiver is assumed to be the builtin\'s'
    end
    return 'commute', 'write-write clean (reads not modeled)'
end

return M
