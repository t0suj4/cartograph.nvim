-- erlrecords — Erlang `-record` declarations read as TYPES, scoped PER MODULE through the include graph, with
-- dependency roots attached READ-ONLY (CART-1095, under CART-1087).
--
-- @langs erlang
-- A record is an Erlang preprocessor-level type: the compiler rewrites `#iq{type = get}` into a tagged tuple using a
-- field list it found in THIS module's text after -include expansion. Nothing here generalises across languages.
--
-- ★★★ WHY. An ejabberd IQ handler reads its request in the CLAUSE HEAD,
--     process_local_iq(#iq{type = get, sub_els = [#disco_info{node = Node}]} = IQ)
-- and to say which fields it reads, `iq` and `disco_info` must be types with field lists. Both live in the xmpp
-- library (include/xmpp_codec.hrl, 278 generated records), which ejabberd pins in rebar.config and does NOT vendor.
--
-- ★★★ SCOPED, NEVER A GLOBAL TABLE. The compiler's answer to "which fields does #state have" depends on the module:
-- ejabberd declares `-record(state, …)` in dozens of modules with different fields. A global name->fields union is
-- right for whichever file you last checked. So the unit of resolution is a MODULE: its own declarations plus the
-- declarations of every file its -include / -include_lib graph reaches, transitively.
--
-- ── THE SHAPE (fixed; CART-0957's pattern IR and CART-1096's codec interpretation consume it) ────────────────────
--   decl  = { name   = 'disco_info',                 -- the record name (quoted atoms unquoted: 'LDAPMessage')
--             file   = '/abs/path/xmpp_codec.hrl',   -- the DECLARING file, absolute
--             line   = 123,                          -- 1-based line of the -record attribute
--             cond   = nil | 'defined(SIP)',         -- the -ifdef/-ifndef/-if branch it sits in (include guards
--                                                    --   are NOT conditions and are dropped), nil when unconditional
--             fields = { f1, f2, ... },              -- DECLARATION ORDER
--             by     = { node = f1, ... } }          -- the same fields keyed by name
--   field = { name    = 'node',
--             index   = 1,                           -- 1-based position in the declaration. ★ THE TUPLE ELEMENT IS
--                                                    --   index + 1 (element 1 is the record tag), which is what
--                                                    --   xmpp_codec.spec's positional `result = {disco_info, '$node',…}`
--                                                    --   and xmpp.hrl's `element(3, Pkt)` macros address
--             default = nil | '<<>>',                -- the default EXPRESSION TEXT, verbatim, when declared
--             type    = nil | 'binary()',            -- the declared TYPE TEXT, verbatim, when declared
--             line    = 123 }
--   scope = E:scope(path) for a .erl (or any file) = {
--             records  = { [name] = decl },          -- what the module sees (the first-reached decl per name)
--             variants = { [name] = { decl, … } },   -- only where >1 decl of a name is visible (ifdef branches)
--             files    = { path, … },                -- every file of the include closure, in reach order
--             missing  = { { kind, spec, from, line, cond, reason }, … } }  -- includes that resolved nowhere
--   use   = one record REFERENCE in a file (E:uses(path)):
--             { kind = 'construct' | 'update' | 'field' | 'index' | 'is_record' | 'record_info',
--               name = 'iq' | nil (nil when the record name is a macro: `#?M{}`), macro = '?M' | nil,
--               fields = { { name, line }, … },     -- the named fields it mentions (`_ = V` is a wildcard, not a field)
--               line, last = the line the reference ENDS on (a nested use lies inside an outer one's line..last),
--               ctx = 'expr' | 'type',        -- 'type' inside -spec/-type/-opaque/-callback/field types
--               cond, in_define = true when inside a -define body (resolved at EXPANSION, not here) }
--   check = E:check(path) -> rows { use, status = 'ok' | 'unknown_record' | 'unknown_field' | 'macro_name',
--                                    field = name when unknown_field }
-- A consumer holding a clause-head pattern `#iq{type = T}` asks E:scope(file).records.iq and reads .by.type.
--
-- ── DEPENDENCY ROOTS: HOW -include_lib MAPS (Erlang's own epp semantics, read-only) ─────────────────────────────
--   -include("x.hrl")             : the directory of the file CONTAINING the directive, then opts.include_dirs in
--                                   order (rebar's `{i, "include"}`). An absolute path is used as is.
--   -include_lib("app/rest.hrl")  : epp first tries it as an -include (same search); then the first path component
--                                   is an APPLICATION NAME: opts.apps[app] (an explicit app dir, e.g.
--                                   apps = { xmpp = '~/git/xmpp' }) WINS; else each of opts.libs (ERL_LIBS-shaped
--                                   dirs such as /usr/lib/erlang/lib) is scanned for `app` or `app-<vsn>`, the
--                                   highest version winning as the code server does. ⚠ NEVER BY ALIAS: Debian's
--                                   `p1_xmpp-1.7.0` is not `xmpp` and `p1_xml` is not `fast_xml`; a renamed package
--                                   stays unresolved and is reported as a missing root.
-- The analysed tree SELECTS what it includes (its -include_lib lines, its rebar.config pin); the CALLER supplies
-- where a dependency lives. Nothing is ever written to, or copied into, either tree.
-- ★ WHY NOT rootjoin's TWO ts.extract CALLS: reading 278 records out of one header does not warrant extracting a
-- whole library (hrldistill's argument). Only files the include graph actually reaches are parsed, lazily, once.
-- What IS reused from rootjoin is "roots as declared data with overridable defaults" (tools/erlrecordcensus.lua).
--
-- ⚠ APPROXIMATIONS, stated: a file is entered once per module (include guards make that what epp does; an unguarded
-- double include would be a compile error anyway); macros are not expanded, so `#?M{}` and uses inside -define
-- bodies are reported, not resolved against their expansion site; all ifdef branches are read and tagged, never
-- evaluated, so two exclusive branches' records both appear, as `variants`.

local M = {}

local function read(path)
    local fd = io.open(path, 'r')
    if not fd then return nil end
    local s = fd:read('a'); fd:close()
    return s
end

local function isfile(p) return p and vim.fn.filereadable(p) == 1 end
local function isdir(p) return p and vim.fn.isdirectory(p) == 1 end
local function abs(p) return (vim.fn.fnamemodify(vim.fn.expand(p), ':p'):gsub('/$', '')) end

-- an atom's NAME: `'LDAPMessage'` -> LDAPMessage
local function atom(s)
    if not s then return nil end
    local q = s:match("^'(.*)'$")
    return q or s
end

local CTX_TYPE = { field_type = true, spec = true, type_alias = true, opaque = true, callback = true }
-- OTP 29 native records (`#mod:rec{}`, `#_{}`): not read here, COUNTED so their arrival is visible
local NATIVE = {
    anon_record_expr = true, anon_record_field_expr = true, anon_record_update_expr = true,
    qualified_record_expr = true, qualified_record_field_expr = true, qualified_record_update_expr = true,
    import_record_attribute = true, export_record_attribute = true,
}
local USE_KIND = {
    record_expr = 'construct', record_update_expr = 'update',
    record_field_expr = 'field', record_index_expr = 'index',
}

local function negate(s)
    if s:sub(1, 4) == 'not ' then return s:sub(5) end
    return 'not ' .. s
end

--- Parse one file's record facts. Pure: (src, path) -> facts. Exposed for tests and consumers holding a buffer.
function M.parse_source(src, path)
    local facts = { path = path, records = {}, includes = {}, uses = {}, errors = 0, native = 0 }
    local view = require('cartograph.parseview').view(src, 'erlang')
    local okp, parser = pcall(vim.treesitter.get_string_parser, view, 'erlang')
    local tree = okp and parser and parser:parse()[1]
    if not tree then facts.unparsed = true; return facts end
    local root = tree:root()
    local function text(n) return vim.treesitter.get_node_text(n, src) end
    local function f1(n, f) return n:field(f)[1] end

    -- ── the condition stack: pp_* directives are FLAT SIBLINGS of the forms they guard ──
    local stack, guard = {}, nil
    -- an include guard: the file's first directive is -ifndef(X) and the next form is -define(X, …)
    do
        local forms = {}
        for ch in root:iter_children() do if ch:named() then forms[#forms + 1] = ch end end
        local a, b = forms[1], forms[2]
        if a and b and a:type() == 'pp_ifndef' and b:type() == 'pp_define' then
            local nm = f1(a, 'name')
            local lhs = f1(b, 'lhs')
            local dn = lhs and f1(lhs, 'name')
            if nm and dn and text(nm) == text(dn) then guard = a:id() end
        end
    end
    local function cond()
        local parts = {}
        for _, fr in ipairs(stack) do if not fr.guard then parts[#parts + 1] = fr.label end end
        return #parts > 0 and table.concat(parts, ' & ') or nil
    end

    local in_define = false
    local function field_list(n)
        local out, wild = {}, false
        for _, rf in ipairs(n:field('fields')) do
            local nm = f1(rf, 'name')
            -- `#r{_ = V}` sets every unnamed field: a wildcard, not a field reference (but it TOUCHES them all)
            if nm and nm:type() == 'atom' then
                out[#out + 1] = { name = atom(text(nm)), line = rf:start() + 1 }
            elseif nm then
                wild = true
            end
        end
        return out, wild
    end
    local function record_name(n)
        local rn = f1(n, 'name')
        local inner = rn and f1(rn, 'name')
        if inner and inner:type() == 'atom' then return atom(text(inner)) end
        return nil, inner and text(inner) or '?'
    end

    local function walk(n, ctx)
        local t = n:type()
        if NATIVE[t] then facts.native = facts.native + 1 end
        if t == 'ERROR' then facts.errors = facts.errors + 1 end
        if CTX_TYPE[t] then ctx = 'type' end
        local kind = USE_KIND[t]
        if kind then
            local name, mac = record_name(n)
            local u = { kind = kind, name = name, macro = mac, line = n:start() + 1,
                last = n:end_() + 1,
                ctx = ctx, cond = cond(), in_define = in_define or nil }
            if kind == 'field' or kind == 'index' then
                local fnode = f1(n, 'field')
                local fnm = fnode and f1(fnode, 'name')
                u.fields = (fnm and fnm:type() == 'atom') and { { name = atom(text(fnm)), line = fnm:start() + 1 } }
                    or {}
            else
                u.fields, u.wildcard = field_list(n)
                u.wildcard = u.wildcard or nil
            end
            facts.uses[#facts.uses + 1] = u
        elseif t == 'call' then
            -- is_record(X, r) / is_record(X, r, N) / record_info(fields | size, r): the compiler checks the name
            local callee = f1(n, 'expr')
            local cn = callee and callee:type() == 'atom' and text(callee)
            if cn == 'is_record' or cn == 'record_info' then
                local args = f1(n, 'args')
                local av = args and args:field('args') or {}
                local rn = av[2]
                if rn and rn:type() == 'atom' then
                    facts.uses[#facts.uses + 1] = { kind = cn, name = atom(text(rn)), fields = {},
                        line = n:start() + 1, last = n:end_() + 1, ctx = ctx, cond = cond(), in_define = in_define or nil }
                end
            end
        end
        for ch in n:iter_children() do if ch:named() then walk(ch, ctx) end end
    end

    for form in root:iter_children() do
        if form:named() then
            local t = form:type()
            if t == 'pp_ifdef' or t == 'pp_ifndef' then
                local nm = f1(form, 'name')
                local base = 'defined(' .. (nm and text(nm) or '?') .. ')'
                if t == 'pp_ifndef' then base = negate(base) end
                stack[#stack + 1] = { label = base, base = base, guard = form:id() == guard }
            elseif t == 'pp_if' then
                local c = f1(form, 'cond')
                local base = 'if' .. (c and text(c) or '(?)')
                stack[#stack + 1] = { label = base, base = base }
            elseif t == 'pp_elif' then
                local c = f1(form, 'cond')
                local top = stack[#stack]
                if top then top.label = 'elif' .. (c and text(c) or '(?)'); top.chain = true end
            elseif t == 'pp_else' then
                local top = stack[#stack]
                if top then
                    top.label = top.chain and ('else of ' .. top.base) or negate(top.base)
                end
            elseif t == 'pp_endif' then
                stack[#stack] = nil
            elseif t == 'pp_include' or t == 'pp_include_lib' then
                local s = f1(form, 'file')
                local spec = s and text(s):match('^"(.*)"$')
                facts.includes[#facts.includes + 1] = {
                    kind = t == 'pp_include' and 'include' or 'include_lib',
                    spec = spec, line = form:start() + 1, cond = cond(),
                }
            elseif t == 'record_decl' then
                local nm = f1(form, 'name')
                local d = { name = nm and nm:type() == 'atom' and atom(text(nm)) or nil, file = path,
                    line = form:start() + 1, cond = cond(), fields = {}, by = {} }
                for i, rf in ipairs(form:field('fields')) do
                    local fn = f1(rf, 'name')
                    local fe, ft = f1(rf, 'expr'), f1(rf, 'ty')
                    local de, te = fe and f1(fe, 'expr'), ft and f1(ft, 'expr')
                    local fld = { name = fn and atom(text(fn)), index = i, line = rf:start() + 1,
                        default = de and text(de) or nil, type = te and text(te) or nil }
                    d.fields[i] = fld
                    if fld.name then d.by[fld.name] = fld end
                end
                if d.name then facts.records[#facts.records + 1] = d
                else facts.unnamed = (facts.unnamed or 0) + 1 end
                -- defaults and field types reference other records: those are uses too
                walk(form, 'expr')
            elseif t == 'pp_define' then
                in_define = true
                walk(form, 'expr')
                in_define = false
            else
                walk(form, 'expr')
            end
        end
    end
    return facts
end

-- `app-1.2.10` beats `app-1.2.9`: compare dotted numeric parts, the code server's rule
local function vsn_less(a, b)
    local pa, pb = {}, {}
    for x in a:gmatch('%d+') do pa[#pa + 1] = tonumber(x) end
    for x in b:gmatch('%d+') do pb[#pb + 1] = tonumber(x) end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or -1, pb[i] or -1
        if x ~= y then return x < y end
    end
    return a < b
end

--- A resolver over one analysed tree plus its read-only dependency roots.
---   opts.include_dirs = { dir, … }       the -I path (rebar's {i, "include"}), absolute or ~-relative
---   opts.apps = { [app] = dir }          explicit application dirs: -include_lib("app/…") -> dir/…  (wins)
---   opts.libs = { dir, … }               ERL_LIBS-shaped dirs holding app or app-<vsn> subdirs
function M.new(opts)
    opts = opts or {}
    local E = { include_dirs = {}, apps = {}, libs = {}, cache = {}, scopes = {} }
    for _, d in ipairs(opts.include_dirs or {}) do E.include_dirs[#E.include_dirs + 1] = abs(d) end
    for a, d in pairs(opts.apps or {}) do E.apps[a] = abs(d) end
    for _, d in ipairs(opts.libs or {}) do E.libs[#E.libs + 1] = abs(d) end
    local libcache = {}

    function E:facts(path)
        local f = self.cache[path]
        if f then return f end
        local src = read(path)
        f = src and M.parse_source(src, path) or { path = path, records = {}, includes = {}, uses = {},
            unreadable = true }
        self.cache[path] = f
        return f
    end

    local function search(spec, from)
        if spec:sub(1, 1) == '/' then return isfile(spec) and spec or nil end
        local dirs = { vim.fn.fnamemodify(from, ':h') }
        for _, d in ipairs(E.include_dirs) do dirs[#dirs + 1] = d end
        for _, d in ipairs(dirs) do
            local p = d .. '/' .. spec
            if isfile(p) then return abs(p) end
        end
    end

    local function lib_dir(app)
        if E.apps[app] then return E.apps[app], 'app' end
        if libcache[app] ~= nil then return libcache[app] or nil, 'lib' end
        local best, bestv
        for _, l in ipairs(E.libs) do
            if isdir(l .. '/' .. app) and not best then best, bestv = l .. '/' .. app, '' end
            for _, cand in ipairs(vim.fn.glob(l .. '/' .. app .. '-*', false, true)) do
                local v = cand:sub(#l + #app + 3)
                -- `app-<vsn>` only: `p1_xmpp-1.7.0` must not answer for `p1`
                if v:match('^%d[%w%.%-]*$') and isdir(cand) and (not bestv or vsn_less(bestv, v)) then
                    best, bestv = cand, v
                end
            end
            if best then break end -- the first lib dir that has the app wins, like ERL_LIBS order
        end
        libcache[app] = best or false
        return best, 'lib'
    end

    --- (kind, spec, from) -> abs path, how | nil, reason
    function E:resolve(kind, spec, from)
        if not spec or spec == '' then return nil, 'no literal path' end
        if spec:find('^%$') then return nil, 'path variable ' .. spec end
        local hit = search(spec, from)
        if hit then return hit, 'search' end
        if kind == 'include_lib' then
            local app, rest = spec:match('^([^/]+)/(.+)$')
            if not app then return nil, 'include_lib with no application component' end
            local dir, how = lib_dir(app)
            if not dir then return nil, 'no root for application ' .. app end
            local p = dir .. '/' .. rest
            if isfile(p) then return abs(p), how end
            return nil, ('application %s at %s has no %s'):format(app, dir, rest)
        end
        return nil, 'not found on the include path'
    end

    --- The records a file SEES: its own plus its transitive include closure. Memoized per path.
    function E:scope(path)
        path = abs(path)
        if self.scopes[path] then return self.scopes[path] end
        local S = { records = {}, variants = {}, files = {}, missing = {} }
        local seen = {}
        local function add(d, via)
            local c = d.cond
            if via then c = c and (via .. ' & ' .. c) or via end
            local entry = d
            -- a PLAIN shallow copy, never a metatable proxy: pairs / vim.inspect / mpack to a worker must see
            -- every field (fields and by stay shared with the facts)
            if c ~= d.cond then
                entry = {}
                for k, v in pairs(d) do entry[k] = v end
                entry.cond = c
            end
            local have = S.records[d.name]
            if not have then S.records[d.name] = entry
            else
                S.variants[d.name] = S.variants[d.name] or { have }
                table.insert(S.variants[d.name], entry)
            end
        end
        local function visit(p, via)
            if seen[p] then return end
            seen[p] = true
            S.files[#S.files + 1] = p
            local f = self:facts(p)
            -- interleave by line so declaration order is textual order
            local items = {}
            for _, d in ipairs(f.records) do items[#items + 1] = { line = d.line, d = d } end
            for _, inc in ipairs(f.includes) do items[#items + 1] = { line = inc.line, inc = inc } end
            table.sort(items, function (a, b) return a.line < b.line end)
            for _, it in ipairs(items) do
                if it.d then add(it.d, via)
                else
                    local inc = it.inc
                    local c = inc.cond
                    if via then c = c and (via .. ' & ' .. c) or via end
                    local hit, why = self:resolve(inc.kind, inc.spec, p)
                    if hit then visit(hit, c)
                    else
                        S.missing[#S.missing + 1] = { kind = inc.kind, spec = inc.spec, from = p, line = inc.line,
                            cond = c, reason = why }
                    end
                end
            end
        end
        visit(path, nil)
        self.scopes[path] = S
        return S
    end

    function E:uses(path) return self:facts(abs(path)).uses end

    --- Grade every record reference in `path` against its own scope — the compiler's check, restated.
    function E:check(path)
        path = abs(path)
        local S = self:scope(path)
        local rows = {}
        for _, u in ipairs(self:uses(path)) do
            if not u.name then rows[#rows + 1] = { use = u, status = 'macro_name' }
            else
                local cands = S.variants[u.name] or (S.records[u.name] and { S.records[u.name] })
                if not cands then rows[#rows + 1] = { use = u, status = 'unknown_record' }
                else
                    local bad
                    for _, fl in ipairs(u.fields) do
                        local found = false
                        for _, d in ipairs(cands) do if d.by[fl.name] then found = true break end end
                        if not found then
                            bad = true
                            rows[#rows + 1] = { use = u, status = 'unknown_field', field = fl.name }
                        end
                    end
                    if not bad then rows[#rows + 1] = { use = u, status = 'ok' } end
                end
            end
        end
        return rows
    end

    return E
end

--- The ordered field names: the identity two same-named records are compared on.
--- ★ THE REVERSE OF `check` (declaration -> uses): which records the corpus DECLARES and nothing uses, and which
--- fields of a used record no use ever names. A WORK LIST, not a verdict: a field can be read POSITIONALLY
--- (element/2, setelement/3 — counted per module and flagged, never subtracted), a record can be used only inside
--- a -define body in a header (not graded here), and a record exported in a header may be used by a consumer
--- OUTSIDE the tree (the reason only records declared under `root` are reported). `record_info/2` and a
--- `#r{_ = V}` wildcard touch every field.
---   files: the modules to read uses from; root: the tree whose DECLARATIONS are reported
--- -> { records = { {decl, uses, value_uses, type_only} }, unused = { decl… }, fields = { {decl, field, positional} },
---      declared = n }
function M.usage(E, files, root)
    root = abs(root)
    local decls, used = {}, {}
    local function key(d) return (d.file or '?') .. ':' .. tostring(d.line) .. ':' .. d.name end
    for _, f in ipairs(files) do
        local S = E:scope(f)
        for _, d in pairs(S.records or {}) do
            if d.file and d.file:sub(1, #root + 1) == root .. '/' then decls[key(d)] = d end
        end
        for _, vs in pairs(S.variants or {}) do
            for _, d in ipairs(vs) do
                if d.file and d.file:sub(1, #root + 1) == root .. '/' then decls[key(d)] = d end
            end
        end
        local src = read(abs(f))
        local positional = src and (src:find('%f[%w_]element%(') or src:find('%f[%w_]setelement%(')) and true or false
        for _, u in ipairs(E:uses(f)) do
            local d = u.name and S.records[u.name]
            if d then
                local k = key(d)
                local r = used[k]
                if not r then r = { n = 0, value = 0, fields = {}, all = false, positional = false }; used[k] = r end
                r.n = r.n + 1
                if u.ctx ~= 'type' then r.value = r.value + 1 end
                if u.kind == 'record_info' or u.wildcard then r.all = true end
                for _, fl in ipairs(u.fields or {}) do r.fields[fl.name] = true end
                if positional then r.positional = true end
            end
        end
    end
    local out = { records = {}, unused = {}, fields = {}, declared = 0 }
    local keys = {}
    for k in pairs(decls) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local d, r = decls[k], used[k]
        out.declared = out.declared + 1
        if not r then out.unused[#out.unused + 1] = d
        else
            out.records[#out.records + 1] = { decl = d, uses = r.n, value_uses = r.value, type_only = r.value == 0 }
            if not r.all then
                for _, fl in ipairs(d.fields or {}) do
                    if not r.fields[fl.name] then
                        out.fields[#out.fields + 1] = { decl = d, field = fl.name, positional = r.positional }
                    end
                end
            end
        end
    end
    return out
end

function M.signature(decl)
    local t = {}
    for i, f in ipairs(decl.fields) do t[i] = f.name or '?' end
    return table.concat(t, ',')
end

--- The full declaration text (names + defaults + types): equal signatures can still differ here.
function M.detail(decl)
    local t = {}
    for i, f in ipairs(decl.fields) do
        t[i] = (f.name or '?') .. '=' .. (f.default or '') .. '::' .. (f.type or '')
    end
    return table.concat(t, ',')
end

return M
