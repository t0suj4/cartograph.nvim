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
-- ⚠ ONLY GAINS ARE LISTED: past CAP a contract also moves saturation (CART-1874), and an answer it makes LESS known is
-- in no column here — self's string.buffer module contract turns 10 partial answers unknown (CART-1875).
-- params: mode = closed | open (default closed), contracts = a file, top = rows in the value (default 30).
-- CLAIM: the solve ran; the value is the ledger.

local function measure(store, p)
    local t0 = vim.uv.hrtime()
    local list = p.contracts and dofile(p.contracts) or nil
    local R = require('cartograph.flowtype').solve(store, { open = p.mode == 'open', ctx = false, contracts = list })
    local v = { secs = 0, contracts = 0, met = 0, whole = 0, partial = 0, stands = 0, rows = {}, unmet = {} }
    local per = {}
    for _, e in ipairs(R.entry_contracts) do
        v.contracts = v.contracts + 1
        per[e.id] = 0
        if e.met then v.met = v.met + 1 else v.unmet[#v.unmet + 1] = e.id end
    end
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
    end
    v.secs = (vim.uv.hrtime() - t0) / 1e9
    for i, e in ipairs(R.entry_contracts) do
        if i > (tonumber(p.top) or 30) then break end
        v.rows[i] = ('%5d %4d  %s %s [%s] %s'):format(per[e.id], #e.sites, e.id, e.module and ('module ' .. e.module) or ('site ' .. e.site),
            table.concat(e.clauses, '+'), e.where)
    end
    return v
end

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
    summary = 'the LEDGER of the entry contracts in force (declared promises about unknown code: by module or site, clauses no-write [, no-callback], src required — the scoped key entry_contracts, or `contracts` = a Lua file returning records, to try some): per contract the whole answers that STAND ON it (dropping it alone changes them: one solve per met contract), the hand-out sites it met, where it was declared; an unmet contract is listed; rows = stands, sites, `id module|site [clauses] where`; mode = closed | open, top = rows',
    params = { mode = 'string?', contracts = 'string?', top = 'string?' },
    measure = measure,
    claim = function (v)
        return true, ('%d contracts in force (%d met%s): %d of %d whole answers stand on them, %d partial; %.1f s')
            :format(v.contracts, v.met, #v.unmet > 0 and (', unmet: ' .. table.concat(v.unmet, ', ')) or '', v.stands, v.whole, v.partial, v.secs)
    end,
    examples = {
        {
            name = 'a module contract makes the answer through what lpeg was handed whole and is cited; a site no hand-out has is unmet',
            files = FX,
            params = function (store) return { contracts = store.data.root .. '/contracts.lua' } end,
            expect = { holds = true, check = function (v)
                return v.contracts == 2 and v.met == 1 and v.unmet[1] == 'stale' and v.stands == 1 and v.partial == 0
                    and (v.rows[1] or ''):match('^%s+1%s+1  lpeg%-reads module lpeg %[no%-write%+no%-callback%] opts%.contracts$') ~= nil, vim.inspect(v)
            end },
        },
    },
}
