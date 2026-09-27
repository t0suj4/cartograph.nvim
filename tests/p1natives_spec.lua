-- THE p1 NIF MODELS (lua/cartograph/p1natives.lua, CART-1138): jid's splitter and stringprep, as the RUNNING runtime
-- answered them (every expectation below was printed by erl with application:ensure_all_started(xmpp);
-- tools/p1natives.lua is the exhaustive acceptance), and erlterms consulting them only where a NIF stands.

local function need() if not parser_available('erlang') then skip 'no erlang parser' end end

local function show(t) return t and require('cartograph.algebra').load().show(t) or 'nil' end
local function call(id, s) return show(require('cartograph.p1natives').models[id] { { k = 'lit', v = s, lk = 'bin' } }) end

test('p1natives: stringprep — nodeprep lowercases and refuses space and "&\'/:<>@; nameprep refuses nothing; resourceprep keeps case', function ()
    eq('"u"', call('stringprep:nodeprep/1', 'U'))
    eq('"a.b"', call('stringprep:nodeprep/1', 'a.b'))
    eq('""', call('stringprep:nodeprep/1', ''))
    for _, s in ipairs { 'a b', 'a"b', 'a&b', "a'b", 'a/b', 'a:b', 'a<b', 'a>b', 'a@b' } do
        eq('"error"', call('stringprep:nodeprep/1', s), s)
    end
    eq('"u"', call('stringprep:nameprep/1', 'U'))
    eq('"a b"', call('stringprep:nameprep/1', 'a b'))
    eq('"a@b"', call('stringprep:nameprep/1', 'a@b'))
    eq('"U"', call('stringprep:resourceprep/1', 'U'))
    eq('"a b"', call('stringprep:resourceprep/1', 'a b'))
end)

test('p1natives: jid:string_to_usr is jid.rl — the node before an @ that precedes any /, labels, a non-empty resource', function ()
    local id = 'jid:string_to_usr/1'
    eq('(tuple "u" "s" "r")', call(id, 'u@s/r'))
    eq('(tuple "" "a" "b@c")', call(id, 'a/b@c'))
    eq('(tuple "u" "s" "r/x")', call(id, 'u@s/r/x'))
    eq('(tuple "U" "S." "")', call(id, 'U@S.'))
    eq('(tuple "u" "s" "r t")', call(id, 'u@s/r t'))
    eq('(tuple "" "s:5" "")', call(id, 's:5'))
    for _, s in ipairs { '', 'u@', 'a/', '@s', 's..t', '.s', 'a@b@c', 'u@@s', 'u s@x', 'u@s t', 'u@s/' } do
        eq('"error"', call(id, s), s)
    end
end)

test('p1natives: outside printable ASCII every model answers nil — the hole stays', function ()
    for id in pairs(require('cartograph.p1natives').models) do
        for _, s in ipairs { 'a\tb', 'a\127', '\195\169' } do eq('nil', call(id, s), id .. ' ' .. s) end
    end
end)

test('p1natives: erlterms consults a model for a nif_error stub and a module with no source, never over a definition', function ()
    need()
    local ET = require 'cartograph.erlterms'
    local N = require 'cartograph.p1natives'
    local A = require('cartograph.algebra').load()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local function write(name, text) local fd = assert(io.open(dir .. '/' .. name, 'w')); fd:write(text); fd:close() end
    write('jid.erl', table.concat({
        '-module(jid).',
        'string_to_usr(_S) -> erlang:nif_error(nif_not_loaded).',
        'decode(S) ->',
        '    case string_to_usr(S) of',
        '        error -> erlang:error({bad_jid, S});',
        '        {U, H, R} -> {stringprep:nodeprep(U), stringprep:nameprep(H), stringprep:resourceprep(R), real:nodeprep(U)}',
        '    end.', '' }, '\n'))
    write('real.erl', '-module(real).\nnodeprep(_) -> <<"mine">>.\n')
    local bin = { k = 'lit', v = 'U@S/R', lk = 'bin' }
    local models = vim.deepcopy(N.models)
    models['real:nodeprep/1'] = function () return A.lit('model') end   -- a model beside a definition: never asked
    local S = ET.session()
    local t = ET.call(ET.program { dirs = { dir }, natives = models }, 'jid', 'decode', { bin }, S)
    eq('(tuple "u" "s" "R" "mine")', A.show(t))
    eq(4, S.stats.natives, 'the stub and three no-source calls answered')
    -- no models: the NIF is a hole again (only the real definition's "mine" is known)
    local bare = ET.call(ET.program { dirs = { dir } }, 'jid', 'decode', { bin })
    eq('partial', ET.status(bare))
    ok(not A.show(bare):find('"u"', 1, true), A.show(bare))
end)
