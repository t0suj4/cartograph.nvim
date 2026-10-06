-- cartograph.mixalg — the ALGEBRA'S OWN operations as mix programs (CART-1279, S3 of the specializer arc CART-1276):
-- the first Futamura projection on the algebra. An operation's CALL CLOSURE inside lua/cartograph/algebra (one module in
-- part files: `M.x` = the M.x of any part, a `SHARED.x` alias = core's file local, a bare name = the file's local
-- function) is ASSEMBLED, derived from the code, into one chunk of top-level functions mix reads — every M.x a
-- `M_x`, every file local a `<file>__x`, references rewritten; a function nested in another is part of that body (a
-- part file's `return function (M, SHARED) … end` is the FILE). Then `compile_match(T)` specializes match to the
-- template T (static) against a dynamic subject: a compiled matcher, a plain Lua function, no template walking.
-- The residual is loaded with its CONSTANT POOL (static data it references: MIXK) and the algebra's grammars (M) in its
-- environment. MEASURED 2026-10-02 (the luajs rules, 33 templates): every compiled matcher equals A.match on every
-- projected subterm of lua/cartograph with the rule's head — 231,451 subjects, 0 differ — and 3.3x faster in all.
-- ★ Names are resolved BY BINDING (CART-1460): an identifier is rewritten — and followed into the closure — only when
-- the algebra's Lua scope graph has a REFERENCE at its offset whose declaration lies outside the definition (a
-- file-level binding, or free). By name, a parameter `key` became core's function `key` and `{ key = a }`'s field was
-- renamed: compiled keyed matching had been a different program since S3, unseen by a population with no keyed node.
local M = {}

local function algebra_dir()
    local here = debug.getinfo(1, 'S').source:sub(2)
    return vim.fn.fnamemodify(here, ':p:h') .. '/algebra'
end

local cache = {}

--- a closure key's name in the assembled program: `M.x` -> `M_x`, `<file>.lua::x` -> `<file>__x` (the entry a caller
--- of M.program specializes)
function M.mangle(k)
    if k:match('^M[.:]') then return (k:gsub('[.:]', '_')) end
    local file, nm = k:match('^(.-)%.lua::(.*)$')
    return ((file .. '__' .. nm):gsub('[.:]', '_'))
end

-- a file's name AS LUA SHOWS IT in an error message (luaL_where / short_src): asked of Lua itself, so it is exact
local shortcache = {}
local function short_src(path)
    if not shortcache[path] then
        shortcache[path] = assert(load('return debug.getinfo(1, "S").short_src', '@' .. path))()
    end
    return shortcache[path]
end
M._short_src = short_src

-- the LOADED-CODE index (M.program, CART-1374): { ['<abs file>:<first line>'] = function }, and the visit that grows
-- it. Walked per call: 1,197 functions in 9 ms against ~1 s for the assembly (measured 2026-10-05) — no cache
local function loaded_index()
    local fobj, seen = {}, {}
    local function visit(f, depth)
        if seen[f] or depth > 6 then return end
        seen[f] = true
        if type(f) == 'function' then
            local info = debug.getinfo(f, 'S')
            if info and info.what == 'Lua' and info.source:sub(1, 1) == '@' then
                fobj[vim.fn.fnamemodify(info.source:sub(2), ':p') .. ':' .. info.linedefined] = f
            end
            for i = 1, 255 do
                local nm, v = debug.getupvalue(f, i)
                if not nm then break end
                if type(v) == 'function' then visit(v, depth + 1) end
            end
        elseif type(f) == 'table' then
            for _, v in pairs(f) do if type(v) == 'function' then visit(v, depth + 1) end end
        end
    end
    for _, mod in pairs(package.loaded) do if type(mod) == 'table' then visit(mod, 0) end end
    return fobj, visit
end

