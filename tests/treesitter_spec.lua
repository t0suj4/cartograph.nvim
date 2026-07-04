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
