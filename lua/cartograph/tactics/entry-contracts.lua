-- ENTRY-CONTRACTS (discovery, CART-1861, arc CART-1858): the LEDGER of the entry contracts in force — the declared
-- promises about unknown code at an entry point (flowtype M.contracts: by the MODULE a require the tree cannot map
-- loads, or by the SITE that hands values over; clauses no-write [, no-callback]; `src` required) — with where each met
-- the tree and the whole answers that STAND ON it (flowtype R.assumes: dropping that contract alone makes the answer
-- partial, unknown or another one — one more solve per met contract). A contract that met nothing is listed `unmet`:
-- it suppresses nothing, and is stale or misspelled.
-- Contracts come from the scoped key `entry_contracts` (config.lua) and, to TRY some before declaring them, from
-- `contracts` = a Lua file returning a list of records (applied to the whole tree).
-- An answer stands on EVERY contract of a site its objects were handed at (one handed to lpeg and to ext.g needs both):
-- the taint is overdetermined (flowpath FLOW-0123), so one contract alone can win nothing.
-- A SITE CONTRACT HOLDS AT A LOST CALL too (CART-1872), the default it means: the call at its site writes nothing it
-- is handed WHATEVER its callee is — tree code unknown code stored in the field it is read from included; its results
-- and errors stay unknown. Not past CAP: a saturated callee (`lost-call:saturated`) is the analysis's own loss, and the
-- contract lapses there. ⚠ What it can win on self: contracting all 4,410 unknown-code sites wins 1 answer, all 42,770
-- hand-out sites 77 (1,271 -> 1,194 partial) — most partiality is the analysis's own (saturation, sinf), which no
-- contract reaches.
-- ★ AND THE ANSWERS IT COSTS (flowtype R.costs, CART-1875): past CAP a contract also moves saturation (CART-1874), and
-- an answer LESS known under it (whole > partial > no verdict) than without it is counted in its `costs` column — self's
-- string.buffer module contract costs 10 partial answers their verdict. Like `stands`, a loss is under a contract only
-- where dropping that one alone undoes it; a partial gain (no verdict -> partial) is in no column.
-- params: mode = closed | open (default closed), contracts = a file, top = rows in the value (default 30).
-- CLAIM: the solve ran; the value is the ledger.

