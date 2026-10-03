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
-- ⚠ Names are resolved BY NAME, not by scope: a local shadowing a file function of the same name would be rewritten
-- to that function — the equivalence gate (tests/mixalg_spec.lua) is what guards the closure it builds.
local M = {}

local function algebra_dir()
    local here = debug.getinfo(1, 'S').source:sub(2)
    return vim.fn.fnamemodify(here, ':p:h') .. '/algebra'
end

local cache = {}

--- the CALL CLOSURE of an algebra function (default M.match) as one mix program -> program text, the closure's keys in
--- order (memoized per root and per process)
function M.program(root)
    root = root or 'M.match'
    if cache[root] then return cache[root].text, cache[root].order end
    local files = vim.fn.glob(algebra_dir() .. '/*.lua', false, true)
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
    for _, f in ipairs(files) do
        local s = io.open(f):read('a')
        local rel = f:match('algebra/(.*)$')
        src[rel] = s
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
    if not defs[root] then error('mixalg: no algebra definition ' .. root, 0) end
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
                local r = resolve(tx(c, d.src), d.file)
                if r and not seen[r] then todo[#todo + 1] = r end
            end
        end
    end
    -- ASSEMBLE: every definition a top-level `local function <mangled>`, its references rewritten
    local function mangle(k)
        if k:match('^M[.:]') then return (k:gsub('[.:]', '_')) end
        local file, nm = k:match('^(.-)%.lua::(.*)$')
        return ((file .. '__' .. nm):gsub('[.:]', '_'))
    end
    local iq = vim.treesitter.query.parse('lua', '[(dot_index_expression) @d (method_index_expression) @d (identifier) @i]')
    local chunks = {}
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
                    if not (par and (par:type() == 'dot_index_expression' or par:type() == 'method_index_expression') and par:named_child(0):id() ~= cap:id()) then
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
        chunks[#chunks + 1] = 'local function ' .. mangle(k) .. ptext .. '\n' .. btext .. '\nend\n'
    end
    local text = table.concat(chunks, '\n')
    cache[root] = { text = text, order = order }
    return text, order
end

local term_cache
--- match specialized to the template T: a COMPILED MATCHER -> function (I) -> what A.match(T, I) returns, the residual
--- text, stats. opts.budget / opts.depth pass to mix
function M.compile_match(T, opts)
    opts = opts or {}
    local MX = require 'cartograph.mix'
    local A = require('cartograph.algebra').load()
    if not term_cache then term_cache = assert(require('cartograph.algebraread').read((M.program('M.match')), 'lua')) end
    local text, stats, pool = MX.mix(term_cache, 'M_match', { 'S', 'D', 'S' }, { T, nil, nil },
        { budget = opts.budget or 5e6, depth = opts.depth, globals = { ['M.grammars'] = A.grammars or {} } })
    local env = setmetatable({ MIXK = pool, M = { grammars = A.grammars } }, { __index = _G })
    local chunk = assert(load(text, 'mixalg.match', 't', env))
    return chunk(), text, stats, pool
end

--- a compiled matcher from its residual TEXT and constant POOL (as compile_match returned them, e.g. read back from a
--- cache) -> the matcher function
function M.load_match(text, pool)
    local A = require('cartograph.algebra').load()
    local env = setmetatable({ MIXK = pool, M = { grammars = A.grammars } }, { __index = _G })
    return assert(load(text, 'mixalg.match', 't', env))()
end

return M
