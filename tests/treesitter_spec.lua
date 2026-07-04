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
