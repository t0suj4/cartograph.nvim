-- TYPENAMES by the GUARD BIFs' own answer: every registered erlang:is_<t>/1, RUN by the interpreter over every
-- representative (erl_bif_op.c's is_list_1 is `is_list(x) || is_nil(x)` — the BIF, not the C macro, is the type). A
-- representative's type is the guard answering `true` for it with the FEWEST representatives (true/false are
-- `boolean`, other atoms `atom`); ties by name; none (a boxed kind, unknown) is `?`.
return {
    fact = 'typenames',
    needs = { 'reps', 'registrations', 'units', 'noret', 'frame', 'layout', 'sentinels', 'builtins' },
    summary = 'each representative\'s type, by running the erlang:is_<t>/1 guard BIFs over it',
    derive = function (_, got)
        local ffi = require 'ffi'
        local CI, F = require 'cartograph.cinterp', require 'cartograph.cinterp.facts'
        local R = got.reps
        if R.kind ~= 'erlterm' then return nil, 'the representatives are not tagged words' end
        local truth = R.tag['ATOM:true'] and R.tag['ATOM:true'].u64
        if not truth then return nil, 'no representative of the atom true' end
        local ctx = assert(F.ctx(got))
        local A = CI.analyzer(ctx)
        local function word(h) h = ('%016s'):format(h):gsub(' ', '0'); return ffi.cast('uint64_t', ffi.new('uint64_t', tonumber(h:sub(1, 8), 16)) * 2 ^ 32 + tonumber(h:sub(9), 16)) end
        local T = word(truth)
        local holds, size = {}, {}
        for _, e in ipairs(got.registrations.funcs) do
            local g = e.name:match('^is_([%w_]+)$')
            local d = g and e.module == 'erlang' and e.arity == 1 and got.units.defs[e.cfn]
            if d then
                local set = {}
                for _, name in ipairs(R.order) do set[name .. '@1'] = true end
                local args = { n = #d.params }
                for i, p in ipairs(d.params) do
                    if p.name == got.frame.array then args[i] = { k = 'slot', i = 1 } elseif p.type and p.type.k == 'p' then args[i] = CI.object(p.name) end
                end
                A.steps = 0
                local sum = A.run(d, args, {}, 1, set, false)
                -- (a guard HOLDS for a representative when EVERY path returns true for it — a boxed word takes both)
                local yes, no = {}, {}
                for _, r in ipairs(sum.returns or {}) do
                    for el in pairs(r.fset) do
                        local v = CI.at(r.v, el)
                        if v and v.k == 'i' and ffi.cast('uint64_t', v.v) == T then yes[CI.elem(el)] = true else no[CI.elem(el)] = true end
                    end
                end
                for el in pairs(sum.rej or {}) do no[CI.elem(el)] = true end
                holds[g], size[g] = {}, 0
                for name in pairs(yes) do if not no[name] then holds[g][name] = true; size[g] = size[g] + 1 end end
            end
        end
        if not next(holds) then return nil, 'no erlang:is_<t>/1 guard BIF is defined in the tree' end
        local out = {}
        for _, name in ipairs(R.order) do
            local best
            for g, hs in pairs(holds) do
                if hs[name] and (not best or size[g] < size[best] or (size[g] == size[best] and g < best)) then best = g end
            end
            out[name] = best or name:lower() -- (no guard answers for it: a boxed kind is named for itself)
        end
        return out
    end,
}
