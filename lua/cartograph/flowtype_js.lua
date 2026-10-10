-- cartograph.flowtype_js — the JAVASCRIPT / TYPESCRIPT walker of cartograph.flowtype (CART-1621): the same inclusion
-- flow, every TYPE ANNOTATION ignored — so the TypeScript checker can score it (tools/experiments/flowtype_oracle/ts).
-- JS is Lua's shape, which is the point: object literals are tables, a dynamic key `o[k]` may reach any field (loads
-- are NOT strict), functions are values. A class is a prototype object holding its methods (`extends` links the
-- prototypes), `new C(…)` allocates an instance of C's prototype and calls C's constructor on it (parameter
-- properties `constructor(private svc)` store `this.svc`); `this` is every function's first parameter (an arrow
-- function's is its enclosing one's), so a call passes its receiver first. Modules: each file's exports are the
-- fields of its module object; an import reads them. Every member call `x.m(…)` is a PROBE.
local tsutil = require 'cartograph.spec.tsutil'

local M = {}

local EMPTY_NODE = { child = function () return nil end }
local function kids(n) return tsutil.inext, n or EMPTY_NODE, -1 end
local WRAP = { as_expression = true, satisfies_expression = true, non_null_expression = true, type_assertion = true,
    parenthesized_expression = true, await_expression = true }
