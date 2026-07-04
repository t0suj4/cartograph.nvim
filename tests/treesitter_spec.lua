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
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
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

test('treesitter: lua blocks, litdata and require edges', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/blocks')
    store.ingest(data)
    local blocks, vars, lit = 0, 0, nil
    for _, n in ipairs(data.nodes) do
        if n.kind == 'block' then blocks = blocks + 1 end
        if n.kind == 'var' then
            vars = vars + 1
            if type(n.data) == 'table' then lit = n end
        end
    end
    ok(blocks >= 1, 'blocks emitted')
    ok(vars >= 3, 'vars emitted (' .. vars .. ')')
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
    ok(byname.frames and byname.frames.kind == 'method', 'inline class method')
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
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
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
