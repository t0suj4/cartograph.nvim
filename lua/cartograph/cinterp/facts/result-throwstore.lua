-- RESULT by a SENTINEL VALUE: a function of the tree that STORES its value parameter into a field behind a pointer and
-- RETURNS a constant — QuickJS' JS_Throw: `rt->current_exception = obj; return JS_EXCEPTION;` (erts' BIF_ERROR is the
-- same shape as a macro: result-status) — the constant is the SENTINEL a raised error returns, the field the pending
-- exception. Every function whose every return is the sentinel — its text, a call of another such function, or a local
-- that only such values are assigned — is a THROWER (a fixpoint over the return statements: JS_ThrowTypeError's
-- `val = JS_ThrowError(…); return val;`); the interpreter takes a thrower's call as the sentinel without walking the
-- error object it builds. -> { kind = 'sentinel', fn, field, text, throwers = { [name] = true } }
local function norm(t) return (t:gsub('%s+', '')) end

return {
    fact = 'result',
    needs = { 'units', 'slot' },
    summary = 'the sentinel a raised error returns, and every function that only returns it',
    derive = function (_, got)
        local CI = require 'cartograph.cinterp'
        local ty = got.slot.type
        local rq = vim.treesitter.query.parse('c', '(return_statement (_) @e)')
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
        -- (the STORE: a parameter of the slot type assigned into a field, one constant returned)
        local base
        local names = vim.tbl_keys(got.units.defs)
        table.sort(names)
        for _, name in ipairs(names) do
            local d = got.units.defs[name]
            if d.ret == ty then
                for _, p in ipairs(d.params) do
                    if p.text == ty then
                        local field = CI.tx(d.node, d.src):match('%->%s*([%w_]+)%s*=%s*' .. p.name .. '%s*;')
                        local rs = field and returns(d)
                        if rs and #rs == 1 and rs[1].id ~= p.name and not rs[1].call and not rs[1].id then
                            base = { fn = name, field = field, text = rs[1].text }
                            break
                        end
                    end
                end
            end
            if base then break end
        end
        if not base then return nil, 'no function stores its ' .. ty .. ' parameter into a field and returns one constant' end
        local throwers = { [base.fn] = true }
        local function sentinel(r, d)
            if r.text == base.text then return true end
            if r.call then return throwers[r.call] == true end
            if r.id then
                -- (a LOCAL: every value assigned to it — its initializer too — a thrower's call or the sentinel)
                local text = CI.tx(d.node, d.src)
                local any = false
                for rhs in text:gmatch('%f[%w_]' .. r.id .. '%s*=%s*([^;=][^;]*);') do
                    any = true
                    local c = rhs:match('^%s*([%w_]+)%s*%(')
                    if not ((c and throwers[c]) or norm(rhs) == base.text) then return false end
                end
                return any
            end
            return false
        end
        local changed = true
        while changed do
            changed = false
            for _, name in ipairs(names) do
                local d = got.units.defs[name]
                if not throwers[name] and d.ret == ty then
                    local rs = returns(d)
                    local all = #rs > 0
                    for _, r in ipairs(rs) do if not sentinel(r, d) then all = false; break end end
                    if all then throwers[name] = true; changed = true end
                end
            end
        end
        return { kind = 'sentinel', fn = base.fn, field = base.field, text = base.text, throwers = throwers }
    end,
}
