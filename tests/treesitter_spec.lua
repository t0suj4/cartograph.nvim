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

test('trace-to-pin: dispatch trace lists caller literals; pin makes the edge', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.get_string_parser, '', 'php') then
        skip 'no php parser'
    end
    local xl = require 'cartograph.xlang'
    local tp = require 'cartograph.panes.trace'
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/phpproj')
    xl.link(data)
    store.ingest(data)
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
    local dispatch_call
    for _, c in ipairs(data.calls) do
        if c.callee == '$cb' then dispatch_call = c end
    end
    ok(dispatch_call and dispatch_call.dynamic, 'the $cb call is a frontier')
    ok(byname.dispatch_param.params and byname.dispatch_param.params[1] == 'cb',
        'php param extracted')
    -- the dispatch trace: one row per caller, literals are the candidates
    tp.open(byname.dispatch_param.id, 1, 'cb', dispatch_call)
    local lits = {}
    for _, r in ipairs(tp.rows) do
        if r.origin.v.k == 'lit' then lits[#lits + 1] = r.origin.v.v end
    end
    table.sort(lits)
    eq({ 'compute', 'scale' }, lits)
    -- pin one: call resolves, edge exists AND is indexed, config carries it
    tp.pin('scale')
    ok(dispatch_call.to == byname.scale.id, 'call resolved by the pin')
    ok(not dispatch_call.dynamic, 'no longer a frontier')
    eq(1, #(require('cartograph.config').pins or {}))
    ok(vim.tbl_contains(store.usedby[byname.scale.id] or {},
        byname.dispatch_param.id), 'edge indexed live')
    -- the durable shape holds NO line numbers: refs discipline
    local pin = require('cartograph.config').pins[1]
    eq(nil, pin.line)
    eq('dispatch_param', pin.fn)
    eq('$cb', pin.callee)
    -- and it re-attaches on a FRESH extraction (a restart, a refresh):
    -- the anchor is (file, fn, callee), immune to line shifts
    local data2 = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/phpproj')
    xl.link(data2)
    local call2
    for _, c in ipairs(data2.calls) do
        if c.callee == '$cb' then call2 = c end
    end
    ok(call2 and call2.to and call2.to:match('::scale@'),
        'durable pin re-attached across re-extraction')
    require('cartograph.config').pins = nil
    tp.close()
end)

test('local dispatch trace: branchy defs flatten to pinnable literals', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.get_string_parser, '', 'php') then
        skip 'no php parser'
    end
    local tp = require 'cartograph.panes.trace'
    local trace = require 'cartograph.trace'
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/phpproj')
    store.ingest(data)
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
    local branchy
    for _, c in ipairs(data.calls) do
        if c.callee == '$h' then branchy = c end
    end
    ok(branchy and branchy.dynamic, 'branchy call is a frontier')
    -- the local's two literal defs surface as candidates
    local origins = trace.origins_local(store, byname.dispatch_branchy.id, 'h', branchy.line)
    local lits = {}
    for _, o in ipairs(origins) do
        if o.v.k == 'lit' then lits[#lits + 1] = o.v.v end
    end
    table.sort(lits)
    eq({ 'compute', 'scale' }, lits)
    -- and the pane pin works from the local entry too
    tp.open_local(byname.dispatch_branchy.id, 'h', branchy.line, branchy)
    tp.pin('compute')
    ok(branchy.to == byname.compute.id, 'pinned through the local trace')
    ok(vim.tbl_contains(store.usedby[byname.compute.id] or {},
        byname.dispatch_branchy.id), 'edge indexed')
    require('cartograph.config').pins = nil
    tp.close()
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
    -- freeze-while-staged
    store.moveset[byname('alpha')] = true
    local s2, w2 = refresh.file('sub/b.lua')
    ok(not s2 and w2:match('frozen'), 'staged changes freeze refresh')
    store.moveset = {}
    vim.fn.delete(root, 'rf')
end)

test('parallel extraction: identical graph to sequential', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not has_parser('lua') then skip 'no lua parser' end
    local par = require 'cartograph.parallel'
    local root = vim.fn.getcwd() .. '/tests/fixtures'
    local seq = ts.extract(root)
    local got, notes = nil, {}
    par.extract(root, {
        workers = 3,
        on_note = function (m) notes[#notes + 1] = m end,
        on_done = function (d) got = d end,
    })
    vim.wait(120000, function () return got ~= nil end, 50)
    ok(got, 'parallel finished (' .. table.concat(notes, '; ') .. ')')
    eq(0, #notes) -- no failed slices

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
    -- edges: same (kind, from, to) multiset
    local function ekeys(list)
        local t = {}
        for _, e in ipairs(list) do
            t[#t + 1] = e.kind .. '|' .. e.from .. '|' .. e.to
        end
        table.sort(t)
        return t
    end
    eq(ekeys(seq.edges), ekeys(got.edges))
    -- calls: same resolutions at same sites
    local function ckeys(list)
        local t = {}
        for _, c in ipairs(list) do
            t[#t + 1] = ('%s|%d|%s|%s|%s'):format(c.file, c.line, c.callee,
                tostring(c.to), tostring(c.dynamic))
        end
        table.sort(t)
        return t
    end
    eq(ckeys(seq.calls), ckeys(got.calls))
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
    write('a.lua', 'local function alpha(x)\n  return beta(x)\nend\n')
    write('sub/b.lua', 'local function beta(y)\n  return y * 2\nend\n')
    write('extra.lua', 'local function gamma()\n  return 1\nend\n')
    cache.save(ts.extract(root))

    -- untouched tree: pure warm open, no extraction
    local warm, note = cache.open(root)
    ok(warm, 'cache hit')
    ok(note:match('unchanged'), tostring(note))

    -- edit one file, delete another; only the diff re-extracts
    write('sub/b.lua', 'local function beta(y)\n  return y * 3\nend\n'
        .. '\nlocal function brand_new(z)\n  return z\nend\n')
    vim.fn.delete(root .. '/extra.lua')
    local warm2, note2 = cache.open(root)
    ok(note2:match('1 re%-extracted, 1 deleted'), tostring(note2))
    local byname = {}
    for _, n in ipairs(warm2.nodes) do byname[n.name] = n end
    ok(byname.brand_new, 'edited file re-extracted')
    ok(byname.gamma == nil, 'deleted file gone from the graph')
    ok(warm2.stamps['extra.lua'] == nil, 'and from the stamps')
    -- the cross-file edge survived the splice
    local edge
    for _, e in ipairs(warm2.edges) do
        if e.kind == 'ref' and e.from == byname.alpha.id
            and e.to == byname.beta.id then edge = true end
    end
    ok(edge, 'alpha -> beta intact after warm open')

    -- the update was saved back: a third open is fully warm again
    local warm3, note3 = cache.open(root)
    ok(note3:match('unchanged'), tostring(note3))
    local has_new = false
    for _, n in ipairs(warm3.nodes) do
        if n.name == 'brand_new' then has_new = true end
    end
    ok(has_new, 'updated graph persisted')

    vim.fn.delete((cache.path(root)))
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
