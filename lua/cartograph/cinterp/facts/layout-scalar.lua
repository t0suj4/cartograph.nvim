-- LAYOUT of a SCALAR slot type (erts' Eterm, a machine word): its width and signedness from the typedef chain — the
-- slot is read whole, one field ''
return {
    fact = 'layout',
    needs = { 'slot', 'units' },
    summary = 'a scalar slot type: its width and signedness, read whole',
    derive = function (_, got)
        local ty = require('cartograph.cinterp').ctype(got.slot.type, got.units.typedefs)
        if not (ty and ty.k == 'i') then return nil, got.slot.type .. ' is not an integer type' end
        return { layout = { scalar = true, size = ty.w / 8, fields = { [''] = { off = 0, cls = (ty.u and 'u' or 'i') .. ty.w } } }, scalar = ty }
    end,
}