local function measure(store, p)
    local t0 = vim.uv.hrtime()
    local list = p.contracts and dofile(p.contracts) or nil
    local R = require('cartograph.flowtype').solve(store, { open = p.mode == 'open', ctx = false, contracts = list })
    local v = { secs = 0, contracts = 0, met = 0, whole = 0, partial = 0, stands = 0, costs = 0, rows = {}, unmet = {}, cost = {} }
    local per, lost = {}, {}
    for _, e in ipairs(R.entry_contracts) do
        v.contracts = v.contracts + 1
        per[e.id], lost[e.id] = 0, 0
        if e.met then v.met = v.met + 1 else v.unmet[#v.unmet + 1] = e.id end
    end
    local callrec = require 'cartograph.callrec'
    for _, c in ipairs(store.data.calls or {}) do
        local a = R.verdict(c)
        if a and a.partial then v.partial = v.partial + 1
        elseif a and a.kind ~= 'unknown' then
            v.whole = v.whole + 1
            local cs = R.assumes(c)
            if cs then
                v.stands = v.stands + 1
                for _, id in ipairs(cs) do per[id] = per[id] + 1 end
            end
        end
        local co = R.costs(c) -- (every call: what a contract costs is mostly an answer left without a verdict)
        if co then
            v.costs = v.costs + 1
            for _, id in ipairs(co) do lost[id] = lost[id] + 1 end
            v.cost[#v.cost + 1] = ('%s:%d %s  %s  [%s]'):format(callrec.file(c), callrec.line(c), tostring(callrec.full(c)),
                a and ((a.partial and 'partial ' or '') .. a.kind) or 'no verdict', table.concat(co, ','))
        end
    end
    table.sort(v.cost)
    v.secs = (vim.uv.hrtime() - t0) / 1e9
    for i, e in ipairs(R.entry_contracts) do
        if i > (tonumber(p.top) or 30) then break end
        v.rows[i] = ('%5d %5d %4d  %s %s [%s] %s'):format(per[e.id], lost[e.id], #e.sites, e.id, e.module and ('module ' .. e.module) or ('site ' .. e.site),
            table.concat(e.clauses, '+'), e.where)
    end
    return v
end

-- (a contract's COST, CART-1875: the unknown-code hub holds the 67 functions handed out here, 10 of them to lpeg — past
-- CAP. Under lpeg's no-callback contract it holds 57, under CAP: unknown code now calls s's setter with EXT, and
-- `s.k:m()`, partial without the contract, has no verdict. The window is lpeg's 10 hand-outs wide, CAP - 11 .. CAP - 2)
local COST = { 'local lpeg = require("lpeg")', 'local ext = require("notintree")', 'local A, B = {}, {}',
    'function A.m(self) return 1 end', 'function B.m(self) return 2 end',
    'local s = { k = setmetatable({}, { __index = A }) }', 'ext.h(function (q) s.k = q end)' }
for i = 1, 10 do COST[#COST + 1] = 'lpeg.Cmt(function () return ' .. i .. ' end)' end
for i = 1, 56 do COST[#COST + 1] = 'ext.h(function () return ' .. i .. ' end)' end
COST[#COST + 1] = 'local function use() return s.k:m() end'

local FX = {
    ['m.lua'] = table.concat({
        'local lpeg = require("lpeg")',
        'local A, B = {}, {}',
        'function A.m(self) return 1 end',
        'function B.m(self) return 2 end',
        'local t = { k = setmetatable({}, { __index = A }) }',
        'lpeg.match(t)',
        'local r1 = t.k:m()' }, '\n') .. '\n',
    ['contracts.lua'] = table.concat({
        'return {',
        '  { id = "lpeg-reads", module = "lpeg", clauses = { "no-write", "no-callback" }, src = "the lpeg manual" },',
        '  { id = "stale", site = "m.lua:40:0", clauses = { "no-write" }, src = "a line that moved" },',
        '}' }, '\n') .. '\n',
}

return {
    name = 'entry-contracts',
    kind = 'discovery',
    tags = { 'measure', 'flow', 'code' },
    summary = 'the LEDGER of the entry contracts in force (declared promises about unknown code: by module or site, clauses no-write [, no-callback], src required — the scoped key entry_contracts, or `contracts` = a Lua file returning records, to try some): per contract the whole answers that STAND ON it (dropping it alone changes them: one solve per met contract) and the answers it COSTS (less known under it than without it — past CAP a contract moves saturation; listed in `cost`), the hand-out sites it met, where it was declared; an unmet contract is listed; rows = stands, costs, sites, `id module|site [clauses] where`; mode = closed | open, top = rows',
    params = { mode = 'string?', contracts = 'string?', top = 'string?' },
    measure = measure,
    claim = function (v)
        return true, ('%d contracts in force (%d met%s): %d of %d whole answers stand on them, %d partial; %d answers less known under one; %.1f s')
            :format(v.contracts, v.met, #v.unmet > 0 and (', unmet: ' .. table.concat(v.unmet, ', ')) or '', v.stands, v.whole, v.partial, v.costs, v.secs)
    end,
    examples = {
        {
            name = 'a module contract makes the answer through what lpeg was handed whole and is cited; a site no hand-out has is unmet',
            files = FX,
            params = function (store) return { contracts = store.data.root .. '/contracts.lua' } end,
            expect = { holds = true, check = function (v)
                return v.contracts == 2 and v.met == 1 and v.unmet[1] == 'stale' and v.stands == 1 and v.partial == 0 and v.costs == 0
                    and (v.rows[1] or ''):match('^%s+1%s+0%s+1  lpeg%-reads module lpeg %[no%-write%+no%-callback%] opts%.contracts$') ~= nil, vim.inspect(v)
            end },
        },
        {
            name = 'past CAP a contract can cost an answer: it is counted under the contract and listed',
            files = {
                ['m.lua'] = table.concat(COST, '\n') .. '\n',
                ['contracts.lua'] = 'return { { id = "lpeg-reads", module = "lpeg", clauses = { "no-write", "no-callback" }, src = "the lpeg manual" } }\n',
            },
            params = function (store) return { contracts = store.data.root .. '/contracts.lua' } end,
            expect = { holds = true, check = function (v)
                return v.met == 1 and v.costs == 1 and #v.cost == 1 and v.cost[1]:match('^m%.lua:%d+ s%.k:m  no verdict  %[lpeg%-reads%]$') ~= nil
                    and (v.rows[1] or ''):match('^%s+0%s+1%s+10  lpeg%-reads ') ~= nil, vim.inspect(v)
            end },
        },
    },
}
