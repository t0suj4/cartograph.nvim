-- REGISTRATIONS from FUNCTION-LIST TABLES: the rows `<P>CFUNC_DEF("name", length, cfunc)` and `<P>CFUNC_MAGIC_DEF("name",
-- length, cfunc, magic)` of a unit's `<entry type> <table>[] = { … };` (QuickJS' js_object_funcs: the property name,
-- the registered LENGTH — what the call path pads the argument array to — the C function and its MAGIC, the constant
-- the shared function is handed: Object.getPrototypeOf is magic 0, Reflect.getPrototypeOf magic 1). Which argument is
-- the function and which the magic is the MACRO's own parameter list (`func1`, `magic`); a macro that also takes a
-- `cproto` registers a function called through ANOTHER prototype (JS_CFUNC_SPECIAL_DEF's `double f(double)`): not a row.
-- The OWNER a table is installed on is not here: that is the running realm's (the adapter's join).
return {
    fact = 'registrations',
    needs = { 'compdb', 'units' },
    summary = 'name -> C function, registered length and magic, from <P>CFUNC_DEF rows of function-list tables',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        local FR = dofile(debug.getinfo(1, 'S').source:sub(2):gsub('[^/]+$', 'frame-cfunctype.lua'))
        -- (each DEF macro's parameters: where the function and the magic are)
        local macros = {}
        for _, p in ipairs(F.files(got, 'h')) do
            for name, params in (F.readfile(p) or ''):gmatch('#%s*define%s+([%u_]*CFUNC[%u_]*DEF%d?)(%b())') do
                local ps = vim.split(params:sub(2, -2), ',', { trimempty = true })
                local m = { }
                for i, x in ipairs(ps) do
                    x = vim.trim(x)
                    if x:match('^func') then m.func = i elseif x == 'magic' then m.magic = i elseif x == 'cproto' then m.cproto = i end
                end
                macros[name] = m
            end
        end
        local funcs, byc, skipped = {}, {}, 0
        for _, u in ipairs(got.compdb.units) do
            local t = F.readfile(u.file) or ''
            for tbl, body in t:gmatch('([%w_]+)%s*%[%s*%]%s*=%s*(%b{})') do
                for macro, args in body:gmatch('([%u_]*CFUNC[%u_]*DEF%d?)%s*(%b())') do
                    local m = macros[macro]
                    local as = FR.split(args)
                    local name, len = (as[1] or ''):match('^"([^"]*)"$'), tonumber(as[2] or '')
                    if m and m.func and not m.cproto and name and len then
                        local cfn = as[m.func] and as[m.func]:match('^([%w_]+)$')
                        local magic
                        if m.magic and as[m.magic] then
                            local x = as[m.magic]
                            magic = tonumber(x) or got.units.enums[x]
                            if magic == nil then magic = false end
                        end
                        if cfn then
                            local e = { name = name, length = len, cfn = cfn, magic = magic, table = tbl, macro = macro }
                            funcs[#funcs + 1] = e
                            byc[cfn] = byc[cfn] or e
                        end
                    elseif m and m.cproto then skipped = skipped + 1 end
                end
            end
        end
        if #funcs == 0 then return nil, 'no table holds <P>CFUNC_DEF("name", length, cfunc) rows' end
        return { funcs = funcs, byc = byc, other_prototype = skipped }
    end,
}