local EXTS = { '', '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '/index.ts', '/index.tsx', '/index.js' }

function M.walker(S, files)
    local new, newobj, addobj, edge, ofp, field, storec, callc, port, fnports =
        S.new, S.newobj, S.addobj, S.edge, S.ofp, S.field, S.storec, S.callc, S.port, S.fnports
    local inset = {}
    for _, f in ipairs(files) do inset[f] = true end
    local function norm(p)
        local out = {}
        for seg in p:gmatch('[^/]+') do
            if seg == '..' then out[#out] = nil elseif seg ~= '.' then out[#out + 1] = seg end
        end
        return table.concat(out, '/')
    end
    local function resolve(from, spec)
        if not spec:match('^%.') then return nil end
        local dir = from:match('^(.*)/[^/]+$') or ''
        local base = norm((dir ~= '' and (dir .. '/') or '') .. spec)
        for _, e in ipairs(EXTS) do
            local cand = base:gsub('%.js$', '') .. e
            if inset[cand] then return cand end
            if inset[base .. e] then return base .. e end
        end
        return nil
    end
    local modobj = {}
    local function module_of(file)
        local o = modobj[file]
        if not o then o = newobj('module:' .. file); modobj[file] = o; addobj(port('mod:' .. file), o) end
        return o
    end
    return function (file, src)
        local lang = file:match('%.tsx$') and 'tsx' or (file:match('%.tsx?$') and 'typescript' or 'javascript')
        local okp, parser = pcall(vim.treesitter.get_string_parser, src, lang)
        if not okp then return end
        local tree = parser:parse()[1]:root()
        local fnmap = S.fn_at[file] or {}
        local function txt(n) local _, _, s, _, _, e = n:range(true); return src:sub(s + 1, e) end
        local mod = module_of(file)
        local function export(name, v) edge(v, ofp(mod, name)) end
        local scopes = { {} }
        local function lookup(name)
            for i = #scopes, 1, -1 do local p = scopes[i][name]; if p then return p end end
            return port('gjs:' .. name) -- (JS's globals, never Lua's: a tree may hold both)
        end
        local function declare(name, p) local q = p or new(); scopes[#scopes][name] = q; return q end
        local fnstack = {} -- { fp, this port }
        local expr, stmt
        local function fnid(n)
            local l, c = n:start()
            return fnmap[l .. ':' .. c] or ('ts:' .. file .. ':' .. l .. ':' .. c)
        end
        -- a destructuring pattern bound to the value port v
        local function bind(pat, v, decl)
            if not pat then return end
            local t = pat:type()
            if t == 'identifier' or t == 'shorthand_property_identifier_pattern' then
                local nm = txt(pat)
                local target = decl and declare(nm) or lookup(nm)
                edge(v, target)
            elseif t == 'object_pattern' then
                for _, c in kids(pat) do
                    local ct = c:type()
                    if ct == 'shorthand_property_identifier_pattern' then bind(c, field(v, txt(c)), decl)
                    elseif ct == 'pair_pattern' then
                        local k, val = c:field('key')[1], c:field('value')[1]
                        bind(val, field(v, k and txt(k) or '[]'), decl)
                    elseif ct == 'object_assignment_pattern' then
                        local l = c:field('left')[1]
                        bind(l, field(v, l and txt(l) or '[]'), decl)
                    elseif ct == 'rest_pattern' then bind(c:named_child(0), v, decl) end
                end
            elseif t == 'array_pattern' then
                for _, c in kids(pat) do if c:named() then bind(c, field(v, '[]'), decl) end end
            elseif t == 'assignment_pattern' then
                bind(pat:field('left')[1], v, decl)
                local r = pat:field('right')[1]
                if r then bind(pat:field('left')[1], expr(r), decl) end
            elseif t == 'rest_pattern' then bind(pat:named_child(0), v, decl)
            elseif t == 'required_parameter' or t == 'optional_parameter' then
                bind(pat:field('pattern')[1], v, decl)
            end
        end
        local function func(n, own_this, ctor_props)
            local id = fnid(n)
            local p = new()
            local o = newobj(id)
            addobj(p, o)
            local fp = { params = {}, ret = port('r:' .. id) }
            for k = 1, 16 do fp.params[k] = port('a:' .. id .. ':' .. k) end
            fnports[o] = fp
            scopes[#scopes + 1] = {}
            -- (THIS: parameter 1 of every function; an arrow function sees its enclosing one's)
            local this = own_this and fp.params[1] or (fnstack[#fnstack] and fnstack[#fnstack].this) or new()
            local i = 1
            local ps = n:field('parameters')[1] or n:field('parameter')[1]
            if ps and ps:type() == 'identifier' then
                i = 2; bind(ps, fp.params[2], true)
            else
                for _, x in kids(ps) do
                    if x:named() and x:type() ~= 'comment' then
                        i = i + 1
                        bind(x, fp.params[i], true)
                        -- (a constructor PARAMETER PROPERTY `private svc: Svc` is `this.svc = svc`)
                        if ctor_props and (x:type() == 'required_parameter' or x:type() == 'optional_parameter') then
                            local mod0 = x:named_child(0)
                            local pat = x:field('pattern')[1]
                            if mod0 and (mod0:type() == 'accessibility_modifier' or txt(mod0) == 'readonly') and pat
                                and pat:type() == 'identifier' then
                                storec(this, txt(pat), fp.params[i])
                            end
                        end
                    end
                end
            end
            fnstack[#fnstack + 1] = { fp = fp, this = this }
            local body = n:field('body')[1]
            if body then
                if body:type() == 'statement_block' then for _, s in kids(body) do if s:named() then stmt(s) end end
                else edge(expr(body), fp.ret) end -- (an arrow function's expression body is its value)
            end
            fnstack[#fnstack] = nil
            scopes[#scopes] = nil
            return p, o
        end
        -- a class: its PROTOTYPE object (methods), the class value (statics, `prototype`, the constructor)
        local function class(n)
            local cv = new()
            local co = newobj('class:' .. fnid(n))
            addobj(cv, co)
            local pr = new()
            local po = newobj('proto:' .. fnid(n))
            addobj(pr, po)
            edge(pr, ofp(co, 'prototype'))
            local selfo = newobj('self:' .. fnid(n)) -- (the instance a method's `this` stands for)
            local sp = new()
            addobj(sp, selfo)
            S.proto(sp, pr)
            for _, h in kids(n) do
                if h:type() == 'class_heritage' then
                    for _, ec in kids(h) do
                        if ec:type() == 'extends_clause' then
                            local base = ec:field('value')[1]
                            if base then
                                local bp = expr(base)
                                S.proto(pr, field(bp, 'prototype')) -- (instances read the base's methods)
                                S.proto(cv, bp) -- (statics too)
                            end
                        end
                    end
                end
            end
            local body = n:field('body')[1]
            for _, m in kids(body) do
                local mt = m:type()
                if mt == 'method_definition' then
                    local nm = m:field('name')[1]
                    local isstatic = false
                    for _, c in kids(m) do if not c:named() and txt(c) == 'static' then isstatic = true end end
                    local name = nm and txt(nm)
                    local fpv, fo = func(m, true, name == 'constructor')
                    if name == 'constructor' then edge(fpv, ofp(co, '()ctor'))
                    elseif name then edge(fpv, ofp(isstatic and co or po, name)) end
                    -- (THIS inside C's method: an instance of C — the checker's static view; a subclass instance that
                    -- flows in adds its overrides. A static method's `this` is the class itself)
                    local fp = fnports[fo]
                    if fp then
                        if isstatic then addobj(fp.params[1], co) else addobj(fp.params[1], selfo) end
                    end
                elseif mt == 'public_field_definition' then
                    local nm, v = m:field('name')[1], m:field('value')[1]
                    local isstatic = false
                    for _, c in kids(m) do if not c:named() and txt(c) == 'static' then isstatic = true end end
                    -- (an instance field initializer runs per instance: through the prototype it reads like one; a
                    -- STATIC field is the class's own — `CodeActionKind.Source`)
                    if nm and v then
                        local fstack = { fp = { params = {}, ret = new() }, this = isstatic and cv or pr }
                        fnstack[#fnstack + 1] = fstack
                        edge(expr(v), ofp(isstatic and co or po, txt(nm)))
                        fnstack[#fnstack] = nil
                    end
                end
            end
            return cv
        end
        local function args_of(n)
            local out = {}
            for _, a in kids(n:field('arguments')[1]) do
                if a:named() and a:type() ~= 'comment' then
                    out[#out + 1] = a:type() == 'spread_element' and field(expr(a:named_child(0)), '[]') or expr(a)
                end
            end
            return out
        end
        local function callv(n)
            local f = n:field('function')[1]
            local res = new()
            if not f then return res end
            local ft = f:type()
            if ft == 'import' then return port('mod:?') end
            local aps
            if ft == 'member_expression' then
                local obj, prop = f:field('object')[1], f:field('property')[1]
                local recv = expr(obj)
                local m = prop and txt(prop) or '[]'
                local callee = field(recv, m)
                local l, c = obj:start()
                S.probes[#S.probes + 1] = { file = file, line = l, col = c, member = m, recv = recv }
                aps = args_of(n)
                table.insert(aps, 1, recv)
                callc(callee, aps, res)
                return res
            end
            if ft == 'super' then
                local top = fnstack[#fnstack]
                aps = args_of(n)
                table.insert(aps, 1, top and top.this or new())
                return res
            end
            local callee = expr(f)
            aps = args_of(n)
            table.insert(aps, 1, new()) -- (no receiver: `this` undefined)
            callc(callee, aps, res)
            return res
        end
        expr = function (n)
            local t = n:type()
            if WRAP[t] then
                for _, c in kids(n) do if c:named() and not c:type():find('type', 1, true) then return expr(c) end end
                return new()
            end
            if t == 'identifier' or t == 'shorthand_property_identifier' then return lookup(txt(n)) end
            if t == 'this' then local top = fnstack[#fnstack]; return top and top.this or new() end
            if t == 'member_expression' then
                local obj, prop = n:field('object')[1], n:field('property')[1]
                return field(expr(obj), prop and txt(prop) or '[]')
            end
            if t == 'subscript_expression' then
                local obj, idx = n:field('object')[1], n:field('index')[1]
                local key = '[]'
                if idx and idx:type() == 'string' then
                    local fr = idx:named_child(0)
                    key = fr and txt(fr) or '[]'
                elseif idx then expr(idx) end
                return field(expr(obj), key)
            end
            if t == 'call_expression' then return callv(n) end
            if t == 'new_expression' then
                local ctor = n:field('constructor')[1]
                local cv = ctor and expr(ctor) or new()
                local p = new()
                local o = newobj('new:' .. file .. ':' .. (n:start()))
                addobj(p, o)
                S.proto(p, field(cv, 'prototype'))
                local aps = n:field('arguments')[1] and args_of(n) or {}
                table.insert(aps, 1, p)
                callc(field(cv, '()ctor'), aps, new())
                return p
            end
            if t == 'arrow_function' then return (func(n, false)) end
            if t == 'function_expression' or t == 'function' or t == 'generator_function' then return (func(n, true)) end
            if t == 'class' then return class(n) end
            if t == 'string' or t == 'template_string' then local p = new(); addobj(p, S.STR); return p end
            if t == 'object' then
                local p = new()
                local o = newobj('obj:' .. file .. ':' .. (n:start()))
                addobj(p, o)
                for _, c in kids(n) do
                    local ct = c:type()
                    if ct == 'pair' then
                        local k, v = c:field('key')[1], c:field('value')[1]
                        local key = '[]'
                        if k and (k:type() == 'property_identifier' or k:type() == 'number') then key = txt(k)
                        elseif k and k:type() == 'string' then local fr = k:named_child(0); key = fr and txt(fr) or '' end
                        if v then edge(expr(v), ofp(o, key)) end
                    elseif ct == 'method_definition' then
                        local nm = c:field('name')[1]
                        if nm then edge((func(c, true)), ofp(o, txt(nm))) end
                    elseif ct == 'shorthand_property_identifier' then edge(lookup(txt(c)), ofp(o, txt(c)))
                    elseif ct == 'spread_element' then edge(field(expr(c:named_child(0)), '[]'), ofp(o, '[]')) end
                end
                return p
            end
            if t == 'array' then
                local p = new()
                local o = newobj('arr:' .. file .. ':' .. (n:start()))
                addobj(p, o)
                for _, c in kids(n) do if c:named() then edge(expr(c), ofp(o, '[]')) end end
                return p
            end
            if t == 'assignment_expression' then
                local l, r = n:field('left')[1], n:field('right')[1]
                local v = r and expr(r) or new()
                if l then
                    local lt = l:type()
                    if lt == 'member_expression' then
                        local obj, prop = l:field('object')[1], l:field('property')[1]
                        storec(expr(obj), prop and txt(prop) or '[]', v)
                    elseif lt == 'subscript_expression' then
                        local obj, idx = l:field('object')[1], l:field('index')[1]
                        local key = '[]'
                        if idx and idx:type() == 'string' then local fr = idx:named_child(0); key = fr and txt(fr) or '[]' end
                        local op = expr(obj)
                        storec(op, key, v)
                        if idx then storec(op, '{k}', expr(idx)) end
                    else bind(l, v, false) end
                end
                return v
            end
            if t == 'binary_expression' then
                local op = n:field('operator')[1]
                local a, b = n:field('left')[1], n:field('right')[1]
                local ap, bp = a and expr(a), b and expr(b)
                local o = op and txt(op)
                if o == '||' or o == '&&' or o == '??' then local r = new(); if ap then edge(ap, r) end; if bp then edge(bp, r) end; return r end
                return new()
            end
            if t == 'ternary_expression' then
                local c, a, b = n:field('condition')[1], n:field('consequence')[1], n:field('alternative')[1]
                if c then expr(c) end
                local r = new()
                if a then edge(expr(a), r) end
                if b then edge(expr(b), r) end
                return r
            end
            for _, c in kids(n) do
                if c:named() and not c:type():find('type', 1, true) then
                    if c:type() == 'statement_block' then stmt(c) else expr(c) end
                end
            end
            return new()
        end
        local function decls(n, exported)
            for _, d in kids(n) do
                if d:type() == 'variable_declarator' then
                    local nm, v = d:field('name')[1], d:field('value')[1]
                    local vp = v and expr(v) or new()
                    bind(nm, vp, true)
                    if exported and nm and nm:type() == 'identifier' then export(txt(nm), lookup(txt(nm))) end
                end
            end
        end
        local function declaration(d, exported)
            local t = d:type()
            if t == 'function_declaration' or t == 'generator_function_declaration' then
                local nm = d:field('name')[1]
                local target = nm and declare(txt(nm))
                local p = func(d, true)
                if target then edge(p, target) end
                if exported and nm then export(txt(nm), target) end
            elseif t == 'class_declaration' or t == 'abstract_class_declaration' then
                local nm = d:field('name')[1]
                local target = nm and declare(txt(nm))
                local cv = class(d)
                if target then edge(cv, target) end
                if exported and nm then export(txt(nm), target) end
            elseif t == 'lexical_declaration' or t == 'variable_declaration' then decls(d, exported)
            else return false end
            return true
        end
        stmt = function (n)
            local t = n:type()
            if declaration(n, false) then return end
            if t == 'import_statement' then
                local srcn = n:field('source')[1]
                local fr = srcn and srcn:named_child(0)
                local target = fr and resolve(file, txt(fr))
                local mp = target and port('mod:' .. target) or new()
                for _, c in kids(n) do
                    if c:type() == 'import_clause' then
                        for _, x in kids(c) do
                            local xt = x:type()
                            if xt == 'identifier' then declare(txt(x), field(mp, 'default'))
                            elseif xt == 'namespace_import' then
                                local id = x:named_child(0)
                                if id then declare(txt(id), mp) end
                            elseif xt == 'named_imports' then
                                for _, sp in kids(x) do
                                    if sp:type() == 'import_specifier' then
                                        local nm, al = sp:field('name')[1], sp:field('alias')[1]
                                        if nm then declare(txt(al or nm), field(mp, txt(nm))) end
                                    end
                                end
                            end
                        end
                    end
                end
            elseif t == 'export_statement' then
                local d = n:field('declaration')[1]
                local v = n:field('value')[1]
                if d then declaration(d, true)
                elseif v then export('default', expr(v))
                else
                    for _, c in kids(n) do
                        if c:type() == 'export_clause' then
                            for _, sp in kids(c) do
                                if sp:type() == 'export_specifier' then
                                    local nm, al = sp:field('name')[1], sp:field('alias')[1]
                                    if nm then export(txt(al or nm), lookup(txt(nm))) end
                                end
                            end
                        end
                    end
                end
            elseif t == 'return_statement' then
                local top = fnstack[#fnstack]
                local v = n:named_child(0)
                if v then local vp = expr(v); if top then edge(vp, top.fp.ret) end end
            elseif t == 'for_in_statement' then
                scopes[#scopes + 1] = {}
                local l, r = n:field('left')[1], n:field('right')[1]
                local isof = false
                for _, c in kids(n) do if not c:named() and txt(c) == 'of' then isof = true end end
                local rp = r and expr(r) or new()
                if l then bind(l, field(rp, isof and '[]' or '{k}'), true) end
                local body = n:field('body')[1]
                if body then stmt(body) end
                scopes[#scopes] = nil
            elseif t == 'statement_block' or t == 'class_body' then
                scopes[#scopes + 1] = {}
                for _, c in kids(n) do if c:named() then stmt(c) end end
                scopes[#scopes] = nil
            elseif t == 'expression_statement' then
                for _, c in kids(n) do if c:named() then expr(c) end end
            elseif t == 'catch_clause' then
                scopes[#scopes + 1] = {}
                local p = n:field('parameter')[1]
                if p then bind(p, new(), true) end
                local body = n:field('body')[1]
                if body then stmt(body) end
                scopes[#scopes] = nil
            else
                for _, c in kids(n) do
                    if c:named() then
                        local ct = c:type()
                        if ct:find('statement', 1, true) or ct:find('declaration', 1, true) or ct == 'statement_block'
                            or ct:find('clause', 1, true) or ct == 'switch_body' or ct == 'switch_case' or ct == 'switch_default' then
                            stmt(c)
                        elseif not ct:find('type', 1, true) then expr(c) end
                    end
                end
            end
        end
        for _, s in kids(tree) do if s:named() then stmt(s) end end
    end
end

return M
