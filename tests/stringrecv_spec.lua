-- A STRING RECEIVER IS THE STDLIB'S (CART-1062): `('%s'):format(x)` is `string.format`, so no project def named
-- `format` can be its target — the name-match used to land 4,330 such calls on one project function. And (CART-1150)
-- a string-library method on an UNTYPED receiver is AMBIGUOUS: refused as `vocab`, never tail-matched. Pinned both ways:
-- every case says which of the two it is.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ingest(files)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    store.ingest(ts.extract(root))
    return store
end

-- what each function's calls to `member` became: `string` (keyed the stdlib's, external), `vocab` (refused: a string-
-- library method on an untyped receiver is AMBIGUOUS, CART-1150), `edge` (resolved into a project def). A function
-- with several such calls reads their distinct outcomes joined.
local function outcomes(st, member)
    local by = {}
    for _, c in ipairs(st.data.calls) do
        if c.callee == member and c.fn then
            local fname = (st.by_id[c.fn] or {}).name or c.fn
            local o = (c.full or ''):match('^string%.') and 'string'
                or (c.refused and c.refused.rule == 'vocab' and 'vocab') or (c.to and 'edge') or 'other'
            by[fname] = by[fname] or {}
            by[fname][o] = true
        end
    end
    local out = {}
    for f, set in pairs(by) do
        local l = vim.tbl_keys(set); table.sort(l); out[f] = table.concat(l, '+')
    end
    return out
end

test('stringrecv: a string-literal, concatenation or tostring() receiver never reaches a project `format`', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local st = ingest {
        ['fmt.lua'] = 'local M = {}\nfunction M.format(a) return a end\nfunction M.rep(a) return a end\nreturn M\n',
        ['use.lua'] = table.concat({
            'local U = {}',
            "function U.lit() return ('%s'):format(1) end",
            "function U.cat(b) return ('a' .. b):rep(2) end",
            "function U.tos(q) return tostring(q):format() end",
            'function U.name(obj) return obj:format(1) end',
            'return U', '' }, '\n'),
    }
    eq({ ['U.lit'] = 'string', ['U.tos'] = 'string', ['U.name'] = 'vocab' }, outcomes(st, 'format'),
        'typed receivers are the stdlib\'s; the untyped one is refused as ambiguous, never matched to M.format')
    eq({ ['U.cat'] = 'string' }, outcomes(st, 'rep'), 'a concatenation is a string')
end)

test('stringrecv (CART-1150): a LOCAL only ever assigned strings is typed — and a reassigned one, a hazard object and a parameter are NOT', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local st = ingest {
        ['hz.lua'] = 'local M = {}\nfunction M.gsub(self, p) return p end\nfunction M.sub(self, i) return i end\nfunction M.new() return setmetatable({}, { __index = M }) end\nreturn M\n',
        ['use.lua'] = table.concat({
            "local hz = require 'hz'",
            'local U = {}',
            "function U.a() local s = ('%s'):format(1); return s:gsub('x', '') end",
            "function U.b() local s = ('x'):sub(1); local t = s:sub(2); return t:sub(1) end",
            "function U.c() local s, n = ('x'):gsub('a', 'b'); return s:sub(1), n end",
            "function U.re() local s = 'a'; s = {}; return s:gsub('x', '') end",
            'function U.obj() local h = hz.new(); return h:gsub(1) end',
            "function U.par(p) return p:sub(1) end",
            -- a string METHOD on a non-string receiver does not make its result a string
            'function U.via() local h = hz.new(); local x = h:gsub(1); return x:sub(1) end',
            -- only the FIRST result of gsub is a string: the second variable is not typed by position
            "function U.pos() local s, n = ('x'):gsub('a', 'b'); return n:sub(1) end",
            'return U', '' }, '\n'),
    }
    -- ⚠ the hazard OBJECT is refused too: its receiver's type is unknown, and the string library owns `gsub` as much as
    -- hazard.lua does — the honest answer is the ambiguity (the correct edge is a guess this graph no longer makes)
    eq({ ['U.a'] = 'string', ['U.c'] = 'string', ['U.pos'] = 'string', ['U.re'] = 'vocab', ['U.obj'] = 'vocab',
        ['U.via'] = 'vocab' }, outcomes(st, 'gsub'), 'typed locals are the stdlib\'s; a reassigned one and a hazard object refuse')
    eq({ ['U.b'] = 'string', ['U.c'] = 'string', ['U.par'] = 'vocab', ['U.via'] = 'vocab', ['U.pos'] = 'vocab' },
        outcomes(st, 'sub'), 'a chain of string locals is the stdlib\'s; a parameter, a hazard method result and a second result refuse')
end)

test('stringrecv (CART-1150): a declaration LATER on the same line is not the binding', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local st = ingest {
        ['hz.lua'] = 'local M = {}\nfunction M.gsub(self, p) return p end\nreturn M\n',
        ['use.lua'] = "local U = {}\nfunction U.a(s) local r = s:gsub('x', ''); local s = 'y'; return r end\nreturn U\n",
    }
    eq({ ['U.a'] = 'vocab' }, outcomes(st, 'gsub'), 'the parameter s is untyped; the later local s does not reach back')
end)

