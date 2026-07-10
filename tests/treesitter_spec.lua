-- The tree-sitter GraphProvider: same neutral schema, no lua-ls. The acid
-- test is cross-provider: the wiretap listener audit must reproduce from a
-- tree-sitter extraction of the same fixture the lua-ls golden uses. Then a
-- small C project proves the language-agnostic half: functions, name-matched
-- cross-file calls, include edges, df-lite, dispatch-table cbarg, main entry.

local ts    = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local lint  = require 'cartograph.lint'

local function has_parser(lang)
    return pcall(vim.treesitter.get_string_parser, '', lang)
end

test('treesitter: wiretap listener audit reproduces without lua-ls', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    store.ingest(ts.extract(vim.fn.getcwd() .. '/tests/fixtures/listener'))
    local blob = ''
    for _, f in ipairs(lint.run(store, { only = { ['listener-audit'] = true } })) do
        blob = blob .. f.message .. '\n'
    end
    ok(blob:match("subscribe to 'on_tikc'"), 'typo subscribe: ' .. blob)
    ok(blob:match("'on_build' is registered but never subscribed"), 'dead registration')
    ok(blob:match("'on_tick' is subscribed but never unsubscribed"), 'leak')
    ok(blob:match("'on_lazy' is registered inside a function"), 'register after init')
end)

