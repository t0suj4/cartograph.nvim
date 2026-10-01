-- REPS of a TAGGED AGGREGATE (QuickJS' JSValue: `{ JSValueUnion u; int64_t tag; }`): one per constant of the tree's
-- TAG ENUM — the family of enum constants sharing a `<P>TAG_` prefix that the units USE most (QuickJS' JS_TAG_, not
-- the serializer's larger BC_TAG_; an alias of another's value, like JS_TAG_FIRST, dropped for the name used more) —
-- its WORDS the slot's size: the tag field holding the constant, every other word UNKNOWN (false). The payload is
-- never invented: a check that reads it — a pointer tag's object, an int's value — reads as content, sound for every
-- value of that tag.
return {
    fact = 'reps',
    needs = { 'layout', 'units', 'sources' },
    summary = 'one representative per constant of the <P>TAG_ enum, the tag field set and the payload unknown',
    derive = function (_, got)
        local bit, ffi = require 'bit', require 'ffi'
        local L = got.layout.layout
        if L.scalar then return nil, 'the slot is a scalar word, not an aggregate with a tag field' end
        -- (the TAG field: the slot's integer field named tag, else its only integer field)
        local tf, ints = nil, {}
        for name, f in pairs(L.fields) do if f.cls:match('^[iu]%d') then ints[#ints + 1] = name; if name:lower():find('tag') then tf = name end end end
        tf = tf or (#ints == 1 and ints[1]) or nil
        if not tf then return nil, 'the slot has no tag field (an integer field named tag, or its only integer field)' end
        local fams = {}
        for nm, v in pairs(got.units.enums) do
            local p, x = nm:match('^(.-TAG_)(.+)$')
            if p then fams[p] = fams[p] or {}; table.insert(fams[p], { x, tonumber(v), nm }) end
        end
        -- (the USES of every family's constants, one pass over the units)
        local uses, fam_uses = {}, {}
        for _, s in ipairs(got.sources.units) do
            for nm in s.text:gmatch('[%w_]*TAG_[%w_]+') do uses[nm] = (uses[nm] or 0) + 1 end
        end
        local best
        for p, l in pairs(fams) do
            fam_uses[p] = 0
            for _, t in ipairs(l) do fam_uses[p] = fam_uses[p] + (uses[t[3]] or 0) end
            if not best or fam_uses[p] > fam_uses[best] then best = p end
        end
        if not best then return nil, 'no enum family <P>TAG_<X>' end
        -- (an ALIAS — two names, one value — keeps the name the units use more)
        local function count(nm) return uses[nm] or 0 end
        local byv = {}
        for _, t in ipairs(fams[best]) do
            local cur = byv[t[2]]
            if not cur or count(t[3]) > count(cur[3]) or (count(t[3]) == count(cur[3]) and t[1] < cur[1]) then byv[t[2]] = t end
        end
        local tags = vim.tbl_values(byv)
        table.sort(tags, function (a, b) return a[2] < b[2] end)
        local f = L.fields[tf]
        local nw = math.ceil((L.size or 8) / 8)
        local R = { order = {}, tag = {}, kind = 'tagenum', field = tf, prefix = best, value = {} }
        for _, t in ipairs(tags) do
            local words = {}
            for i = 1, nw do words[i] = false end
            local inword = f.off % 8
            local w = ffi.cast('uint64_t', ffi.cast('int64_t', t[2]))
            if f.cls:match('%d+') ~= '64' then w = bit.band(w, ffi.cast('uint64_t', 2 ^ tonumber(f.cls:match('%d+')) - 1)) end
            words[math.floor(f.off / 8) + 1] = bit.tohex(bit.lshift(w, inword * 8), 16)
            R.order[#R.order + 1] = t[1]
            R.tag[t[1]] = { words = words }
            R.value[t[1]] = t[2]
        end
        return R
    end,
}