--- the CALL CLOSURE of an algebra function (default M.match) as one mix program -> program text, the closure's keys in
--- order, the LINE MAP: lines[n] = { src = the file's short name, line } — where line n of the text came from (a
--- definition's renames never add a line, so its lines map one to one) (memoized per root and per process)
--- `files` (CART-1445): ANY Lua files (absolute paths) instead of the algebra's — a module's own call closure (its
--- `M.x` and file locals; a name in another file is a free name, as anything required is). Default: the algebra.
--- ★ FILE-LEVEL LOCALS THE CLOSURE READS (CART-1374): a definition's free names that are not definitions — `local Q =
--- 'q\1'`, a table of rules, the basis bound once — used to reach mix as unknown GLOBALS and refuse. Their VALUES are
--- read from the LOADED code: each closure function's runtime object (found by file and first line among the loaded
--- modules) names, through debug.getupvalue, exactly the bindings it captures — no name guessing. A local NO code in
--- its file writes is a constant: a scalar is inlined as a literal, a table becomes a KNOWN global (`<file>__<name>`,
--- returned in `knowns`: the caller passes them to mix as opts.globals and to the residual's environment). A local
--- the file WRITES (the basis bound in apply_to, a lazy cache) is a value only at this moment: taken only with
--- opts.snapshot, and listed in `report.snapshots`; otherwise it stays free (`report.free`).
--- A FUNCTION field the closure reads off such a table (`B.kinds` of the bound basis) is a PRIMITIVE of the program
--- (CART-1372 rung 5): returned in `prims` ({ [path] = function }) for mix's opts.prims — an effect to mix unless
--- proven pure (opts.pure).
--- -> text, order, lines, knowns, report { known = { name }, snapshots = { name }, free = { name } }, prims
function M.program(root, files, opts)
    root = root or 'M.match'
    opts = opts or {}
    local ckey = root .. (files and ('\0' .. table.concat(files, '\0')) or '') .. (opts.snapshot and '\0snap' or '')
        .. (opts.through and '\0through' or '')
        .. (opts.opaque and ('\0opaque:' .. table.concat((function () local t = vim.tbl_keys(opts.opaque); table.sort(t); return t end)(), ',')) or '')
    -- (a run with a decision hook is never served from, nor stored in, the cache: its answers may differ)
    if cache[ckey] and not opts.decide then local c = cache[ckey]; return c.text, c.order, c.lines, c.knowns, c.report, c.prims end
    files = files or vim.fn.glob(algebra_dir() .. '/*.lua', false, true)
    local fq = vim.treesitter.query.parse('lua', '(function_declaration) @f')
    local aq = vim.treesitter.query.parse('lua', '(function_definition) @f')
    local defs, src = {}, {}
    local function tx(n, s) return vim.treesitter.get_node_text(n, s) end
    -- (a part file's `return function (M, SHARED) … end` is the FILE, not an enclosing function)
    local function wrapper(x)
        local el = x:type() == 'function_definition' and x:parent()
        local rs = el and el:type() == 'expression_list' and el:parent()
        return rs and rs:type() == 'return_statement' and rs:parent() and rs:parent():type() == 'chunk'
    end
    local function nested(n)
        local x = n:parent()
        for _ = 1, 1000 do
            if not x then return false end
            if (x:type() == 'function_declaration' or x:type() == 'function_definition') and not wrapper(x) then return true end
            x = x:parent()
        end
        return false
    end
    local path = {}
    for _, f in ipairs(files) do
        local s = io.open(f):read('a')
        local rel = f:match('algebra/(.*)$') or vim.fn.fnamemodify(f, ':t')
        src[rel] = s
        path[rel] = f
        local tree = vim.treesitter.get_string_parser(s, 'lua'):parse()[1]:root()
        for _, n in fq:iter_captures(tree, s, 0, -1) do
            local nm = not nested(n) and n:field('name')[1]
            if nm then
                local name = tx(nm, s)
                local key = name:match('^M[.:]') and name or (rel .. '::' .. name)
                defs[key] = defs[key] or { node = n, file = rel, src = s }
            end
        end
        -- (a function BOUND BY ASSIGNMENT at file level: `local f = function`, `M.x = function`)
        for _, fn in aq:iter_captures(tree, s, 0, -1) do
            local el = fn:parent()
            local asg = el and el:parent()
            if el and el:type() == 'expression_list' and asg and asg:type() == 'assignment_statement' and not nested(fn) then
                local idx = 0
                for i = 0, el:named_child_count() - 1 do if el:named_child(i):id() == fn:id() then idx = i end end
                local vl = asg:named_child(0)
                local var = vl and vl:type() == 'variable_list' and vl:named_child(idx)
                if var then
                    local name = tx(var, s)
                    local key = name:match('^M[.:]') and name or (rel .. '::' .. name)
                    defs[key] = defs[key] or { node = fn, file = rel, src = s }
                end
            end
        end
    end
    -- ★ BY BINDING, NOT BY NAME (CART-1460): which identifier occurrences are REFERENCES, and where each one's declaration
    -- is — the algebra's own Lua scope graph over the file's lossless read, its reference sites turned into byte offsets.
    -- By name, `kid_by_key(t, key)`'s parameter `key` was rewritten to core's file local `key` (the body compared a kid's
    -- key to a FUNCTION) and the field of `{ key = a }` was renamed too: compiled keyed matching was a different
    -- program. -> refs[byte offset] = { decl = the declaration's byte offset | nil (free) }
    local refcache = {}
    local function refs_of(rel)
        if refcache[rel] then return refcache[rel] end
        local A = require('cartograph.algebra').load()
        local term = assert(require('cartograph.algebraread').read(src[rel], 'lua'))
        local G = A.scope_graph()
        A.lua_scope_graph(term, G, { file = rel })
        pcall(A.sg_link, G)
        local pos_at, pos = {}, 0
        local function walk(n, path)
            pos_at[table.concat(path, ',')] = pos_at[table.concat(path, ',')] or pos
            if n.k == 'lit' then pos = pos + #tostring(n.v == nil and '' or n.v); return end
            for i, c in ipairs(n.kids or {}) do path[#path + 1] = i; walk(c, path); path[#path] = nil end
        end
        walk(term, {})
        local out = {}
        for id, r in pairs(G.refs or {}) do
            local at = r.site and pos_at[table.concat(r.site, ',')]
            if at then
                local res = A.resolve(G, id)
                local e = res.entries and res.entries[1]
                local d = e and G.decls[e.decl]
                out[at] = { decl = d and d.site and pos_at[table.concat(d.site, ',')] or nil }
            end
        end
        refcache[rel] = out
        return out
    end
    -- is the identifier node `cap` of definition d a REFERENCE to something declared OUTSIDE d (a file-level binding, or
    -- free)? A parameter, a local, a field name, a declaration's own name: no
    local function outer_ref(cap, d)
        local _, _, s0 = cap:start()
        local r = refs_of(d.file)[s0]
        if not r then return false end
        if not r.decl then return true end
        -- (the definition's OWN name — `local function f` declares f inside its own node — is the definition, not a
        -- local of it: a self-recursive local function's call of itself is rewritten with the rest)
        local own = d.node:field('name')[1]
        if own and select(3, own:start()) == r.decl then return true end
        local _, _, d0 = d.node:start()
        local _, _, d1 = d.node:end_()
        return r.decl < d0 or r.decl >= d1
    end
    -- a name inside a definition -> the definition it reaches
    local function resolve(name, file)
        if name:match('^M[.:][%w_]+$') then
            local k = name:gsub(':', '.')
            -- (opts.opaque: a definition named there is NOT followed — it stays a primitive call, `M.admits(…)`; the
            -- domain NARROWED to what the specialization can handle, CART-1500)
            if opts.opaque and opts.opaque[k] then return nil end
            return defs[k] and k or nil
        end
        if name:match('^SHARED%.([%w_]+)$') or name:match('^PARTS%.([%w_]+)$') then
            local k = 'core.lua::' .. name:match('%.([%w_]+)$')
            return defs[k] and k or nil
        end
        -- (a file's own module table: `D.x` in derive.lua, a `function D.x` of that file)
        if name:match('^[%a_][%w_]*%.[%w_]+$') and defs[file .. '::' .. name] then return file .. '::' .. name end
        if name:match('^[%a_][%w_]*$') then
            if defs[file .. '::' .. name] then return file .. '::' .. name end
            -- (a SHARED alias: `local child, … = SHARED.child, …` makes `child` core's local)
            if file ~= 'core.lua' and defs['core.lua::' .. name] and src[file]:find('SHARED%.' .. name .. '%f[^%w_]') then return 'core.lua::' .. name end
        end
        return nil
    end
    if not defs[root] then error('mixalg: no definition ' .. root .. ' in ' .. (files and #files == 1 and files[1] or 'the algebra'), 0) end
    -- ASSEMBLE: every definition a top-level `local function <mangled>`, its references rewritten
    local mangle = M.mangle
    local iq = vim.treesitter.query.parse('lua', '[(dot_index_expression) @d (method_index_expression) @d (identifier) @i]')
    -- THE LOADED CODE, indexed by (absolute file, first line): every Lua function reachable from a loaded module's table
    -- or from another such function's upvalues (the algebra loaded first, so its parts are among them)
    pcall(function () require('cartograph.algebra').load() end)
    local fobj, visit = loaded_index()
    local function ensure_loaded(abs)
        local mod = abs:match('/lua/(.-)%.lua$')
        if not mod then return end
        mod = mod:gsub('/', '.')
        if package.loaded[mod] == nil then
            local ok, m = pcall(require, mod)
            if ok and type(m) == 'table' then visit(m, 0) end
        end
    end
    -- the module tables of the closure's files (`M`, `D` …): their dotted calls are rewritten whole above, so the bare
    -- name is no value to carry
    local modtab = {}
    for k in pairs(defs) do
        local file, nm = k:match('^(.-)::(.*)$')
        local t = nm and nm:match('^([%a_][%w_]*)[.:]')
        if t then modtab[file] = modtab[file] or {}; modtab[file][t] = true end
    end
    -- is `name` WRITTEN anywhere in `file`'s text (a reassignment or a store into it — not its own declaration)?
    local written_memo = {}
    local function written(file, name)
        local key = file .. '\0' .. name
        if written_memo[key] == nil then
            local s, w = src[file], false
            local p = vim.pesc(name)
            for line in s:gmatch('[^\n]+') do
                local l = line:gsub('%-%-.*$', '')
                if not l:match('^%s*local%s+' .. p .. '%f[^%w_]') and (l:find('%f[%w_]' .. p .. '%s*=[^=]') or l:find('%f[%w_]' .. p .. '%s*%[[^%]]*%]%s*=[^=]')
                    or l:find('%f[%w_.]' .. p .. '%.[%w_]+%s*=[^=]')) then w = true; break end
            end
            written_memo[key] = w
        end
        return written_memo[key]
    end
    -- the runtime object of a definition (nil: not loaded), and each loaded definition's key by its function object
    local function fkey_of(d) return vim.fn.fnamemodify(path[d.file], ':p') .. ':' .. ((d.node:start()) + 1) end
    local function obj_of(d)
        local fk = fkey_of(d)
        if not fobj[fk] then ensure_loaded(vim.fn.fnamemodify(path[d.file], ':p')) end
        return fobj[fk]
    end
    local key_of_fn, key_of_n
    local prims = {} -- (the program's own primitives, by path: opaque definitions, vetoed follows)
    local decisions, follow_memo = {}, {} -- (the decision hook's log and per-site answers, CART-1501)
    -- the definition whose loaded function object is fv -> its key, or nil (rebuilt when more objects were loaded since)
    local function fn_key(fv)
        local n = 0
        for _ in pairs(fobj) do n = n + 1 end
        if not key_of_fn or key_of_n ~= n then
            key_of_fn, key_of_n = {}, n
            for k2, d2 in pairs(defs) do
                local o2 = fobj[fkey_of(d2)]
                if o2 then key_of_fn[o2] = k2 end
            end
        end
        return key_of_fn[fv]
    end
    -- (the DECISION HOOK, CART-1501: 'follow' — default true; false keeps this site a primitive call. Asked once per
    -- site: the closure walk and the assembly both come here)
    local function follow_ok(cap, d, k3)
        local sk = d.file .. ':' .. cap:id()
        if follow_memo[sk] == nil then
            local choice = true
            if opts.decide then
                local c = opts.decide('follow', { from = d.file, name = tx(cap, d.src), target = k3 }, true)
                if c ~= nil then choice = c end
            end
            decisions[#decisions + 1] = { kind = 'follow', ctx = { from = d.file, name = tx(cap, d.src), target = k3 }, default = true, choice = choice }
            follow_memo[sk] = choice and true or false
        end
        return follow_memo[sk]
    end
    -- THROUGH THE BASIS (opts.through, CART-1500): `B.join` where B is a captured table whose field IS a definition of
    -- these files (the derivations' basis is the algebra's own functions) is that definition — followed into the
    -- closure and rewritten to its mangled name, so mix specializes it with the rest instead of calling it opaque.
    -- The table is read as knowns are: never written in its file, or a snapshot. -> the definition's key, or nil
    local function through(cap, d)
        if not opts.through then return nil end
        local ident = cap:type() == 'identifier'
        if not ident and cap:type() ~= 'dot_index_expression' then return nil end
        -- (`B.join` — a field of a captured table — or `label` — a captured local ALIAS, `local label = M.node_label`)
        local obj, fld = cap, nil
        if not ident then obj, fld = cap:named_child(0), cap:field('field')[1] end
        if not (obj and obj:type() == 'identifier' and (ident or fld)) then return nil end
        if ident then
            local par = cap:parent()
            if par and (par:type() == 'dot_index_expression' or par:type() == 'method_index_expression') and par:named_child(0):id() ~= cap:id() then return nil end
        end
        local nm = tx(obj, d.src)
        if nm == 'M' or nm == 'SHARED' or nm == 'PARTS' or not outer_ref(obj, d) then return nil end
        if written(d.file, nm) and not opts.snapshot then return nil end
        local fo = obj_of(d)
        if not fo then return nil end
        local tbl, found
        for i = 1, 255 do
            local un, uv = debug.getupvalue(fo, i)
            if not un then break end
            if un == nm then tbl, found = uv, true; break end
        end
        if not found then return nil end
        local fv
        if ident then fv = tbl
        else
            if type(tbl) ~= 'table' then return nil end
            local okf, v = pcall(function () return tbl[tx(fld, d.src)] end)
            if not okf then return nil end
            fv = v
        end
        if type(fv) ~= 'function' then return nil end
        local k3 = fn_key(fv)
        if k3 and opts.opaque and opts.opaque[k3] then return nil end -- (kept a primitive)
        if k3 and not follow_ok(cap, d, k3) then return nil end
        return k3
    end
    -- an `M.x` that is no definition of its own but an ALIAS of one — core.lua's `M.kv_kind = kv_kind`, called as
    -- `M.kv_kind` from the part file kvterm.lua — is that definition, found by its function object as `through` finds a
    -- captured alias -> the definition's key, or nil (not loaded, not a function, kept opaque, or a vetoed follow)
    local function m_alias(cap, d, t)
        if not opts.through or (opts.opaque and opts.opaque[t]) then return nil end
        local okA, Acore = pcall(require, 'cartograph.algebra.core')
        local fv = okA and Acore[t:match('^M%.([%w_]+)$')]
        if type(fv) ~= 'function' then return nil end
        if path['core.lua'] then ensure_loaded(vim.fn.fnamemodify(path['core.lua'], ':p')) end
        local k3 = fn_key(fv)
        if not k3 or (opts.opaque and opts.opaque[k3]) then return nil end
        if not follow_ok(cap, d, k3) then prims[t] = fv; return nil end -- (vetoed: a primitive by its path)
        return k3
    end
    -- THE CLOSURE: calls and references-as-values (`local with_cursor = M.with_cursor`), and with opts.through the
    -- basis fields that are definitions of these files
    local rq = vim.treesitter.query.parse('lua', '[(dot_index_expression) @d (identifier) @d]')
    local seen, order, todo = {}, {}, { root }
    for _ = 1, 100000 do
        if #todo == 0 then break end
        local k = table.remove(todo, 1)
        if not seen[k] then
            seen[k] = true
            order[#order + 1] = k
            local d = defs[k]
            for _, c in rq:iter_captures(d.node, d.src, 0, -1) do
                local r = (c:type() ~= 'identifier' or outer_ref(c, d)) and resolve(tx(c, d.src), d.file)
                if not r then r = through(c, d) end
                if not r and c:type() == 'dot_index_expression' then
                    local t = tx(c, d.src)
                    if t:match('^M%.[%w_]+$') and not defs[t] then r = m_alias(c, d, t) end
                end
                if r and not seen[r] then todo[#todo + 1] = r end
            end
        end
    end
    local knowns, report = {}, { known = {}, snapshots = {}, free = {} }
    local noted = {}
    local function note(list, nm) if not noted[list .. nm] then noted[list .. nm] = true; table.insert(report[list], nm) end end
    -- a scalar as a Lua literal that adds NO line (the line map counts the original's lines one to one)
    local function literal(v)
        if v == nil then return 'nil' end
        if type(v) == 'boolean' then return tostring(v) end
        if type(v) == 'number' then
            if v ~= v or v == math.huge or v == -math.huge then return nil end
            return math.floor(v) == v and string.format('%d', v) or string.format('%.17g', v)
        end
        if type(v) == 'string' then return (string.format('%q', v):gsub('\\\n', '\\n')) end
        return nil
    end
    local chunks, lines, nline = {}, {}, 1
    for _, k in ipairs(order) do
        local d = defs[k]
        local n = d.node
        -- the bindings THIS definition captures, by name, from its runtime object (nil: not loaded — nothing carried)
        local uv
        local fkey = vim.fn.fnamemodify(path[d.file], ':p') .. ':' .. ((n:start()) + 1)
        if not fobj[fkey] then ensure_loaded(vim.fn.fnamemodify(path[d.file], ':p')) end
        local fo = fobj[fkey]
        if fo then
            uv = {}
            for i = 1, 255 do
                local nm, v = debug.getupvalue(fo, i)
                if not nm then break end
                uv[nm] = { v = v }
            end
        end
        local params = n:field('parameters')[1]
        local body = n:field('body')[1]
        local ptext = params and tx(params, d.src) or '()'
        local btext = ''
        if body then
            local _, _, b0 = body:start()
            local _, _, b1 = body:end_()
            local edits = {}
            for id, cap in iq:iter_captures(body, d.src, 0, -1) do
                local t = tx(cap, d.src)
                local target
                if iq.captures[id] == 'd' then
                    if t:match('^M[.:][%w_]+$') and defs[(t:gsub(':', '.'))] then
                        local k2 = (t:gsub(':', '.'))
                        if opts.opaque and opts.opaque[k2] then
                            -- (kept opaque: a primitive by its path — the caller passes it as opts.prims and in the env)
                            local okA, Acore = pcall(require, 'cartograph.algebra.core')
                            local fv = okA and Acore[k2:match('^M%.(.*)$')]
                            if type(fv) == 'function' then prims[k2] = fv end
                        else target = mangle(k2) end
                    end
                    if t:match('^SHARED%.([%w_]+)$') and defs['core.lua::' .. t:match('%.([%w_]+)$')] then target = mangle('core.lua::' .. t:match('%.([%w_]+)$')) end
                    if not target and defs[d.file .. '::' .. t] then target = mangle(d.file .. '::' .. t) end
                    if not target then local th = through(cap, d); if th then target = mangle(th) end end -- (CART-1500)
                    if not target and t:match('^M%.[%w_]+$') and not defs[t] then
                        local ka = m_alias(cap, d, t)
                        if ka then target = mangle(ka) end
                    end
                    -- (through: an algebra DATA field the followed code reads — `M.OBSERVED`, `M.grammars` — is a KNOWN
                    -- global by its dotted name, as compile_match passes M.grammars)
                    if not target and opts.through and t:match('^M%.[%w_]+$') and knowns[t] == nil then
                        local okA, Acore = pcall(require, 'cartograph.algebra.core')
                        local v = okA and Acore[t:match('^M%.([%w_]+)$')]
                        if v ~= nil and type(v) ~= 'function' then knowns[t] = v end
                    end
                else
                    -- (an identifier that is a field name — the `f` of `a.f`, `a:f` — is no reference)
                    local par = cap:parent()
                    if not (par and (par:type() == 'dot_index_expression' or par:type() == 'method_index_expression') and par:named_child(0):id() ~= cap:id())
                        and outer_ref(cap, d) then
                        local r = resolve(t, d.file)
                        local th = not r and through(cap, d) -- (CART-1500: a captured alias of a definition)
                        local vetoed = not r and not th and follow_memo[d.file .. ':' .. cap:id()] == false
                        if th then target = mangle(th)
                        elseif vetoed then
                            -- (a FOLLOW the hook vetoed on an alias, CART-1501: the alias stays a primitive under its own
                            -- mangled name — its function value carried, so the call still reaches something)
                            target = mangle(d.file .. '::' .. t)
                            prims[target] = uv and uv[t] and uv[t].v
                        elseif r and not r:match('^M') then target = mangle(r)
                        elseif not r and uv and uv[t] and not (modtab[d.file] and modtab[d.file][t])
                            and t ~= 'M' and t ~= 'SHARED' and t ~= 'PARTS' then -- (the algebra's own tables: mix knows M.x by name)
                            -- (CART-1374: a captured file-level VALUE — a constant inlined or carried known; a written one
                            -- only as a snapshot; a function value stays free: mix calls only what it can see)
                            local v = uv[t].v
                            local w = written(d.file, t)
                            if type(v) ~= 'function' and (not w or (opts.snapshot and v ~= nil)) then
                                local lit = literal(v)
                                -- (a literal as the OBJECT of an index or a call needs parentheses: `nil.x`, `"s":m()` do
                                -- not parse)
                                local pt = par and par:type()
                                if lit and (pt == 'dot_index_expression' or pt == 'method_index_expression'
                                    or pt == 'bracket_index_expression' or pt == 'function_call') then lit = '(' .. lit .. ')' end
                                if lit then target = lit
                                elseif type(v) == 'table' then
                                    target = mangle(d.file .. '::' .. t)
                                    knowns[target] = v
                                    -- (mix names a known global by its DOTTED PATH — `M.grammars` — so a field this
                                    -- closure reads is known under `<file>__<name>.<field>` too; a function field is
                                    -- a call mix must see as a primitive, never a value carried here)
                                    -- (a FUNCTION field is a PRIMITIVE of this program — rung 5: the basis `B.kinds` —
                                    -- returned in `prims` for mix's opts.prims; read under pcall: the basis table
                                    -- raises on a name it does not hold)
                                    if pt == 'dot_index_expression' then
                                        local fld = par:field('field')[1]
                                        local fname = fld and tx(fld, d.src)
                                        local okf, fv = pcall(function () return v[fname] end)
                                        if fname and okf and fv ~= nil then
                                            if type(fv) == 'function' then prims[target .. '.' .. fname] = fv
                                            else knowns[target .. '.' .. fname] = fv end
                                        end
                                    end
                                end
                                if target then note(w and 'snapshots' or 'known', d.file .. '::' .. t) end
                            else note('free', d.file .. '::' .. t) end
                        end
                    end
                end
                if target then
                    local _, _, s0 = cap:start()
                    local _, _, s1 = cap:end_()
                    edits[#edits + 1] = { s0 - b0, s1 - b0, target }
                end
            end
            btext = d.src:sub(b0 + 1, b1)
            -- (from the end; at one start the LONGER edit — `B.join` rewritten whole, not its `B`)
            table.sort(edits, function (a, b) if a[1] ~= b[1] then return a[1] > b[1] end return a[2] > b[2] end)
            local last = math.huge
            for _, e in ipairs(edits) do
                if e[2] <= last then btext = btext:sub(1, e[1]) .. e[3] .. btext:sub(e[2] + 1); last = e[1] end
            end
        end
        local chunk = 'local function ' .. mangle(k) .. ptext .. '\n' .. btext .. '\nend\n'
        -- (the header holds the parameters, the body starts on the next line: each line from there is the body's)
        local hdr = (n:start()) + 1
        local _, pl = ptext:gsub('\n', '')
        for i = 0, pl do lines[nline + i] = { src = short_src(path[d.file]), line = hdr + i } end
        local b0 = body and ((body:start()) + 1) or hdr
        local _, bl = btext:gsub('\n', '')
        for i = 0, bl do lines[nline + pl + 1 + i] = { src = short_src(path[d.file]), line = b0 + i } end
        local _, cl = chunk:gsub('\n', '')
        nline = nline + cl + 1 -- (the blank line between chunks)
        chunks[#chunks + 1] = chunk
    end
    local text = table.concat(chunks, '\n')
    report.decisions = decisions
    if not opts.decide then cache[ckey] = { text = text, order = order, lines = lines, knowns = knowns, report = report, prims = prims } end
    return text, order, lines, knowns, report, prims
end

local term_cache
-- ★ SPECULATION (CART-1463): the DEOPTIMIZATION a compiled matcher raises when an assumption it was compiled under
-- (opts.assume, see cartograph.mix) fails at run time — the caller then runs the ORIGINAL. A deopt is also FLAGGED: a
-- residual `pcall` (key computations keep the original's) would otherwise swallow it and answer from a wrong branch
M.DEOPT = setmetatable({}, { __tostring = function () return 'mixalg: an assumption of the compiled matcher failed (deoptimize)' end })
-- the residual chunk's environment and the function it serves: the matcher, checked for a swallowed deopt
local function served(text, pool)
    local A = require('cartograph.algebra').load()
    local flag = { up = false }
    local env = setmetatable({ MIXK = pool, M = { grammars = A.grammars },
        MIXDEOPT = function () flag.up = true; error(M.DEOPT, 0) end }, { __index = _G })
    local m = assert(load(text, 'mixalg.match', 't', env))()
    return function (I)
        flag.up = false
        local r = m(I)
        if flag.up then error(M.DEOPT, 0) end
        return r
    end
end

--- match specialized to the template T: a COMPILED MATCHER -> function (I) -> what A.match(T, I) returns, the residual
--- text, stats. opts.env: match's env, STATIC (e.g. { lazy_refusal = true }). opts.budget / opts.depth pass to mix;
--- opts.assume: SPECULATE — e.g. { align = { value = nil } }, a
--- subject's nodes are never keyed (algebraread's are not): the keyed code folds away, a guard raises M.DEOPT when a
--- node is keyed after all
function M.compile_match(T, opts)
    opts = opts or {}
    local MX = require 'cartograph.mix'
    local A = require('cartograph.algebra').load()
    if not term_cache then term_cache = assert(require('cartograph.algebraread').read((M.program('M.match')), 'lua')) end
    local _, _, lines = M.program('M.match')
    local text, stats, pool, map = MX.mix(term_cache, 'M_match', { 'S', 'D', 'S' }, { T, nil, opts.env },
        { budget = opts.budget or 5e6, depth = opts.depth, globals = { ['M.grammars'] = A.grammars or {} }, lines = lines, assume = opts.assume })
    -- (map: residual line -> the algebra's src:line — MX.translate turns an error of this code into the source's terms)
    return served(text, pool), text, stats, pool, map
end

--- a compiled matcher from its residual TEXT and constant POOL (as compile_match returned them, e.g. read back from a
--- cache) -> the matcher function
function M.load_match(text, pool)
    return served(text, pool)
end

return M
