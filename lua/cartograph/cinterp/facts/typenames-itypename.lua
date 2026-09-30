-- TYPENAMES: Lua's type() name of each tag — a unit's `<x>_itypename[] = { "nil", … }`, by position (the tags' ~N)
return {
    fact = 'typenames',
    needs = { 'reps', 'numbers', 'compdb' },
    summary = 'each tag\'s type() name, from an itypename table',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        local _, _, body
        for _, u in ipairs(got.compdb.units) do
            body = (F.readfile(u.file) or ''):match('[%w_]*itypename%[%]%s*=%s*{(.-)}')
            if body then break end
        end
        if not body then return nil, 'no unit defines an `<x>_itypename[]` table' end
        local names = {}
        for s in body:gmatch('"([^"]*)"') do names[#names + 1] = s end
        local out = { ABSENT = 'absent' }
        for name, t in pairs(got.reps.tag) do out[name] = names[bit.band(bit.bnot(t.value), 0xffffffff) + 1] end
        for name, n in pairs(got.numbers.numof) do out[name] = out[n] end
        return out
    end,
}