test('treesitter: C project — nodes, calls, includes, df-lite', function ()
    if not has_parser('c') then skip 'no c parser' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/cproj')
    eq('treesitter', data.provider)
    store.ingest(data)

    local byname = {}
    -- a header prototype and the .c definition share a name; the definition
    -- (not the decl) is the one this test means
    for _, n in ipairs(data.nodes) do
        if not byname[n.name] or byname[n.name].decl then byname[n.name] = n end
    end
    ok(byname.helper and byname.helper.kind == 'function', 'helper found')
    ok(byname.main and byname.main.entry, 'main is an entry point')
    ok(byname.dispatched and byname.dispatched.cbarg,
        'dispatch-table reference marks the fn dynamically dispatched')
    ok(byname.counter and byname.counter.kind == 'var', 'top-level var')

    -- cross-file call: main -> helper, name-matched (honest ~)
    local ref
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.to == byname.helper.id then ref = e end
    end
    ok(ref and ref.from == byname.main.id, 'main -> helper ref edge')
    ok(ref.inferred, 'cross-file match is inferred')

    -- include edges through the basename fallback
    ok(#(store.imports_out['main.c'] or {}) == 1
        and store.imports_out['main.c'][1] == 'util.h', 'include edge')

    -- df-lite: helper's statements carry lines and def/use names
    local df = byname.helper.df
    ok(df and #df.stmts == 2, 'two body statements')
    eq({ 't' }, df.stmts[1].def)
    ok(vim.tbl_contains(df.stmts[1].use, 'counter'), 'use names captured')

    -- use edge: helper reads the module var
    ok(#(store.var_usedby[byname.counter.id] or {}) == 1, 'var use edge')

    -- the only dead function is the genuinely dead one
    local dead = lint.run(store, { only = { ['dead-function'] = true } })
    eq(1, #dead)
    ok(dead[1].message:match('unused_static'), 'only unused_static is dead')
end)

test('c headers: prototypes, macros and types make the interface browsable', function ()
    if not has_parser('c') then skip 'no c parser' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/hdrproj')
    store.ingest(data)
    local hdr = {}
    for _, n in ipairs(data.nodes) do
        if n.file == 'api.h' then hdr[n.name] = n end
    end
    -- the prototype: a function node, marked decl, kept OUT of resolution
    ok(hdr.api_compute and hdr.api_compute.kind == 'function'
        and hdr.api_compute.decl, 'prototype is a decl function node')
    -- a function-like macro IS a callable node; object-like + types are vars
    ok(hdr.API_SQUARE and hdr.API_SQUARE.kind == 'function'
        and hdr.API_SQUARE.macro, 'function-like macro is callable')
    ok(hdr.API_VERSION and hdr.API_VERSION.kind == 'var'
        and hdr.API_VERSION.ctype == 'macro', 'object macro is a const var')
    ok(hdr.point and hdr.point.ctype == 'struct', 'struct type')
    ok(hdr.color and hdr.color.ctype == 'enum', 'enum type')
    ok(hdr.Point and hdr.Point.ctype == 'typedef', 'typedef type')
    -- the prototype does NOT compete: main -> api_compute resolves to the .c
    -- DEFINITION (decl=nil), not the header declaration
    local def, call
    for _, n in ipairs(data.nodes) do
        if n.name == 'api_compute' and n.file == 'api.c' then def = n end
    end
    ok(def and not def.decl, 'the definition is in api.c')
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.to == def.id then call = e end
    end
    ok(call, 'a call resolves to the definition, not the prototype')
    ok(hdr.api_compute.id ~= def.id, 'decl and def are distinct nodes')
    -- the fn-like macro is a real call target: API_SQUARE(n) links to it
    local mref
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.to == hdr.API_SQUARE.id then mref = e end
    end
    ok(mref, 'API_SQUARE(n) resolves to the macro')
    -- includes make the file's dependencies navigable. Both forms resolve:
    -- "api.h" (quoted) and <util.h> (a project header reached via -I). The
    -- external <stdlib.h> has no project file, so it stays an unlinked leaf.
    local out = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'import' and e.from == 'api.c' then out[e.to] = true end
    end
    ok(out['api.h'], 'quoted #include "api.h" is an import edge')
    ok(out['util.h'], 'angle-bracket #include <util.h> resolves to the project header')
    ok(not out['stdlib.h'], 'external <stdlib.h> resolves to nothing (no edge)')
end)

test('treesitter: lua blocks, litdata and require edges', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/blocks')
    store.ingest(data)
    local blocks, vars, lit = 0, 0, nil
    for _, n in ipairs(data.nodes) do
        if n.kind == 'region' then blocks = blocks + 1 end
        if n.kind == 'var' then
            vars = vars + 1
            if type(n.data) == 'table' then lit = n end
        end
    end
    ok(blocks >= 1, 'blocks emitted')
    ok(vars >= 3, 'vars emitted (' .. vars .. ')')
    -- regions are BOUNDED runs: a run flushes at every function def, so no
    -- block may span across one. (A node-identity bug once merged every file
    -- into one giant region, which read as isolated statements when browsed.)
    local blks, fns = {}, {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'region' then blks[#blks + 1] = n
        elseif n.kind == 'function' then fns[#fns + 1] = n end
    end
    ok(#blks >= 3, 'the interleaved fixture yields several blocks (' .. #blks .. ')')
    for _, b in ipairs(blks) do
        for _, f in ipairs(fns) do
            ok(not (b.range.start.line <= f.range.start.line
                and b.range['end'].line >= f.range['end'].line),
                ('block L%d-%d must not swallow fn %s L%d'):format(
                    b.range.start.line + 1, b.range['end'].line + 1, f.name,
                    f.range.start.line + 1))
        end
    end
end)

test('cache: a warm graph is per-item identical to the extract it cached', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function put(f, t)
        local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(t); fd:close()
    end
    put('a.lua', 'local config = { x = 1 }\nlocal function apply()\n'
        .. '    return config.x\nend\nreturn { apply = apply, config = config }\n')
    put('b.lua', 'local m = require "a"\nlocal function go()\n'
        .. '    return m.apply()\nend\nreturn { go = go }\n')
    local cache = require 'cartograph.cache'
    local gd = require 'cartograph.graphdiff'
    cache.wipe(root)
    local data = ts.extract(root)
    cache.save(data)
    local back = cache.load(root)
    ok(back, 'cache loads')
    -- the instrument invariant: count parity can hide compensating errors;
    -- per-item diff cannot. This is what a version-bump miss would break —
    -- a cached graph must be indistinguishable from a fresh extract.
    ok(gd.empty(gd.diff(data, back)), 'per-item identical after round-trip')
    cache.wipe(root)
    vim.fn.delete(root, 'rf')
end)

test('id pass: lexical-first — bound mentions do not name-match globals', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function put(f, t)
        local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(t); fd:close()
    end
    put('a.lua', table.concat({
        'local config = { x = 1 }',
        'local function apply()',
        '    return config.x', -- module-bound: the SAME-FILE use edge stays
        'end',
        'local function helper()',
        '    return 1',
        'end',
        'return { apply = apply, helper = helper, config = config }',
    }, '\n'))
    put('b.lua', table.concat({
        'local function work()',
        '    local config = { y = 2 }',
        '    return config.y', -- inner-bound: NOT a.lua\'s config
        'end',
        'local function take(helper)',
        '    return helper', -- param-bound: NOT a.lua\'s helper
        'end',
        'local function free()',
        '    return helper', -- FREE: still name-matches a.lua\'s unique fn
        'end',
        'return { work = work, take = take, free = free }',
    }, '\n'))
    local data = ts.extract(root)
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
    local function edge(kind, fromname, toname)
        for _, e in ipairs(data.edges) do
            if e.kind == kind and byname[fromname] and byname[toname]
                and e.from == byname[fromname].id and e.to == byname[toname].id then
                return e
            end
        end
    end
    ok(edge('use', 'apply', 'config'), 'module-bound mention keeps its use edge')
    ok(not edge('use', 'work', 'config'), 'inner local must not use-match a module var')
    ok(not edge('ref', 'take', 'helper'), 'a param must not ref-match a unique fn')
    ok(edge('ref', 'free', 'helper'), 'a free mention still name-matches')
    vim.fn.delete(root, 'rf')
end)

test('forms: one level of nested statements / forms, on demand', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function put(f, t)
        local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(t); fd:close()
    end
    -- lua: the if_statement's then/else bodies are its sub-forms (position mode)
    put('m.lua', 'function f(x)\n  if x then\n    g(x)\n    h(x)\n  else\n    k()\n  end\nend\n')
    local subs = ts.forms(root .. '/m.lua', 1) -- row 1 (0-based) = the `if`
    local texts = {}
    for _, s in ipairs(subs) do texts[#texts + 1] = s.text end
    eq({ 'g(x)', 'h(x)', 'k()' }, texts)
    ok(not subs[1].branch, 'a bare call is a leaf, not a branch')

    -- a nested if is itself a branch (descendable again)
    put('n.lua', 'function f(x)\n  if x then\n    if y then\n      g()\n    end\n  end\nend\n')
    local s2 = ts.forms(root .. '/n.lua', 1)
    eq(1, #s2)
    ok(s2[1].branch, 'the nested if is a branch')
    eq({ 'g()' }, (function () local t = {}
        for _, s in ipairs(ts.forms(root .. '/n.lua', s2[1].sr, s2[1].sc, s2[1].er, s2[1].ec)) do
            t[#t + 1] = s.text end return t end)())

    if has_parser('scheme') then
        -- scheme: a define's body is its forms (minus the signature list);
        -- a call form's arguments that are themselves lists are sub-forms
        -- NB this branch only runs when an earlier spec put the parser dir on
        -- the rtp (scope_spec does); it was dormant until then, hiding an
        -- out-of-bounds range here (3,20 — past the define's true end 3,13),
        -- which made exact-node mode resolve to the program root
        put('a.scm', '(define (f x)\n  (when (> x 0)\n    (bar x)\n    (baz x)))\n')
        local def = ts.forms(root .. '/a.scm', 0, 0, 3, 13) -- exact: the define
        eq(1, #def)                       -- just the (when ...) body form
        ok(def[1].branch, 'the when-form is descendable')
        local body = ts.forms(root .. '/a.scm', def[1].sr, def[1].sc, def[1].er, def[1].ec)
        local names = {}
        for _, s in ipairs(body) do names[#names + 1] = s.text end
        eq({ '(> x 0)', '(bar x)', '(baz x)' }, names)
    end
    vim.fn.delete(root, 'rf')
end)

test('treesitter: haskell — equations merge, where stays interior, imports', function ()
    -- the parser lives in nvim-treesitter's dir; tests run with bare rtp
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.get_string_parser, '', 'haskell') then
        skip 'no haskell parser'
    end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/hsproj')
    store.ingest(data)
    local byname, count = {}, {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'function' then
            byname[n.name] = n
            count[n.name] = (count[n.name] or 0) + 1
        end
    end
    -- two equations, ONE node spanning both
    eq(1, count.double)
    ok(byname.double.range['end'].line > byname.double.range.start.line,
        'range extends over the second equation')
    -- the where-bind `go` is interior, not a node
    ok(not byname.go, 'where binds are not top-level nodes')
    -- but it IS a df row of run
    ok(byname.run.df and #byname.run.df.stmts == 2, 'match + where bind rows')
    ok(byname.main.entry, 'main is an entry point')
    -- cross-file call through the where clause: run -> double (~)
    local hit
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.from == byname.run.id and e.to == byname.double.id then
            hit = e
        end
    end
    ok(hit and hit.inferred, 'run -> double, name-matched')
    eq({ 'Util.hs' }, store.imports_out['Main.hs'])
end)

test('treesitter: cpp — methods, qualified calls, includes', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.get_string_parser, '', 'cpp') then
        skip 'no cpp parser'
    end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/cppproj')
    store.ingest(data)
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
    ok(byname['Engine::go'] and byname['Engine::go'].kind == 'method', 'qualified method')
    ok(byname['Engine::frames'] and byname['Engine::frames'].kind == 'method',
        'inline class method, class-qualified')
    ok(byname.run and byname.run.kind == 'function', 'plain namespace fn')
    ok(byname.main and byname.main.entry, 'main entry')
    -- Engine::go calls run (same file, exact) and frames
    local hits = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.from == byname['Engine::go'].id then
            hits[store.node(e.to).name] = true
        end
    end
    ok(hits.run, 'go -> run')
    eq({ 'engine.hpp' }, store.imports_out['engine.cpp'])
    local dead = lint.run(store, { only = { ['dead-function'] = true } })
    eq(1, #dead)
    ok(dead[1].message:match('helper_unused'), 'only the unused static is dead')
end)

test('treesitter: scheme — defines, named-let interior, use-modules', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.get_string_parser, '', 'scheme') then
        skip 'no scheme parser'
    end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/scmproj')
    store.ingest(data)
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
    ok(byname.run and byname.run.kind == 'function', 'define fn')
    ok(byname.step and byname.step.kind == 'function', 'define fn (util)')
    ok(byname.limit and byname.limit.kind == 'var' and byname.limit.data == nil
        or byname.limit, 'scalar define present')
    ok(not byname.loop, 'named-let loop is not a node')
    -- run -> step across modules (name-matched)
    local hit
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.from == byname.run.id and e.to == byname.step.id then
            hit = e
        end
    end
    ok(hit and hit.inferred, 'run -> step')
    -- the define/lambda SIGNATURE `(run n)` / `(step x)` is not a call: a fn
    -- must not become its own (bogus) caller, and no self-edge is emitted
    for _, c in ipairs(data.calls) do
        ok(not (c.callee == 'run' and c.fn == byname.run.id),
            'run does not call itself via its signature')
        ok(not (c.callee == 'step' and c.fn == byname.step.id),
            'step does not call itself via its signature')
    end
    for _, e in ipairs(data.edges) do
        ok(not (e.kind == 'ref' and e.self and e.from == byname.run.id),
            'no bogus self-edge from the signature')
    end
    eq(0, #(store.usedby[byname.run.id] or {}))    -- no function-callers
    eq(1, #(store.usedby[byname.step.id] or {}))   -- exactly run
    eq({ 'demo/util.scm' }, store.imports_out['demo/main.scm'])
    -- the top-level (display (run 5)) is a load-time call
    local top
    for _, c in ipairs(data.calls) do
        if c.callee == 'run' and c.top then top = c end
    end
    ok(top, 'load-time call flagged')
end)

test('clangd: resolution oracle proves the C fixture edges', function ()
    if not has_parser('c') then skip 'no c parser' end
    local cd = require 'cartograph.providers.clangd'
    local data = require('cartograph.providers.treesitter')
        .extract(vim.fn.getcwd() .. '/tests/fixtures/cproj')
    local stats, why = cd.enrich(data, { timeout = 8000 })
    if not stats then skip('no clangd: ' .. tostring(why)) end
    ok(stats.resolved_fns >= 3, 'answered for the fixture fns')
    local inf, main_helper = 0, nil
    local byname = {}
    for _, n in ipairs(data.nodes) do
        if not byname[n.name] or byname[n.name].decl then byname[n.name] = n end
    end
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' then
            if e.inferred then inf = inf + 1 end
            if e.from == byname.main.id and e.to == byname.helper.id then
                main_helper = e
            end
        end
    end
    eq(0, inf)
    ok(main_helper and not main_helper.inferred, 'main -> helper is proven now')
end)

test('clangd async: same proof, without blocking the caller', function ()
    if not has_parser('c') then skip 'no c parser' end
    local cd = require 'cartograph.providers.clangd'
    local data = require('cartograph.providers.treesitter')
        .extract(vim.fn.getcwd() .. '/tests/fixtures/cproj')
    local done, stats, why = false, nil, nil
    cd.enrich_async(data, {}, function (s, w) stats, why, done = s, w, true end)
    -- the call returns immediately — the callback is always scheduled, never
    -- run inline (that IS the non-blocking contract)
    ok(not done, 'enrich_async does not resolve synchronously')
    ok(vim.wait(20000, function () return done end, 50), 'on_done eventually fires')
    if not stats then skip('no clangd: ' .. tostring(why)) end
    ok(stats.resolved_fns >= 3, 'answered async for the fixture fns')
    local byname = {}
    for _, n in ipairs(data.nodes) do
        if not byname[n.name] or byname[n.name].decl then byname[n.name] = n end
    end
    local main_helper
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.from == byname.main.id
            and e.to == byname.helper.id then main_helper = e end
    end
    ok(main_helper and main_helper.proven and not main_helper.inferred,
        'main -> helper proven via the async path')
end)

test('clangd demand session: focus resolves a function\'s callers, proven', function ()
    if not has_parser('c') then skip 'no c parser' end
    local clangd = require 'cartograph.providers.clangd'
    local bin_ok = vim.fn.executable('clangd') == 1
        or vim.fn.executable(vim.fn.expand('~/.local/bin/clangd')) == 1
    if not bin_ok then skip 'no clangd' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local function put(f, t)
        local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(t); fd:close()
    end
    put('util.h', 'int helper(int a);\n')
    put('util.c', '#include "util.h"\nint helper(int a) { return a + 1; }\n')
    put('main.c', '#include "util.h"\nint main(void) { return helper(2); }\n')
    -- compile_commands gives clangd real include/define eyes
    put('compile_commands.json', ('[{"directory":%q,"file":%q,"command":"cc -c'
        .. ' main.c"},{"directory":%q,"file":%q,"command":"cc -c util.c"}]')
        :format(root, root .. '/main.c', root, root .. '/util.c'))
    local data = ts.extract(root)
    store.ingest(data)
    ok(clangd.compile_dir(root), 'compile_commands.json discovered')
    local helper
    for _, n in ipairs(data.nodes) do
        if n.name == 'helper' and n.file == 'util.c' then helper = n end
    end
    ok(clangd.start_session(data), 'demand session started')
    local got
    -- resolve ON DEMAND (as focusing would), instead of the whole graph
    clangd.resolve_focused(helper, function (edges) got = edges end)
    ok(vim.wait(20000, function () return got ~= nil end, 100), 'demand resolution returned')
    if got then
        store.set_callers(helper.id, got) -- the splice the on_focus hook does
        local names = {}
        for _, f in ipairs(store.usedby[helper.id] or {}) do
            names[#names + 1] = (store.node(f) or {}).name
        end
        ok(vim.tbl_contains(names, 'main'), 'main resolved as caller: ' .. vim.inspect(names))
        local proven = false
        for _, e in ipairs(data.edges) do
            if e.kind == 'ref' and e.to == helper.id and e.proven then proven = true end
        end
        ok(proven, 'the spliced caller edge is proven, not ~')
    end
    clangd.stop_session()
    vim.fn.delete(root, 'rf')
end)

test('compile_plan: detects the build system and its configure command', function ()
    local clangd = require 'cartograph.providers.clangd'
    local function fresh(files)
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, 'p')
        for f, t in pairs(files) do
            local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(t); fd:close()
        end
        return root
    end

    -- cmake: configure-only, exports the db into <root>/build
    local c = fresh({ ['CMakeLists.txt'] = 'project(x)\n' })
    local p = clangd.compile_plan(c)
    ok(p and p.tool == 'cmake', 'CMakeLists.txt → cmake')
    ok(p.dir == c .. '/build', 'db lands in build/')
    ok(vim.tbl_contains(p.argv, '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON'), 'export flag present')
    ok(not p.builds, 'cmake configure does not build')
    vim.fn.delete(c, 'rf')

    -- meson: configure-only too
    local m = fresh({ ['meson.build'] = "project('x','c')\n" })
    p = clangd.compile_plan(m)
    ok(p and p.tool == 'meson', 'meson.build → meson')
    ok(not p.builds, 'meson setup does not build')
    vim.fn.delete(m, 'rf')

    -- plain make: no configure step → bear wraps a full build (opt-in)
    local k = fresh({ ['Makefile'] = "all:\n\tcc -c x.c\n" })
    p = clangd.compile_plan(k)
    ok(p and p.tool == 'bear' and p.builds, 'Makefile → bear (a full build, opt-in)')
    ok(not p.cmdline:find('configure'), 'an existing Makefile needs no bootstrap')
    vim.fn.delete(k, 'rf')

    -- fresh automake clone (Makefile.am/configure.ac, no configure/Makefile yet):
    -- bootstrap autogen → configure BEFORE bear -- make
    local a = fresh({ ['configure.ac'] = 'AC_INIT([x],[1])\n',
        ['Makefile.am'] = 'bin_PROGRAMS = x\n', ['autogen.sh'] = 'autoreconf -i\n' })
    p = clangd.compile_plan(a)
    ok(p and p.tool == 'bear', 'automake → bear')
    ok(p.cmdline:find('autogen') and p.cmdline:find('configure') and p.cmdline:find('bear'),
        'bootstrap chained: ' .. p.cmdline)
    vim.fn.delete(a, 'rf')

    -- configure.ac but no autogen.sh → autoreconf -i does the bootstrap
    local a2 = fresh({ ['configure.ac'] = 'AC_INIT([x],[1])\n', ['Makefile.am'] = 'bin_PROGRAMS = x\n' })
    p = clangd.compile_plan(a2)
    ok(p.cmdline:find('autoreconf'), 'no autogen.sh → autoreconf -i: ' .. p.cmdline)
    vim.fn.delete(a2, 'rf')

    -- an override build dir is honored (resolved relative to root)
    local c2 = fresh({ ['CMakeLists.txt'] = 'project(x)\n' })
    p = clangd.compile_plan(c2, 'out/cc')
    ok(p.dir == c2 .. '/out/cc', 'relative builddir resolved under root')
    vim.fn.delete(c2, 'rf')

    -- nothing recognizable → nil (caller degrades gracefully)
    local n = fresh({ ['readme.md'] = '# x\n' })
    ok(clangd.compile_plan(n) == nil, 'no build system → nil')
    vim.fn.delete(n, 'rf')
end)

test('xlang: string-key dispatch links JS to the C++ handler', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not (pcall(vim.treesitter.get_string_parser, '', 'cpp')
        and pcall(vim.treesitter.get_string_parser, '', 'javascript')) then
        skip 'missing parsers'
    end
    local xl = require 'cartograph.xlang'
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/xlang')
    local stats = xl.link(data)
    eq(1, stats.exports)          -- getThing resolved through BindRepeating
    eq(1, stats.unresolved)       -- ghostMessage's handler doesn't exist
    eq(2, stats.links)            -- chrome.send + sendWithPromise
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
    local hits = 0
    for _, e in ipairs(data.edges) do
        if e.xlang and e.to == byname['ThingHandler::HandleGetThing'].id
            and (e.from == byname.requestThing.id
                or e.from == byname.requestPromised.id) then
            hits = hits + 1
            ok(#e.at > 0 and e.at[1].start.char > 0, 'site range on the key literal')
        end
    end
    eq(2, hits)
    -- the send call's statement row now descends into the handler
    local sent
    for _, c in ipairs(data.calls) do
        if c.callee == 'send' and c.args[1] == 'getThing' then sent = c end
    end
    ok(sent and sent.to == byname['ThingHandler::HandleGetThing'].id,
        'call inventory upgraded')
end)

test('php: functions, qualified methods, requires, hook fan-out', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.get_string_parser, '', 'php') then
        skip 'no php parser'
    end
    local xl = require 'cartograph.xlang'
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/phpproj')
    local stats = xl.link(data)
    store.ingest(data)
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
    ok(byname.compute and byname.compute.kind == 'function', 'plain fn')
    ok(byname['Worker::work'] and byname['Worker::work'].kind == 'method',
        'method carries its class')
    -- cross-file call through the require
    eq({ 'functions.php' }, store.imports_out['worker.php'])
    local hit
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.from == byname['Worker::work'].id
            and e.to == byname.compute.id then
            hit = e
        end
    end
    ok(hit, 'Worker::work -> compute')
    -- hooks: two named handlers resolved, the closure honestly unresolved,
    -- and the do_action site fans out to BOTH
    eq(2, stats.exports)
    eq(1, stats.unresolved)
    local fan = 0
    for _, e in ipairs(data.edges) do
        if e.xlang and e.from == byname.on_boot.id then fan = fan + 1 end
    end
    eq(2, fan)
    -- php's crazier dispatch: call_user_func('scale') RESOLVES (the string
    -- is the mechanism), $op(3) stays a visible dynamic frontier
    local cuf, dyn
    for _, c in ipairs(data.calls) do
        if c.callee == 'call_user_func' then cuf = c end
        if c.dynamic and c.callee == '$op' then dyn = c end
    end
    ok(cuf and cuf.to == byname.scale.id, 'call_user_func literal resolved')
    ok(dyn and dyn.callee == '$op' and not dyn.to, 'variable call visible, unresolved')
    -- single-assignment literal flow resolves; a branchy one refuses
    local stat, branchy
    for _, c in ipairs(data.calls) do
        if c.callee == '$handler' then stat = c end
        if c.callee == '$h' then branchy = c end
    end
    ok(stat and stat.to == byname.scale.id and stat.traced,
        'single-assignment $handler traced to scale')
    ok(branchy and not branchy.to and branchy.dynamic,
        'two defs -> refuses to pick sides')
    -- a human pin outranks the analysis
    require('cartograph.config').pins = {
        { file = 'functions.php', line = branchy.line + 1, to = 'compute' },
    }
    local data2 = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/phpproj')
    local st2 = xl.link(data2)
    require('cartograph.config').pins = nil
    eq(1, st2.pinned)
    local byname2, pinned = {}, nil
    for _, n in ipairs(data2.nodes) do byname2[n.name] = n end
    for _, c in ipairs(data2.calls) do
        if c.callee == '$h' then pinned = c end
    end
    ok(pinned and pinned.to == byname2.compute.id, 'pin names the target')
end)

test('frontier: minified bundles are opaque but reachable by text search', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.get_string_parser, '', 'javascript') then
        skip 'no javascript parser'
    end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/frontier')
    eq({ 'lib.min.js' }, data.unparsed)
    store.ingest(data)
    ok(store.by_id['lib.min.js'] and store.by_id['lib.min.js'].unparsed,
        'frontier module node present')
    eq('used', store.classify('lib.min.js'))
    -- no parsed content leaked out of the bundle
    for _, n in ipairs(data.nodes) do
        ok(not (n.file == 'lib.min.js' and n.kind == 'function'),
            'no function nodes from the bundle')
    end
    -- lazy landing: the name resolves to its position in the bundle
    local hits = store.frontier_find('myfun')
    eq(1, #hits)
    eq('lib.min.js', hits[1].file)
    eq(0, hits[1].line)
    ok(hits[1].char > 40, 'char lands inside the one-liner')
    -- the option: unparsed = false makes bundles invisible
    require('cartograph.config').unparsed = false
    local data2 = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/frontier')
    require('cartograph.config').unparsed = true
    eq(nil, data2.unparsed)
end)

test('frontier: landings are content-keyed cache — regeneration evicts them', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.get_string_parser, '', 'javascript') then
        skip 'no javascript parser'
    end
    -- bundles get regenerated in place, so work on a copy of the fixture
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    for _, f in ipairs({ 'app.js', 'lib.min.js' }) do
        vim.fn.writefile(
            vim.fn.readfile(vim.fn.getcwd() .. '/tests/fixtures/frontier/' .. f),
            root .. '/' .. f)
    end
    store.ingest(ts.extract(root))
    local hits = store.frontier_find('myfun')
    eq(1, #hits)
    eq(0, hits[1].line)
    -- the landing, as the browser's descend would create it
    local id = ('%s::myfun@%d'):format(hits[1].file, hits[1].line)
    store.add_node({ id = id, name = 'myfun', kind = 'function',
        unparsed = true, file = hits[1].file, order = hits[1].line,
        range = { start = { line = hits[1].line, char = hits[1].char },
            ['end'] = { line = hits[1].line, char = hits[1].char + 5 } } })
    ok(store.by_id[id], 'landing registered')

    -- the bundle is regenerated OUTSIDE nvim (no autocmd): content shifts
    local old = table.concat(vim.fn.readfile(root .. '/lib.min.js'), '\n')
    local fd = assert(io.open(root .. '/lib.min.js', 'w'))
    fd:write('// regenerated banner\n' .. old .. '\n')
    fd:close()
    local hits2 = store.frontier_find('myfun')
    eq(1, #hits2)
    eq(1, hits2[1].line) -- shifted down by the banner
    ok(not store.by_id[id], 'stale landing evicted with its file content')

    -- touched but byte-identical (build ran, output unchanged): kept
    local id2 = ('%s::myfun@%d'):format(hits2[1].file, hits2[1].line)
    store.add_node({ id = id2, name = 'myfun', kind = 'function',
        unparsed = true, file = hits2[1].file, order = hits2[1].line,
        range = { start = { line = hits2[1].line, char = hits2[1].char },
            ['end'] = { line = hits2[1].line, char = hits2[1].char + 5 } } })
    local same = table.concat(vim.fn.readfile(root .. '/lib.min.js'), '\n')
    fd = assert(io.open(root .. '/lib.min.js', 'w'))
    fd:write(same .. '\n')
    fd:close()
    store.frontier_find('myfun')
    ok(store.by_id[id2], 'unchanged rewrite keeps the landing')
    vim.fn.delete(root, 'rf')
end)

test('greenspun: the wiretap registry is discovered, not configured', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local g = require 'cartograph.greenspun'
    local xl = require 'cartograph.xlang'
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/listener')
    local bindings, report = g.registries(data)
    eq(1, #bindings)
    eq('register_listener', bindings[1].export.verb)
    eq(1, bindings[1].export.name)
    eq({ 'subscribe' }, bindings[1].import.verb)
    eq(2, bindings[1].import.name) -- the listener name is subscribe's 2nd arg
    ok(report[1] and report[1].keys == 3, 'three interned keys reported')
    -- linking with ONLY the discovery: the fixture's handlers are inline
    -- closures, so they are honest frontiers — counted, not invented
    local stats = xl.link(data, bindings)
    eq(0, stats.exports)
    ok(stats.unresolved >= 3, 'inline closures stay unresolved: ' .. stats.unresolved)
end)

test('greenspun: funcall tables and evals are surfaced', function ()
    local g = require 'cartograph.greenspun'
    local data = { schema = 1, root = '/x', edges = {}, calls = {
        { callee = 'loadstring', args = { '' }, argv = {}, file = 'a.lua', line = 3 },
    }, nodes = {
        { id = 'f1', name = 'on_tick', kind = 'function', file = 'a.lua', order = 1,
          range = { start = { line = 0, char = 0 }, ['end'] = { line = 1, char = 0 } } },
        { id = 'f2', name = 'on_build', kind = 'function', file = 'a.lua', order = 4,
          range = { start = { line = 4, char = 0 }, ['end'] = { line = 5, char = 0 } } },
        { id = 'v1', name = 'handlers', kind = 'var', file = 'a.lua', order = 8,
          range = { start = { line = 8, char = 0 }, ['end'] = { line = 9, char = 0 } },
          data = { tick = { ref = 'on_tick' }, build = 'on_build', misc = 42 } },
    } }
    local tables = g.dispatch_tables(data)
    eq(1, #tables)
    eq('handlers', tables[1].var.name)
    eq(2, tables[1].fns)
    eq(1, #g.evals(data))
end)

test('registry-audit: auto-configured, names the typo', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    store.ingest(ts.extract(vim.fn.getcwd() .. '/tests/fixtures/listener'))
    local fs = lint.run(store, { only = { ['registry-audit'] = true } })
    local blob, sev = '', {}
    for _, f in ipairs(fs) do
        blob = blob .. f.severity .. ':' .. f.message .. '\n'
        sev[f.severity] = (sev[f.severity] or 0) + 1
    end
    ok(blob:match("'on_tikc' is dispatched but never registered — did you mean 'on_tick'%?"),
        'typo named with suggestion: ' .. blob)
    ok(blob:match("1 key%(s%) dispatched but never registered, 2 registered"),
        'summary counts both directions')
    eq(1, sev.warn)  -- the typo
    eq(1, sev.info)  -- the summary
end)

test('discovery explain: every gate has a verdict with numbers', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local g = require 'cartograph.greenspun'
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/listener')
    -- summary: export and import verdicts, one line each
    local blob = table.concat(g.explain(data), '\n')
    ok(blob:match("register_listener%s+EXPORT %(key = arg 1, 3 sites%)"), 'export verdict')
    ok(blob:match("subscribe%s+IMPORT of 'register_listener'"), 'import verdict')
    -- detail: gates with numbers, pairing shown
    blob = table.concat(g.explain(data, 'register_listener'), '\n')
    ok(blob:match('sites: 3 %(2 required%) ✓'), 'site gate')
    ok(blob:match('key position: arg 1'), 'key gate')
    ok(blob:match('PAIRED imports: subscribe'), 'pairing shown')
    -- a misspelled verb gets pointed at the real one
    blob = table.concat(g.explain(data, 'register_listner'), '\n')
    ok(blob:match('no calls with this callee name'), 'absence stated')
    ok(blob:match('register_listener %(3 calls%)'), 'near verb suggested: ' .. blob)
end)

test('parse-time callables: the cheap tier handles arrays and prefixes', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.get_string_parser, '', 'php') then
        skip 'no php parser'
    end
    local g = require 'cartograph.greenspun'
    local xl = require 'cartograph.xlang'
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/phpproj')
    -- array callables are classified at PARSE TIME: no button needed
    local cheap = {}
    for _, b in ipairs(g.registries(data)) do cheap[b.export.verb] = b end
    ok(cheap.register_thing, 'cheap tier accepts the array-callable registry')
    eq({ 'fire_thing' }, cheap.register_thing.import.verb)
    local stats = xl.link(data, { cheap.register_thing })
    eq(5, stats.exports) -- every handler resolves through [$obj, 'method']
    -- prefix families come from argv kinds too: cheap audit flags only zeta
    local fs = g.audit(data, { cheap.register_thing })
    local blob = ''
    for _, f in ipairs(fs) do blob = blob .. f.message .. '\n' end
    ok(blob:match('1 registered but never dispatched'), 'only zeta uncovered: ' .. blob)
    ok(blob:match('prefix famil'), 'family honored without deep')
end)

test('deep tier: the fallback for graphs without argv kinds', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.get_string_parser, '', 'php') then
        skip 'no php parser'
    end
    local g = require 'cartograph.greenspun'
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/phpproj')
    -- simulate an older provider: strip the parse-time kinds
    for _, c in ipairs(data.calls) do
        for _, a in ipairs(c.argv or {}) do
            if a.k == 'callable' or a.k == 'concat' then
                a.k, a.name, a.prefix = 'expr', nil, nil
            end
        end
    end
    local cheap = {}
    for _, b in ipairs(g.registries(data)) do cheap[b.export.verb] = true end
    ok(not cheap.register_thing, 'kind-less graph: cheap rejects')
    local blob = table.concat(g.explain(data, 'register_thing'), '\n')
    ok(blob:match('would PASS with deep heuristics'), 'button advertised: ' .. blob)
    local deep = {}
    for _, b in ipairs(g.registries(data, { deep = true })) do
        deep[b.export.verb] = b
    end
    ok(deep.register_thing and deep.register_thing.deep,
        'deep source scan recovers the registry')
    -- and the deep audit recovers the prefix family from source
    local fs = g.audit(data, { deep.register_thing }, { deep = true })
    local blob2 = ''
    for _, f in ipairs(fs) do blob2 = blob2 .. f.message .. '\n' end
    ok(blob2:match('1 registered but never dispatched'), 'zeta still flagged: ' .. blob2)
end)

test('pair-audit: ad-hoc RAII discovered, imbalances named', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    store.ingest(ts.extract(vim.fn.getcwd() .. '/tests/fixtures/raii'))
    local fs = lint.run(store, { only = { ['pair-audit'] = true } })
    local blob = ''
    for _, f in ipairs(fs) do blob = blob .. f.severity .. ':' .. f.message .. '\n' end
    ok(blob:match("releases a key never acquired — did you mean 'cache'%?"),
        'transposition suggested: ' .. blob)
    ok(blob:match("acquire_lock%('tmp'%) is never release_lockd"), 'leak named')
    ok(not blob:match("open_file%('log'%) is never"), 'dynamic release suppresses leaks')
    ok(blob:match('release keys dynamic'), 'suppression stated')
    -- morphology dedup: exactly one pair per verb couple
    local n = 0
    for _ in blob:gmatch('ad%-hoc RAII: acquire_lock/release_lock') do n = n + 1 end
    eq(1, n)
end)

test('schema-mirror: shared vocabularies report their divergence', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    store.ingest(ts.extract(vim.fn.getcwd() .. '/tests/fixtures/raii'))
    local fs = lint.run(store, { only = { ['schema-mirror'] = true } })
    eq(1, #fs)
    ok(fs[1].message:match('states %(keys%) ~ labels %(keys%)'), fs[1].message)
    ok(fs[1].message:match('retry'), 'left divergence named')
    ok(fs[1].message:match('abort'), 'right divergence named')
end)

test('vtables: C initializer arrays are browsable funcall tables', function ()
    if not has_parser('c') then skip 'no c parser' end
    local g = require 'cartograph.greenspun'
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/cproj')
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
    ok(byname.cmds and type(byname.cmds.data) == 'table', 'vtable var carries litdata')
    local tables = g.dispatch_tables(data)
    local hit
    for _, t in ipairs(tables) do
        if t.var.name == 'cmds' then hit = t end
    end
    ok(hit and hit.fns == 2, 'funcall table detected with both handlers')
end)

test('fsm autodetect: a {name,from,to} list needs no configuration', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local fsm = require 'cartograph.fsm'
    store.ingest(ts.extract(vim.fn.getcwd() .. '/tests/fixtures/raii'))
    local cfg = fsm.detect(store)
    ok(cfg and cfg.detected, 'spec detected')
    eq('flow', cfg.events.var)
    eq({ 'transitions' }, cfg.events.path)
    local model = assert(fsm.load(store, cfg))
    eq('idle,run,dead', table.concat(model.order, ','))
end)

test('access points: trivial high-fanin functions are plumbing', function ()
    local nodes = {
        { id = 'g', name = 'get_thing', kind = 'function', file = 'a.lua', order = 1,
          range = { start = { line = 0, char = 0 }, ['end'] = { line = 2, char = 0 } },
          df = { inputs = {}, stmts = { { l = 2, def = {}, use = {}, dep = {} } } } },
        { id = 'big', name = 'get_other', kind = 'function', file = 'a.lua', order = 9,
          range = { start = { line = 9, char = 0 }, ['end'] = { line = 30, char = 0 } },
          df = { inputs = {}, stmts = { { l = 10, def = {}, use = {}, dep = {} },
              { l = 11, def = {}, use = {}, dep = {} }, { l = 12, def = {}, use = {}, dep = {} },
              { l = 13, def = {}, use = {}, dep = {} }, { l = 14, def = {}, use = {}, dep = {} } } } },
    }
    local edges = {}
    for i = 1, 16 do
        nodes[#nodes + 1] = { id = 'c' .. i, name = 'caller' .. i, kind = 'function',
            file = 'b.lua', order = i * 10,
            range = { start = { line = i * 10, char = 0 }, ['end'] = { line = i * 10 + 1, char = 0 } } }
        edges[#edges + 1] = { from = 'c' .. i, to = 'g', kind = 'ref', at = {} }
        edges[#edges + 1] = { from = 'c' .. i, to = 'big', kind = 'ref', at = {} }
    end
    store.ingest({ schema = 1, root = '/x', nodes = nodes, edges = edges })
    local fs = lint.run(store, { only = { ['access-point'] = true } })
    eq(1, #fs)
    ok(fs[1].message:match("'get_thing'"), fs[1].message)
    ok(store.node('g').access, 'node marked')
    ok(not store.node('big').access, 'a 5-statement getter is not plumbing')
end)

test('clones: same shape, same callees, different names', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    store.ingest(ts.extract(vim.fn.getcwd() .. '/tests/fixtures/raii'))
    local fs = lint.run(store, { only = { ['clone'] = true } })
    eq(1, #fs)
    ok(fs[1].message:match('alpha') and fs[1].message:match('beta'),
        'the twins found: ' .. fs[1].message)
    ok(not fs[1].message:match('gamma'), 'the different one excluded')
end)

test('layering: imports against the dominant direction are named', function ()
    local nodes, edges = {}, {}
    local function mod(f)
        nodes[#nodes + 1] = { id = f, name = f, kind = 'module', file = f, order = -1,
            range = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } } }
    end
    for _, f in ipairs({ 'ui/a.lua', 'ui/b.lua', 'ui/c.lua', 'ui/d.lua', 'ui/e.lua',
        'core/x.lua', 'core/y.lua' }) do mod(f) end
    for _, p in ipairs({ { 'ui/a.lua', 'core/x.lua' }, { 'ui/b.lua', 'core/x.lua' },
        { 'ui/c.lua', 'core/y.lua' }, { 'ui/d.lua', 'core/y.lua' },
        { 'ui/e.lua', 'core/x.lua' } }) do
        edges[#edges + 1] = { from = p[1], to = p[2], kind = 'import' }
    end
    edges[#edges + 1] = { from = 'core/y.lua', to = 'ui/a.lua', kind = 'import' }
    store.ingest({ schema = 1, root = '/x', nodes = nodes, edges = edges })
    local fs = lint.run(store, { only = { ['layering'] = true } })
    local blob = ''
    for _, f in ipairs(fs) do blob = blob .. f.severity .. ':' .. f.message .. '\n' end
    ok(blob:match("ui %-> core dominates %(5 imports%)"), blob)
    ok(blob:match("'core/y%.lua' %-> 'ui/a%.lua' runs against it"), 'the stray named')
    ok(blob:match('5 with the current, 1 against'), 'summary')
end)

test('factories: many keys, no callables — the lookup half', function ()
    local g = require 'cartograph.greenspun'
    local calls = {}
    for i = 1, 40 do
        calls[#calls + 1] = { callee = 'getModel',
            args = { 'mod/key' .. i }, argv = { { k = 'lit', v = 'mod/key' .. i } },
            file = 'a.php', line = i, method = false }
    end
    for i = 1, 40 do -- prose keys must NOT qualify
        calls[#calls + 1] = { callee = 'translate',
            args = { 'this is a long prose sentence number ' .. i },
            argv = {}, file = 'a.php', line = 100 + i, method = false }
    end
    local out = g.factories({ nodes = {}, calls = calls, root = '/x' })
    eq(1, #out)
    eq('getModel', out[1].verb)
    eq(40, out[1].keys)
end)

test('sql: embedded queries make tables first-class entities', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.get_string_parser, '', 'php') then
        skip 'no php parser'
    end
    local sql = require 'cartograph.sql'
    -- the parser itself
    local q = sql.parse("SELECT a FROM orders o JOIN users u ON u.id = o.uid")
    eq('read', q.kind)
    eq({ 'orders', 'users' }, q.tables)
    ok(not sql.parse('not sql at all'), 'prose refuses')
    ok(not sql.parse('product_id = :product_id'), 'fragments refuse')
    -- end to end on the fixture
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/phpproj')
    local stats = sql.attach(data)
    eq(2, stats.tables) -- items, settings
    store.ingest(data)
    local items = store.node('sql::table:items')
    ok(items and items.sql, 'table node exists')
    local users = {}
    for _, u in ipairs(store.var_usedby[items.id] or {}) do
        users[store.node(u.from).name] = true
    end
    ok(users.load_items and users.save_item and users.report,
        'all three touchers have use edges')
    -- the lint footprint
    local fs = lint.run(store, { only = { sql = true } })
    local blob = ''
    for _, f in ipairs(fs) do blob = blob .. f.message .. '\n' end
    ok(blob:match("table 'items': 2 read%(s%), 1 write%(s%)"), blob)
end)

test('live refresh: splice, remap, and both directions of relink', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local refresh = require 'cartograph.refresh'
    -- a disposable two-file project
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/sub', 'p')
    local function write(rel, text)
        local fd = assert(io.open(root .. '/' .. rel, 'w'))
        fd:write(text)
        fd:close()
    end
    write('a.lua', [[
local function alpha(x)
  return beta(x) + 1
end

local function calls_new()
  return brand_new(2)
end
]])
    write('sub/b.lua', [[
local function beta(y)
  return y * 2
end

local function doomed(q)
  return q
end
]])
    local data = ts.extract(root)
    require('cartograph.xlang').link(data, require('cartograph.xlang').effective_bindings(data))
    store.ingest(data)
    local function byname(n)
        for id, node in pairs(store.by_id) do
            if node.name == n then return id end
        end
    end
    ok(byname('alpha') and byname('beta'), 'both files extracted')
    ok(vim.tbl_contains(store.uses[byname('alpha')] or {}, byname('beta')),
        'cross-file edge before')
    ok(not byname('brand_new'), 'target does not exist yet')
    store.set_focus(byname('beta'))
    -- seed nav history: [beta, doomed, alpha] as jump origins, focus beta
    local beta1 = byname('beta')
    -- and mark beta in the working set: it must FOLLOW the id shift
    vim.fn.delete(store.ws_file())
    store.ws_load()
    store.ws_toggle(beta1)
    store.pivot(byname('doomed'))   -- pushes beta
    store.pivot(byname('alpha'))    -- pushes doomed
    store.pivot(beta1)              -- pushes alpha
    -- a live sample, to prove ingest invalidates it
    store.live = { states = { inactive = 1 }, tick = 1 }

    -- edit b.lua: lines shift (id changes) AND brand_new appears
    write('sub/b.lua', [[
-- a comment pushing everything down
local hidden = 1

local function beta(y)
  return y * 3
end

local function brand_new(z)
  return z + hidden
end
]])
    -- external edit visible as staleness BEFORE refresh, gone after
    ok(store.stale('sub/b.lua') == true, 'external edit detected as stale')
    local stats, why = refresh.file('sub/b.lua')
    ok(stats, tostring(why))
    eq(false, store.stale('sub/b.lua'))
    -- inbound edge remapped across the id shift
    local beta2 = byname('beta')
    ok(beta2 and beta2:match('@3'), 'beta has its new line-shifted id: ' .. tostring(beta2))
    ok(vim.tbl_contains(store.uses[byname('alpha')] or {}, beta2),
        'alpha -> beta survived the shift')
    -- the OTHER direction: a pre-existing call resolves to the NEW function
    local bn = byname('brand_new')
    ok(bn, 'new function present')
    ok(vim.tbl_contains(store.usedby[bn] or {}, byname('calls_new')),
        'old call into the new function relinked')
    -- focus survived the remap
    eq(beta2, store.focused)
    -- history remapped like everything else: beta's entry follows the id
    -- shift, doomed's (deleted) entry is pruned, alpha's untouched
    eq(2, #store._nav_back)
    eq(beta2, store._nav_back[1].id)
    eq(byname('alpha'), store._nav_back[2].id)
    -- and back() walks the carried stack cleanly
    store.back()
    eq(byname('alpha'), store.focused)
    store.back()
    eq(beta2, store.focused)
    -- the live sample did not survive the re-ingest (evidence about the
    -- OLD graph state)
    ok(store.live == nil, 'live sample invalidated by ingest')
    -- the working set followed beta through the refs remap
    ok(store.ws_has(beta2), 'working-set membership survived the refresh')
    vim.fn.delete(store.ws_file())
    store.workset = { ids = {}, refs = {}, pending = {} }
    -- freeze-while-staged
    store.moveset[byname('alpha')] = true
    local s2, w2 = refresh.file('sub/b.lua')
    ok(not s2 and w2:match('frozen'), 'staged changes freeze refresh')
    store.moveset = {}
    vim.fn.delete(root, 'rf')
end)

test('parallel priority order: attention first, then recency', function ()
    local par = require 'cartograph.parallel'
    local mt = { ['old.lua'] = 100, ['new.lua'] = 900, ['mid.lua'] = 500,
        ['cur.lua'] = 1, ['buf.lua'] = 2 }
    local got = par.order(
        { 'mid.lua', 'old.lua', 'cur.lua', 'new.lua', 'buf.lua' },
        { current = 'cur.lua', bufs = { 'cur.lua', 'buf.lua' },
            mtime = function (f) return mt[f] end })
    -- current buffer beats everything, open buffers beat recency,
    -- the rest newest-first
    eq({ 'cur.lua', 'buf.lua', 'new.lua', 'mid.lua', 'old.lua' }, got)
end)

test('parallel extraction: identical graph to sequential', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local par = require 'cartograph.parallel'
    local root = vim.fn.getcwd() .. '/tests/fixtures'
    local seq = ts.extract(root)
    local got, notes = nil, {}
    local batch = par.BATCH
    par.BATCH = 8 -- force real queue cycling over the fixture corpus
    par.extract(root, {
        workers = 3,
        on_note = function (m) notes[#notes + 1] = m end,
        on_done = function (d) got = d end,
    })
    -- demand while the queue is hot: extracts in-process NOW; the queued
    -- copy must dedup on arrival (the equality below proves it)
    local demand_f = ts.list_files(root)[1]
    ok(par.demand(demand_f), 'demand extracted ' .. tostring(demand_f))
    vim.wait(120000, function () return got ~= nil end, 50)
    par.BATCH = batch
    ok(got, 'parallel finished (' .. table.concat(notes, '; ') .. ')')
    eq(0, #notes) -- no failed batches

    -- node identity: same ids, exactly
    eq(#seq.nodes, #got.nodes)
    local ids = {}
    for _, n in ipairs(seq.nodes) do ids[n.id] = true end
    for _, n in ipairs(got.nodes) do
        ok(ids[n.id], 'unexpected node ' .. n.id)
    end
    -- cbarg marks identical (phase-2 global index at work)
    local function cbset(nodes)
        local t = {}
        for _, n in ipairs(nodes) do if n.cbarg then t[#t + 1] = n.id end end
        table.sort(t)
        return t
    end
    eq(cbset(seq.nodes), cbset(got.nodes))
    -- edges: same (kind, from, to, bind) multiset — the import binding
    -- feeds requalification, so workers must carry it too
    local function ekeys(list)
        local t = {}
        for _, e in ipairs(list) do
            t[#t + 1] = e.kind .. '|' .. e.from .. '|' .. e.to
                .. '|' .. tostring(e.bind)
        end
        table.sort(t)
        return t
    end
    eq(ekeys(seq.edges), ekeys(got.edges))
    -- calls: same resolutions at same sites; inferred is part of the
    -- contract too (the parallel path must not lose the ~ mark — relink
    -- once dropped it)
    local function ckeys(list)
        local t = {}
        for _, c in ipairs(list) do
            -- the refusal is part of the contract too: a slice-local
            -- refusal must be re-derived to the global one by relink
            local ref = c.refused
                and (c.refused.rule .. ':' .. tostring(c.refused.n)) or '-'
            t[#t + 1] = ('%s|%d|%s|%s|%s|%s|%s'):format(c.file, c.line, c.callee,
                tostring(c.to), tostring(c.dynamic), tostring(c.inferred), ref)
        end
        table.sort(t)
        return t
    end
    eq(ckeys(seq.calls), ckeys(got.calls))
    -- the mention index is part of the contract too (sorted packing
    -- makes worker-borne and inline-collected sets byte-identical)
    eq(seq.names, got.names)
end)

test('parallel audit: a slice-locally settled return chain re-derives', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('java') then skip 'no java parser' end
    local par = require 'cartograph.parallel'
    local gd = require 'cartograph.graphdiff'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function put(f, t)
        local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(t); fd:close()
    end
    -- the failing slice shape, pinned EXPLICITLY (the spawn path's slices
    -- depend on mtime ordering — in-process slices make it deterministic).
    -- The chain call must settle VIA THE ROUNDS inside its slice, which
    -- requires `tally` to be name-AMBIGUOUS in-slice (B and C both define
    -- it — else the main loop tail-resolves first and never touches rt):
    -- rounds settle by exact type, the audit nulls the inferred
    -- resolution, and relink can only re-derive from the KEPT rt
    -- provenance (the name is ambiguous globally too — no tail rescue).
    -- When settle cleared rt, this edge was lost (probe-verified).
    put('A.java', 'public class A {\n    public B make() { return new B(); }\n'
        .. '    public int go() { return make().tally(); }\n}\n')
    put('B.java', 'public class B {\n    public int tally() { return 1; }\n}\n')
    put('C.java', 'public class C {\n    public int tally() { return 3; }\n}\n')
    put('D.java', 'public class D {\n    public int other() { return 4; }\n}\n')
    local seq = ts.extract(root)
    local fileset = ts.list_files(root)
    local acc = { schema = 1, root = root, provider = 'treesitter',
        nodes = {}, edges = {}, calls = {}, stamps = {}, extends = {} }
    for _, slice in ipairs({ { 'A.java', 'B.java', 'C.java' }, { 'D.java' } }) do
        local chunk = ts.extract(root, { files = slice, fileset = fileset,
            skip_idpass = true })
        for _, n in ipairs(chunk.nodes) do acc.nodes[#acc.nodes + 1] = n end
        for _, e in ipairs(chunk.edges) do acc.edges[#acc.edges + 1] = e end
        for _, c in ipairs(chunk.calls or {}) do acc.calls[#acc.calls + 1] = c end
        for _, x in ipairs(chunk.extends or {}) do
            acc.extends[#acc.extends + 1] = x
        end
    end
    par.audit(acc)
    ts.relink(acc)
    -- the id pass ran in seq but was skipped per-slice; diff CALLS + the
    -- ref/reg edge multiset the audit+relink own (use edges are phase 2)
    local function no_use(data)
        local out = { nodes = data.nodes, calls = data.calls, edges = {} }
        for _, e in ipairs(data.edges) do
            if e.kind ~= 'use' and e.kind ~= 'reg' then
                out.edges[#out.edges + 1] = e
            end
        end
        return out
    end
    local d = gd.diff(no_use(seq), no_use(acc))
    ok(gd.empty(d), 'audited+relinked == sequential per-item: '
        .. table.concat(gd.report(d, { limit = 5 }), ' | '))
    vim.fn.delete(root, 'rf')
end)

test('mention index: globals reconcile in UNCHANGED files, both ways', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local cache = require 'cartograph.cache'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/sub', 'p')
    local function write(rel, text)
        local fd = assert(io.open(root .. '/' .. rel, 'w'))
        fd:write(text)
        fd:close()
    end
    -- alpha MENTIONS shiny; nothing defines it yet
    write('a.lua', 'local function alpha(x)\n  return x + #shiny\nend\n')
    write('sub/b.lua', 'local function beta(y)\n  return y\nend\n')
    cache.save(ts.extract(root))
    local function edge_alpha_shiny(data)
        local alpha, shiny = nil, {}
        for _, n in ipairs(data.nodes) do
            if n.name == 'alpha' then alpha = n end
            if n.name == 'shiny' then shiny[n.id] = true end
        end
        for _, e in ipairs(data.edges) do
            if e.kind == 'use' and alpha and e.from == alpha.id
                and shiny[e.to] then return true end
        end
        return false
    end

    -- 0 -> 1: an EDIT ELSEWHERE creates the global; alpha's file is
    -- untouched, yet its inbound use edge must appear
    write('sub/b.lua', 'local shiny = {}\n\nlocal function beta(y)\n'
        .. '  return y\nend\n')
    local warm = cache.open(root)
    ok(edge_alpha_shiny(warm), 'inbound use edge appeared in unchanged file')
    -- the reconciliation's dirty accounting persisted a.lua's new edge:
    -- a fresh load must see it too
    ok(edge_alpha_shiny(cache.load(root)),
        'reconciled edge survived the O(diff) save')

    -- 1 -> 2: a second definition makes the name ambiguous; the edge
    -- that only uniqueness justified must disappear
    write('c.lua', 'local shiny = 1\n')
    local warm2 = cache.open(root)
    ok(not edge_alpha_shiny(warm2),
        'ambiguity retracted the inferred use edge')

    cache.wipe(root)
    vim.fn.delete(root, 'rf')
end)

test('incremental cache: warm open re-extracts only the diff', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local cache = require 'cartograph.cache'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/sub', 'p')
    local function write(rel, text)
        local fd = assert(io.open(root .. '/' .. rel, 'w'))
        fd:write(text)
        fd:close()
    end
    write('a.lua', 'local registry = {}\n\nlocal function alpha(x)\n'
        .. '  return beta(x)\nend\n')
    write('sub/b.lua', 'local function beta(y)\n  return y * 2 + #registry\nend\n')
    write('extra.lua', 'local function gamma()\n  return 1\nend\n')
    cache.save(ts.extract(root))

    -- untouched tree: pure warm open, no extraction
    local warm, note = cache.open(root)
    ok(warm, 'cache hit')
    ok(note:match('unchanged'), tostring(note))

    -- edit one file, delete another; only the diff re-extracts
    write('sub/b.lua', 'local function beta(y)\n  return y * 3 + #registry\nend\n'
        .. '\nlocal function brand_new(z)\n  return z\nend\n')
    vim.fn.delete(root .. '/extra.lua')
    local warm2, note2 = cache.open(root)
    ok(note2:match('1 re%-extracted, 1 deleted'), tostring(note2))
    local byname = {}
    for _, n in ipairs(warm2.nodes) do byname[n.name] = n end
    ok(byname.brand_new, 'edited file re-extracted')
    -- GLOBAL reconciliation: the refreshed file reads a var defined in
    -- ANOTHER file — its use edge must survive the splice (the id pass
    -- re-runs at global scope, not against the mini's one-file index)
    local use
    for _, e in ipairs(warm2.edges) do
        if e.kind == 'use' and e.from == byname.beta.id
            and e.to == byname.registry.id then use = true end
    end
    ok(use, 'cross-file global use edge survived the warm open')
    ok(byname.gamma == nil, 'deleted file gone from the graph')
    ok(warm2.stamps['extra.lua'] == nil, 'and from the stamps')
    -- the cross-file edge survived the splice
    local edge
    for _, e in ipairs(warm2.edges) do
        if e.kind == 'ref' and e.from == byname.alpha.id
            and e.to == byname.beta.id then edge = true end
    end
    ok(edge, 'alpha -> beta intact after warm open')
    -- O(diff) save honesty: the shards on disk must reproduce the
    -- in-memory graph exactly (dirty accounting missed nothing)
    local function graph_keys(d)
        local ids, eks, cks = {}, {}, {}
        for _, n in ipairs(d.nodes) do ids[#ids + 1] = n.id end
        for _, e in ipairs(d.edges) do
            eks[#eks + 1] = e.kind .. '|' .. e.from .. '|' .. e.to
        end
        for _, c in ipairs(d.calls) do
            cks[#cks + 1] = ('%s|%d|%s|%s'):format(c.file, c.line,
                c.callee, tostring(c.to))
        end
        table.sort(ids); table.sort(eks); table.sort(cks)
        return { ids = ids, edges = eks, calls = cks, names = d.names }
    end
    eq(graph_keys(warm2), graph_keys(cache.load(root)))
    -- deletion was a TOMBSTONE: the manifest omits extra.lua (load above
    -- already proved gamma is gone) but its shard file still exists —
    -- reclaiming is gc's job, off the hot path
    local dir = cache.path(root)
    local gshard = dir .. '/' .. ('extra.lua'):gsub('[/\\:]', '%%') .. '.bin'
    ok(vim.uv.fs_stat(gshard) ~= nil, 'tombstoned shard still on disk')
    ok(cache.gc(root, { sync = true }) >= 1, 'gc reclaimed it')
    ok(vim.uv.fs_stat(gshard) == nil, 'shard gone after gc')
    eq(graph_keys(warm2), graph_keys(cache.load(root)))

    -- background save: same bytes, written off the hot path
    cache.wipe(root)
    cache.save_bg(warm2)
    vim.wait(10000, function () return not cache.saving(root) end, 10)
    ok(not cache.saving(root), 'background save completed')
    eq(graph_keys(warm2), graph_keys(cache.load(root)))

    -- a corrupted SHARD costs exactly its own file: it re-extracts
    -- (extraction is pure, so the repair is exact), the rest stays warm
    local bshard = dir .. '/' .. ('sub/b.lua'):gsub('[/\\:]', '%%') .. '.bin'
    local bfd = assert(io.open(bshard, 'wb'))
    bfd:write('not a shard at all')
    bfd:close()
    local fixed, fnote = cache.open(root)
    ok(fixed and fnote:match('1 corrupted shard'), tostring(fnote))
    eq(graph_keys(warm2), graph_keys(fixed))

    -- a corrupted MANIFEST misses the whole cache — cold, never wrong
    local mfd = assert(io.open(dir .. '/manifest.bin', 'wb'))
    mfd:write('garbage')
    mfd:close()
    ok(cache.open(root) == nil, 'bad manifest reads as a miss')
    cache.save(fixed) -- restore for the assertions below

    -- the update was saved back: a third open is fully warm again
    local warm3, note3 = cache.open(root)
    ok(note3:match('unchanged'), tostring(note3))
    local has_new = false
    for _, n in ipairs(warm3.nodes) do
        if n.name == 'brand_new' then has_new = true end
    end
    ok(has_new, 'updated graph persisted')

    -- past the diff limit the cache steps aside: a warm open must never
    -- lose to the (parallel, streaming) cold path
    write('a.lua', 'local registry = {}\n\nlocal function alpha(x)\n'
        .. '  return beta(x) + 1\nend\n')
    require('cartograph.config').cache_max_diff = 0
    local w4, n4 = cache.open(root)
    require('cartograph.config').cache_max_diff = nil
    ok(w4 == nil and n4:match('cold extract'), tostring(n4))

    cache.wipe(root)
    vim.fn.delete(root, 'rf')
end)

test('async cache: load_async / open_async match the blocking path exactly', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local cache = require 'cartograph.cache'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/sub', 'p')
    local function write(rel, text)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    -- cross-file edges + a global use, so the shards carry real structure
    write('a.lua', 'local registry = {}\n\nlocal function alpha(x)\n  return beta(x) + #registry\nend\n')
    write('sub/b.lua', 'local function beta(y)\n  return y * 2\nend\n')
    write('c.lua', 'local function gamma()\n  return 1\nend\n')
    cache.save(ts.extract(root))

    local function graph_keys(d)
        local ids, eks, cks = {}, {}, {}
        for _, n in ipairs(d.nodes) do ids[#ids + 1] = n.id end
        for _, e in ipairs(d.edges) do eks[#eks + 1] = e.kind .. '|' .. e.from .. '|' .. e.to end
        for _, c in ipairs(d.calls) do
            cks[#cks + 1] = ('%s|%d|%s|%s'):format(c.file, c.line, c.callee, tostring(c.to))
        end
        table.sort(ids); table.sort(eks); table.sort(cks)
        return { ids = ids, edges = eks, calls = cks, names = d.names }
    end

    -- load_async == load (deterministic sorted concat, just spread over ticks)
    local sync = cache.load(root)
    local async, chunks
    local roster = cache.load_async(root, function () chunks = (chunks or 0) + 1 end,
        function (d) async = d end)
    ok(type(roster) == 'table' and #roster == 3, 'roster returned synchronously')
    ok(vim.wait(5000, function () return async ~= nil end, 20), 'load_async completed')
    eq(graph_keys(sync), graph_keys(async))

    -- open_async == open: same graph, same note shape. Small corpus, but the
    -- streamed path is size-independent — force it directly.
    local stubbed, done, onote
    local started = cache.open_async(root, {
        on_stub = function (files) stubbed = #files end,
        on_chunk = function () end,
        on_done = function (d, n) done = d; onote = n end,
    })
    ok(started == true, 'open_async committed to warm')
    ok(stubbed == 3, 'on_stub fired synchronously with the roster')
    ok(vim.wait(5000, function () return done ~= nil end, 20), 'open_async completed')
    ok(onote:match('unchanged'), tostring(onote))
    eq(graph_keys(cache.load(root)), graph_keys(done))

    -- a changed file streams through open_async too: the splice runs on
    -- completion, same as the sync open
    write('sub/b.lua', 'local function beta(y)\n  return y * 3\nend\n\nlocal function nu(z)\n  return z\nend\n')
    local done2, onote2
    cache.open_async(root, {
        on_stub = function () end, on_chunk = function () end,
        on_done = function (d, n) done2 = d; onote2 = n end,
    })
    ok(vim.wait(5000, function () return done2 ~= nil end, 20), 'streamed warm w/ diff completed')
    ok(onote2:match('1 re%-extracted'), tostring(onote2))
    local hasnu = false
    for _, n in ipairs(done2.nodes) do if n.name == 'nu' then hasnu = true end end
    ok(hasnu, 'streamed splice re-extracted the changed file')
    eq(graph_keys(done2), graph_keys(cache.load(root)))

    cache.wipe(root)
    vim.fn.delete(root, 'rf')
end)

test('async cache: a multi-tick load closes once (no double-close race)', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local cache = require 'cartograph.cache'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    -- >256 files, so load_async spans multiple 256-shard ticks — the case where
    -- schedule_wrap queued extra callbacks and the done branch double-closed the
    -- timer (handle already closing) + fired on_done twice
    for i = 1, 260 do
        local fd = assert(io.open(('%s/m%03d.lua'):format(root, i), 'w'))
        fd:write(('local M = {}\nfunction M.f%d() return %d end\nreturn M\n'):format(i, i))
        fd:close()
    end
    cache.save(ts.extract(root))

    local dones, chunks = 0, 0
    local roster = cache.load_async(root, function () chunks = chunks + 1 end,
        function () dones = dones + 1 end)
    ok(type(roster) == 'table' and #roster == 260, 'roster of 260 returned')
    ok(vim.wait(6000, function () return dones > 0 end, 20), 'load_async completed')
    vim.wait(300) -- let any stray queued callbacks fire; the latch must drop them
    eq(1, dones)  -- exactly once, despite spanning multiple ticks
    ok(chunks >= 1, 'streamed across ticks (on_chunk fired)')
    cache.wipe(root)
    vim.fn.delete(root, 'rf')
end)

test('python: class-qualified methods, stdlib gate, decorator cbarg', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('python') then skip 'no python parser' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/pyproj')
    store.ingest(data)
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
    -- methods carry their class
    ok(byname['Basket.all'] and byname['Basket.all'].kind == 'method',
        'qualified method name')
    ok(byname['Basket.add_line'], 'qualified method name (2)')
    -- the stdlib gate: report's basket.all() must NOT absorb into
    -- Basket.all (the django-oscar lesson: .all() is ORM vocabulary)
    for _, c in ipairs(data.calls) do
        if c.fn == byname.report.id and c.callee:find('all') then
            ok(c.to == nil, '.all() left unresolved, not absorbed: '
                .. tostring(c.to))
        end
    end
    -- a called decorator registers its function: not dead
    ok(byname.track_view and byname.track_view.cbarg,
        '@receiver(...) marks the fn dynamically dispatched')
    local dead = require('cartograph.lint').run(store,
        { only = { ['dead-function'] = true } })
    for _, f in ipairs(dead) do
        ok(not f.message:find('track_view'), 'receiver not dead-listed')
    end
end)

test('monorepo: the workspace package scopes js bare names', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('javascript') then skip 'no javascript parser' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/monoproj')
    store.ingest(data)
    local byid = {}
    for _, n in ipairs(data.nodes) do byid[n.id] = n end
    local a_norm = 'packages/alpha/src/index.js::normalize@0'
    local b_norm = 'packages/beta/src/index.js::normalize@0'
    ok(byid[a_norm] and byid[b_norm], 'both normalize defs present')
    -- runAlpha's normalize binds to ALPHA's (same file beats everything);
    -- the cross-package twin gains nothing from alpha
    local runA = 'packages/alpha/src/index.js::runAlpha@4'
    local hits = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.from == runA then hits[e.to] = true end
    end
    ok(hits[a_norm], 'runAlpha -> alpha normalize')
    ok(not hits[b_norm], 'beta normalize untouched from alpha')
    -- publishPkg is unique WORKSPACE-wide but lives in beta: alpha's bare
    -- call must NOT cross the package boundary (import linking is not
    -- name matching)
    ok(not hits['packages/beta/src/index.js::publishPkg@4'],
        'bare name does not cross packages')
    local pub_callers = store.usedby['packages/beta/src/index.js::publishPkg@4']
    ok(pub_callers == nil or #pub_callers == 1,
        'publishPkg callers stay in beta')
end)

test('ruby: qualified defs, file-scoped bare calls, honest frontiers', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('ruby') then skip 'no ruby parser' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/rubyproj')
    store.ingest(data)
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
    -- instance vs singleton qualification
    ok(byname['Owner#full_name'], 'instance method: Owner#full_name')
    ok(byname['Owner.find_by_city'], 'singleton method: Owner.find_by_city')
    ok(byname.helper and byname.helper.kind == 'function', 'top-level def')
    -- same-file bare call links (self dispatch within the file)
    local hits = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.from == byname['Owner#full_name'].id then
            hits[(store.node(e.to) or {}).name] = true
        end
    end
    ok(hits['Owner#build_name'], 'full_name -> build_name (same file)')
    ok(hits['Owner#first_part'], 'full_name -> first_part')
    -- build_name exists in BOTH files: cross-file bare stays a frontier
    -- (Visits#build_name gains no callers from owner.rb)
    eq(nil, store.usedby[byname['Visits#build_name'].id])
    -- require_relative resolves
    ok(vim.tbl_contains(store.imports_out['owner.rb'] or {}, 'visits.rb'),
        'require_relative resolved')
end)

test('java: class-qualified, annotation cbarg, public exported', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('java') then skip 'no java parser' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/javaproj')
    store.ingest(data)
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
    -- methods qualify with `::` (php-style, also Java's own method-ref syntax)
    ok(byname['PetController::listPets'], 'class-qualified method')
    -- @GetMapping("/pets") registers the handler: cbarg, not dead
    ok(byname['PetController::listPets'].cbarg, 'annotation with args = registered')
    ok(not byname['PetController::render'].cbarg, 'plain method not cbarg')
    ok(byname['VisitService::count'].exported, 'public = exported')
    ok(not byname['PetController::render'].exported, 'private not exported')
    local function refs_of(nm)
        local hits = {}
        for _, e in ipairs(data.edges) do
            if e.kind == 'ref' and e.from == byname[nm].id then
                hits[(store.node(e.to) or {}).name] = true
            end
        end
        return hits
    end
    -- render() bare -> implicit this -> PetController::render (same class);
    -- visits.count() -> field typed VisitService -> VisitService::count
    local lp = refs_of('PetController::listPets')
    ok(lp['PetController::render'], 'listPets -> render (implicit this)')
    ok(lp['VisitService::count'], 'listPets -> count (typed field receiver)')
    -- BLOCK-SCOPE receiver: a local typed by its declaration resolves through
    -- the block symbol table (the memoized jvt block branch)
    local tl = refs_of('PetController::tally')
    ok(tl['VisitService::count'], 'tally -> count (typed block local)')
    -- SHADOW WALK-OUT, resolve-but-mark (scope-model step 2): a local whose
    -- scoped-generic type java_base_type cannot name (Map.Entry<...> -> nil)
    -- must NOT terminate the walk — the shadowed typed FIELD still resolves
    -- (recall kept), but the qualification was a GUESS, so the call carries a
    -- hedge and the edge is capped at ~ even where the name-match is
    -- same-file confident.
    local sh = refs_of('PetController::shadowedTally')
    ok(sh['VisitService::count'], 'shadowedTally -> count (nil-type shadow walks out)')
    local function call_of(fnname, callee)
        for _, c in ipairs(data.calls) do
            if c.fn == byname[fnname].id and c.callee == callee then return c end
        end
    end
    ok(call_of('PetController::shadowedTally', 'count').hedge, 'walk-out call is hedged')
    eq('shadow-walkout', call_of('PetController::shadowedTally', 'count').hedge.rule)
    ok(not call_of('PetController::tally', 'count').hedge, 'plain typed local: no hedge')
    -- the tier flip the hedge exists for: Counter lives in the SAME file, so
    -- the name-match alone would be confident — the edge must still be ~
    local function edge_of(fromname, toname)
        for _, e in ipairs(data.edges) do
            if e.kind == 'ref' and e.from == byname[fromname].id
                and e.to == byname[toname].id then return e end
        end
    end
    local sfe = edge_of('PetController::shadowedSameFile', 'Counter::count')
    ok(sfe, 'shadowedSameFile -> Counter::count (same-file walk-out)')
    ok(sfe.inferred, 'hedged qualification caps a same-file match at ~')
    -- RETURN-TYPE ROUNDS (graph-VM MVP): chained receivers and
    -- initializer-typed locals resolve through the callee's declared-return
    -- summary (n.ret), settled after plain resolution
    local ch = refs_of('PetController::chained')
    ok(ch['PetController::service'], 'chained -> service (the determining call)')
    ok(ch['VisitService::count'], 'f().g(): g resolves via f\'s return type')
    ok(refs_of('PetController::viaVar')['VisitService::count'],
        'var x = f(); x.m(): init provenance + return round')
    ok(refs_of('PetController::viaNew')['VisitService::count'],
        'var x = new T(); x.m(): typed at the declarator')
    -- constructor call: new VisitService() -> VisitService::VisitService
    ok(byname['VisitService::VisitService'] == nil
        or byname['VisitService::VisitService'].kind == 'method', 'ctor shape ok')
    -- import resolves through the maven-layout suffix
    ok(vim.tbl_contains(
        store.imports_out['src/main/java/app/PetController.java'] or {},
        'src/main/java/app/VisitService.java'), 'import resolved')

    -- INHERITANCE: super_query populates the extends chain, and refused
    -- Class::m calls walk it to the defining ancestor.
    local lbl = refs_of('Owner::label')
    -- this.fullName() -> inherited from Person (this->Owner->Person)
    ok(lbl['Person::fullName'], 'this.fullName -> Person::fullName (inherited)')
    -- super.describe() -> resolved two hops up (Person->BaseEntity)
    ok(lbl['BaseEntity::describe'], 'super.describe -> BaseEntity::describe (2 hops)')

    -- TYPED RECEIVER crossing a package: owner (param typed Owner) resolves
    -- to Owner's methods in app.model from app.owner — the `::` scope fix.
    local show = refs_of('OwnerController::show')
    ok(show['Owner::addPet'], 'owner.addPet -> Owner::addPet (cross-package)')
    ok(show['Owner::label'], 'owner.label -> Owner::label (cross-package)')

    -- dead: only the genuinely dead private method
    local dead = require('cartograph.lint').run(store,
        { only = { ['dead-function'] = true } })
    eq(1, #dead)
    ok(dead[1].message:match('neverCalled'), dead[1].message)
end)

test('go: receiver-qualified methods, package scope, init entry, caps', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('go') then skip 'no go parser' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/goproj')
    store.ingest(data)
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
    ok(byname['Store.Total'] and byname['Store.Total'].kind == 'method',
        'receiver-qualified method')
    ok(byname.main.entry, 'main is entry')
    ok(byname.init.entry, 'init is runtime-invoked')
    -- capitalization is exportedness
    ok(byname.NewStore.exported, 'capitalized fn exported')
    ok(not byname.report.exported, 'lowercase fn not exported')
    -- main -> NewStore (module-path import + selector call), -> Total,
    -- -> report (bare, same package)
    local hits = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.from == byname.main.id then
            hits[(store.node(e.to) or {}).name] = true
        end
    end
    ok(hits.NewStore, 'main -> store.NewStore')
    ok(hits['Store.Total'], 'main -> Total')
    ok(hits.report, 'main -> report (package-scoped bare call)')
    -- import resolves through the module-path suffix
    ok(vim.tbl_contains(store.imports_out['main.go'] or {}, 'store/store.go'),
        'module-path import resolved')
    -- dead: only lonely (init's callee register has a caller)
    local dead = require('cartograph.lint').run(store,
        { only = { ['dead-function'] = true } })
    eq(1, #dead)
    ok(dead[1].message:match('lonely'), dead[1].message)
end)

test('rust: impl-qualified methods, crate scope, trait/test cbarg, pub', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('rust') then skip 'no rust parser' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/rustproj')
    store.ingest(data)
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
    -- impl methods carry their type; Engine::new resolves from boot
    ok(byname['Engine::new'] and byname['Engine::new'].kind == 'method',
        'impl-qualified method')
    ok(byname.boot and byname.boot.exported, 'pub fn marked exported')
    ok(not byname.helper.exported, 'private fn not exported')
    local hits = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.from == byname.boot.id then
            hits[(store.node(e.to) or {}).name] = true
        end
    end
    ok(hits['Engine::new'], 'boot -> Engine::new (scoped_identifier call)')
    ok(hits['Engine::speed'], 'boot -> Engine::speed (dotted method call)')
    ok(hits.helper, 'boot -> helper (bare call, same crate)')
    -- Display impl is trait-registered; #[test] is harness-invoked
    ok(byname['Engine::fmt'].cbarg, 'trait impl method marked dispatched')
    ok(byname.spins.cbarg, '#[test] fn marked harness-invoked')
    -- use crate::helper resolves to the file
    ok(vim.tbl_contains(store.imports_out['src/engine.rs'] or {}, 'src/lib.rs'),
        'crate:: import resolved')
    -- dead-function: only the genuinely lonely one
    local dead = require('cartograph.lint').run(store,
        { only = { ['dead-function'] = true } })
    eq(1, #dead)
    ok(dead[1].message:match('lonely'), dead[1].message)
end)

test('django loop: routes are entities, templates link, audit fires', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('python') then skip 'no python parser' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/djproj')
    local dj = require('cartograph.django').attach(data)
    store.ingest(data)
    -- namespaced entities; same-file same-name = ONE route (overloads)
    eq(3, dj.routes)
    ok(store.node('route::shop:index') and store.node('route::shop:basket'),
        'route entities present')
    eq(0, #dj.duplicate)
    -- template joined the graph and linked; reverse() linked from code
    eq(1, dj.templates)
    local namers = store.var_usedby['route::shop:index'] or {}
    eq(2, #namers) -- the template AND redirect_home's reverse()
    -- the audit: ghost named but never registered; dead route unused
    eq(1, #dj.unregistered)
    eq('shop:ghost', dj.unregistered[1].name)
    eq({ 'shop:never-named' }, dj.unused)
    local findings = require('cartograph.lint').run(store,
        { only = { ['route-audit'] = true } })
    local blob = ''
    for _, f in ipairs(findings) do blob = blob .. f.message .. '\n' end
    ok(blob:match("'shop:ghost' is named here but never registered"), blob)
    ok(blob:match("'shop:never%-named' is registered but nothing names"), blob)
end)

test('symfony loop: yaml routes are entities, twig + code link, audit fires', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('php') then skip 'no php parser' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/sfproj')
    local sf = require('cartograph.symfony').attach(data)
    store.ingest(data)
    -- leaf routes (a top-level key with a path) across config/routes.yaml
    -- AND config/routes/*.yaml become entities
    eq(6, sf.routes)
    ok(store.node('sfroute::blog_index') and store.node('sfroute::blog_show')
        and store.node('sfroute::blog_archive'), 'route entities present')
    eq(0, #sf.duplicate)
    -- controller links: our controllers wire (BlogController::index/__invoke,
    -- HomeController::home); the framework TemplateController is external
    eq(5, sf.controllers)
    eq(1, sf.external)
    -- the controller's ALIBI: BlogController::index is named by its route
    local idx
    for id, n in pairs(store.by_id) do
        if n.name == 'BlogController::index' then idx = id end
    end
    ok(idx and #(store.var_usedby[idx] or {}) == 1,
        'controller method is kept alive by its route')
    -- invokable controller resolves to __invoke
    local inv
    for id, n in pairs(store.by_id) do
        if n.name == 'BlogController::__invoke' then inv = id end
    end
    ok(inv and #(store.var_usedby[inv] or {}) == 1, 'invokable route -> __invoke')
    -- naming: twig path('blog_index') AND code generateUrl('blog_index')
    eq(2, #(store.var_usedby['sfroute::blog_index'] or {}))
    -- twig joined the graph; {% extends/include %} resolved to real files
    eq(4, sf.templates)
    local tmpl_edge = false
    for _, e in ipairs(data.edges) do
        if e.sf and e.from == 'templates/blog/index.html.twig'
            and e.to == 'templates/base.html.twig' then tmpl_edge = true end
    end
    ok(tmpl_edge, "{% extends 'base.html.twig' %} resolves to the file")
    -- the audit: ghost named in twig but never registered; dead routes unused
    eq(1, #sf.unregistered)
    eq('ghost_route', sf.unregistered[1].name)
    ok(vim.tbl_contains(sf.unused, 'orphan_route'), 'unreferenced route is dead surface')
    local findings = require('cartograph.lint').run(store,
        { only = { ['route-audit'] = true } })
    local blob = ''
    for _, f in ipairs(findings) do blob = blob .. f.message .. '\n' end
    ok(blob:match("'ghost_route' is named here but never registered"), blob)
    ok(blob:match('RouteNotFoundException'), 'symfony runtime symptom named')
    ok(blob:match("'orphan_route' is registered but nothing names"), blob)
end)

test('symfony: resource imports make discovery partial — no false unregistered', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/config/routes', 'p')
    vim.fn.mkdir(root .. '/templates', 'p')
    local function put(rel, body)
        local fd = assert(io.open(root .. '/' .. rel, 'w'))
        fd:write(body); fd:close()
    end
    -- one leaf route AND a resource import (the sylius pattern): the import
    -- pulls in routes we cannot enumerate, so discovery is PARTIAL
    put('config/routes.yaml', table.concat({
        'home:',
        '    path: /',
        'admin:',
        '    resource: "@SomeBundle/Resources/config/routing.yml"',
        '    prefix: /admin', '' }, '\n'))
    -- a twig naming a route only the unseen import could define
    put('templates/page.html.twig',
        '<a href="{{ path(\'admin_generated_index\') }}">x</a>\n')
    local data = ts.extract(root)
    local sf = require('cartograph.symfony').attach(data)
    ok(sf.partial, 'a resource import marks discovery partial')
    ok(sf.imports >= 1, 'the import is counted')
    eq(1, sf.routes) -- only the leaf `home` becomes an entity
    -- the would-be-unregistered ref is DISCLOSED as a count, never a warning
    eq(0, #sf.unregistered)
    ok(sf.unmatched >= 1, 'unmatched refs are disclosed as a count, not flagged')
    store.ingest(data)
    local findings = require('cartograph.lint').run(store,
        { only = { ['route-audit'] = true } })
    for _, f in ipairs(findings) do
        ok(not f.message:match('admin_generated_index'),
            'partial discovery does not cry wolf over generated routes')
    end
    vim.fn.delete(root, 'rf')
end)

test('ansible loop: handlers are entities, notify links, no-op audit fires', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('yaml') then skip 'no yaml parser' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/ansproj')
    local a = require('cartograph.ansible').attach(data)
    store.ingest(data)
    eq(5, a.handlers)
    eq(6, a.links)
    eq(2, a.dynamic) -- "{{ handler_var }}" and "Remount {{ mount_point }}"
    -- a handler reachable ONLY by a templated notify's static prefix
    -- ("Remount {{ mp }}" -> listen "Remount /tmp") is NOT dead: honest
    -- analysis can't rule out the runtime trigger
    ok(not vim.tbl_contains(a.dead, 'remount tmp'),
        'a dynamic-prefix listener is not called dead')
    -- handlers are entities; notify is their ALIBI (who triggers them)
    ok(store.node('handler::restart sshd'), 'handler entity present')
    -- reload firewall: notify-two + anchored + aliased (anchor/alias resolved)
    eq(3, #(store.var_usedby['handler::reload firewall'] or {}))
    -- rotate logs is reached by its `listen:` topic, not its name
    eq(1, #(store.var_usedby['handler::rotate logs'] or {}))
    -- the killer audit: a typo'd notify names no handler = a silent no-op
    eq(1, #a.noop)
    eq('restart ssh', a.noop[1].name)
    eq({ 'never notified' }, a.dead)
    ok(vim.tbl_contains(vim.tbl_map(function (b) return b.target end, a.broken),
        'does_not_exist.yml'), 'missing include is flagged broken')
    -- include_tasks resolves to the real file (an import edge)
    local inc = false
    for _, e in ipairs(data.edges) do
        if e.an and e.kind == 'import' and e.from == 'tasks/main.yml'
            and e.to == 'tasks/sub.yml' then inc = true end
    end
    ok(inc, 'include_tasks resolves to the file')
    -- the lint surfaces the no-op and the broken include
    local findings = require('cartograph.lint').run(store,
        { only = { ['ansible-audit'] = true } })
    local blob = ''
    for _, f in ipairs(findings) do blob = blob .. f.message .. '\n' end
    ok(blob:match("notify 'restart ssh' names no handler"), blob)
    ok(blob:match("SILENT no%-op"), 'the no-op symptom is named')
    ok(blob:match("include target 'does_not_exist.yml' does not exist"), blob)
    -- variable graph: declared defaults become entities, references link,
    -- a default named nowhere is dead config (no undefined-var audit — vars
    -- come from inventory/facts/extra-vars, so absence proves nothing)
    eq(3, a.vars)
    ok(store.node('ansvar::ansproj_enabled'), 'declared default is an entity')
    ok(#(store.var_usedby['ansvar::ansproj_message'] or {}) >= 1,
        '{{ ansproj_message }} links to its declaration')
    eq({ 'ansproj_unused_flag' }, a.unused_vars)
    local vfindings = require('cartograph.lint').run(store,
        { only = { ['ansible-vars'] = true } })
    local vblob = ''
    for _, f in ipairs(vfindings) do vblob = vblob .. f.message .. '\n' end
    ok(vblob:match("'ansproj_unused_flag' is declared but referenced nowhere"),
        vblob)
end)

test('clone-merge: plan, refusals, apply, journal, byte-exact undo', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local refresh = require 'cartograph.refresh'
    local journal = require 'cartograph.journal'
    local cm = require 'cartograph.clonemerge'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/sub', 'p')
    local function write(rel, text)
        local fd = assert(io.open(root .. '/' .. rel, 'w'))
        fd:write(text)
        fd:close()
    end
    local function readf(rel)
        local fd = assert(io.open(root .. '/' .. rel, 'r'))
        local t = fd:read('a')
        fd:close()
        return t
    end
    local A = table.concat({
        'local function greet(x)',
        '  local y = x + 1',
        '  return y * 2',
        'end',
        '',
        '-- twin docs: adhesion removes this line with the clone',
        'local function salute(x)',
        '  local y = x + 1',
        '  return y * 2',
        'end',
        '',
        'local function caller_a()',
        '  return salute(3)',
        'end',
        '' }, '\n')
    local B = table.concat({
        'local function caller_b()',
        '  return salute(5)',
        'end',
        '' }, '\n')
    write('a.lua', A)
    write('sub/b.lua', B)
    store.ingest(ts.extract(root))
    root = store.data.root
    journal.wipe(root)
    local function byname(nm)
        for id, n in pairs(store.by_id) do
            if n.name == nm then return id end
        end
    end

    -- the plan: salute is greet's witness twin; both callers rewrite;
    -- the cross-file one is a visibility hazard
    local plan, why = cm.plan(store, byname('greet'))
    ok(plan, tostring(why))
    eq(1, #plan.removed)
    eq('salute', plan.removed[1].name)
    eq(2, #plan.rewrites)
    eq(1, #plan.hazards)
    ok(plan.hazards[1]:match('sub/b.lua'), plan.hazards[1])

    -- staged transaction freezes refresh
    store.set_txn(plan)
    local s, w = refresh.file('a.lua')
    ok(not s and w:match('frozen'), tostring(w))

    -- CAS: the file moved since planning -> apply REFUSES
    local fd = assert(io.open(root .. '/a.lua', 'a'))
    fd:write('-- touched\n')
    fd:close()
    local e1, w1 = cm.apply(store, plan)
    ok(not e1 and w1:match('changed on disk'), tostring(w1))

    -- restore, re-plan (fresh stamps), apply for real
    write('a.lua', A)
    store.set_txn(nil)
    plan = assert(cm.plan(store, byname('greet')))
    store.set_txn(plan)
    local entry, aerr = cm.apply(store, plan)
    ok(entry, tostring(aerr))
    eq('applied', entry.status)
    ok(store.txn == nil, 'apply cleared the staged txn')

    -- the files, byte-exact
    local expectedA = table.concat({
        'local function greet(x)',
        '  local y = x + 1',
        '  return y * 2',
        'end',
        '',
        'local function caller_a()',
        '  return greet(3)',
        'end',
        '' }, '\n')
    eq(expectedA, readf('a.lua'))
    eq((B:gsub('salute', 'greet')), readf('sub/b.lua'))

    -- the graph followed through refresh
    ok(not byname('salute'), 'the clone is gone from the graph')
    ok(vim.tbl_contains(store.usedby[byname('greet')] or {}, byname('caller_a')),
        'caller_a rewired')
    ok(vim.tbl_contains(store.usedby[byname('greet')] or {}, byname('caller_b')),
        'caller_b rewired (cross-file)')

    -- undo refuses when a touched file drifted after the apply
    fd = assert(io.open(root .. '/sub/b.lua', 'a'))
    fd:write('-- drift\n')
    fd:close()
    local r1, rw1 = journal.rollback(root)
    ok(not r1 and rw1:match('changed since the apply'), tostring(rw1))

    -- restore the post-apply state, then roll back byte-exact
    write('sub/b.lua', (B:gsub('salute', 'greet')))
    local r2, rw2 = journal.rollback(root)
    ok(r2, tostring(rw2))
    eq(A, readf('a.lua'))
    eq(B, readf('sub/b.lua'))
    refresh.files({ 'a.lua', 'sub/b.lua' })
    ok(byname('salute'), 'the clone is back after undo')

    -- and the journal knows there is nothing left
    local r3, rw3 = journal.rollback(root)
    ok(not r3 and rw3:match('nothing applied'), tostring(rw3))

    journal.wipe(root)
    vim.fn.delete(root, 'rf')
end)

test('refs: witness, ordinal, drift, rename, ambiguity', function ()
    local refs = require 'cartograph.refs'
    local function fn(id, name, order, stmts, params)
        return { id = id, name = name, kind = 'function', file = 'a.lua',
            order = order, params = params or { 'x' },
            range = { start = { line = order, char = 0 }, ['end'] = { line = order + 2, char = 0 } },
            df = { inputs = {}, stmts = stmts } }
    end
    local s1 = { { l = 1, def = { 't' }, use = { 'x' }, dep = {} } }
    local s2 = { { l = 1, def = { 't' }, use = { 'x' }, dep = {} },
        { l = 2, def = {}, use = { 't' }, dep = { { from = 1, var = 't' } } } }
    local a = fn('a.lua::twin@10', 'twin', 10, s1)
    local b = fn('a.lua::twin@20', 'twin', 20, s2)
    local ctx = { callees = function () return nil end }
    -- distinct witnesses disambiguate same-named twins even after reorder
    local ra = refs.of(a, { a, b })
    local a2 = fn('a.lua::twin@30', 'twin', 30, s1) -- moved below b
    local id, note = refs.resolve(ra, { b, a2 }, ctx)
    eq('a.lua::twin@30', id)
    eq(nil, note)
    -- identical witnesses (true clones): ordinal speaks, with its caveat
    local c1 = fn('a.lua::dup@5', 'dup', 5, s1)
    local c2 = fn('a.lua::dup@15', 'dup', 15, s1)
    local rc = refs.of(c2, { c1, c2 })
    eq(2, rc.ordinal)
    id, note = refs.resolve(rc, { c1, c2 }, ctx)
    eq('a.lua::dup@15', id)
    ok(note:match('ordinal'), note)
    -- body edit: resolves with a drift note
    local a3 = fn('a.lua::twin@10', 'twin', 10, s2)
    id, note = refs.resolve(refs.of(a, { a }), { a3 }, ctx)
    eq('a.lua::twin@10', id)
    ok(note:match('drifted'), note)
    -- rename: recovered by witness, offered not assumed
    local renamed = fn('a.lua::fresh@10', 'fresh', 10, s1)
    id, note = refs.resolve(refs.of(a, { a }), { renamed },
        { callees = ctx.callees, all = { renamed } })
    eq('a.lua::fresh@10', id)
    ok(note:match("renamed%? now 'fresh'"), note)
    -- deletion is the truth
    id, note = refs.resolve(refs.of(a, { a }), {}, ctx)
    eq(nil, id)
    eq('missing', note)
end)

test('refs: refresh follows reordered twins by witness, not position', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local refresh = require 'cartograph.refresh'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local function write(rel, text)
        local fd = assert(io.open(root .. '/' .. rel, 'w'))
        fd:write(text)
        fd:close()
    end
    -- two same-named siblings with DIFFERENT bodies (lua: legal, shadowing)
    write('twins.lua', [[
local function pick(a)
  return small(a)
end

local function pick(a)
  local t = a + 1
  local u = big(t)
  return u
end
]])
    write('caller.lua', [[
local function drive(v)
  return pick(v)
end
]])
    local data = ts.extract(root)
    store.ingest(data)
    -- find the SECOND pick (3 statements) and point at it
    local second
    for id, n in pairs(store.by_id) do
        if n.name == 'pick' and n.df and #n.df.stmts == 3 then second = id end
    end
    ok(second, 'the bigger twin found')
    local ref = store.ref_of(second)
    eq(2, ref.ordinal)
    -- swap the twins: the bigger one now comes FIRST
    write('twins.lua', [[
local function pick(a)
  local t = a + 1
  local u = big(t)
  return u
end

local function pick(a)
  return small(a)
end
]])
    assert(refresh.file('twins.lua'))
    local id, note = store.resolve_ref(ref)
    ok(id, tostring(note))
    local n = store.node(id)
    eq(3, #n.df.stmts) -- still the bigger twin, now at the top
    ok(id:match('@0') or id:match('@1'), 'it moved to the front: ' .. id)
    vim.fn.delete(root, 'rf')
end)

test('mcp provider: a server tool that returns the schema is a provider', function ()
    if vim.fn.executable('luajit') == 0 then skip 'no luajit' end
    local cfg = require 'cartograph.config'
    cfg.mcp = { world = { cmd = { 'luajit',
        vim.fn.getcwd() .. '/tests/fixtures/mcp/server.lua' } } }
    local data, err = require('cartograph.providers.mcp').extract('world')
    cfg.mcp = nil
    ok(data, tostring(err))
    eq('mcp-fixture', data.provider)
    ok(type(data.fetched_at) == 'number', 'sample stamped with fetch time')
    store.ingest(data)
    local tick
    for id, n in pairs(store.by_id) do
        if n.name == 'tick' then tick = id end
    end
    ok(tick, 'nodes arrived over the wire')
    ok(vim.tbl_contains(store.uses[tick] or {}, 'world::spawn@0'),
        'edges too — the graph is browsable')
    -- and a bad tool name is an honest error, not a hang
    cfg.mcp = { world = { cmd = { 'luajit',
        vim.fn.getcwd() .. '/tests/fixtures/mcp/server.lua' }, tool = 'nope' } }
    local d2, e2 = require('cartograph.providers.mcp').extract('world')
    cfg.mcp = nil
    ok(not d2 and e2:match('no such tool'), tostring(e2))
end)

test('mcp hygiene: a failed spawn errors cleanly and leaks no client', function ()
    local mcp = require 'cartograph.mcp'
    -- a nonexistent binary: spawn fails, the pipes we made are closed, and
    -- connect returns an honest error instead of a half-open client
    local c, err = mcp.connect({ cmd = { '/nonexistent/cartograph-mcp-xyz' } })
    ok(not c, 'no client from a failed spawn')
    ok(err and err:match('spawn failed'), tostring(err))
    ok(next(mcp._live) == nil, 'a failed connect registers no live client')
end)

test('transport substrate: DB tables cache, warm opens re-scan only the diff', function ()
    if vim.fn.executable('luajit') == 0 then skip 'no luajit' end
    local cache = require 'cartograph.cache'
    local cfgm = require 'cartograph.config'
    local db = vim.fn.tempname()
    local log = db .. '.log'
    local function write_db(lines)
        local fd = assert(io.open(db, 'w'))
        fd:write(table.concat(lines, '\n') .. '\n')
        fd:close()
    end
    local function log_calls()
        if vim.fn.filereadable(log) == 0 then return '' end
        return table.concat(vim.fn.readfile(log), ' ')
    end
    write_db({ 'users v1 id,name,email', 'orders v1 id,total' })
    cfgm.mcp = { pg = { cmd = { 'luajit',
        vim.fn.getcwd() .. '/tests/fixtures/mcp/pgserver.lua', db } } }
    cache.wipe('mcp://pg')

    -- cold: full introspection; the server stamps its tables, so the
    -- scan is SUBSTRATE and persists
    local mcp = require 'cartograph.providers.mcp'
    local data = mcp.extract('pg')
    ok(data and data.stamps and data.stamps['tables/users'] == 'v1',
        'server stamped its tables')
    cache.save(data)

    -- warm, unchanged: ONE stamps call, zero rescans
    vim.fn.delete(log)
    local warm, note = cache.open('mcp://pg')
    ok(warm and note and note:match('unchanged'), tostring(note))
    eq('stamps', log_calls())

    -- alter one table's definition: only IT re-introspects
    write_db({ 'users v2 id,name,email,age', 'orders v1 id,total' })
    vim.fn.delete(log)
    local warm2, note2 = cache.open('mcp://pg')
    ok(warm2 and note2:match('1 re%-extracted'), tostring(note2))
    ok(log_calls():match('graph:only=1'), 'sliced re-scan: ' .. log_calls())
    local users
    for _, n in ipairs(warm2.nodes) do
        if n.name == 'users' and n.kind == 'var' then users = n end
    end
    ok(users and vim.inspect(users.data):find('age'), 'new column arrived')
    eq('v2', warm2.stamps['tables/users'])
    eq('v1', warm2.stamps['tables/orders'])

    -- drop a table: tombstoned like any deletion
    write_db({ 'users v2 id,name,email,age' })
    local warm3, note3 = cache.open('mcp://pg')
    ok(warm3 and note3:match('1 deleted'), tostring(note3))
    eq(nil, warm3.stamps['tables/orders'])

    cfgm.mcp = nil
    cache.wipe('mcp://pg')
    vim.fn.delete(db)
    vim.fn.delete(log)
end)

test('dblink: code SQL entities meet database tables, prefix-aware', function ()
    local dbl = require 'cartograph.dblink'
    eq('wp_', dbl.prefix_of({ 'wp_posts', 'wp_users', 'wp_options' }))
    eq(nil, dbl.prefix_of({ 'wp_posts', 'app_users', 'plain' }))

    local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
    local function tbl(name)
        local file = 'tables/public.' .. name
        return { id = file, name = file, kind = 'module', file = file,
                range = R0, order = -1 },
            { id = file .. '::table:' .. name .. '@0', name = name,
                kind = 'var', file = file, range = R0, order = 0 }
    end
    local um, uv = tbl('wp_posts')
    local om, ov = tbl('wp_dead')
    local db = { nodes = { um, uv, om, ov }, edges = {
        { from = ov.id, to = uv.id, kind = 'use', at = { R0 } } } }
    local data = { root = '/x', nodes = {
        { id = 'sql::table:posts', name = 'table posts', kind = 'var',
            sql = true, file = 'a.php', range = R0, order = 1 },
        { id = 'sql::table:wp_posts', name = 'table wp_posts', kind = 'var',
            sql = true, file = 'b.php', range = R0, order = 1 },
        { id = 'sql::table:ghosts', name = 'table ghosts', kind = 'var',
            sql = true, file = 'c.php', range = R0, order = 1 },
    }, edges = {}, calls = {} }

    local out = dbl.link(data, db)
    eq('wp_', out.prefix)
    -- posts matched via prefix, wp_posts exactly; ghosts is missing;
    -- wp_dead is unused (its FK inbound does not count as a query)
    eq(2, out.matched)
    eq(1, #out.missing)
    eq('ghosts', out.missing[1].name)
    eq({ 'wp_dead' }, out.unused)
    local links = 0
    for _, e in ipairs(data.edges) do
        if e.db and e.kind == 'use' and e.from:find('^sql::') then
            links = links + 1
            ok(e.to == uv.id, 'links land on the real table')
        end
    end
    eq(2, links)

    -- idempotent: re-linking replaces the previous attachment
    dbl.link(data, db)
    local dbnodes = 0
    for _, n in ipairs(data.nodes) do
        if n.db then dbnodes = dbnodes + 1 end
    end
    eq(4, dbnodes)
end)

test('postgres recipe: catalog rows become the neutral schema', function ()
    local rec = require 'cartograph.recipes.postgres'
    -- a canned postgres-mcp: python-repr envelope around json, dispatched
    -- by query shape (the same envelope the real server produces)
    local queries = {}
    local function sql(q)
        queries[#queries + 1] = q
        if q:find('json_object_agg') then
            return [==[[{'j': '{ "tables/public.users" : "aaa", "tables/public.orders" : "bbb" }'}]]==]
        elseif q:find('FOREIGN KEY') then
            return [==[[{'j': '[{"s":"public","n":"orders","fs":"public","fn":"users"}]'}]]==]
        else
            return [==[[{'j': '[{"s":"public","n":"orders","cols":[{"c":"id","t":"integer"}]},{"s":"public","n":"users","cols":[{"c":"id","t":"integer"},{"c":"name","t":"text"}]}]'}]]==]
        end
    end
    local data, err = rec.extract(sql)
    ok(data, tostring(err))
    eq('aaa', data.stamps['tables/public.users'])
    local byname = {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'var' then byname[n.name] = n end
    end
    ok(byname.users and byname.orders, 'table entities')
    eq(2, #byname.users.data) -- columns as litdata
    eq('name text', byname.users.data[2].v)
    -- the FK is the database's own dependency edge
    eq(1, #data.edges)
    ok(data.edges[1].from:find('orders') and data.edges[1].to:find('users'),
        'orders -> users use edge')
    -- incremental slice: the filter reaches every catalog query
    queries = {}
    rec.extract(sql, { only = { 'tables/public.users' } })
    for _, q in ipairs(queries) do
        ok(q:find("IN ('tables/public.users')", 1, true), 'filtered: ' .. q:sub(1, 60))
    end
    -- stamps alone, for the warm-open diff
    local st = rec.stamps(sql)
    eq('bbb', st['tables/public.orders'])
end)

test('live oracle: the diff classifies missing, leaked and unknown', function ()
    local live = require 'cartograph.live'
    store.ingest({ schema = 1, root = '/x', nodes = {}, edges = {}, calls = {
        -- a permanent, load-time subscription
        { callee = 'subscribe', method = true, top = true, file = 'c.lua', line = 1,
          args = { '', 'ev', 'always_on' }, argv = {} },
    } })
    local model = {
        subs = { flying = { { listener = 'handle_flight' },
            { listener = 'handle_wind' } } },
        bindings = { handle_flight = {}, handle_wind = {}, handle_ground = {} },
    }
    local d = live.diff(store, model, {
        states = { player = 'flying' },
        subscriptions = { 'handle_flight', 'handle_ground', 'mystery', 'always_on' },
    })
    eq({ 'handle_wind' }, d.missing)   -- flying demands it; game lacks it
    eq({ 'handle_ground' }, d.extra)   -- known listener, no occupied state
    eq({ 'mystery' }, d.unknown)       -- graph blind spot
    -- always_on is neither leaked nor missing: the permanent baseline
end)

test('sfc containers: script regions, template calls, handler cbarg', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not (has_parser('vue') and has_parser('svelte')) then
        skip 'no vue/svelte parser'
    end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/sfcproj')
    store.ingest(data)
    local byname, byid = {}, {}
    for _, n in ipairs(data.nodes) do byname[n.name] = n byid[n.id] = n end
    -- containers are modules; script fns land at ABSOLUTE rows
    ok(byid['App.vue'], 'vue module node')
    ok(byid['Board.svelte'], 'svelte module node')
    ok(byname.save and byname.save.file == 'App.vue', 'script fn extracted')
    eq(13, byname.save.range.start.line)
    -- @click="save(total)" is a real call: linked, file-level
    local linked
    for _, c in ipairs(data.calls) do
        if c.callee == 'save' and c.file == 'App.vue'
            and c.to == byname.save.id then linked = c end
    end
    ok(linked, 'template call resolves to the script fn')
    ok(linked and not linked.fn, 'template call has no enclosing fn')
    -- bare handlers (@click="onCopy", onclick={bump}): registered, not dead
    ok(byname.onCopy and byname.onCopy.cbarg, 'vue bare handler cbarg')
    ok(byname.bump and byname.bump.cbarg, 'svelte handler cbarg')
    -- imports: component -> component, and SFC script -> plain ts
    ok(vim.tbl_contains(store.imports_out['App.vue'] or {}, 'Widget.vue'),
        'vue -> vue import')
    ok(vim.tbl_contains(store.imports_out['App.vue'] or {}, 'util.ts'),
        'vue -> ts import')
    -- bundler alias: '@/lib/leaf' walks ancestors to src/lib/leaf.ts
    ok(vim.tbl_contains(store.imports_out['src/deep/Leaf.vue'] or {},
        'src/lib/leaf.ts'), 'alias import resolved')
    -- helperFn called from BOTH containers' scripts: js/ts/vue/svelte
    -- resolve as ONE family
    local callers = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.to == byname.helperFn.id then
            callers[(byid[e.from] or {}).name] = true
        end
    end
    ok(callers.save, 'vue(ts) script -> .ts fn')
    ok(callers.bump, 'svelte(js) script -> .ts fn')
    -- the template is a visible block row
    local tpl
    for _, n in ipairs(data.nodes) do
        if n.file == 'App.vue' and n.kind == 'region'
            and n.name == 'template' then tpl = n end
    end
    ok(tpl, 'template block node')
end)

test('php: attributes register, $this->/self:: resolve in-class', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('php') then skip 'no php parser' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/phpproj')
    store.ingest(data)
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
    -- #[Route('/products', ...)] has arguments: registered, not dead;
    -- the bare #[\Override] marker registers nothing
    ok(byname['ProductController::goAction'].cbarg, 'attribute with args = cbarg')
    ok(not byname['ProductController::buildBody'].cbarg, 'marker attribute is not')
    -- $this->buildBody() and self::statCount() carry the enclosing class:
    -- exact same-class matches, not tail guesses
    local hits = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.from == byname['ProductController::goAction'].id then
            hits[(store.node(e.to) or {}).name] = e
        end
    end
    ok(hits['ProductController::buildBody'], '$this-> resolves in-class')
    ok(not hits['ProductController::buildBody'].inferred, 'exact, not ~')
    ok(hits['ProductController::statCount'], 'self:: resolves in-class')
    -- parent::m() resolves to the SUPERCLASS named by `extends`, not a
    -- tail-match across every class's method. Base_Handler is the parent;
    -- parent::boot() (from goAction) and parent::__construct() (from the
    -- ctor) both land on Base_Handler's methods — cross-file, via base_clause
    ok(hits['Base_Handler::boot'], 'parent::boot resolves to the superclass')
    -- transitive: Base_Handler only INHERITS rootMethod (defined on its own
    -- parent Base_Root). parent::rootMethod() from ProductController walks
    -- the extends chain Base_Handler -> Base_Root to the nearest definer
    ok(hits['Base_Root::rootMethod'],
        'parent::m walks the extends chain to the ancestor that defines m')
    ok(hits['Base_Root::rootMethod'].inferred, 'transitive resolution is ~')
    local ctorhits = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref'
            and e.from == byname['ProductController::__construct'].id then
            ctorhits[(store.node(e.to) or {}).name] = true
        end
    end
    ok(ctorhits['Base_Handler::__construct'],
        'parent::__construct resolves to the superclass ctor, not refused')
    -- and it does NOT tail-refuse across unrelated __construct defs
    for _, c in ipairs(data.calls) do
        if c.callee == '__construct' and c.file == 'controller.php' then
            ok(not (c.refused and c.refused.cands), 'parent::__construct not refused')
        end
    end
    -- PSR-4 prefix remap: use App\Service\Renderer lives at lib/Renderer.php
    -- (progressively shorter namespace suffixes, unique-only)
    ok(vim.tbl_contains(store.imports_out['controller.php'] or {},
        'lib/Renderer.php'), 'PSR-4 remapped use resolves')
    -- extends names a file too: PSR-0 underscores (magento's dialect)
    ok(vim.tbl_contains(store.imports_out['controller.php'] or {},
        'Base/Handler.php'), 'extends Base_Handler imports PSR-0')
    -- custom loader: require_api('functions.php') includes by basename
    ok(vim.tbl_contains(store.imports_out['loader_page.php'] or {},
        'functions.php'), 'loader-shaped verb includes')
    -- legacy syntax ($s{0}) tears the parse: defs beyond the ERROR stay
    -- visible but never absorb name matches (magento's Layout.php lesson)
    local torn
    for _, n in ipairs(data.nodes) do
        if n.name:find('orphanMethod') then torn = n end
    end
    ok(torn and torn.torn, 'def beyond parse error is torn')
    for _, c in ipairs(data.calls) do
        ok(c.to ~= (torn or {}).id, 'torn def absorbs nothing')
    end
end)

test('php: malformed files survive — cyclic/self/orphan parent:: never hang or mislink', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('php') then skip 'no php parser' end
    -- extraction must COMPLETE over a dir of pathological files: cyclic and
    -- self-referential inheritance, parent:: with no superclass, a truncated
    -- class, syntactic garbage, an empty file, a bare <?php. A hang (a
    -- runaway superclass walk) fails via the runner timeout; a throw fails here.
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/badphp')
    ok(type(data.nodes) == 'table' and type(data.calls) == 'table'
        and type(data.edges) == 'table', 'graph is well-formed over bad files')
    local by = {}
    for _, c in ipairs(data.calls) do by[c.callee] = c end
    -- cyclic (Cyc_A <-> Cyc_B) and self-extension (Self_Loop): the walk's
    -- visited-set breaks the loop, so these parent:: calls resolve to
    -- NOTHING — never, ever, to a wrong def picked mid-cycle
    for _, name in ipairs({ 'ghost', 'phantom', 'nope' }) do
        ok(by[name], 'call present: ' .. name)
        ok(not by[name].to, name .. ' did not mislink through an inheritance cycle')
    end
    -- parent:: with no base_clause (a plain class; a trait whose parent is
    -- the using class): declined, left unresolved, no crash
    for _, name in ipairs({ 'missing', 'whoKnows' }) do
        ok(by[name] and not by[name].to, name .. ' (no superclass) stays unresolved')
    end
    -- the truncated class tears the parse: its def is torn, absorbs nothing
    local torn
    for _, n in ipairs(data.nodes) do if n.torn then torn = n end end
    ok(torn, 'truncated file yields a torn def')
    for _, c in ipairs(data.calls) do
        ok(c.to ~= (torn or {}).id, 'torn def absorbs no calls')
    end
end)

test('php: transitive parent:: walk is bounded — a deep chain does not run away', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('php') then skip 'no php parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    -- deepMethod/shallowMethod each have a DECOY definer, so the plain tail
    -- match is ambiguous and refuses — forcing the transitive walk to run
    -- (a unique tail would resolve in the main pass, never exercising it).
    local lines = { '<?php',
        'class Decoy1 { public function deepMethod(): int { return -1; } }',
        'class Decoy2 { public function shallowMethod(): int { return -1; } }',
        -- a chain FAR deeper than the step limit: C0 defines deepMethod,
        -- the bottom class calls parent::deepMethod. The definer sits >32
        -- hops up, so the bounded walk must NOT reach it.
        'class C0 { public function deepMethod(): int { return 0; } }' }
    local N = 45
    for k = 1, N - 1 do
        lines[#lines + 1] = ('class C%d extends C%d {}'):format(k, k - 1)
    end
    lines[#lines + 1] = ('class C%d extends C%d { public function trigger(): int { return parent::deepMethod(); } }')
        :format(N, N - 1)
    -- a SHALLOW chain (two hops, within the limit) proves the walk still
    -- resolves when the definer is actually reachable
    lines[#lines + 1] = 'class S0 { public function shallowMethod(): int { return 0; } }'
    lines[#lines + 1] = 'class S1 extends S0 {}'
    lines[#lines + 1] = 'class S2 extends S1 { public function go(): int { return parent::shallowMethod(); } }'
    local fd = io.open(root .. '/deep.php', 'w')
    fd:write(table.concat(lines, '\n'))
    fd:close()

    local data = ts.extract(root)
    local by = {}
    for _, c in ipairs(data.calls) do by[c.callee] = c end
    -- deep: definer beyond the step limit -> unresolved (the bound holds)
    ok(by['deepMethod'], 'deep call present')
    ok(not by['deepMethod'].to, 'deep chain past the step limit is not resolved')
    ok(by['deepMethod'].refused, 'deep chain stays an honest refusal')
    -- shallow: definer two hops up, through an inheriting middle -> resolved
    ok(by['shallowMethod'] and by['shallowMethod'].to,
        'shallow chain within the limit resolves transitively')
    vim.fn.delete(root, 'rf')
end)

test('every language survives malformed files — no crash, no hang, torn containment', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    -- Per language: a CLEAN file with a `survivor` def, plus sibling files
    -- that are broken (truncated mid-def), pure garbage, and empty. Contract:
    -- extraction never throws or hangs, the graph stays well-formed, the good
    -- def still extracts beside its bad neighbors (one broken file must not
    -- nuke the project), and no call ever resolves INTO a torn def.
    local L = {
        { lang = 'lua', ext = 'lua',
          good = 'local function survivor() return 1 end', bad = 'local function wreck(' },
        { lang = 'c', ext = 'c',
          good = 'int survivor(void) { return 1; }', bad = 'int wreck(' },
        { lang = 'cpp', ext = 'cpp',
          good = 'int survivor() { return 1; }', bad = 'class Wreck { void wreck(' },
        { lang = 'javascript', ext = 'js',
          good = 'function survivor() { return 1; }', bad = 'function wreck(' },
        { lang = 'typescript', ext = 'ts',
          good = 'function survivor(): number { return 1; }', bad = 'class Wreck { wreck(x:' },
        { lang = 'python', ext = 'py',
          good = 'def survivor():\n    return 1', bad = 'def wreck(' },
        { lang = 'ruby', ext = 'rb',
          good = 'def survivor\n  1\nend', bad = 'def wreck(' },
        { lang = 'java', ext = 'java',
          good = 'class Ok { int survivor() { return 1; } }', bad = 'class Wreck { void wreck(' },
        { lang = 'go', ext = 'go',
          good = 'package p\nfunc survivor() int { return 1 }', bad = 'package q\nfunc wreck(' },
        { lang = 'rust', ext = 'rs',
          good = 'fn survivor() -> i32 { 1 }', bad = 'fn wreck(' },
        { lang = 'haskell', ext = 'hs',
          good = 'survivor :: Int\nsurvivor = 1', bad = 'wreck x =' },
        { lang = 'scheme', ext = 'scm',
          good = '(define (survivor) 1)', bad = '(define (wreck' },
    }
    local garbage = '~!@#$%^&*()_+ }{ ][ <> ?? garbage 123 \\ zzz'
    local tested = 0
    for _, c in ipairs(L) do
        if has_parser(c.lang) then
            tested = tested + 1
            local dir = vim.fn.tempname()
            vim.fn.mkdir(dir, 'p')
            local function put(name, body)
                local fd = io.open(dir .. '/' .. name, 'w')
                fd:write(body); fd:close()
            end
            put('good.' .. c.ext, c.good)
            put('bad.' .. c.ext, c.bad)
            put('garbage.' .. c.ext, garbage)
            put('empty.' .. c.ext, '')
            local okx, data = pcall(ts.extract, dir)
            ok(okx, c.lang .. ': extract did not throw — ' .. tostring(data))
            if okx then
                ok(type(data.nodes) == 'table' and type(data.calls) == 'table'
                    and type(data.edges) == 'table', c.lang .. ': well-formed graph')
                local found, torn = false, {}
                for _, n in ipairs(data.nodes) do
                    if n.name and n.name:find('survivor') then found = true end
                    if n.torn then torn[n.id] = true end
                end
                ok(found, c.lang .. ': the clean def extracts beside bad files')
                local mislink = false
                for _, call in ipairs(data.calls) do
                    if call.to and torn[call.to] then mislink = true end
                end
                ok(not mislink, c.lang .. ': no call resolves into a torn def')
            end
            vim.fn.delete(dir, 'rf')
        end
    end
    ok(tested > 0, 'at least one language parser was available to test')
end)

test('containers survive malformed SFCs — the script region still yields defs', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('javascript') then skip 'no javascript parser' end
    -- a truncated template/markup expression must degrade to an empty region,
    -- not crash — the valid <script> def still extracts
    local C = {
        { lang = 'vue', ext = 'vue', good =
            '<script>\nfunction survivor() { return 1 }\n</script>\n'
            .. '<template>\n  <div @click="broken(\n</template>\n' },
        { lang = 'svelte', ext = 'svelte', good =
            '<script>\nfunction survivor() { return 1 }\n</script>\n'
            .. '<div on:click={broken(\n' },
    }
    local tested = 0
    for _, c in ipairs(C) do
        if has_parser(c.lang) then
            tested = tested + 1
            local dir = vim.fn.tempname()
            vim.fn.mkdir(dir, 'p')
            local fd = io.open(dir .. '/comp.' .. c.ext, 'w')
            fd:write(c.good); fd:close()
            local ef = io.open(dir .. '/empty.' .. c.ext, 'w')
            ef:write(''); ef:close()
            local okx, data = pcall(ts.extract, dir)
            ok(okx, c.lang .. ': malformed SFC did not throw — ' .. tostring(data))
            if okx then
                local found = false
                for _, n in ipairs(data.nodes) do
                    if n.name and n.name:find('survivor') then found = true end
                end
                ok(found, c.lang .. ': script region def extracts despite broken markup')
            end
            vim.fn.delete(dir, 'rf')
        end
    end
    if tested == 0 then skip 'no vue/svelte parser' end
end)

test('move-apply: plan, refusals, apply, moveset consumed, undo', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local refresh = require 'cartograph.refresh'
    local journal = require 'cartograph.journal'
    local mv = require 'cartograph.moveapply'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local function write(rel, text)
        local fd = assert(io.open(root .. '/' .. rel, 'w'))
        fd:write(text)
        fd:close()
    end
    local function readf(rel)
        local fd = assert(io.open(root .. '/' .. rel, 'r'))
        local t = fd:read('a')
        fd:close()
        return t
    end
    local A = table.concat({
        'local function traveler(x)',
        '  return x + 7',
        'end',
        '',
        'local function stays()',
        '  return traveler(2)',
        'end',
        '' }, '\n')
    local B = table.concat({
        'local M = {}',
        '',
        'function M.existing()',
        '  return 1',
        'end',
        '',
        'return M',
        '' }, '\n')
    write('a.lua', A)
    write('b.lua', B)
    store.ingest(ts.extract(root))
    root = store.data.root
    journal.wipe(root)
    local function byname(nm)
        for id, n in pairs(store.by_id) do
            if n.name == nm then return id end
        end
    end

    -- refusals: nothing staged; then no destination
    local p0, w0 = mv.plan(store)
    ok(not p0 and w0:match('nothing staged'), tostring(w0))
    store.stage(byname('traveler'))
    p0, w0 = mv.plan(store)
    ok(not p0 and w0:match('no destination'), tostring(w0))
    -- dest == home refuses
    store.set_dest('a.lua')
    p0, w0 = mv.plan(store)
    ok(not p0 and w0:match('already lives'), tostring(w0))

    store.set_dest('b.lua')
    local plan, why = mv.plan(store)
    ok(plan, tostring(why))
    eq(1, #plan.moves)
    eq('traveler', plan.moves[1].name)
    eq(6, plan.dest_at) -- 0-based index of `return M`
    -- the stays() call site is disclosed, not rewritten
    local disclosed
    for _, h in ipairs(plan.hazards) do
        if h:match('call site') and h:match('a.lua') then disclosed = true end
    end
    ok(disclosed, table.concat(plan.hazards, ' | '))

    -- verb rung: the move-set changed after planning -> refuse
    store.set_txn(plan)
    store.stage(byname('stays'))
    local e0, we0 = mv.apply(store, plan)
    ok(not e0 and we0:match('changed since planning'), tostring(we0))
    store.unstage(byname('stays'))

    -- apply for real
    local entry, aerr = mv.apply(store, plan)
    ok(entry, tostring(aerr))
    eq('applied', entry.status)
    ok(store.txn == nil, 'apply cleared the staged txn')
    eq(0, #store.staged_ids()) -- the move-set was consumed

    local expectedA = table.concat({
        'local function stays()',
        '  return traveler(2)',
        'end',
        '' }, '\n')
    local expectedB = table.concat({
        'local M = {}',
        '',
        'function M.existing()',
        '  return 1',
        'end',
        '',
        'local function traveler(x)',
        '  return x + 7',
        'end',
        '',
        'return M',
        '' }, '\n')
    eq(expectedA, readf('a.lua'))
    eq(expectedB, readf('b.lua'))

    -- the graph followed: traveler now lives in b.lua, caller relinked
    local t2 = store.node(byname('traveler'))
    eq('b.lua', t2 and t2.file)
    ok(vim.tbl_contains(store.usedby[byname('traveler')] or {}, byname('stays')),
        'stays still linked cross-file')

    -- byte-exact undo
    local r, rw = journal.rollback(root)
    ok(r, tostring(rw))
    eq(A, readf('a.lua'))
    eq(B, readf('b.lua'))
    refresh.files({ 'a.lua', 'b.lua' })
    eq('a.lua', (store.node(byname('traveler')) or {}).file)

    journal.wipe(root)
    vim.fn.delete(root, 'rf')
end)

test('extract-module: new file, header, adhesion, undo deletes', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local refresh = require 'cartograph.refresh'
    local journal = require 'cartograph.journal'
    local mv = require 'cartograph.moveapply'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local function write(rel, text)
        local fd = assert(io.open(root .. '/' .. rel, 'w'))
        fd:write(text)
        fd:close()
    end
    local function readf(rel)
        local fd = io.open(root .. '/' .. rel, 'r')
        if not fd then return nil end
        local t = fd:read('a')
        fd:close()
        return t
    end
    local A = table.concat({
        'local function anchor()',
        '  return 1',
        'end',
        '',
        '-- doc line: travels with the def',
        '-- second doc line',
        'local function nomad(x)',
        '  return x * 3',
        'end',
        '',
        'local function keeper()',
        '  return nomad(4)',
        'end',
        '' }, '\n')
    write('a.lua', A)
    store.ingest(ts.extract(root))
    root = store.data.root
    journal.wipe(root)
    local function byname(nm)
        for id, n in pairs(store.by_id) do
            if n.name == nm then return id end
        end
    end

    store.stage(byname('nomad'))
    -- refusals: existing file is a MOVE; escape attempts refused
    local p0, w0 = mv.plan_extract(store, 'a.lua')
    ok(not p0 and w0:match('already exists'), tostring(w0))
    p0, w0 = mv.plan_extract(store, '../evil.lua')
    ok(not p0 and w0:match('inside the project root'), tostring(w0))
    p0, w0 = mv.plan_extract(store, 'util.nope')
    ok(not p0 and w0:match('no language spec'), tostring(w0))

    local plan, why = mv.plan_extract(store, 'sub/util.lua')
    ok(plan, tostring(why))
    -- adhesion: the two doc lines ride along (range grew upward)
    eq(4, plan.moves[1].lines.s)
    store.set_txn(plan)
    -- the pre-apply diff IS the apply: preview must equal what lands
    local pb, pa = mv.preview(store, plan)
    ok(pb and pb['sub/util.lua'] == false, 'preview sees the create')
    local entry, aerr = mv.apply(store, plan)
    ok(entry, tostring(aerr))
    eq('applied', entry.status)
    eq(0, #store.staged_ids())

    local expectedA = table.concat({
        'local function anchor()',
        '  return 1',
        'end',
        '',
        'local function keeper()',
        '  return nomad(4)',
        'end',
        '' }, '\n')
    local expectedU = table.concat({
        '-- doc line: travels with the def',
        '-- second doc line',
        'local function nomad(x)',
        '  return x * 3',
        'end',
        '' }, '\n')
    eq(expectedA, readf('a.lua'))
    eq(expectedU, readf('sub/util.lua'))
    -- the preview promised exactly these bytes
    eq(expectedA, pa['a.lua'])
    eq(expectedU, pa['sub/util.lua'])

    -- the graph followed: nomad lives in the NEW file
    eq('sub/util.lua', (store.node(byname('nomad')) or {}).file)

    -- undo DELETES the created file, restores the source byte-exact
    local r, rw = journal.rollback(root)
    ok(r, tostring(rw))
    eq(A, readf('a.lua'))
    eq(nil, readf('sub/util.lua'))

    -- changed your mind about changing your mind: redo re-applies
    local rd, rdw = journal.redo(root)
    ok(rd, tostring(rdw))
    eq(expectedA, readf('a.lua'))
    eq(expectedU, readf('sub/util.lua'))
    -- and redo refuses once the before-state drifted
    local r2 = assert(journal.rollback(root))
    eq('rolled_back', r2.status)
    write('a.lua', A .. '-- drifted\n')
    local rd2, rdw2 = journal.redo(root)
    ok(not rd2 and rdw2:match('changed since the undo'), tostring(rdw2))
    write('a.lua', A)
    ok(journal.redo(root), 'redo after restoring')
    assert(journal.rollback(root))

    journal.wipe(root)
    vim.fn.delete(root, 'rf')
end)

test('adhesion declines file headers: the license stays', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local mv = require 'cartograph.moveapply'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local function write(rel, text)
        local fd = assert(io.open(root .. '/' .. rel, 'w'))
        fd:write(text)
        fd:close()
    end
    -- the def sits DIRECTLY under the license block: no blank line
    write('lic.lua', table.concat({
        '-- Copyright (c) 2026 Somebody',
        '-- SPDX-License-Identifier: MIT',
        'local function first(x)',
        '  return x',
        'end',
        '' }, '\n'))
    write('dest.lua', 'local d = 1\n')
    store.ingest(ts.extract(root))
    store.stage((function ()
        for id, n in pairs(store.by_id) do
            if n.name == 'first' then return id end
        end
    end)())
    store.set_dest('dest.lua')
    local plan = assert(mv.plan(store))
    -- the block touches line 1: it is the FILE's, not the def's
    eq(2, plan.moves[1].lines.s)
    local hz
    for _, h in ipairs(plan.hazards) do
        if h:match('file header') then hz = true end
    end
    ok(hz, table.concat(plan.hazards, ' | '))
    store.clear_stage()
    vim.fn.delete(root, 'rf')
end)

test('move wiring: import line written, call sites requalified', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local journal = require 'cartograph.journal'
    local mv = require 'cartograph.moveapply'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local function write(rel, text)
        local fd = assert(io.open(root .. '/' .. rel, 'w'))
        fd:write(text)
        fd:close()
    end
    local function readf(rel)
        local fd = assert(io.open(root .. '/' .. rel, 'r'))
        local t = fd:read('a')
        fd:close()
        return t
    end
    local A = table.concat({
        'local M = {}',
        '',
        'function M.foo(x)',
        '  return x + 10',
        'end',
        '',
        'function M.bar()',
        '  return 1',
        'end',
        '',
        'return M',
        '' }, '\n')
    local B = table.concat({
        'local M = {}',
        '',
        'return M',
        '' }, '\n')
    local C = table.concat({
        "local a = require 'mod_a'",
        '',
        'local function go()',
        '  return a.foo(2) + a.bar()',
        'end',
        '' }, '\n')
    write('mod_a.lua', A)
    write('mod_b.lua', B)
    write('c.lua', C)
    store.ingest(ts.extract(root))
    root = store.data.root
    journal.wipe(root)
    local function byname(nm)
        for id, n in pairs(store.by_id) do
            if n.name == nm then return id end
        end
    end

    store.stage(byname('M.foo'))
    store.set_dest('mod_b.lua')
    local plan, why = mv.plan(store)
    ok(plan, tostring(why))
    -- the WRITE pair: one requalification + one new import line
    eq(1, #plan.rewrites)
    eq('mod_b.foo', plan.rewrites[1].to)
    eq(1, #plan.imports_add)
    eq('c.lua', plan.imports_add[1].file)
    eq("local mod_b = require 'mod_b'", plan.imports_add[1].text)
    eq(0, plan.imports_add[1].after) -- after the existing require
    -- no 'should import' hazard for c.lua: it is being WRITTEN
    for _, h in ipairs(plan.hazards) do
        ok(not h:match('c.lua should import'), h)
        ok(not h:match('call site.*c.lua'), h)
    end

    store.set_txn(plan)
    local entry, aerr = mv.apply(store, plan)
    ok(entry, tostring(aerr))

    eq(table.concat({
        'local M = {}',
        '',
        'function M.bar()',
        '  return 1',
        'end',
        '',
        'return M',
        '' }, '\n'), readf('mod_a.lua'))
    eq(table.concat({
        'local M = {}',
        '',
        'function M.foo(x)',
        '  return x + 10',
        'end',
        '',
        'return M',
        '' }, '\n'), readf('mod_b.lua'))
    eq(table.concat({
        "local a = require 'mod_a'",
        "local mod_b = require 'mod_b'",
        '',
        'local function go()',
        '  return mod_b.foo(2) + a.bar()',
        'end',
        '' }, '\n'), readf('c.lua'))

    -- byte-exact undo across all three files
    local r, rw = journal.rollback(root)
    ok(r, tostring(rw))
    eq(A, readf('mod_a.lua'))
    eq(B, readf('mod_b.lua'))
    eq(C, readf('c.lua'))

    journal.wipe(root)
    vim.fn.delete(root, 'rf')
end)

test('plugin startup: commands exist, nothing heavy loads', function ()
    -- a CHILD nvim proves the plugin/ contract: source only the plugin
    -- file, and every command must exist while no cockpit module has
    -- been required yet
    local repo = vim.fn.getcwd()
    local script = vim.fn.tempname() .. '.lua'
    local fd = assert(io.open(script, 'w'))
    fd:write(([[
vim.opt.rtp:prepend('%s')
vim.cmd('runtime! plugin/cartograph.lua')
local cmds = { 'Cartograph', 'CartographMove', 'CartographApply',
    'CartographUndo', 'CartographRedo', 'CartographJournal',
    'CartographDiff', 'CartographMerge', 'CartographExtractModule',
    'CartographLint', 'CartographRefresh' }
for _, c in ipairs(cmds) do
    assert(vim.fn.exists(':' .. c) == 2, c .. ' missing')
end
for _, m in ipairs({ 'cartograph', 'cartograph.store',
    'cartograph.providers.treesitter' }) do
    assert(package.loaded[m] == nil, m .. ' loaded at startup')
end
-- a graph-needing command answers with a message, not an error
local ok = pcall(vim.cmd, 'CartographUndo')
assert(ok, 'command errored without a graph')
print('plugin-smoke-ok')
]]):format(repo))
    fd:close()
    local out = vim.system({ 'nvim', '--headless', '-u', 'NONE', '-l', script })
        :wait()
    vim.fn.delete(script)
    ok(out.code == 0 and (out.stdout .. out.stderr):match('plugin%-smoke%-ok'),
        'child nvim: ' .. tostring(out.stdout) .. tostring(out.stderr))
end)

test('source: a def renders with its leading doc comment, file header declined', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/a.lua', 'w'))
    fd:write(table.concat({
        '-- LICENSE header — belongs to the file, not the def',
        '',
        '-- greet doubles its input.',
        '-- (a second doc line)',
        'local function greet(x)',
        '  return x * 2',
        'end', '' }, '\n'))
    fd:close()
    local data = ts.extract(root)
    store.ingest(data)
    local greet
    for _, n in ipairs(data.nodes) do if n.name == 'greet' then greet = n end end
    ok(greet, 'greet extracted')
    local body = table.concat(require('cartograph.panes.source')._body_lines(greet), '\n')
    ok(body:match('greet doubles its input'), 'the def shows with its doc comment')
    ok(body:match('a second doc line'), 'the whole contiguous doc block shows')
    ok(not body:match('LICENSE header'), 'the file-header block is declined')
    ok(body:match('local function greet'), 'the def itself is still shown')
    vim.fn.delete(root, 'rf')
end)

test('source: a top-level statement widens to its enclosing block', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/c.lua', 'w'))
    fd:write(table.concat({
        'local WIDTH = 80',   -- 1: a run of three top-level statements
        'local HEIGHT = 24',  -- 2
        'local names = {}',   -- 3
        '',                   -- 4
        'local function area()', -- 5
        '  return WIDTH * HEIGHT',
        'end', '' }, '\n'))
    fd:close()
    local data = ts.extract(root)
    store.ingest(data)
    local height
    for _, n in ipairs(data.nodes) do
        if n.name == 'HEIGHT' and n.kind == 'var' then height = n end
    end
    ok(height, 'HEIGHT is a top-level var')
    -- focusing HEIGHT alone would show one isolated line; instead it renders
    -- the whole block run (WIDTH, HEIGHT, names), not the following function
    local body = table.concat(require('cartograph.panes.source')._body_lines(height), '\n')
    ok(body:match('WIDTH = 80'), 'the sibling above shows for context')
    ok(body:match('HEIGHT = 24'), 'the focused statement shows')
    ok(body:match('names = {}'), 'the sibling below shows')
    ok(not body:match('function area'), 'the block stops before the next function')
    vim.fn.delete(root, 'rf')
end)

test('lua: top-level GLOBAL assignments are vars (a flat globals module)', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    -- a module that is a flat list of GLOBAL assignments (X = ...), not
    -- `local` — bnw's globals.lua. These must extract as var nodes so the
    -- block-descend view lists them (before: 0 vars -> "no declarations").
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/globals.lua', 'w'))
    fd:write(table.concat({
        'MOD_NAME = "x"',
        'local loc = 1',        -- a local: captured once, not doubled
        'VERSION = "1.0"',
        'pos, bb = a.p, a.b',   -- multi-assign: two vars, cross-product deduped
        '' }, '\n'))
    fd:close()
    local data = ts.extract(root)
    local count = {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'var' then count[n.name] = (count[n.name] or 0) + 1 end
    end
    ok(count['MOD_NAME'], 'a bare global is a var')
    ok(count['VERSION'], 'globals interleaved with other statements too')
    ok(count['loc'], 'a local is still a var')
    eq(1, count['MOD_NAME'])            -- global captured once (no double)
    eq(1, count['pos']); eq(1, count['bb']) -- multi-assign deduped
    vim.fn.delete(root, 'rf')
end)

test('lua effects: load-time side effects on module nodes', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/effects')
    local eff = {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'module' then eff[n.file] = n.effects or false end
    end
    eq(true, eff['barecall.lua'])      -- bare print() at load time
    eq(true, eff['global_assign.lua']) -- assigns a global
    eq(true, eff['global_field.lua'])  -- function table.x() mutates a global root
    eq(false, eff['pure.lua'])         -- locals only
    eq(false, eff['value_require.lua']) -- value-bound require stays pure
end)

test('luals oracle: references settle what names refuse', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local luals = require 'cartograph.providers.luals'
    local bin_ok = vim.fn.executable('lua-language-server') == 1
        or vim.fn.executable(vim.fn.expand(
            '~/.local/lib/lua-language-server/bin/lua-language-server')) == 1
    if not bin_ok then skip 'no lua-language-server' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/luaoracle')
    -- two defs named pick: the name graph REFUSES the a.pick(3) call
    local site
    for _, c in ipairs(data.calls) do
        if c.callee == 'pick' and c.file == 'user.lua' then site = c end
    end
    ok(site, 'call site found')
    eq(nil, site.to)
    local stats, why = luals.enrich(data)
    ok(stats, tostring(why))
    -- lua-ls knows the require binding: the call links to ALPHA's pick
    ok(site.to and site.to:match('^alpha%.lua'), tostring(site.to))
    ok(not site.inferred, 'oracle answers are solid, not ~')
end)

test('luals async: settles the same, without blocking the caller', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local bin_ok = vim.fn.executable('lua-language-server') == 1
        or vim.fn.executable(vim.fn.expand(
            '~/.local/lib/lua-language-server/bin/lua-language-server')) == 1
    if not bin_ok then skip 'no lua-language-server' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/luaoracle')
    local site
    for _, c in ipairs(data.calls) do
        if c.callee == 'pick' and c.file == 'user.lua' then site = c end
    end
    local done, stats = false, nil
    require('cartograph.providers.luals').enrich_async(data, {},
        function (s) stats = s; done = true end)
    ok(not done, 'enrich_async does not resolve synchronously')
    ok(vim.wait(90000, function () return done end, 50), 'on_done eventually fires')
    ok(stats, 'answered')
    ok(site.to and site.to:match('^alpha%.lua') and not site.inferred,
        'async oracle settles a.pick to alpha, solid')
end)

test('refusals are places: an ambiguous call keeps its candidates', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    -- alpha.lua and beta.lua both define M.pick; user.lua calls a.pick(3)
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/luaoracle')
    local site
    for _, c in ipairs(data.calls) do
        if c.callee == 'pick' and c.file == 'user.lua' then site = c end
    end
    ok(site, 'call site found')
    eq(nil, site.to) -- name-matching refuses
    ok(site.refused, 'the refusal is recorded')
    eq('ambiguous', site.refused.rule)
    eq(2, site.refused.n)
    eq(2, #site.refused.cands)
    -- the candidates are real, jumpable defs (both M.pick)
    for _, cid in ipairs(site.refused.cands) do
        local n = store.ingest(data) or store.node(cid)
        ok(store.node(cid) and store.node(cid).name == 'M.pick', tostring(cid))
    end
end)

test('registration edges: a dispatch table is a descendable alibi', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/registry')
    store.ingest(data)
    local function byname(nm)
        for id, n in pairs(store.by_id) do if n.name == nm then return id end end
    end
    local hs = byname('handle_start')
    ok(hs, 'handler found')
    -- kept alive: reg edge from the module, and the cbarg flag
    ok(store.node(hs).cbarg, 'flagged registered (not dead)')
    ok(store.reg_by[hs] and #store.reg_by[hs] > 0, 'registered-by recorded')
    eq('mod.lua', store.reg_by[hs][1].from)
    -- the reverse alibi: the module registers both handlers
    local roster = store.registers['mod.lua'] or {}
    eq(2, #roster)
    -- and no phantom CALL edge (a registration is not a call)
    eq(nil, store.usedby[hs])
    -- the dead-function lint spares it (registered = alibi)
    local dead = {}
    for _, f in ipairs(require('cartograph.lint').run(store,
        { only = { ['dead-function'] = true } })) do
        dead[f.message] = true
    end
    for m in pairs(dead) do ok(not m:match('handle_start'), m) end
end)

test('ladder: the epistemic distribution and refusal ranking', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local ladder = require 'cartograph.ladder'
    -- luaoracle: user.lua's go() calls a.pick — a refused (ambiguous) call
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/luaoracle')
    store.ingest(data)
    local t = ladder.tally(store)
    ok(t.total > 0, 'calls counted')
    ok(t.refused >= 1, 'the ambiguous a.pick is on the refused rung')
    -- every call sits on exactly one rung (the total is the partition)
    local sum = 0
    for _, r in ipairs(ladder.RUNGS) do sum = sum + t[r] end
    eq(t.total, sum)
    -- the report ranks the refusal as a resolvable fork
    local blob = table.concat(ladder.report(store), '\n')
    ok(blob:match('refused'), blob)
    ok(blob:match('heaviest refusals'), 'forks surfaced')
    ok(blob:match('pick'), 'the ambiguous callee named')
end)

test('bash: functions, command calls, source imports, vars + df', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('bash') then skip 'no bash parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function put(f, t)
        local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(t); fd:close()
    end
    put('main.sh', table.concat({
        '#!/usr/bin/env bash',
        'CONF="/etc/app"',
        'main() {',
        '    local out',
        '    out=$(fetch_data "$CONF")',
        '    render "$out"',
        '}',
        'source ./lib.sh',
        'main "$@"',
    }, '\n'))
    put('lib.sh', table.concat({
        'fetch_data() {',
        '    curl -s "$1"',
        '}',
        'render() {',
        "    printf '%s\\n' \"$1\"",
        '}',
    }, '\n'))
    local data = ts.extract(root)
    store.ingest(data)
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = byname[n.name] or n end
    ok(byname.main and byname.fetch_data and byname.render, 'fn nodes')
    ok(byname.CONF and byname.CONF.kind == 'var', 'top-level var node')
    local function edge(kind, from, to)
        for _, e in ipairs(data.edges) do
            if e.kind == kind and e.from == from and e.to == to then return e end
        end
    end
    ok(edge('import', 'main.sh', 'lib.sh'), 'source resolves to an import edge')
    ok(edge('ref', byname.main.id, byname.fetch_data.id), 'main -> fetch_data')
    ok(edge('ref', byname.main.id, byname.render.id), 'main -> render')
    -- builtins/externals never resolve into the corpus
    for _, c in ipairs(data.calls) do
        if c.callee == 'curl' or c.callee == 'printf' then
            ok(not c.to, c.callee .. ' stays outside the corpus')
        end
    end
    -- module effects: main.sh runs at load (source + main call); lib.sh
    -- only defines
    ok(byname['main.sh'].effects, 'main.sh has load-time effects')
    ok(not byname['lib.sh'].effects, 'lib.sh is pure defs')
    -- df: main defs `out` (local + assignment) and uses CONF via $CONF
    local df = byname.main.df
    ok(df and #df.stmts >= 2, 'df present')
    local defs, uses = {}, {}
    for _, s in ipairs(df.stmts) do
        for _, d in ipairs(s.def) do defs[d] = true end
        for _, u in ipairs(s.use) do uses[u] = true end
    end
    ok(defs.out, 'local/assignment defs out')
    ok(uses.CONF, '$CONF expansion is a use')
    vim.fn.delete(root, 'rf')
end)

test('bash: node-local torn — a parse error does not tear the file', function ()
    -- the everything-after-first-error rule was calibrated on truncated
    -- class contexts; bash defs have no enclosing context, and one exotic
    -- construct tears 98% of testssl.sh (26k lines, error at 580) under
    -- it. spec.torn_by_node: only defs whose OWN subtree errors are torn.
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('bash') then skip 'no bash parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local src = table.concat({
        '#!/usr/bin/env bash',
        'early() {',
        '    echo ok',
        '}',
        'wreck() {', -- truncated def: the parse error
        'late() {',
        '    echo fine',
        '}',
        'caller() {',
        '    late',
        '}',
    }, '\n')
    local fd = assert(io.open(root .. '/big.sh', 'w')); fd:write(src); fd:close()
    -- the test only means something while the grammar actually errors
    -- here AND recovers late() as a real def
    local p = vim.treesitter.get_string_parser(src, 'bash')
    if not p:parse()[1]:root():has_error() then
        vim.fn.delete(root, 'rf')
        skip 'grammar parses the truncated def now'
    end
    local data = ts.extract(root)
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = byname[n.name] or n end
    -- structurally intact defs before AND after the error stay matchable;
    -- the wreck either fails to extract or is torn — both honest
    ok(byname.early and not byname.early.torn, 'def before the error is NOT torn')
    ok(byname.late and not byname.late.torn, 'def after the error is NOT torn')
    ok(not byname.wreck or byname.wreck.torn, 'the wreck never becomes matchable')
    local linked
    for _, c in ipairs(data.calls) do
        if c.callee == 'late' then linked = c.to == byname.late.id end
    end
    ok(linked, 'call past the error resolves (the cascade is gone)')
    vim.fn.delete(root, 'rf')
end)

test('bash: eval aperture — namespaced defless call refuses with witness', function ()
    -- emission only, zero analyzers (the scope-model memo's contract):
    -- eval conjures what no static pass can enumerate. A call wearing a
    -- KNOWN fn namespace with no visible def is corpus-internal, not an
    -- external command — with conjuring sites present, the honest answer
    -- is refusal-with-witness. Bare unknown commands stay silent.
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('bash') then skip 'no bash parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function put(f, t)
        local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(t); fd:close()
    end
    put('core.sh', table.concat({
        'ns/defined() {',
        '    echo real',
        '}',
        'ns/boot() {',
        '    builtin eval -- "function ns/conjured { :; }"',
        '}',
    }, '\n'))
    put('user.sh', table.concat({
        'run() {',
        '    ns/defined',
        '    ns/conjured',
        '    grep -q x /dev/null',
        '}',
    }, '\n'))
    local data = ts.extract(root)
    local mod
    for _, n in ipairs(data.nodes) do
        if n.id == 'core.sh' then mod = n end
    end
    ok(mod and mod.apertures and mod.apertures[1].rule == 'eval',
        'eval witness rides the module node')
    local by = {}
    for _, c in ipairs(data.calls) do by[c.full or c.callee] = c end
    ok(by['ns/defined'] and by['ns/defined'].to, 'namespaced call with a def links')
    local conj = by['ns/conjured']
    ok(conj and not conj.to and conj.refused
        and conj.refused.rule == 'aperture', 'defless namespaced call refuses as aperture')
    ok(conj and conj.refused.witness and conj.refused.witness:match('^core%.sh:%d+$'),
        'the refusal names its witness: ' .. tostring(conj and conj.refused.witness))
    ok(by.grep and not by.grep.to and not by.grep.refused,
        'bare unknown command stays a silent external')
    vim.fn.delete(root, 'rf')
end)

test('typed strings: sql sink flow + confidence tiers', function ()
    -- sink position = CONFIDENT (the API contract types the arg);
    -- content sniffing = ~ by design (typed-strings v1)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('php') then skip 'no php parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/a.php', 'w'))
    fd:write(table.concat({
        '<?php',
        'function loader() {',
        "    $t_query = 'SELECT id FROM {widgets} WHERE deleted=0';",
        '    db_query( $t_query );',
        '}',
        'function renderer() {',
        "    helper('SELECT name FROM prose_t WHERE x=1');",
        '}',
    }, '\n'))
    fd:close()
    local data = ts.extract(root)
    -- the sink call carries the FLOWED, sink-typed string
    local sq
    for _, c in ipairs(data.calls) do
        if c.callee == 'db_query' then sq = c.strarg end
    end
    ok(sq and sq.ty == 'sql' and sq.v:find('FROM {widgets}', 1, true),
        'single-assignment string flows into the sink, typed sql')
    require('cartograph.sql').attach(data)
    local edges = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'use' and e.to:match('^sql::table:') then
            edges[e.to] = e
        end
    end
    local w, pr = edges['sql::table:widgets'], edges['sql::table:prose_t']
    ok(w and not w.inferred, 'sink-typed table edge is CONFIDENT (brace pattern mined)')
    ok(pr and pr.inferred, 'content-only table edge is ~')
    vim.fn.delete(root, 'rf')
end)

test('typed strings: eval head is the real callee (bash code sink)', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('bash') then skip 'no bash parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.sh', 'w'))
    fd:write(table.concat({
        'ns/target() {',
        '    echo hi',
        '}',
        'run() {',
        '    eval "ns/target $arg"',
        '}',
    }, '\n'))
    fd:close()
    local data = ts.extract(root)
    local target
    for _, n in ipairs(data.nodes) do
        if n.name == 'ns/target' then target = n end
    end
    local ev
    for _, c in ipairs(data.calls) do
        if (c.full or c.callee) == 'eval' then ev = c end
    end
    ok(ev and ev.strarg and ev.strarg.ty == 'code' and ev.strarg.pre,
        'interpolated eval arg is a code-typed PREFIX')
    ok(ev and ev.traced == 'ns/target', 'the proven head token rides traced')
    ok(ev and target and ev.to == target.id, 'the eval call links to the eval´d fn')
    local linked
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.to == (target or {}).id then linked = e end
    end
    ok(linked, 'run -> ns/target edge exists through the eval')
    vim.fn.delete(root, 'rf')
end)
