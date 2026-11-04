-- ENTRY-POINTS (discovery, CART-1860, arc CART-1858): every site where the tree's values meet code the analysis cannot
-- follow — handed to unknown code (a module outside the tree, load's chunk, setfenv), to a builtin with no model, to a
-- host function whose result is `any` — with the partial answers that FIRST TRACE to it (flowtype's R.entry_of: the
-- answer's taint walked back to its seed, the seed's object to the hand-out that let it go). Beside them, how many
-- partial answers trace to the analysis's OWN losses instead (saturation past CAP, sinf, …): a contract on an entry
-- cannot reach those.
-- A row: `kinds site` (kinds joined by `+`, site `file:line:col` 0-based — a handler the walk runs, an operator's or a
-- store's `__newindex` or a generic for's iterator, at its operator token, CART-1868 — `-` where the solve made the call
-- itself: unknown code calling back, `__gc`),
-- answers = the partial answers listing it, sole = those listing ONLY it, in = those where outside code passes a value
-- IN (calls a tree function it was handed), closure = the objects unknown code was handed there, closed over fields and
-- prototypes (unknown-code sites only). Every unknown-code site is a row, also one no answer traces to.
-- REACH (CART-1866): `answers` / `sole` follow ONE witness route per answer (the closure's spanning tree); `reach` counts
-- the partial answers EVERY hand-out site reaches (R.entry_of's `all`: the closure walked back from the answer's object to
-- each object a hand-out held), `alone` those only this site reaches — the answers one contract on this site could
-- touch at all, and the ones no other site also explains. Still first-arrival taint (FLOW-0123): reach is no removal.
-- ROOTS: the same answers by the OBJECT they trace to (R.entry_of's `at`: the root handed over, on the closure's
-- spanning tree — ONE WITNESS ROUTE, not every root that reaches the answer — or the late-escaped object)
-- with the number of entry sites that handed it — one object handed at many sites is one contract, not many: WoW w3's
-- partial answers share their sites almost entirely.
-- UNKNOWN answers (CART-1867): a receiver that may hold unknown code's OWN value — it returned it, it is a member of a
-- module outside the tree or of a loaded chunk, unknown code called a tree function back with it — has no verdict and no
-- taint path. flowtype R.unknown_of walks that value's first arrival back to its root: the `unknown` column counts them
-- per site (the call that returned it, the require, the hand-outs of the function called back); a receiver past CAP is
-- the analysis's own loss (`saturated`). A receiver of tree objects whose member LOOKUP is unknown (CART-1877): unknown
-- code's value read as the member is that value's arrival at the field, counted as above (`member`); else the lookup is
-- the analysis's own loss — a field past CAP (`lookup-saturated`), a function stored under a computed key
-- (`computed-key`), a function the graph has no node for, in loaded text (`unmapped-function`) — no entry's doing.
-- `unattributed` = the solve's unknown answers R.unknown_of names no cause for (0 is the invariant).
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
    local v = { secs = 0, partial = 0, entry = 0, loss = 0, nosite = 0, causes = {}, rows = {}, sites = 0, roots = {},
        unknown = 0, usat = 0, unosite = 0, ucauses = {}, multi = 0, umember = 0, ulook = 0, ulookup = {}, unattributed = 0 }
    local roots = {}
    local rows = {}
    local function row(k)
        local r = rows[k]
        if not r then r = { key = k, answers = 0, sole = 0, ['in'] = 0, closure = 0, unknown = 0, reach = 0, alone = 0 }; rows[k] = r end
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
                local all = e.all or e.sites
                if #all > 1 then v.multi = v.multi + 1 end
                for _, k in ipairs(all) do
                    local r = row(k)
                    r.reach = r.reach + 1
                    if #all == 1 then r.alone = r.alone + 1 end
                end
            end
        else
            local u = R.unknown_of(c)
            if u then
                v.unknown = v.unknown + 1
                if u.cause == 'saturated' then v.usat = v.usat + 1
                elseif u.cause == 'lookup' then v.ulook = v.ulook + 1; v.ulookup[u.lookup] = (v.ulookup[u.lookup] or 0) + 1
                else
                    if u.lookup == 'member' then v.umember = v.umember + 1 end
                    local k = u.root or u.cause
                    v.ucauses[k] = (v.ucauses[k] or 0) + 1
                    if not u.sites then v.unosite = v.unosite + 1
                    else for _, sk in ipairs(u.sites) do local r = row(sk); r.unknown = r.unknown + 1 end end
                end
            end
        end
    end
    v.unattributed = (R.stats.unknown or 0) - v.unknown
    v.secs = (vim.uv.hrtime() - t0) / 1e9
    local l = {}
    for _, r in pairs(rows) do l[#l + 1] = r end
    table.sort(l, function (a, b)
        if a.answers + a.unknown ~= b.answers + b.unknown then return a.answers + a.unknown > b.answers + b.unknown end
        if a.closure ~= b.closure then return a.closure > b.closure end
        return a.key < b.key
    end)
    v.sites = #l
    if p.out then
        local fd = assert(io.open(p.out, 'w'))
        fd:write('kinds\tsite\tanswers\tsole\tin\tclosure\tunknown\treach\talone\n')
        for _, r in ipairs(l) do
            local ks, st = r.key:match('^(%S+) (.*)$')
            fd:write(('%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n'):format(ks, st, r.answers, r.sole, r['in'], r.closure, r.unknown, r.reach, r.alone))
        end
        fd:close()
    end
    local rl = {}
    for _, r in pairs(roots) do rl[#rl + 1] = r end
    table.sort(rl, function (a, b) if a.answers ~= b.answers then return a.answers > b.answers end return a.key < b.key end)
    for i = 1, math.min(tonumber(p.top) or 30, #rl) do v.roots[i] = ('%5d %5d  %s'):format(rl[i].answers, rl[i].sites, rl[i].key) end
    for i = 1, math.min(tonumber(p.top) or 30, #l) do
        local r = l[i]
        v.rows[i] = ('%5d %5d %5d %7d %5d %5d %5d  %s'):format(r.answers, r.sole, r['in'], r.closure, r.unknown, r.reach, r.alone, r.key)
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
local FXR = { ['m.lua'] = table.concat({
    'local ext = require("notintree")',
    'local A, B = {}, {}',
    'function A.m(self) return 1 end',
    'function B.m(self) return 2 end',
    'local x = { k = setmetatable({}, { __index = A }) }',
    'local r1 = { x = x }',
    'local r2 = { y = { z = x } }',
    'ext.f(r1)',
    'ext.g(r2)',
    'local a1 = x.k:m()',
    'local y = { k = setmetatable({}, { __index = B }) }',
    'ext.h(y)',
    'local a2 = y.k:m()',
    'local p = setmetatable({}, { __index = x })',
    'ext.p(p)' }, '\n') .. '\n' }
local FXU = { ['m.lua'] = table.concat({
    'local ext = require("notintree")',
    'local A, B = {}, {}',
    'function A.m(self) return 1 end',
    'function B.m(self) return 2 end',
    'local r = ext.f()',
    'local function u1() return r:m() end',
    'local function u2() return ext.g:m() end' }, '\n') .. '\n' }
local FXL = { ['m.lua'] = table.concat({
    'local ext = require("notintree")',
    'local A, B = {}, {}',
    'function A.m(self) return 1 end',
    'function B.m(self) return 2 end',
    'local t1 = setmetatable({}, { __index = A })',
    't1.m = ext.f',
    'local function u1() return t1:m() end',
    'local t3 = setmetatable({}, { __index = A })',
    'local function put(k) t3[k] = function () return 4 end end',
    'local function u3() return t3:m() end',
    'local L = load("return { m = function (self) return 3 end }")()',
    'local t4 = setmetatable({}, { __index = L })',
    'local function u4() return t4:m() end' }, '\n') .. '\n' }

return {
    name = 'entry-points',
    kind = 'discovery',
    tags = { 'measure', 'flow', 'code' },
    summary = 'every site where the tree\'s values meet code the analysis cannot follow (unknown code, a builtin with no model, a host `any`), with the partial answers that FIRST TRACE to each (flowtype R.entry_of) and how many trace to the analysis\'s own losses instead, and the UNKNOWN answers (a receiver that may hold unknown code\'s own value: R.unknown_of, its first arrival back to the call / require / load / function called back that made it — or, for a receiver of tree objects, the member LOOKUP: unknown code\'s value read as the member, or the analysis\'s own loss: lookup-saturated, computed-key, unmapped-function; unattributed = unknown answers with no cause, 0); rows = answers, sole, in, closure, unknown, reach, alone, `kinds site` (reach / alone: the partial answers EVERY site reaches, not one witness route, and those it alone reaches); roots = answers, sites, `cause object` (one object handed at many sites); first arrival, not cause — never read a row as what a contract wins; mode = closed | open, top = rows, out = a TSV of every row',
    params = { mode = 'string?', top = 'string?', out = 'string?' },
    measure = measure,
    claim = function (v)
        local cs = {}
        for k, n in pairs(v.causes) do cs[#cs + 1] = ('%s %d'):format(k, n) end
        table.sort(cs)
        local us = {}
        for k, n in pairs(v.ucauses) do us[#us + 1] = ('%s %d'):format(k, n) end
        table.sort(us)
        local ls = {}
        for k, n in pairs(v.ulookup) do ls[#ls + 1] = ('%s %d'):format(k, n) end
        table.sort(ls)
        return true, ('%d partial answers: %d first trace to an entry (%d without a site; %d reached from more than one site), %d to the analysis\'s own losses; %d unknown: %d trace to unknown code\'s value (%d without a site; %s; %d read as the member), %d saturated receivers, %d lookups the analysis lost (%s), %d unattributed; %d entry sites; causes: %s; %.1f s')
            :format(v.partial, v.entry, v.nosite, v.multi, v.loss, v.unknown, v.unknown - v.usat - v.ulook, v.unosite, table.concat(us, ', '), v.umember, v.usat, v.ulook,
                #ls > 0 and table.concat(ls, ', ') or 'none', v.unattributed, v.sites, table.concat(cs, ', '), v.secs)
    end,
    examples = {
        {
            name = 'the call that handed t to unknown code carries the answer through t; a call handing a fresh table is a row with none',
            files = FX,
            params = function () return { top = '10' } end,
            expect = { holds = true, check = function (v)
                local first, other = v.rows[1] or '', nil
                for _, r in ipairs(v.rows) do if r:match(' call m%.lua:7:0$') then other = r end end
                return first:match('^%s+1%s+1%s+0%s+%d+%s+0%s+1%s+1  call m%.lua:5:0$') ~= nil and other ~= nil and other:match('^%s+0 ') ~= nil
                    and v.partial == 1 and v.entry == 1 and (v.roots[1] or ''):match('^%s+1%s+1  unknown%-code tbl:m%.lua:4:10$') ~= nil, vim.inspect(v)
            end },
        },
        {
            name = 'reach: every hand-out whose object reaches the answer counts it, alone only where no other does',
            files = FXR,
            params = function () return { top = '10' } end,
            expect = { holds = true, check = function (v)
                local got = {}
                for _, r in ipairs(v.rows) do local re, al, k = r:match('(%d+)%s+(%d+)  (call m%.lua:%d+:0)$'); if k then got[k] = re .. '/' .. al end end
                return v.multi == 1 and got['call m.lua:7:0'] == '1/0' and got['call m.lua:8:0'] == '1/0' and got['call m.lua:14:0'] == '1/0'
                    and got['call m.lua:11:0'] == '1/1', vim.inspect(v)
            end },
        },
        {
            name = 'an answer whose receiver unknown code returned is unknown, counted at the call that returned it; a member of an unmapped module at its require',
            files = FXU,
            params = function () return { top = '10' } end,
            expect = { holds = true, check = function (v)
                local call, req
                for _, r in ipairs(v.rows) do
                    if r:match('^%s+0%s+0%s+0%s+%d+%s+1%s+0%s+0  call m%.lua:4:10$') then call = true end
                    if r:match('^%s+0%s+0%s+0%s+%d+%s+1%s+0%s+0  require m%.lua:0:12$') then req = true end
                end
                return call and req and v.unknown == 2 and v.usat == 0 and v.unosite == 0 and v.ucauses.call == 1 and v.ucauses.require == 1, vim.inspect(v)
            end },
        },
        {
            name = 'a receiver of tree objects with an unknown LOOKUP: unknown code\'s value as the member at its require; a computed key and loaded text the analysis\'s own',
            files = FXL,
            params = function () return { top = '10' } end,
            expect = { holds = true, check = function (v)
                local req
                for _, r in ipairs(v.rows) do if r:match('^%s+0%s+0%s+0%s+%d+%s+1%s+0%s+0  require m%.lua:0:12$') then req = true end end
                return req and v.unknown == 3 and v.umember == 1 and v.ucauses.require == 1 and v.ulook == 2
                    and v.ulookup['computed-key'] == 1 and v.ulookup['unmapped-function'] == 1 and v.unattributed == 0, vim.inspect(v)
            end },
        },
    },
}
