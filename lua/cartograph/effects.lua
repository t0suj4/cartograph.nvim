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

return M
