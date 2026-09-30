-- SENTINELS: a VM cell whose initializer in the tree is a tag's setter — `set<tag>V(&<var>-><a>.<b>)` in a unit
-- (niltv's cell is nil)
return {
    fact = 'sentinels',
    needs = { 'reps', 'compdb' },
    summary = 'VM cells a set<tag>V initializes, and their tags',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        local out = {}
        for _, u in ipairs(got.compdb.units) do
            for setter, fp in (F.readfile(u.file) or ''):gmatch('(set%a+V)%(%s*&%s*[%w_]+%s*%->%s*([%w_]+%.[%w_]+)%s*%)') do
                local nm = setter:match('^set(%a+)V$'):upper()
                if got.reps.tag[nm] then out[fp] = nm end
            end
        end
        return out
    end,
}
