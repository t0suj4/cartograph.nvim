-- mix's BINDING-TIME SETS per lowered program, as rows a `join` instrument compares across two trees: every derivation
-- program (plain and through) and the M.match closure -> `ROW\t<sha256 of the source term and options>\t<forced> |
-- <freshroot> | <boxed>` (each a sorted id:name list). The CART-1524 retirements were accepted on this join, by hand.
return { measure = function ()
    local MA, MX, R = require 'cartograph.mixalg', require 'cartograph.mix', require 'cartograph.algebraread'
    local A = require('cartograph.algebra').load()
    local D = require 'cartograph.algebra.derive'
    D.apply_to(A, '')
    local function ser(t, b)
        if type(t) ~= 'table' then b[#b + 1] = tostring(t); return end
        b[#b + 1] = '(' .. tostring(t.k) .. ' ' .. tostring(t.v)
        for _, c in ipairs(t.kids or {}) do b[#b + 1] = ' '; ser(c, b) end
        b[#b + 1] = ')'
    end
    local function set(s, names)
        local r = {}
        for id in pairs(s or {}) do r[#r + 1] = tostring(id) .. ':' .. tostring(names[id]) end
        table.sort(r)
        return table.concat(r, ',')
    end
    local function row(term, opts, tag)
        local ok, prog = pcall(MX.lower, term, opts)
        local b = {}
        ser(term, b)
        local key = vim.fn.sha256(table.concat(b) .. '\0' .. tag)
        if not ok then io.write('ROW\t', key, '\tREFUSED\n'); return end
        io.write('ROW\t', key, '\t', set(prog.forced, prog.names), ' | ', set(prog.freshroot, prog.names), ' | ', set(prog.boxed, prog.names), '\n')
    end
    local OPQ = { ['M.admits'] = true, ['M.admits_slice'] = true, ['M.match'] = true, ['M.entails'] = true }
    for _, op in ipairs(D.OPERATORS) do
        for _, through in ipairs({ false, true }) do
            local okp, text, _, lines = pcall(MA.program, 'derive.lua::D.' .. op, nil, { snapshot = true, through = through or nil, opaque = through and OPQ or nil })
            if okp then row(R.read(text, 'lua'), { lines = lines }, op .. (through and ':through' or '')) end
        end
    end
    local text, _, lines = MA.program('M.match')
    row(R.read(text, 'lua'), { lines = lines }, 'M.match')
    return {}
end }
