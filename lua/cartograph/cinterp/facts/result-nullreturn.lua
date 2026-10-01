-- RESULT by a NULL RETURN: the slot is a POINTER (CPython's `PyObject *`) and the registered function returns one — the
-- SENTINEL is NULL, a raised error's return. Every function returning a pointer of the slot's pointee whose every
-- return is NULL — directly, a call of another such, a local only such values are assigned — and whose body makes a
-- call (an error helper — PyErr_Format, PyErr_NoMemory, type_error — not an empty stub) is a THROWER: its call is
-- the sentinel, the error object it formats never walked. -> { kind = 'sentinel', text = '((void *)0)', throwers }
local function norm(t) return (t:gsub('%s+', '')) end
local NULLS = { ['((void*)0)'] = true, ['0'] = true, ['NULL'] = true }

return {
    fact = 'result',
    needs = { 'units', 'slot', 'layout' },
    summary = 'NULL as the sentinel a raised error returns, and every pointer function that only returns it',
    derive = function (_, got)
        local CI = require 'cartograph.cinterp'
        if not got.layout.pointer then return nil, 'the slot is not a pointer' end
        local pointee = got.slot.type:match('^([%w_]+)')
        local rq = vim.treesitter.query.parse('c', '(return_statement (_) @e)')
        local cq = vim.treesitter.query.parse('c', '(call_expression) @c')
        local info = {}
        local function returns(d)
            local l = info[d]
            if l then return l end
            l = {}
            for _, n in rq:iter_captures(d.node, d.src, 0, -1) do
                local fnode = n:type() == 'call_expression' and n:field('function')[1]
                l[#l + 1] = { text = norm(CI.tx(n, d.src)), call = fnode and fnode:type() == 'identifier' and CI.tx(fnode, d.src) or nil,
                    id = n:type() == 'identifier' and CI.tx(n, d.src) or nil }
            end
            info[d] = l
            return l
        end
        local names = {}
        for name, d in pairs(got.units.defs) do if d.ptrret == pointee then names[#names + 1] = name end end
        table.sort(names)
        local throwers = {}
        local function sentinel(r, d)
            if NULLS[r.text] then return true end
            if r.call then return throwers[r.call] == true end
            if r.id then
                local text = CI.tx(d.node, d.src)
                local any = false
                for rhs in text:gmatch('%f[%w_]' .. r.id .. '%s*=%s*([^;=][^;]*);') do
                    any = true
                    local c = rhs:match('^%s*([%w_]+)%s*%(')
                    if not ((c and throwers[c]) or NULLS[norm(rhs)]) then return false end
                end
                return any
            end
            return false
        end
        local function calls(d) for _ in cq:iter_captures(d.node, d.src, 0, -1) do return true end return false end
        local changed = true
        while changed do
            changed = false
            for _, name in ipairs(names) do
                local d = got.units.defs[name]
                if not throwers[name] then
                    local rs = returns(d)
                    local all = #rs > 0
                    for _, r in ipairs(rs) do if not sentinel(r, d) then all = false; break end end
                    if all and calls(d) then throwers[name] = true; changed = true end
                end
            end
        end
        if not next(throwers) then return nil, 'no ' .. pointee .. ' * function only returns NULL' end
        return { kind = 'sentinel', text = '((void *)0)', throwers = throwers }
    end,
}