test('stringrecv (CART-1150): a BUILT-IN record field is typed — debug.getinfo(…).source is a string; its number fields and a project table are not', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local st = ingest {
        ['hz.lua'] = 'local M = {}\nfunction M.sub(self, i) return i end\nreturn M\n',
        ['use.lua'] = table.concat({
            'local U = {}',
            "function U.direct() return debug.getinfo(1, 'S').source:sub(2) end",
            "function U.via() local info = debug.getinfo(1, 'S'); return info.source:sub(2) end",
            "function U.num() local info = debug.getinfo(1, 'l'); return info.currentline:sub(1) end",
            "function U.proj(t) local r = { source = t }; return r.source:sub(1) end",
            'return U', '' }, '\n'),
    }
    eq({ ['U.direct'] = 'string', ['U.via'] = 'string', ['U.num'] = 'vocab', ['U.proj'] = 'vocab' }, outcomes(st, 'sub'),
        'the string fields are the stdlib\'s; a number field and a project record refuse')
end)

test('stringrecv (CART-1150): a file handle is a built-in record — fd:read() is a string, fd:close() is not', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local st = ingest {
        ['hz.lua'] = 'local M = {}\nfunction M.gsub(self, p) return p end\nfunction M.close(self) end\nreturn M\n',
        ['use.lua'] = table.concat({
            'local U = {}',
            "function U.r(p) local fd = io.open(p); local s = fd:read('a'); fd:close(); return s:gsub('x', '') end",
            "function U.other(t) local s = t:read('a'); return s:gsub('x', '') end",
            'return U', '' }, '\n'),
    }
    eq({ ['U.r'] = 'string', ['U.other'] = 'vocab' }, outcomes(st, 'gsub'), 'a read from io.open is a string; a read from anything else is not known')
end)

-- an nvim-plugin layout (plugin/ + lua/) activates the `nvim` profile: the runtime's own declared returns
local function ingest_tree(files)
    local root = vim.fn.tempname()
    for rel, text in pairs(files) do
        local dir = (root .. '/' .. rel):match('^(.*)/[^/]*$')
        vim.fn.mkdir(dir, 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    store.ingest(ts.extract(root))
    return store
end

test('stringrecv (CART-1150): the NVIM profile types a runtime call\'s declared string return — only where the plugin shape activates it', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    if not require('cartograph.spec.profile').load('nvim') then skip 'no nvim profile distilled' end
    local hz = 'local M = {}\nfunction M.gsub(self, p) return p end\nreturn M\n'
    local use = table.concat({
        'local U = {}',
        "function U.tx(n, src) local text = vim.treesitter.get_node_text(n, src); return text:gsub('x', '') end",
        "function U.sys() local out = vim.fn.system({ 'ls' }); return out:gsub('x', '') end",
        "function U.pos() local p = vim.fn.getpos('.'); return p:gsub('x', '') end",
        -- a union that only CONTAINS string (`integer|string`) is not a string
        "function U.chr() local c = vim.fn.getchar(); return c:gsub('x', '') end",
        'return U', '' }, '\n')
    local st = ingest_tree { ['plugin/p.lua'] = '-- entry\n', ['lua/p/hz.lua'] = hz, ['lua/p/use.lua'] = use }
    eq('nvim', st.data.profile, 'the plugin shape activated the profile')
    eq({ ['U.tx'] = 'string', ['U.sys'] = 'string', ['U.pos'] = 'vocab', ['U.chr'] = 'vocab' }, outcomes(st, 'gsub'),
        'declared string returns are the stdlib\'s; getpos (a tuple) and getchar (integer|string) refuse')
    st = ingest_tree { ['lua/p/hz.lua'] = hz, ['lua/p/use.lua'] = use }
    eq({ ['U.tx'] = 'vocab', ['U.sys'] = 'vocab', ['U.pos'] = 'vocab', ['U.chr'] = 'vocab' }, outcomes(st, 'gsub'),
        'no plugin shape, no environment: nothing typed, all ambiguous')
end)

test('stringrecv (CART-1150): the ambiguity gate is NARROW — self:m() and a non-string method still resolve, and a refusal names its candidate', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local st = ingest {
        ['hz.lua'] = table.concat({
            'local M = {}',
            'function M:gsub(p) return p end',
            'function M:close() end',
            'function M:tidy(p) return self:gsub(p) end', -- the method's own class: resolves
            'function M.tidy2(self, p) return self:gsub(p) end', -- an explicit self, dot-defined
            'return M', '' }, '\n'),
        ['use.lua'] = 'local U = {}\nfunction U.shut(x) return x:close() end\nfunction U.g(x) return x:gsub(1) end\nreturn U\n',
    }
    eq({ ['M:tidy'] = 'edge', ['M.tidy2'] = 'edge', ['U.g'] = 'vocab' }, outcomes(st, 'gsub'),
        'self:gsub resolves, colon- or dot-defined; an untyped x:gsub refuses')
    eq({ ['U.shut'] = 'edge' }, outcomes(st, 'close'), 'close is no string-library member: the gate does not touch it')
    for _, c in ipairs(st.data.calls) do
        if c.callee == 'gsub' and c.refused then
            eq({ 'hz.lua::M:gsub@1' }, c.refused.cands, 'the refusal is a PLACE: the project candidate is named')
        end
    end
end)
