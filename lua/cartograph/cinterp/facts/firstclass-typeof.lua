-- FIRSTCLASS by the language's own TYPEOF: the function of the tree implementing it — named `…_typeof` (not getPrototypeOf), taking a value
-- of the slot type (QuickJS' js_operator_typeof: a switch on the tag) — RUN by the interpreter over every
-- representative; one it answers ONLY with its switch's DEFAULT arm (`default: atom = JS_ATOM_unknown;`) is no value
-- of the language (an exception marker, a catch offset, bytecode). An answer read from memory (an object: function or
-- object) still answers: first-class.
return {
    fact = 'firstclass',
    needs = { 'reps', 'slot', 'units', 'noret', 'frame', 'layout', 'sentinels', 'builtins' },
    summary = 'the first-class representatives: those the typeof operator answers outside its default arm',
    derive = function (_, got)
        local CI, F = require 'cartograph.cinterp', require 'cartograph.cinterp.facts'
        local R = got.reps
        local ty = got.slot.type
        local d, at
        local names = vim.tbl_keys(got.units.defs)
        table.sort(names)
        for _, name in ipairs(names) do
            if name:lower():match('_typeof$') or name:lower() == 'typeof' then
                for i, p in ipairs(got.units.defs[name].params) do if p.text == ty then d, at = got.units.defs[name], i; break end end
            end
            if d then break end
        end
        if not d then return nil, 'no …typeof function takes a ' .. ty end
        local text = CI.tx(d.node, d.src)
        local dname = text:match('default%s*:%s*[%w_]+%s*=%s*([%w_]+)%s*;') or text:match('default%s*:%s*return%s+([%w_]+)%s*;')
        local dv = dname and (got.units.enums[dname] or tonumber(dname))
        if not dv then return nil, d.name .. ' has no default arm answering a constant' end
        local ctx = assert(F.ctx(got))
        local A = CI.analyzer(ctx)
        local set = {}
        for _, t in ipairs(R.order) do set[t .. '@1'] = true end
        local args = { n = #d.params }
        for i, p in ipairs(d.params) do
            if i == at then args[i] = { k = 'slotv', i = 1 } elseif p.type and p.type.k == 'p' then args[i] = CI.object(p.name) end
        end
        A.steps = 0
        local sum = A.run(d, args, {}, 1, set, false)
        local out = {}
        for _, t in ipairs(R.order) do out[t] = false end
        for _, r in ipairs(sum.returns or {}) do
            for el in pairs(r.fset) do
                local v = CI.at(r.v, el)
                if not (v and v.k == 'i' and tonumber(v.v) == tonumber(dv)) then out[CI.elem(el)] = true end
            end
        end
        return out
    end,
}
