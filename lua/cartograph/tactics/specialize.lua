-- SPECIALIZE (discovery, CART-1445): ANY Lua function of the graph specialized to some of its arguments, and the
-- residual ACCEPTED — the pipeline compile_match runs for the matcher, as pieces over one function:
--     mixfn.lower_ref -> mix.specialize (BTA inside) -> mix.print -> load -> accept against mix.run (the original, by
--     mix's own evaluator) on the samples
-- `statics` = JSON object { param = value } (the known arguments; JSON null = nil), `samples` = JSON list of the
-- DYNAMIC arguments, one list per call, in parameter order. The answer is the residual text (a function of the dynamic
-- parameters), the specializer's stats, and per sample the original's value and the residual's — the generalized
-- acceptance (compiledverb.accept is the matcher's). A refusal is mix's LOCATED one (mix.describe).
-- CLAIM: mix specialized it and the residual equals the original on every sample (at least one).
local F = require 'cartograph.mixfn'

local function decode(s, what)
    if s == nil then return nil end
    local ok, v = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
    if not ok then return nil, ('%s is not JSON: %s'):format(what, tostring(v)) end
    return v
end

local function measure(store, p)
    local prog, params, entry, how = F.lower_ref(store, p.ref)
    if not prog then return { error = tostring(params) } end
    local statics, swhy = decode(p.statics or '{}', 'statics')
    if not statics then return { error = swhy } end
    local samples, pwhy = decode(p.samples or '[]', 'samples')
    if not samples then return { error = pwhy } end
    local MX = require 'cartograph.mix'
    local division, svals, dyn = {}, {}, {}
    for i, n in ipairs(params) do
        if statics[n] ~= nil or (p.statics or ''):find('"' .. n .. '"%s*:%s*null') then division[i], svals[i] = 'S', statics[n]
        else division[i] = 'D'; dyn[#dyn + 1] = i end
    end
    for k in pairs(statics) do
        if not vim.tbl_contains(params, k) then return { error = ('statics: no parameter `%s` (it takes: %s)'):format(k, table.concat(params, ', ')) } end
    end
    local oks, res, stats = pcall(MX.specialize, prog, entry, division, svals, { budget = tonumber(p.budget or 2e6), globals = how.knowns, prims = how.prims })
    if not oks then return { error = 'mix refused: ' .. F.why(res), refused = true } end
    local text, map = MX.print(res, prog.where)
    local okl, f = pcall(function () return assert(load(text, 'residual', 't', F.env(res.pool, how.knowns)))() end)
    if not okl then return { error = 'the residual does not load: ' .. tostring(f), text = text } end
    local rows, ok = {}, true
    for si, d in ipairs(samples) do
        local full = {}
        for i = 1, #params do full[i] = svals[i] end
        for j, i in ipairs(dyn) do full[i] = d[j] end
        local okw, want = pcall(MX.run, prog, entry, full, tonumber(p.budget or 2e6))
        local okg, got = pcall(f, unpack(d, 1, #dyn))
        local same = okw and okg and vim.deep_equal(want, got)
        if not same then ok = false end
        rows[si] = { sample = d, original = okw and want or ('raised: ' .. F.why(want)), residual = okg and got or ('raised: ' .. MX.translate(tostring(got), map)), same = same }
    end
    return { text = text, stats = stats, division = division, samples = rows, accepted = ok and #rows > 0, cone = how.cone, members = how.members }
end

local E = {
    name = 'specialize',
    kind = 'discovery',
    tags = { 'code', 'optimize' },
    measures = 'CART-1445',
    summary = 'specialize ANY Lua function (ref = file::name) to some of its arguments: statics = JSON { param = value }, samples = JSON list of the dynamic arguments per call — the residual text and mix\'s stats, and the residual ACCEPTED against the original (mix\'s own evaluator) on every sample; a refusal is mix\'s located one',
    params = { ref = 'ref', statics = 'string?', samples = 'string?', budget = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        if #v.samples == 0 then return false, 'no sample to accept the residual on' end
        for i, r in ipairs(v.samples) do
            if not r.same then return false, ('sample %d: the original gives %s, the residual %s'):format(i, vim.inspect(r.original), vim.inspect(r.residual)) end
        end
        return true, ('the residual equals the original on %d sample(s) (%d lines)'):format(#v.samples, select(2, v.text:gsub('\n', '')) + 1)
    end,
}

local SRC = table.concat({
    'local M = {}',
    'function M.pow(x, n)',
    '  local r = 1',
    '  for _ = 1, n do r = r * x end',
    '  return r',
    'end',
    'function M.jump(x) goto done ::done:: return x end',
    'return M', '' }, '\n')

E.examples = {
    {
        name = 'pow with n = 3 known: the loop is gone from the residual, and it equals the original on every sample',
        files = { ['m.lua'] = SRC },
        params = { ref = 'm.lua::M.pow', statics = '{"n": 3}', samples = '[[2], [5], [-1]]' },
        expect = { holds = true, check = function (v)
            return v.accepted and not v.text:find('for ', 1, true) and v.samples[2].residual == 125, v.text
        end },
    },
    {
        name = 'a function outside mix\'s subset (goto) is refused BY NAME, nothing is guessed',
        files = { ['m.lua'] = SRC },
        params = { ref = 'm.lua::M.jump', samples = '[[1]]' },
        expect = { holds = false, check = function (v) return v.error and v.error:find('goto', 1, true) ~= nil, vim.inspect(v) end },
    },
}

return E
