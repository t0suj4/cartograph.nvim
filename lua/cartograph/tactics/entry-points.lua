-- ENTRY-POINTS (discovery, CART-1860, arc CART-1858): every site where the tree's values meet code the analysis cannot
-- follow — handed to unknown code (a module outside the tree, load's chunk, setfenv), to a builtin with no model, to a
-- host function whose result is `any` — with the partial answers that FIRST TRACE to it (flowtype's R.entry_of: the
-- answer's taint walked back to its seed, the seed's object to the hand-out that let it go). Beside them, how many
-- partial answers trace to the analysis's OWN losses instead (saturation past CAP, sinf, …): a contract on an entry
-- cannot reach those.
-- A row: `kinds site` (kinds joined by `+`, site `file:line:col` 0-based, `-` where the solve made the call itself),
-- answers = the partial answers listing it, sole = those listing ONLY it, in = those where outside code passes a value
-- IN (calls a tree function it was handed), closure = the objects unknown code was handed there, closed over fields and
-- prototypes (unknown-code sites only). Every unknown-code site is a row, also one no answer traces to.
-- ROOTS: the same answers by the OBJECT they trace to (R.entry_of's `at`: the root handed over, on the closure's
-- spanning tree — ONE WITNESS ROUTE, not every root that reaches the answer — or the late-escaped object)
-- with the number of entry sites that handed it — one object handed at many sites is one contract, not many: WoW w3's
-- partial answers share their sites almost entirely.
-- ⚠ FIRST ARRIVAL, NOT CAUSE: the taint is overdetermined (flowpath FLOW-0123: once anything escapes, the world rules
-- hit every escaped object), so `answers` is no count of what a contract on that entry would win — never rank by it as
-- a removal. Runs the solve with explain on (one ⊤ per saturated port): its answers are checked against the default
-- solve by `toolbelt.lua run variants`, not here.
-- params: mode = closed | open (default closed), top = rows in the value (default 30), out = a file for every row (TSV).
-- CLAIM: the solve ran; the value says how the partial answers divide.
local ENTRY = { ['unknown-code'] = true, ['builtin-lost'] = true, ['host-any'] = true }

local function measure(store, p)
    local t0 = vim.uv.hrtime()
    local R = require('cartograph.flowtype').solve(store, { open = p.mode == 'open', ctx = false, explain = true })
    local v = { secs = 0, partial = 0, entry = 0, loss = 0, nosite = 0, causes = {}, rows = {}, sites = 0, roots = {} }
    local roots = {}
    local rows = {}
    local function row(k)
        local r = rows[k]
        if not r then r = { key = k, answers = 0, sole = 0, ['in'] = 0, closure = 0 }; rows[k] = r end
        return r
    end
    for k, n in pairs(R.xclosure()) do row(k).closure = n end
    for _, c in ipairs(store.data.calls or {}) do
        local e = R.entry_of(R.verdict(c))
        if e then
            v.partial = v.partial + 1
            local cls = (ENTRY[e.cause] or e.cause:match('^lost%-call')) and e.cause or e.cause:match('^saturated') and 'saturated' or e.cause
            v.causes[cls] = (v.causes[cls] or 0) + 1
            if ENTRY[e.cause] or e.cause:match('^lost%-call') then v.entry = v.entry + 1 else v.loss = v.loss + 1 end
            if ENTRY[e.cause] or e.cause:match('^lost%-call') then
                local k = e.cause .. ' ' .. tostring(e.at)
                local r = roots[k]
                if not r then r = { key = k, answers = 0, sites = e.sites and #e.sites or 0 }; roots[k] = r end
                r.answers = r.answers + 1
            end
            if not e.sites then if ENTRY[e.cause] then v.nosite = v.nosite + 1 end
            else
                for _, k in ipairs(e.sites) do
                    local r = row(k)
                    r.answers = r.answers + 1
                    if #e.sites == 1 then r.sole = r.sole + 1 end
                    if e.dir == 'in' then r['in'] = r['in'] + 1 end
                end
            end
        end
    end
    v.secs = (vim.uv.hrtime() - t0) / 1e9
    local l = {}
    for _, r in pairs(rows) do l[#l + 1] = r end
    table.sort(l, function (a, b)
        if a.answers ~= b.answers then return a.answers > b.answers end
        if a.closure ~= b.closure then return a.closure > b.closure end
        return a.key < b.key
    end)
    v.sites = #l
    if p.out then
        local fd = assert(io.open(p.out, 'w'))
        fd:write('kinds\tsite\tanswers\tsole\tin\tclosure\n')
        for _, r in ipairs(l) do
            local ks, st = r.key:match('^(%S+) (.*)$')
            fd:write(('%s\t%s\t%d\t%d\t%d\t%d\n'):format(ks, st, r.answers, r.sole, r['in'], r.closure))
        end
        fd:close()
    end
    local rl = {}
    for _, r in pairs(roots) do rl[#rl + 1] = r end
    table.sort(rl, function (a, b) if a.answers ~= b.answers then return a.answers > b.answers end return a.key < b.key end)
    for i = 1, math.min(tonumber(p.top) or 30, #rl) do v.roots[i] = ('%5d %5d  %s'):format(rl[i].answers, rl[i].sites, rl[i].key) end
    for i = 1, math.min(tonumber(p.top) or 30, #l) do
        local r = l[i]
        v.rows[i] = ('%5d %5d %5d %7d  %s'):format(r.answers, r.sole, r['in'], r.closure, r.key)
    end
    return v
end

local FX = { ['m.lua'] = table.concat({
    'local ext = require("notintree")',
    'local A, B = {}, {}',
    'function A.m(self) return 1 end',
    'function B.m(self) return 2 end',
    'local t = { k = setmetatable({}, { __index = A }) }',
    'ext.f(t)',
    'local r1 = t.k:m()',
    'ext.g({})',
    'local C, D = {}, {}',
    'function C.n(self) return 3 end',
    'function D.n(self) return 4 end',
    'local own = setmetatable({}, { __index = C })',
    'local r3 = own:n()' }, '\n') .. '\n' }

return {
    name = 'entry-points',
    kind = 'discovery',
    tags = { 'measure', 'flow', 'code' },
    summary = 'every site where the tree\'s values meet code the analysis cannot follow (unknown code, a builtin with no model, a host `any`), with the partial answers that FIRST TRACE to each (flowtype R.entry_of) and how many trace to the analysis\'s own losses instead; rows = answers, sole, in, closure, `kinds site`; roots = answers, sites, `cause object` (one object handed at many sites); first arrival, not cause — never read a row as what a contract wins; mode = closed | open, top = rows, out = a TSV of every row',
    params = { mode = 'string?', top = 'string?', out = 'string?' },
    measure = measure,
    claim = function (v)
        local cs = {}
        for k, n in pairs(v.causes) do cs[#cs + 1] = ('%s %d'):format(k, n) end
        table.sort(cs)
        return true, ('%d partial answers: %d first trace to an entry (%d without a site), %d to the analysis\'s own losses; %d entry sites; causes: %s; %.1f s')
            :format(v.partial, v.entry, v.nosite, v.loss, v.sites, table.concat(cs, ', '), v.secs)
    end,
    examples = {
        {
            name = 'the call that handed t to unknown code carries the answer through t; a call handing a fresh table is a row with none',
            files = FX,
            params = function () return { top = '10' } end,
            expect = { holds = true, check = function (v)
                local first, other = v.rows[1] or '', nil
                for _, r in ipairs(v.rows) do if r:match(' call m%.lua:7:0$') then other = r end end
                return first:match('^%s+1%s+1%s+0%s+%d+  call m%.lua:5:0$') ~= nil and other ~= nil and other:match('^%s+0 ') ~= nil
                    and v.partial == 1 and v.entry == 1 and (v.roots[1] or ''):match('^%s+1%s+1  unknown%-code tbl:m%.lua:4:10$') ~= nil, vim.inspect(v)
            end },
        },
    },
}
