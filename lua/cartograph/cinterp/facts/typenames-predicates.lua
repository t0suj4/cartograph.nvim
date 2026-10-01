-- TYPENAMES by the tree's own PREDICATES: every one-argument function `bool <P>Is<X>(<slot type> v)` (QuickJS'
-- JS_IsNumber, JS_IsNull, JS_IsString …), RUN by the interpreter over every representative. A representative's type
-- is the predicate holding for it (true on every path) with the FEWEST representatives (number holds for INT and
-- FLOAT64); ties by name; none: a representative of a concrete word is not a value ('-'). Null is its own type
-- here — JS's typeof calls it object, its predicate does not. Subtypes as typenames-guardbifs: carried beside the map.
return {
    fact = 'typenames',
    needs = { 'reps', 'slot', 'units', 'noret', 'frame', 'layout', 'sentinels', 'builtins' },
    summary = 'each representative\'s type, by running the tree\'s one-argument <P>Is<X>(value) predicates over it',
    derive = function (_, got)
        local CI, F = require 'cartograph.cinterp', require 'cartograph.cinterp.facts'
        local R = got.reps
        local ty = got.slot.type
        local ctx = assert(F.ctx(got))
        local A = CI.analyzer(ctx)
        local holds, size = {}, {}
        for name, d in pairs(got.units.defs) do
            local x = name:match('Is(%u[%w]*)$')
            if x and #d.params == 1 and d.params[1].text == ty and (d.ret == 'bool' or d.ret == '_Bool') then
                local g = x:lower()
                local set = {}
                for _, t in ipairs(R.order) do set[t .. '@1'] = true end
                A.steps = 0
                local sum = A.run(d, { { k = 'slotv', i = 1 }, n = 1 }, {}, 1, set, false)
                local yes, no = {}, {}
                for _, r in ipairs(sum.returns or {}) do
                    for el in pairs(r.fset) do
                        local v = CI.at(r.v, el)
                        if v and v.k == 'i' and tonumber(v.v) ~= 0 then yes[CI.elem(el)] = true else no[CI.elem(el)] = true end
                    end
                end
                for el in pairs(sum.rej or {}) do no[CI.elem(el)] = true end
                holds[g], size[g] = {}, 0
                for t in pairs(yes) do if not no[t] then holds[g][t] = true; size[g] = size[g] + 1 end end
                if size[g] == 0 then holds[g], size[g] = nil, nil end
            end
        end
        if not next(holds) then return nil, 'no one-argument <P>Is<X>(' .. ty .. ') predicate holds for a representative' end
        local sub = {}
        for g, hs in pairs(holds) do
            for u, hu in pairs(holds) do
                if u ~= g and size[g] < size[u] then
                    local all = true
                    for t in pairs(hs) do if not hu[t] then all = false; break end end
                    if all then sub[g] = sub[g] or {}; table.insert(sub[g], u) end
                end
            end
        end
        local out = setmetatable({}, { __index = { subtypes = sub } })
        for _, t in ipairs(R.order) do
            local best
            for g, hs in pairs(holds) do
                if hs[t] and (not best or size[g] < size[best] or (size[g] == size[best] and g < best)) then best = g end
            end
            out[t] = best or '-'
        end
        return out
    end,
}
