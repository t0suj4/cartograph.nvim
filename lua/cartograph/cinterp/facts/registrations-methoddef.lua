-- REGISTRATIONS from METHOD TABLES: the rows `{ "name", (cast) cfunc, flags, doc }` of a unit's `<T> <table>[] = { … }`
-- in the PREPROCESSED text (CPython's PyMethodDef: builtin_methods, list_methods — Argument Clinic's *_METHODDEF macros
-- expanded); the flags a number there, NAMED by the headers' own `#define METH_<X> <value>` (METH_O, METH_FASTCALL,
-- METH_KEYWORDS …). The OWNER of a table is the first string literal of the initializer that names it: a PyModuleDef's
-- "builtins", a PyTypeObject's tp_name "list".
return {
    fact = 'registrations',
    needs = { 'compdb', 'sources', 'units' },
    summary = 'owner.name -> C function and its calling flags, from PyMethodDef-shaped rows of method tables',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        local FR = dofile(debug.getinfo(1, 'S').source:sub(2):gsub('[^/]+$', 'frame-cfunctype.lua'))
        local bit = require 'bit'
        local flagname = {}
        for _, p in ipairs(F.files(got, 'h')) do
            for nm, v in (F.readfile(p) or ''):gmatch('#%s*define%s+METH_([%u_]+)%s+(0x%x+)') do flagname[nm] = tonumber(v) end
        end
        if not next(flagname) then return nil, 'no header defines METH_<X> flags' end
        local function flags(text)
            local v = 0
            for num in text:gmatch('0x%x+') do v = bit.bor(v, tonumber(num)) end
            for num in text:gsub('0x%x+', ''):gmatch('%f[%w]%d+%f[^%w]') do v = bit.bor(v, tonumber(num)) end
            return v
        end
        local funcs, byc, tables = {}, {}, {}
        for _, s in ipairs(got.sources.units) do
            for tbl, body in s.text:gmatch('([%w_]+)%s*%[%s*%d*%s*%]%s*=%s*(%b{})') do
                local rows = {}
                for row in body:sub(2, -2):gmatch('%b{}') do
                    local as = FR.split('(' .. row:sub(2, -2) .. ')')
                    local name = as[1] and as[1]:match('^"([^"]*)"$')
                    -- (the function: the last identifier of the cast expression that is a definition —
                    -- `((PyCFunction)(void(*)(void))(builtin_getattr))`)
                    local cfn
                    for id in (as[2] or ''):gmatch('[%a_][%w_]*') do if got.units.defs[id] then cfn = id end end
                    if name and cfn and as[3] and not as[3]:find('"', 1, true) then
                        local fv = flags(as[3])
                        local names = {}
                        for nm, v in pairs(flagname) do if v ~= 0 and bit.band(fv, v) == v then names[nm] = true end end
                        rows[#rows + 1] = { name = name, cfn = cfn, flags = fv, meth = names, table = tbl, unit = s.name }
                    end
                end
                if #rows > 0 then tables[tbl] = { rows = rows, unit = s.name } end
            end
        end
        if not next(tables) then return nil, 'no table holds { "name", cfunc, METH flags, doc } rows' end
        -- (each table's OWNER: the first string literal of an initializer naming it)
        for _, s in ipairs(got.sources.units) do
            for _, body in s.text:gmatch('([%w_]+)%s*=%s*(%b{})') do
                for tbl, t in pairs(tables) do
                    if not t.owner and t.unit == s.name and body:find('%f[%w_]' .. tbl .. '%f[^%w_]') and not body:find('^{%s*{%s*"') then
                        t.owner = body:match('"([^"]*)"')
                    end
                end
            end
        end
        for tbl, t in pairs(tables) do
            for _, e in ipairs(t.rows) do
                e.owner = t.owner
                funcs[#funcs + 1] = e
                byc[e.cfn] = byc[e.cfn] or e
            end
        end
        table.sort(funcs, function (a, b) return (a.owner or '') .. a.name < (b.owner or '') .. b.name end)
        return { funcs = funcs, byc = byc }
    end,
}
