-- LAYOUT of a SCALAR slot type (erts' Eterm, a machine word): its width and signedness from the typedef chain — the
-- slot is read whole, one field ''
return {
    fact = 'layout',
    needs = { 'slot', 'units' },
    summary = 'a scalar slot type: its width and signedness, read whole',
    derive = function (_, got)
        local ty = require('cartograph.cinterp').ctype(got.slot.type, got.units.typedefs)
        -- (a POINTER slot — CPython's `PyObject *` — is a word too: the object's address, read whole)
        if ty and ty.k == 'p' then
            local w = require('ffi').sizeof('void *') * 8
            return { layout = { scalar = true, size = w / 8, fields = { [''] = { off = 0, cls = 'u' .. w } } }, scalar = { k = 'i', w = w, u = true }, pointer = ty }
        end
        if not (ty and ty.k == 'i') then return nil, got.slot.type .. ' is not an integer type' end
        return { layout = { scalar = true, size = ty.w / 8, fields = { [''] = { off = 0, cls = (ty.u and 'u' or 'i') .. ty.w } } }, scalar = ty }
    end,
}
