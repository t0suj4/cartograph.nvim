-- cartograph.flowtype_go — the GO walker of cartograph.flowtype (CART-1621): the same inclusion flow, over Go, with
-- every DECLARED type of a variable, parameter, field or return IGNORED — so the type checker can score it. What is
-- read from types is what a dynamically typed program also has at its allocation sites: `T{…}` / `&T{…}` / `new(T)`
-- create an object whose methods are T's (a method table per (package dir, type), filled by the method declarations;
-- an EMBEDDED field's type's table is a prototype — Go's promotion). Everything else FLOWS: assignments (`:=`, `=`,
-- `var`), multi-value returns, parameters (the receiver is the first), `range` (value: `[]`, key: `{k}`), channels,
-- index expressions, function values, `pkg.Name` (the package's top-level name). Every method call `x.m(…)` is a
-- PROBE: which functions reach field(x, m).
local tsutil = require 'cartograph.spec.tsutil'

local M = {}

local EMPTY_NODE = { child = function () return nil end }
local function kids(n) return tsutil.inext, n or EMPTY_NODE, -1 end

--- a walker over the solver S for the tree's Go files -> walk(file, src)
function M.walker(S, files)
    local new, newobj, addobj, edge, ofp, storec, callc, port, objproto, fnports =
        S.new, S.newobj, S.addobj, S.edge, S.ofp, S.storec, S.callc, S.port, S.objproto, S.fnports
    -- (Go records have no dynamic keys: every load is STRICT — exactly its field)
    local function field(x, f) return S.field(x, f, true) end
    -- the module path (go.mod), for an import path -> its directory in the tree
    local modpath
    do
        local fd = type(S.root) == 'string' and io.open(S.root .. '/go.mod')
        local t = fd and fd:read('a')
        if fd then fd:close() end
        modpath = t and t:match('^%s*module%s+(%S+)') or t and t:match('\nmodule%s+(%S+)')
    end
    local dirs = {}
    for _, f in ipairs(files) do if f:match('%.go$') then dirs[f:match('^(.*)/[^/]+$') or '.'] = true end end
    local function dir_of_import(path)
        if not (modpath and path) then return nil end
        if path == modpath then return '.' end
        local rel = path:sub(1, #modpath + 1) == modpath .. '/' and path:sub(#modpath + 2)
        return rel and dirs[rel] and rel or nil
    end
    -- a type's METHOD TABLE: one object per (dir, type name); a value allocated as T carries it as its prototype
    local mt = {}
    local function mtobj(dir, tname)
        local k = dir .. ':' .. tname
        local o = mt[k]
        if not o then o = newobj('mt:' .. k); mt[k] = o end
        return o
    end
    local typenames = {} -- dir -> { [type name] = true }: a call `T(x)` is a CONVERSION, its value is x
    -- the names a package DECLARES at top level (the graph's nodes): only those resolve to the package's port — an
    -- identifier the walker cannot bind is a fresh port, never a name shared across the package's functions (a
    -- `bytes.Buffer` named `buf` in one function had joined pflag values named `buf` in another)
    local pkgnames = {}
    for _, nd in ipairs(S.nodes or {}) do
        local f = nd.file
        if type(f) == 'string' and f:match('%.go$') and (nd.kind == 'function' or nd.kind == 'var' or nd.kind == 'class') then
            local d = f:match('^(.*)/[^/]+$') or '.'
            local nm = tostring(nd.name):match('([%w_]+)$')
            if nm and not tostring(nd.name):find('[.:]') then
                pkgnames[d] = pkgnames[d] or {}
                pkgnames[d][nm] = true
            end
        end
    end
    return function (file, src)
        local okp, parser = pcall(vim.treesitter.get_string_parser, src, 'go')
        if not okp then return end
        local tree = parser:parse()[1]:root()
        local dir = file:match('^(.*)/[^/]+$') or '.'
        local fnmap = S.fn_at[file] or {}
        local function txt(n) local _, _, s, _, _, e = n:range(true); return src:sub(s + 1, e) end
        local tn = typenames[dir]
        if not tn then tn = {}; typenames[dir] = tn end
        -- imports: alias -> directory
        local imports = {}
        for _, d in kids(tree) do
            if d:type() == 'import_declaration' then
                local function spec(sp)
                    local p = sp:field('path')[1]
                    local nm = sp:field('name')[1]
                    local path = p and txt(p):gsub('^"', ''):gsub('"$', '')
                    local dd = dir_of_import(path)
                    if dd then imports[nm and txt(nm) or path:match('([^/]+)$')] = dd end
                end
                for _, c in kids(d) do
                    if c:type() == 'import_spec' then spec(c)
                    elseif c:type() == 'import_spec_list' then for _, sp in kids(c) do if sp:type() == 'import_spec' then spec(sp) end end end
                end
            end
        end
        -- the TYPE NAME an allocation names: `T`, `pkg.T`, `*T`, `T[U]` -> dir, name | nil
        local function tname_of(t)
            if not t then return nil end
            local ty = t:type()
            if ty == 'type_identifier' then return dir, txt(t) end
            if ty == 'pointer_type' then return tname_of(t:named_child(0)) end
            if ty == 'generic_type' then return tname_of(t:field('type')[1]) end
            if ty == 'qualified_type' then
                local pk, nm = t:field('package')[1], t:field('name')[1]
                local dd = pk and imports[txt(pk)]
                if dd and nm then return dd, txt(nm) end
            end
            return nil
        end
        local scopes = { {} }
        local pn = pkgnames[dir] or {}
        local function lookup(name)
            for i = #scopes, 1, -1 do local p = scopes[i][name]; if p then return p end end
            if pn[name] or tn[name] then return port('pkg:' .. dir .. ':' .. name) end
            return new() -- (an unbound name: unknown, shared with nothing)
        end
        local function declare(name, p) local q = p or new(); scopes[#scopes][name] = q; return q end
        local fnstack = {}
        local expr, stmt, block
        local function list_of(n) -- an expression_list's members
            local out = {}
            if n and n:type() == 'expression_list' then for _, x in kids(n) do if x:named() then out[#out + 1] = x end end
            elseif n then out[1] = n end
            return out
        end
        local function params_of(pl, fp, i)
            for _, pd in kids(pl) do
                if pd:type() == 'parameter_declaration' or pd:type() == 'variadic_parameter_declaration' then
                    local any = false
                    for _, nm in kids(pd) do
                        if nm:type() == 'identifier' then
                            any = true
                            i = i + 1
                            fp.params[i] = declare(txt(nm), fp.params[i])
                        end
                    end
                    if not any then i = i + 1 end -- (an unnamed parameter still takes its position)
                end
            end
            return i
        end
        local function func(n, id, recvname)
            local p = new()
            local o = newobj(id)
            addobj(p, o)
            local fp = { params = {}, rets = {} }
            for k = 1, 8 do fp.rets[k] = port('r:' .. id .. ':' .. k) end
            fp.ret = fp.rets[1]
            for k = 1, 16 do fp.params[k] = port('a:' .. id .. ':' .. k) end
            fnports[o] = fp
            scopes[#scopes + 1] = {}
            local i = 0
            if recvname then
                local rl = n:field('receiver')[1]
                i = params_of(rl, fp, 0)
            end
            params_of(n:field('parameters')[1], fp, i)
            -- (NAMED results are variables the function returns: each is its return port)
            local res = n:field('result')[1]
            if res and res:type() == 'parameter_list' then
                local k = 0
                for _, pd in kids(res) do
                    if pd:type() == 'parameter_declaration' then
                        local any = false
                        for _, nm in kids(pd) do
                            if nm:type() == 'identifier' then any = true; k = k + 1; if fp.rets[k] then declare(txt(nm), fp.rets[k]) end end
                        end
                        if not any then k = k + 1 end
                    end
                end
            end
            fnstack[#fnstack + 1] = fp
            local body = n:field('body')[1]
            if body then block(body) end
            fnstack[#fnstack] = nil
            scopes[#scopes] = nil
            return p, o
        end
        local function fnid(n)
            local l, c = n:start()
            return fnmap[l .. ':' .. c] or ('ts:' .. file .. ':' .. l .. ':' .. c)
        end
        -- an allocation of type T -> a port holding a fresh object with T's methods
        local function alloc(d, nm, tag)
            local p = new()
            local o = newobj(tag)
            addobj(p, o)
            if d and nm then objproto(o, mtobj(d, nm)) end
            return p, o
        end
        local function callv(n) -- -> the result ports (a list: multi-value)
            local f = n:field('function')[1]
            local args = {}
            for _, a in kids(n:field('arguments')[1]) do if a:named() then args[#args + 1] = a end end
            local res = { new(), new(), new(), new() }
            if not f then return res end
            local ft = f:type()
            if ft == 'identifier' then
                local nm = txt(f)
                if nm == 'new' and args[1] then local d, t = tname_of(args[1]); res[1] = alloc(d, t, 'new'); return res end
                if nm == 'make' then res[1] = alloc(nil, nil, 'make'); return res end
                if nm == 'append' and args[1] then
                    local s = expr(args[1])
                    for j = 2, #args do storec(s, '[]', expr(args[j])) end
                    edge(s, res[1])
                    return res
                end
                if (tn[nm] or nm:match('^u?int%d*$') or nm == 'string' or nm == 'byte' or nm == 'float64' or nm == 'any')
                    and #args == 1 and not scopes[#scopes][nm] then
                    edge(expr(args[1]), res[1]) -- (a conversion `T(x)`: the value is x's)
                    return res
                end
            end
            local recvp, callee
            if ft == 'selector_expression' then
                local op, fl = f:field('operand')[1], f:field('field')[1]
                local pk = op and op:type() == 'identifier' and imports[txt(op)]
                if pk and not (function () for i = #scopes, 1, -1 do if scopes[i][txt(op)] then return true end end end)() then
                    callee = port('pkg:' .. pk .. ':' .. txt(fl))
                else
                    recvp = expr(op)
                    callee = field(recvp, txt(fl))
                    local l, c = op:start()
                    S.probes[#S.probes + 1] = { file = file, line = l, col = c, member = txt(fl), recv = recvp }
                end
            else callee = expr(f) end
            local aps = {}
            if recvp then aps[1] = recvp end
            for _, a in ipairs(args) do aps[#aps + 1] = expr(a) end
            callc(callee, aps, res)
            return res
        end
        expr = function (n)
            local t = n:type()
            if t == 'identifier' then return lookup(txt(n)) end
            if t == 'parenthesized_expression' then return expr(n:named_child(0)) end
            if t == 'selector_expression' then
                local op, fl = n:field('operand')[1], n:field('field')[1]
                local pk = op and op:type() == 'identifier' and imports[txt(op)]
                if pk and not scopes[#scopes][txt(op)] then return port('pkg:' .. pk .. ':' .. txt(fl)) end
                return field(expr(op), txt(fl))
            end
            if t == 'call_expression' then return callv(n)[1] end
            if t == 'func_literal' then return (func(n, fnid(n))) end
            if t == 'interpreted_string_literal' or t == 'raw_string_literal' then
                local p = new(); addobj(p, S.STR); return p
            end
            if t == 'unary_expression' then
                local op = n:child(0)
                local x = n:field('operand')[1]
                if op and txt(op) == '<-' and x then return field(expr(x), '[]') end
                if x then return expr(x) end -- (&x, *x: the same value for flow)
                return new()
            end
            if t == 'composite_literal' then
                local d, nm = tname_of(n:field('type')[1])
                local p, o = alloc(d, nm, 'lit:' .. file .. ':' .. (n:start()))
                for _, el in kids(n:field('body')[1]) do
                    if el:type() == 'keyed_element' then
                        local k, v = el:named_child(0), el:named_child(1)
                        local kk = k and k:named_child(0) or k
                        local vv = v and v:named_child(0) or v
                        local vp = vv and expr(vv)
                        if vp then
                            if kk and kk:type() == 'identifier' and nm then edge(vp, ofp(o, txt(kk)))
                            else edge(vp, ofp(o, '[]')); if kk then edge(expr(kk), ofp(o, '{k}')) end end
                        end
                    elseif el:type() == 'literal_element' then
                        local vv = el:named_child(0)
                        if vv then edge(expr(vv), ofp(o, '[]')) end
                    end
                end
                return p
            end
            if t == 'index_expression' then
                local x = n:field('operand')[1]
                for _, c in kids(n) do if c:named() and c ~= x then expr(c) end end
                return x and field(expr(x), '[]') or new()
            end
            if t == 'type_assertion_expression' or t == 'slice_expression' then
                local x = n:field('operand')[1] or n:named_child(0)
                return x and expr(x) or new()
            end
            if t == 'binary_expression' then
                local a, b = n:field('left')[1], n:field('right')[1]
                if a then expr(a) end
                if b then expr(b) end
                return new()
            end
            for _, c in kids(n) do if c:named() then expr(c) end end
            return new()
        end
        local function assign_list(lefts, rights, decl)
            local rp = {}
            if #rights == 1 and #lefts > 1 and rights[1]:type() == 'call_expression' then
                rp = callv(rights[1])
            elseif #rights == 1 and #lefts == 2 and rights[1]:type() == 'index_expression' then
                rp = { expr(rights[1]), new() } -- (`v, ok := m[k]`)
            elseif #rights == 1 and #lefts == 2 and rights[1]:type() == 'type_assertion_expression' then
                rp = { expr(rights[1]), new() }
            else
                for i, r in ipairs(rights) do rp[i] = expr(r) end
            end
            for i, l in ipairs(lefts) do
                local v = rp[i]
                local lt = l:type()
                if lt == 'identifier' then
                    local nm = txt(l)
                    if nm ~= '_' then
                        local target = decl and declare(nm) or lookup(nm)
                        if v then edge(v, target) end
                    end
                elseif lt == 'selector_expression' and v then
                    local op, fl = l:field('operand')[1], l:field('field')[1]
                    local pk = op and op:type() == 'identifier' and imports[txt(op)]
                    if pk then edge(v, port('pkg:' .. pk .. ':' .. txt(fl))) else storec(expr(op), txt(fl), v) end
                elseif lt == 'index_expression' and v then
                    local x = l:field('operand')[1]
                    local xp = x and expr(x)
                    if xp then
                        storec(xp, '[]', v)
                        for _, c in kids(l) do if c:named() and c ~= x then storec(xp, '{k}', expr(c)) end end
                    end
                elseif lt == 'unary_expression' and v then
                    local x = l:field('operand')[1]
                    if x then edge(v, expr(x)) end
                end
            end
        end
        stmt = function (n)
            local t = n:type()
            if t == 'short_var_declaration' then
                assign_list(list_of(n:field('left')[1]), list_of(n:field('right')[1]), true)
            elseif t == 'assignment_statement' then
                local op = n:field('operator')[1]
                local o = op and txt(op) or '='
                if o == '=' then assign_list(list_of(n:field('left')[1]), list_of(n:field('right')[1]), false)
                else expr(n:field('right')[1] or n) end
            elseif t == 'var_declaration' or t == 'const_declaration' then
                local function spec(sp)
                    local names, vals = {}, {}
                    for _, c in kids(sp) do
                        if c:type() == 'identifier' then names[#names + 1] = c end
                    end
                    local v = sp:field('value')[1]
                    vals = list_of(v)
                    if #vals > 0 then assign_list(names, vals, true)
                    else for _, nm in ipairs(names) do declare(txt(nm)) end end
                end
                for _, c in kids(n) do
                    if c:type() == 'var_spec' or c:type() == 'const_spec' then spec(c)
                    elseif c:type() == 'var_spec_list' then for _, sp in kids(c) do if sp:type() == 'var_spec' then spec(sp) end end end
                end
            elseif t == 'return_statement' then
                local fp = fnstack[#fnstack]
                local vals = list_of(n:named_child(0))
                if #vals == 1 and vals[1]:type() == 'call_expression' and fp then
                    local r = callv(vals[1])
                    for i = 1, 4 do edge(r[i], fp.rets[i]) end
                else
                    for i, v in ipairs(vals) do local vp = expr(v); if fp and fp.rets[i] then edge(vp, fp.rets[i]) end end
                end
            elseif t == 'expression_statement' or t == 'go_statement' or t == 'defer_statement' then
                for _, c in kids(n) do if c:named() then expr(c) end end
            elseif t == 'send_statement' then
                local ch, v = n:field('channel')[1], n:field('value')[1]
                if ch and v then storec(expr(ch), '[]', expr(v)) end
            elseif t == 'for_statement' then
                scopes[#scopes + 1] = {}
                for _, c in kids(n) do
                    if c:type() == 'range_clause' then
                        local left, right = c:field('left')[1], c:field('right')[1]
                        local rp = right and expr(right)
                        local ls = list_of(left)
                        if rp then
                            local decl = true
                            for i, l in ipairs(ls) do
                                if l:type() == 'identifier' and txt(l) ~= '_' then
                                    local p = decl and declare(txt(l)) or lookup(txt(l))
                                    edge(field(rp, i == 1 and '{k}' or '[]'), p)
                                end
                            end
                        end
                    elseif c:type() == 'for_clause' then
                        for _, x in kids(c) do if x:named() then stmt(x) end end
                    elseif c:type() == 'block' then block(c)
                    elseif c:named() then expr(c) end
                end
                scopes[#scopes] = nil
            elseif t == 'if_statement' or t == 'expression_switch_statement' or t == 'type_switch_statement'
                or t == 'select_statement' or t == 'labeled_statement' then
                scopes[#scopes + 1] = {}
                if t == 'type_switch_statement' then
                    -- (`switch v := x.(type)`: v is x in every case)
                    local al, val = n:field('alias')[1], n:field('value')[1]
                    if al and val then
                        local vp = expr(val)
                        for _, a in ipairs(list_of(al)) do if a:type() == 'identifier' then edge(vp, declare(txt(a))) end end
                    end
                end
                for _, c in kids(n) do
                    if c:named() then
                        local ct = c:type()
                        if ct == 'block' then block(c)
                        elseif ct:find('statement', 1, true) or ct:find('declaration', 1, true) or ct:find('case', 1, true)
                            or ct == 'communication_case' or ct == 'default_case' then stmt(c)
                        else expr(c) end
                    end
                end
                scopes[#scopes] = nil
            elseif t == 'expression_case' or t == 'default_case' or t == 'type_case' or t == 'communication_case' then
                scopes[#scopes + 1] = {}
                for _, c in kids(n) do
                    if c:named() then
                        local ct = c:type()
                        if ct:find('statement', 1, true) or ct:find('declaration', 1, true) then stmt(c) else expr(c) end
                    end
                end
                scopes[#scopes] = nil
            elseif t == 'block' then block(n)
            elseif t == 'statement_list' then for _, c in kids(n) do if c:named() then stmt(c) end end
            elseif t == 'inc_statement' or t == 'dec_statement' then
            elseif t:find('statement', 1, true) or t:find('declaration', 1, true) then
                for _, c in kids(n) do if c:named() then stmt(c) end end
            else expr(n) end
        end
        block = function (n)
            scopes[#scopes + 1] = {}
            for _, c in kids(n) do
                if c:named() then
                    if c:type() == 'statement_list' then for _, s in kids(c) do if s:named() then stmt(s) end end
                    else stmt(c) end
                end
            end
            scopes[#scopes] = nil
        end
        -- (top level: types first — the embedding prototypes —, then the declarations)
        for _, d in kids(tree) do
            if d:type() == 'type_declaration' then
                for _, sp in kids(d) do
                    if sp:type() == 'type_spec' then
                        local nm, ty = sp:field('name')[1], sp:field('type')[1]
                        if nm then
                            tn[txt(nm)] = true
                            if ty and ty:type() == 'struct_type' then
                                for _, fl in kids(ty) do
                                    if fl:type() == 'field_declaration_list' then
                                        for _, fd in kids(fl) do
                                            if fd:type() == 'field_declaration' and not fd:field('name')[1] then
                                                local ed, en = tname_of(fd:field('type')[1])
                                                if ed and en then objproto(mtobj(dir, txt(nm)), mtobj(ed, en)) end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        for _, d in kids(tree) do
            local t = d:type()
            if t == 'function_declaration' then
                local nm = d:field('name')[1]
                local p = func(d, fnid(d))
                if nm then edge(p, port('pkg:' .. dir .. ':' .. txt(nm))) end
            elseif t == 'method_declaration' then
                local nm = d:field('name')[1]
                local rl = d:field('receiver')[1]
                local rty
                for _, pd in kids(rl) do if pd:type() == 'parameter_declaration' then rty = pd:field('type')[1] end end
                local rd, rn = tname_of(rty)
                local p, o = func(d, fnid(d), true)
                if nm and rd and rn then edge(p, ofp(mtobj(rd, rn), txt(nm))) end
            elseif t == 'var_declaration' or t == 'const_declaration' then
                stmt(d)
                -- (a package-level var is the package's: re-key the declared names to the package port)
                for _, c in kids(d) do
                    local function lift(sp)
                        for _, x in kids(sp) do
                            if x:type() == 'identifier' then
                                local q = scopes[1][txt(x)]
                                if q then edge(q, port('pkg:' .. dir .. ':' .. txt(x))); edge(port('pkg:' .. dir .. ':' .. txt(x)), q) end
                            end
                        end
                    end
                    if c:type() == 'var_spec' or c:type() == 'const_spec' then lift(c)
                    elseif c:type() == 'var_spec_list' then for _, sp in kids(c) do if sp:type() == 'var_spec' then lift(sp) end end end
                end
            end
        end
    end
end

return M
