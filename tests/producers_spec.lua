-- INPUT PRODUCER CANDIDATES (lua/cartograph/producers.lua, CART-1118 v1): consumers, attachable dependencies and
-- obligation producers for a tree, each cited by the line that selects it. Fixture: two repos in a temp dir.

local function need() if not parser_available('erlang') then skip 'no erlang parser' end end

local function fixture()
    local root = vim.fn.tempname()
    local function w(p, t) vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. p, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. p, 'w')); fd:write(t); fd:close() end
    w('lib/rebar.config', '{deps, []}.\n')
    w('lib/src/lib.app.src', '{application, lib, [{vsn, "1.0"}]}.\n')
    w('lib/src/lib_beh.erl', '-module(lib_beh).\n-callback go() -> ok.\n')
    w('app/rebar.config', '{deps, [{lib, "1.0"},\n        {if_var_true, flag, {cond_dep, "2.0"}}]}.\n')
    w('app/src/app.app.src', '{application, app, [{vsn, "0.1"}]}.\n')
    w('app/src/own_beh.erl', '-module(own_beh).\n-callback run() -> ok.\n')
    w('app/src/m.erl', '-module(m).\n-behaviour(lib_beh).\n-behaviour(gen_server).\n-behaviour(missing_beh).\n-behaviour(own_beh).\n')
    w('ext/package.json', '{ "name": "lib", "version": "9.9.9" }\n')   -- an npm repo that merely SHARES the name
    return root
end

test('producers: identity, dependencies (conditional wrappers unwrapped), consumers found by their manifest line', function ()
    need()
    local P = require 'cartograph.producers'
    local root = fixture()
    local repos = P.scan_manifests({ root })
    eq('app', P.identity(root .. '/app').name)
    local names = {}
    for _, d in ipairs(P.deps(root .. '/app')) do names[#names + 1] = d.name end
    table.sort(names)
    eq({ 'cond_dep', 'lib' }, names, 'the wrapper VARIABLE `flag` is not a dependency')
    local cons = P.consumers(root .. '/lib', repos)
    eq(1, #cons); eq(root .. '/app', cons[1].root); eq(1, cons[1].line, 'cited by the consumer manifest line')
    vim.fn.delete(root, 'rf')
end)

test('producers: a dependency attaches only to a repo of its ECOSYSTEM; obligations name their producer or NONE', function ()
    need()
    local P = require 'cartograph.producers'
    local root = fixture()
    local repos = P.scan_manifests({ root })
    local att = P.attachable(root .. '/app', P.deps(root .. '/app'), repos, {})
    local lib
    for _, a in ipairs(att) do if a.dep.name == 'lib' then lib = a end end
    eq(1, #lib.candidates, 'the erlang repo, not the npm package that shares the name')
    eq(root .. '/lib', lib.candidates[1].path)
    local _, by = P.obligations(root .. '/app', att)
    eq('dependency', by.lib_beh.producer.kind)
    eq('tree', by.own_beh.producer.kind)
    eq('runtime', by.gen_server.producer.kind, 'gen_server: the runtime-distilled profile')
    eq('NONE', by.missing_beh.producer.kind, 'a behaviour nothing on this machine produces is NAMED, not dropped')
    vim.fn.delete(root, 'rf')
end)
