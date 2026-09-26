-- The PARSER IDENTITY in graph validity (nvim 0.12 upgrade prep): a cached graph is only valid for the nvim and the
-- tree-sitter parsers that produced it. nvim BUNDLES c and lua (its runtime parser dir precedes nvim-treesitter's on
-- the runtimepath), so an nvim upgrade swaps those grammars under every warm cache.

local parserid = require 'cartograph.parserid'
local cache = require 'cartograph.cache'
local ts = require 'cartograph.providers.treesitter'

local function fake_parser_dir(lang, bytes)
    local d = vim.fn.tempname()
    vim.fn.mkdir(d .. '/parser', 'p')
    local fd = assert(io.open(d .. '/parser/' .. lang .. '.so', 'wb')); fd:write(bytes); fd:close()
    return d
end

test('parserid: the key names the nvim version and is stable across calls', function ()
    local v = vim.version()
    local k = parserid.key()
    ok(k:find(('nvim %d.%d.%d'):format(v.major, v.minor, v.patch), 1, true), k)
    eq(k, parserid.key())
end)

test('parserid: a parser appearing FIRST on the runtimepath changes the key, and removing it restores it', function ()
    local k0 = parserid.key()
    -- a made-up language, so no real grammar is shadowed for the rest of the suite
    local d = fake_parser_dir('zzparseridfake', 'not a parser')
    vim.opt.rtp:prepend(d)
    local k1 = parserid.key()
    vim.opt.rtp:remove(d)
    local k2 = parserid.key()
    vim.fn.delete(d, 'rf')
    ok(k1 ~= k0, 'a new parser moved the key')
    eq(k0, k2, 'and it is back once the parser is gone')
end)

test('parserid: a SHADOWING parser for an existing language changes the key (the upgrade case)', function ()
    local found = vim.api.nvim_get_runtime_file('parser/lua.so', false)[1]
    if not found then skip 'no lua parser on the runtimepath' end
    local k0 = parserid.key()
    local d = fake_parser_dir('lua', 'a different grammar build')
    vim.opt.rtp:prepend(d)
    local k1 = parserid.key() -- only the KEY is computed: nothing parses lua while the fake is first
    vim.opt.rtp:remove(d)
    vim.fn.delete(d, 'rf')
    ok(k1 ~= k0, 'the lua parser that would load is a different file')
    eq(k0, parserid.key())
end)

test('parserid: contributes to graph validity, so a warm cache built with other parsers is a MISS', function ()
    local names = {}
    for _, n in ipairs(require('cartograph.validity').contributors()) do names[n] = true end
    ok(names.parsers, 'parsers contributes to graph validity')
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local function f(x) return x end\nreturn { f = f }\n'); fd:close()
    cache.wipe(root)
    cache.save(ts.extract(root))
    ok(cache.open(root) ~= nil, 'warm open works right after save')
    local d = fake_parser_dir('zzparseridfake', 'not a parser')
    vim.opt.rtp:prepend(d)
    eq(nil, cache.open(root), 'the parser set moved: the cache is stale')
    vim.opt.rtp:remove(d)
    vim.fn.delete(d, 'rf')
    ok(cache.open(root) ~= nil, 'and valid again once restored')
    cache.wipe(root); vim.fn.delete(root, 'rf')
end)

-- ★ THE SKIPPED COUNT IS WHERE A LOST PARSER HIDES. Every language spec guards itself with `parser_available(...)` and
-- SKIPS when the grammar is missing, so an upgrade that moves parsers (nvim-treesitter's 0.12 `main` branch installs
-- them elsewhere) would turn hundreds of tests from green into skipped and leave the suite looking healthy. This one
-- FAILS instead, naming the languages, for every tree-sitter language cartograph has a spec for (the spec table, so a
-- new language enters with no edit here).
test('parserid: every tree-sitter language cartograph specs has a loadable parser (a lost one FAILS, not skips)', function ()
    local missing = {}
    local n = 0
    for lang in pairs(ts.spec) do
        n = n + 1
        if not parser_available(lang) then missing[#missing + 1] = lang end
    end
    table.sort(missing)
    ok(n >= 18, 'the spec table is populated (' .. n .. ')')
    eq({}, missing, 'no parser for: ' .. table.concat(missing, ' '))
end)
