-- BINDING-TIMES (discovery, CART-1445): mix's BTA as a question — "given these parameters known, what is static?" — and
-- its sharpest use: WHICH PARAMETERS THE RESULT DEPENDS ON. One BTA per parameter, that one dynamic and the rest
-- static: a result still static does not depend on it, so a memo needs no key for it (memoize `key`). One more with
-- every parameter static: a result still dynamic reads something OUTSIDE its parameters (a global, a module local,
-- an effect) — then no memo keyed by parameters alone is sound.
-- SOUND ONE WAY: BTA is conservative, so "independent" is a proof (over the lowered program) and "depends" may be a
-- false alarm. The function is lowered ALONE (cartograph.mixfn): a helper it calls is a free name, so `outside` is
-- the usual answer for real code that calls helpers — it says what could not be proven, not that state is read.
-- Value: { params, known, vars = { name = S | C | D } under `known`, result, depends = { name = bool }, key, outside }.
-- CLAIM: the result depends on FEWER than all its parameters and on nothing outside them.
local F = require 'cartograph.mixfn'

local function measure(store, p)
    local prog, params, entry, how = F.lower_ref(store, p.ref)
    if not prog then return { error = tostring(params) } end
    local MX = require 'cartograph.mix'
    local known = {}
    for _, k in ipairs(p.known or {}) do known[k] = true end
    for k in pairs(known) do
        if not vim.tbl_contains(params, k) then return { error = ('known = %s: no such parameter (it takes: %s)'):format(k, table.concat(params, ', ')) } end
    end
    local function bta(div)
        local ok, bt = pcall(MX.bta, prog, entry, div, { globals = how.knowns, prims = how.prims })
        if not ok then error(F.why(bt), 0) end
        return bt
    end
    local okall, err = pcall(function ()
        local div = {}
        for i, n in ipairs(params) do div[i] = known[n] and 'S' or 'D' end
        local bt = bta(div)
        local vars, seen = {}, {}
        for id, b in pairs(bt) do
            local name = type(id) ~= 'table' and prog.names[id]
            if name then
                local k = seen[name] and (name .. '@' .. tostring(id)) or name
                seen[name] = true
                vars[k] = b
            end
        end
        local result = F.result_bt(prog, bt, entry)
        local depends, key = {}, {}
        for i, n in ipairs(params) do
            local d = {}
            for j = 1, #params do d[j] = j == i and 'D' or 'S' end
            depends[n] = F.result_bt(prog, bta(d), entry) ~= 'S'
            if depends[n] then key[#key + 1] = n end
        end
        local all = {}
        for j = 1, #params do all[j] = 'S' end
        local outside = F.result_bt(prog, bta(all), entry) ~= 'S'
        return { params = params, known = p.known or {}, vars = vars, result = result, depends = depends, key = key, outside = outside,
            cone = how.cone, members = how.members, cone_why = how.why }
    end)
    if not okall then return { error = tostring(err) } end
    return err
end

local E = {
    name = 'binding-times',
    kind = 'discovery',
    tags = { 'code', 'optimize' },
    measures = 'CART-1445',
    summary = 'mix\'s binding-time analysis as a question, for one Lua function (ref = file::name): with `known` parameters static, each variable\'s binding time (S / C / D), and which parameters the RESULT depends on — a memo needs no key for the rest; `outside` = it reads something besides its parameters (or calls a helper: the function is lowered alone)',
    params = { ref = 'ref', known = 'list?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        if v.outside then return false, 'the result reads something outside its parameters (a global, a module local, a helper it calls): no memo keyed by parameters alone is sound' end
        if #v.key == #v.params then return false, ('the result depends on every parameter (%s)'):format(table.concat(v.params, ', ')) end
        return true, ('the result depends on %s of (%s)'):format(#v.key > 0 and table.concat(v.key, ', ') or 'none', table.concat(v.params, ', '))
    end,
}

local SRC = table.concat({
    'local M = {}',
    'function M.area(w, h, unit)',
    '  local a = w * h',
    '  local label = unit .. "2"',
    '  return a',
    'end',
    'function M.pick(k) return CONFIG[k] end',
    'function M.both(a, b) if a > 0 then return b end return 0 end',
    'local function scale(x) return x * 2 end',
    'function M.twice(a, b) return scale(a) end',
    'return M', '' }, '\n')

E.examples = {
    {
        name = 'the result does not depend on `unit` (only a dead local reads it): the memo key is (w, h); with w known, `a` is still dynamic',
        files = { ['m.lua'] = SRC },
        params = { ref = 'm.lua::M.area', known = 'w' },
        expect = { holds = true, check = function (v)
            return vim.deep_equal(v.key, { 'w', 'h' }) and v.depends.unit == false and v.vars.w == 'S' and v.vars.a == 'D'
                and v.vars.label == 'D' and not v.outside, vim.inspect(v)
        end },
    },
    {
        name = 'a result read from a GLOBAL is outside the parameters: no parameter key is sound, the claim fails by name',
        files = { ['m.lua'] = SRC },
        params = { ref = 'm.lua::M.pick' },
        expect = { holds = false, check = function (v) return v.outside == true, vim.inspect(v) end },
    },
    {
        name = 'a module-local HELPER is code, not a free name: lowered with its call cone, the result depends on `a` only',
        files = { ['m.lua'] = SRC },
        params = { ref = 'm.lua::M.twice' },
        expect = { holds = true, check = function (v)
            return v.cone == true and v.members == 2 and vim.deep_equal(v.key, { 'a' }) and not v.outside, vim.inspect(v)
        end },
    },
    {
        name = 'a return under a condition on `a` depends on `a` as well as on `b`: CONTROL counts, not only data',
        files = { ['m.lua'] = SRC },
        params = { ref = 'm.lua::M.both' },
        expect = { holds = false, check = function (v) return vim.deep_equal(v.key, { 'a', 'b' }), vim.inspect(v) end },
    },
}

return E
