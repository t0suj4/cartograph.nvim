-- A STRING RECEIVER IS THE STDLIB'S (CART-1062): `('%s'):format(x)` is `string.format`, so no project def named
-- `format` can be its target — the name-match used to land 4,330 such calls on one project function. Pinned both ways:
-- a receiver that is NOT a string by syntax still resolves as it did.

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

-- the callers of `name` in `file`: { caller name… }
local function callers(st, file, name)
    local out = {}
    for _, n in ipairs(st.data.nodes) do
        if n.file == file and n.name == name then
            for _, c in ipairs(st.usedby[n.id] or {}) do out[#out + 1] = st.by_id[c].name end
        end
    end
    table.sort(out)
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
    eq({ 'U.name' }, callers(st, 'fmt.lua', 'M.format'), 'only the untyped receiver still name-matches')
    eq({}, callers(st, 'fmt.lua', 'M.rep'), 'a concatenation is a string')
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
    eq({ 'U.obj', 'U.re', 'U.via' }, callers(st, 'hz.lua', 'M.gsub'), 'typed locals leave; a reassigned one and a hazard object stay')
    eq({ 'U.par', 'U.pos', 'U.via' }, callers(st, 'hz.lua', 'M.sub'), 'a chain of string locals leaves; a parameter, a hazard method result and a second result stay')
end)

test('stringrecv (CART-1150): a declaration LATER on the same line is not the binding', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local st = ingest {
        ['hz.lua'] = 'local M = {}\nfunction M.gsub(self, p) return p end\nreturn M\n',
        ['use.lua'] = "local U = {}\nfunction U.a(s) local r = s:gsub('x', ''); local s = 'y'; return r end\nreturn U\n",
    }
    eq({ 'U.a' }, callers(st, 'hz.lua', 'M.gsub'), 'the parameter s is untyped; the later local s does not reach back')
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
    eq({ 'U.num', 'U.proj' }, callers(st, 'hz.lua', 'M.sub'), 'the string fields leave; a number field and a project record stay')
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
    eq({ 'U.other' }, callers(st, 'hz.lua', 'M.gsub'), 'a read from io.open is a string; a read from anything else is not known')
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
    eq({ 'U.chr', 'U.pos' }, callers(st, 'lua/p/hz.lua', 'M.gsub'), 'declared string returns leave; getpos (a tuple) and getchar (integer|string) stay')
    st = ingest_tree { ['lua/p/hz.lua'] = hz, ['lua/p/use.lua'] = use }
    eq({ 'U.chr', 'U.pos', 'U.sys', 'U.tx' }, callers(st, 'lua/p/hz.lua', 'M.gsub'), 'no plugin shape, no environment: nothing typed')
end)
