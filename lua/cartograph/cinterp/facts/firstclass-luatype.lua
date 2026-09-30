-- FIRSTCLASS: the tags a Lua value may hold — all but those the API's own lua_type conflates with nil (LUA_TNIL, read
-- from the header defining it, for a tag that is not nil: upvalues, traces)
return {
    fact = 'firstclass',
    needs = { 'reps', 'numbers', 'units', 'noret', 'frame', 'layout', 'sentinels', 'builtins' },
    summary = 'the first-class tags, by the API\'s own lua_type',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        local CI = require 'cartograph.cinterp'
        local lt = got.units.defs.lua_type
        if not lt then return nil, 'no lua_type in the tree' end
        local _, _, luanil = F.find(F.files(got, 'h'), '#define%s+LUA_TNIL%s+(%d+)')
        if not luanil then return nil, 'no header defines LUA_TNIL' end
        local A = CI.analyzer(assert(F.ctx(got)))
        local out = {}
        for _, name in ipairs(got.reps.order) do
            local sum = A.run(lt, { CI.thread(), CI._int(1), n = 2 }, {}, 1, { [name .. '@1'] = true }, false)
            local v = sum and sum.vals[name .. '@1'] or nil
            local code = v and v.k == 'i' and CI.asnum(v) or nil
            out[name] = not (code == tonumber(luanil) and got.reps.matrix.tvisnil[name] ~= 1)
        end
        return out
    end,
}
