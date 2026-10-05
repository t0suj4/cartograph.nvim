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

--- the CALL CLOSURE of an algebra function (default M.match) as one mix program -> program text, the closure's keys in
--- order, the LINE MAP: lines[n] = { src = the file's short name, line } — where line n of the text came from (a
--- definition's renames never add a line, so its lines map one to one) (memoized per root and per process)
--- `files` (CART-1445): ANY Lua files (absolute paths) instead of the algebra's — a module's own call closure (its
--- `M.x` and file locals; a name in another file is a free name, as anything required is). Default: the algebra.
function M.program(root, files)
    root = root or 'M.match'
    local ckey = root .. (files and ('\0' .. table.concat(files, '\0')) or '')
    if cache[ckey] then return cache[ckey].text, cache[ckey].order, cache[ckey].lines end
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
        local _, _, d0 = d.node:start()
        local _, _, d1 = d.node:end_()
        return r.decl < d0 or r.decl >= d1
    end
    -- a name inside a definition -> the definition it reaches
    local function resolve(name, file)
        if name:match('^M[.:][%w_]+$') then local k = name:gsub(':', '.'); return defs[k] and k or nil end
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
    -- THE CLOSURE: calls and references-as-values (`local with_cursor = M.with_cursor`)
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
                if r and not seen[r] then todo[#todo + 1] = r end
            end
        end
    end
    -- ASSEMBLE: every definition a top-level `local function <mangled>`, its references rewritten
    local mangle = M.mangle
    local iq = vim.treesitter.query.parse('lua', '[(dot_index_expression) @d (method_index_expression) @d (identifier) @i]')
    local chunks, lines, nline = {}, {}, 1
    for _, k in ipairs(order) do
        local d = defs[k]
        local n = d.node
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
                    if t:match('^M[.:][%w_]+$') and defs[(t:gsub(':', '.'))] then target = mangle((t:gsub(':', '.'))) end
                    if t:match('^SHARED%.([%w_]+)$') and defs['core.lua::' .. t:match('%.([%w_]+)$')] then target = mangle('core.lua::' .. t:match('%.([%w_]+)$')) end
                    if not target and defs[d.file .. '::' .. t] then target = mangle(d.file .. '::' .. t) end
                else
                    -- (an identifier that is a field name — the `f` of `a.f`, `a:f` — is no reference)
                    local par = cap:parent()
                    if not (par and (par:type() == 'dot_index_expression' or par:type() == 'method_index_expression') and par:named_child(0):id() ~= cap:id())
                        and outer_ref(cap, d) then
                        local r = resolve(t, d.file)
                        if r and not r:match('^M') then target = mangle(r) end
                    end
                end
                if target then
                    local _, _, s0 = cap:start()
                    local _, _, s1 = cap:end_()
                    edits[#edits + 1] = { s0 - b0, s1 - b0, target }
                end
            end
            btext = d.src:sub(b0 + 1, b1)
            table.sort(edits, function (a, b) return a[1] > b[1] end)
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
    cache[ckey] = { text = text, order = order, lines = lines }
    return text, order, lines
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
