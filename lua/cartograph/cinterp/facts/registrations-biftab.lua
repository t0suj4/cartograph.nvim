-- REGISTRATIONS from a GENERATED BIF TABLE: the unit whose `{am_<module>, am_<name>, <arity>, <cfunc>, …}` rows the build
-- generated (erts' erl_bif_table.c, by make_tables), each atom's TEXT from the generated atom table (`#define
-- am_<c> make_atom(<i>)` and `erl_atom_names[i]`)
return {
    fact = 'registrations',
    needs = { 'compdb' },
    summary = 'module:name/arity -> C function, from the generated BIF table and atom table',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        local rows, names, index = {}, nil, {}
        for _, u in ipairs(got.compdb.units) do
            local t = F.readfile(u.file) or ''
            for m, n, a, c in t:gmatch('{%s*am_([%w_]+)%s*,%s*am_([%w_]+)%s*,%s*(%d+)%s*,%s*([%w_]+)%s*,') do rows[#rows + 1] = { m, n, tonumber(a), c } end
            local body = t:match('erl_atom_names%[%]%s*=%s*{(.-)};')
            if body then names = {}; for s in body:gmatch('"([^"]*)"') do names[#names + 1] = s end end
        end
        if #rows == 0 then return nil, 'no unit holds a {am_<module>, am_<name>, <arity>, <cfunc>} table' end
        if not names then return nil, 'no unit holds the atom names (erl_atom_names[])' end
        for _, p in ipairs(F.files(got, 'h')) do
            for c, i in (F.readfile(p) or ''):gmatch('#%s*define%s+am_([%w_]+)%s+make_atom%((%d+)%)') do index[c] = tonumber(i) end
        end
        local function text(c) local i = index[c]; return i and names[i + 1] or c end
        local funcs, byc = {}, {}
        for _, r in ipairs(rows) do
            local e = { module = text(r[1]), name = text(r[2]), arity = r[3], cfn = r[4] }
            funcs[#funcs + 1] = e
            byc[e.cfn] = byc[e.cfn] or e
        end
        return { funcs = funcs, byc = byc, atoms = index, natoms = #names }
    end,
}
