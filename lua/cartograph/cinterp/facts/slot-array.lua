-- SLOT of an ARGUMENT ARRAY frame: the type its elements have — what the array parameter points to (`Eterm *BIF__ARGS`)
return {
    fact = 'slot',
    needs = { 'frame', 'units' },
    summary = 'the slot type: what an argument array parameter points to',
    derive = function (_, got)
        local fr = got.frame
        if fr.kind ~= 'array' then return nil, 'the frame is not an argument array' end
        for _, d in pairs(got.units.defs) do
            for _, p in ipairs(d.params) do if p.name == fr.array and p.pointee then return { type = p.pointee } end end
        end
        return nil, 'no function takes the argument array ' .. fr.array
    end,
}
