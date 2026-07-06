-- The self provider: the running instance as a multi-root corpus.
-- Roster comes from the runtimepath (deterministic here — run.sh puts the
-- checkout on rtp); resolution across roots is exercised with temp fixtures.

local function has_parser(lang)
    return pcall(vim.treesitter.language.add or vim.treesitter.language.require_language, lang)
end

test('self: runtimepath is the loaded-root roster; VIMRUNTIME held lazy', function ()
    local selfp = require 'cartograph.providers.self'
    local kept, vr = selfp.roots()
    ok(vr ~= '', 'VIMRUNTIME is known')
    ok(#kept >= 1, 'at least one loaded root')
    local norm = function (p) return (vim.fn.fnamemodify(p, ':p')):gsub('/+$', '') end
    local cwd, found = norm(vim.fn.getcwd()), false
    for _, r in ipairs(kept) do
        ok(r.label and r.dir, 'each kept root has a label + dir')
        ok(r.dir ~= vr and r.dir:sub(1, #vr + 1) ~= vr .. '/',
            'no kept root lives inside $VIMRUNTIME (that is the lazy node)')
        if norm(r.dir) == cwd then found = true end
    end
    ok(found, 'the cartograph checkout (on rtp) is a kept root')
end)

test('self: multi-root corpus — labelled keys resolve, refs cross roots', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local ts    = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local dirA  = vim.fn.tempname(); vim.fn.mkdir(dirA, 'p')
    local dirB  = vim.fn.tempname(); vim.fn.mkdir(dirB, 'p')
    local function put(dir, f, t)
        local fd = assert(io.open(dir .. '/' .. f, 'w')); fd:write(t); fd:close()
    end
    -- B defines a uniquely-named global; A calls it — the only way that link
    -- resolves is if both roots share ONE corpus (cross-root name match).
    put(dirB, 'lib.lua', 'function uniquehelper(x)\n  return x + 1\nend\n')
    put(dirA, 'app.lua', 'local function run()\n  return uniquehelper(41)\nend\nreturn run\n')

    local roots = { plugA = dirA, plugB = dirB }
    local files = { 'plugA/app.lua', 'plugB/lib.lua' }
    local function abs(file)
        local label, rest = file:match('^([^/]+)/(.*)$')
        return roots[label] .. '/' .. rest
    end
    local data = ts.extract('self://loaded', { files = files, abs = abs })
    data.roots = roots

    local byfile = {}
    for _, n in ipairs(data.nodes) do byfile[n.file] = true end
    ok(byfile['plugA/app.lua'] and byfile['plugB/lib.lua'],
        'nodes carry plugin-labelled file keys')

    store.data = data
    eq(dirB .. '/lib.lua', store.abs('plugB/lib.lua'),
        'abspath resolves a labelled key through the roots map')

    -- the call in A settled onto B's function (cross-root, one corpus)
    local crossed = false
    for _, c in ipairs(data.calls) do
        if c.callee == 'uniquehelper' and c.to and c.to:match('^plugB/') then
            crossed = true
        end
    end
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.from:match('^plugA/') and e.to:match('^plugB/') then
            crossed = true
        end
    end
    ok(crossed, 'a call in plugA resolves to plugB — cross-root resolution')

    vim.fn.delete(dirA, 'rf'); vim.fn.delete(dirB, 'rf')
end)

test('self oracle: loaded-vs-not — required modules mark ran, the rest do not', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local ts     = require 'cartograph.providers.treesitter'
    local oracle = require 'cartograph.self_oracle'
    local dir = vim.fn.tempname(); vim.fn.mkdir(dir .. '/lua', 'p')
    local function put(f, t)
        local fd = assert(io.open(dir .. '/lua/' .. f, 'w')); fd:write(t); fd:close()
    end
    put('ranmod.lua', 'return { touched = true }\n')
    put('deadmod.lua', 'return {}\n') -- present in the tree, never required
    vim.opt.rtp:append(dir)
    require('ranmod') -- only this one runs

    local roots = { plug = dir }
    local files = { 'plug/lua/ranmod.lua', 'plug/lua/deadmod.lua' }
    local data = ts.extract('self://loaded', { files = files,
        abs = function (f)
            local l, r = f:match('^([^/]+)/(.*)$'); return roots[l] .. '/' .. r
        end })
    data.provider, data.root, data.roots = 'self', 'self://loaded', roots

    local ran = oracle.loaded_files(data)
    ok(ran['plug/lua/ranmod.lua'], 'the required module is marked as run')
    ok(not ran['plug/lua/deadmod.lua'], 'the never-required file is not marked')

    vim.fn.delete(dir, 'rf')
end)

test('parallel: summarize gives nearest-rank percentiles', function ()
    local par = require 'cartograph.parallel'
    eq(0, par.summarize({}).n)
    local list = {}
    for i = 1, 100 do list[i] = i end -- 1..100, shuffled order doesn't matter
    local s = par.summarize(list)
    eq(100, s.n)
    eq(50, s.p50)   -- nearest-rank: ceil(0.50*100)=50 -> value 50
    eq(90, s.p90)
    eq(95, s.p95)
    eq(99, s.p99)
    eq(100, s.max)
    ok(math.abs(s.mean - 50.5) < 0.001, 'mean is 50.5')
    -- percentiles expose a tail the mean hides: 90 tiny + 10 huge stalls
    local tail = {}
    for i = 1, 90 do tail[i] = 1 end
    for i = 91, 100 do tail[i] = 1000 end
    local t = par.summarize(tail)
    eq(1, t.p90)      -- the bulk is tiny (mean would read ~101, misleading)
    eq(1000, t.p95)   -- but the 10% tail of big stalls is caught
    eq(1000, t.p99)
    eq(1000, t.max)
end)

test('self: finalize (the open path) attaches the lazy node + resolves requires', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local ts    = require 'cartograph.providers.treesitter'
    local selfp = require 'cartograph.providers.self'
    local dir = vim.fn.tempname(); vim.fn.mkdir(dir .. '/lua', 'p')
    local function put(f, t)
        local fd = assert(io.open(dir .. '/lua/' .. f, 'w')); fd:write(t); fd:close()
    end
    put('libf.lua', 'return {}\n')
    put('appf.lua', "local L = require('libf')\nreturn L\n")
    vim.opt.rtp:append(dir); require('appf')

    local roots = { plug = dir }
    local acc = ts.extract('self://loaded', { files =
        { 'plug/lua/appf.lua', 'plug/lua/libf.lua' },
        abs = function (f)
            local l, r = f:match('^([^/]+)/(.*)$'); return roots[l] .. '/' .. r
        end })
    acc.provider, acc.root, acc.roots = 'self', 'self://loaded', roots
    acc.vimruntime = dir -- stand-in; just exercises lazy_node attachment

    -- this is the exact call init's async on_done makes — guards the
    -- provider-vs-oracle module mixup that slipped past unit tests twice
    local req = selfp.finalize(acc)
    ok(req and req.added >= 1, 'requires resolved through the open path')
    local hasLazy = false
    for _, n in ipairs(acc.nodes) do if n.lazy then hasLazy = true end end
    ok(hasLazy, 'the lazy $VIMRUNTIME node was attached')

    vim.fn.delete(dir, 'rf')
end)

test('self oracle: resolve-requires — the loader builds the import graph', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local ts     = require 'cartograph.providers.treesitter'
    local oracle = require 'cartograph.self_oracle'
    local dir = vim.fn.tempname(); vim.fn.mkdir(dir .. '/lua', 'p')
    local function put(f, t)
        local fd = assert(io.open(dir .. '/lua/' .. f, 'w')); fd:write(t); fd:close()
    end
    put('lib.lua', 'return { n = 1 }\n')
    put('app.lua', "local L = require('lib')\nreturn L.n\n")
    vim.opt.rtp:append(dir)
    require('app') -- loads app, which requires lib

    local roots = { plug = dir }
    local data = ts.extract('self://loaded', { files =
        { 'plug/lua/app.lua', 'plug/lua/lib.lua' },
        abs = function (f)
            local l, r = f:match('^([^/]+)/(.*)$'); return roots[l] .. '/' .. r
        end })
    data.provider, data.root, data.roots = 'self', 'self://loaded', roots

    -- the labelled keys defeat path-matching: no import edge app -> lib yet
    local function edge()
        for _, e in ipairs(data.edges) do
            if e.kind == 'import' and e.from == 'plug/lua/app.lua'
                and e.to == 'plug/lua/lib.lua' then return e end
        end
    end
    ok(not edge(), 'path-match cannot resolve the require (labelled keys)')

    local r = oracle.resolve_requires(data)
    ok(r.added >= 1, 'the loader resolved the missing require')
    local e = edge()
    ok(e and e.proven, 'a PROVEN import edge app -> lib was added')

    vim.fn.delete(dir, 'rf')
end)

test('self oracle: registrations — declared commands/keymaps vs live', function ()
    local oracle = require 'cartograph.self_oracle'
    vim.api.nvim_create_user_command('FooRegTest', function () end, {})
    vim.keymap.set('n', 'gzptest', '<nop>')
    local mk = function (name, arg1, arg2)
        return { full = 'vim.api.' .. name, callee = name,
            args = { arg1, arg2 or '' }, file = 'x.lua' }
    end
    local data = { calls = {
        mk('nvim_create_user_command', 'FooRegTest'),
        mk('nvim_create_user_command', 'BarMissingTest'),
        { full = 'vim.keymap.set', callee = 'keymap.set',
            args = { 'n', 'gzptest' }, file = 'x.lua' },
        { full = 'vim.keymap.set', callee = 'keymap.set',
            args = { 'n', 'gzqmissing' }, file = 'x.lua' },
    } }
    local lines, diff = oracle.registrations(data)
    ok(type(lines) == 'table' and #lines > 0, 'produces a report')
    eq(1, diff.commands.ok)                          -- FooRegTest is live
    eq(1, #diff.commands.missing)
    eq('BarMissingTest', diff.commands.missing[1].name)
    eq(1, diff.keymaps.ok)                            -- gzptest is mapped
    eq(1, #diff.keymaps.missing)                      -- gzqmissing is not
    eq('gzqmissing', diff.keymaps.missing[1].lhs)

    vim.api.nvim_del_user_command('FooRegTest')
    pcall(vim.keymap.del, 'n', 'gzptest')
end)

test('self oracle: metatable __index exposes + resolves OOP methods', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local ts     = require 'cartograph.providers.treesitter'
    local oracle = require 'cartograph.self_oracle'
    local dir = vim.fn.tempname(); vim.fn.mkdir(dir .. '/lua', 'p')
    local fd = assert(io.open(dir .. '/lua/metamod.lua', 'w'))
    fd:write('local Base = {}\n'
        .. 'Base.__index = Base\n'
        .. "function Base:greet () return 'hi' end\n"
        .. 'function Base.new () return setmetatable({ x = 1 }, Base) end\n'
        .. 'local M = { obj = Base.new() }\n'
        .. 'return M\n')
    fd:close()
    vim.opt.rtp:append(dir); require('metamod')

    local roots = { plug = dir }
    local data = ts.extract('self://loaded', { files = { 'plug/lua/metamod.lua' },
        abs = function (f)
            local l, r = f:match('^([^/]+)/(.*)$'); return roots[l] .. '/' .. r
        end })
    data.provider, data.root, data.roots = 'self', 'self://loaded', roots
    require('cartograph.store').data = data

    local modnode
    for _, n in ipairs(data.nodes) do if n.kind == 'module' then modnode = n end end
    local tree = oracle.live_value(modnode, data)
    local mi = tree.obj and tree.obj['↑ __index']
    ok(type(mi) == 'table', 'the instance exposes its class through __index')
    ok(mi.greet and mi.greet.live_fn, 'a class method is present as a live fn')
    ok(mi.greet.id, 'the method resolves to its def node (dispatch closed)')
    -- the M.__index = M self idiom does NOT recurse forever
    ok(mi['↑ __index'] == nil, 'a self-indexed class does not re-add __index')

    vim.fn.delete(dir, 'rf')
end)

-- invoke the callback of a buffer-local mapping by its lhs
local function press(buf, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        if m.lhs == lhs and m.callback then return m.callback() end
    end
    error('no mapping for ' .. lhs)
end

test('self oracle: the live lens shows the runtime table, refs resolve to defs', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local ts      = require 'cartograph.providers.treesitter'
    local store   = require 'cartograph.store'
    local source  = require 'cartograph.panes.source'
    local symbols = require 'cartograph.panes.symbols'
    local cfg     = require 'cartograph.config'

    local dir = vim.fn.tempname(); vim.fn.mkdir(dir .. '/lua', 'p')
    local fd = assert(io.open(dir .. '/lua/mod.lua', 'w'))
    -- M is BUILT incrementally: the static literal is `{}` (empty), but at
    -- runtime M holds the dispatch table + helpers — the whole point.
    fd:write('local M = {}\n'
        .. 'M.handlers = { open = function () end, close = function () end }\n'
        .. 'local function helper () return 1 end\n'
        .. 'M.helper = helper\n'
        .. 'function M.run () return M.handlers end\n'
        .. 'return M\n')
    fd:close()
    vim.opt.rtp:append(dir)
    require('mod') -- load it into THIS instance

    local roots = { plug = dir }
    local files = { 'plug/lua/mod.lua' }
    local data = ts.extract('self://loaded', { files = files,
        abs = function (f)
            local l, r = f:match('^([^/]+)/(.*)$'); return roots[l] .. '/' .. r
        end })
    data.provider, data.root, data.roots = 'self', 'self://loaded', roots
    store.ingest(data)

    vim.cmd('tabnew')
    local wsrc = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsrc, source.create()); source.attach(wsrc)
    vim.cmd('leftabove vsplit')
    local wsym = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsym, symbols.create()); symbols.attach(wsym)

    symbols.show('file', 'plug/lua/mod.lua')
    -- <Tab> flips the file altitude from static members to the live lens
    press(symbols.buf, cfg.keys.cycle)
    local function lines()
        return vim.api.nvim_buf_get_lines(symbols.buf, 0, -1, false)
    end
    local text = table.concat(lines(), '\n')
    ok(text:match('⚡'), 'live crumb marks a runtime read')
    ok(text:match('handlers'), 'the runtime-assembled handlers table is shown')
    ok(text:match('run → M%.run') or text:match('helper → helper'),
        'a runtime function value is resolved to its def node')

    -- descend the `handlers` sub-table -> its live entries (open/close)
    local hrow
    for r, l in ipairs(lines()) do if l:match('handlers') then hrow = r end end
    ok(hrow, 'found the handlers row')
    pcall(vim.api.nvim_win_set_cursor, wsym, { hrow, 2 })
    press(symbols.buf, cfg.keys.descend)
    eq('live', symbols.view.level)
    local htext = table.concat(lines(), '\n')
    ok(htext:match('open') and htext:match('close'),
        'the dispatch table\'s live entries are open + close')

    -- descend `open` -> focus the concrete function it dispatches to
    local orow
    for r, l in ipairs(lines()) do if l:match('open') then orow = r end end
    pcall(vim.api.nvim_win_set_cursor, wsym, { orow, 2 })
    press(symbols.buf, cfg.keys.descend)
    eq('fn', symbols.view.level)
    ok((store.focused or ''):match('open'),
        'dispatch resolved: open() focuses its real definition')

    store.loc_provider = nil
    vim.cmd('tabclose')
    vim.fn.delete(dir, 'rf')
end)

test('self oracle: descending a live closure shows its captured upvalues', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local ts      = require 'cartograph.providers.treesitter'
    local store   = require 'cartograph.store'
    local source  = require 'cartograph.panes.source'
    local symbols = require 'cartograph.panes.symbols'
    local cfg     = require 'cartograph.config'
    local oracle  = require 'cartograph.self_oracle'

    local dir = vim.fn.tempname(); vim.fn.mkdir(dir .. '/lua', 'p')
    local fd = assert(io.open(dir .. '/lua/capmod.lua', 'w'))
    fd:write('local M = {}\n'
        .. "local state = { mode = 'idle' }\n"
        .. 'local function log () end\n'
        .. 'function M.make ()\n'
        .. "  return function () state.mode = 'run'; log() end\n"
        .. 'end\n'
        .. 'M.handler = M.make()\n'
        .. 'return M\n')
    fd:close()
    vim.opt.rtp:append(dir); require('capmod')

    local roots = { plug = dir }
    local data = ts.extract('self://loaded', { files = { 'plug/lua/capmod.lua' },
        abs = function (f)
            local l, r = f:match('^([^/]+)/(.*)$'); return roots[l] .. '/' .. r
        end })
    data.provider, data.root, data.roots = 'self', 'self://loaded', roots
    store.ingest(data)

    -- engine: the closure entry carries its fn + upvalue count; upvalues() reads them
    local modnode
    for _, n in ipairs(data.nodes) do if n.kind == 'module' then modnode = n end end
    local tree = oracle.live_value(modnode, data)
    ok(tree.handler and tree.handler.live_fn and tree.handler.fn,
        'M.handler is a live function entry with its fn value')
    ok(tree.handler.up and tree.handler.up >= 1, 'it reports captured upvalues')
    local ups = oracle.upvalues(tree.handler.fn, data)
    ok(ups.state, 'captured table `state` is exposed')
    ok(ups.log and ups.log.live_fn, 'captured function `log` resolves as a live fn')

    -- browser: descend the closure -> the upvalue view (state + log)
    vim.cmd('tabnew')
    local wsrc = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsrc, source.create()); source.attach(wsrc)
    vim.cmd('leftabove vsplit')
    local wsym = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsym, symbols.create()); symbols.attach(wsym)

    symbols.show('file', 'plug/lua/capmod.lua')
    press(symbols.buf, cfg.keys.cycle) -- -> live lens
    local function blines() return vim.api.nvim_buf_get_lines(symbols.buf, 0, -1, false) end
    local hrow
    for r, l in ipairs(blines()) do if l:match('handler%s*→') and l:match('⇡') then hrow = r end end
    ok(hrow, 'the closure row shows an upvalue marker (⇡)')
    pcall(vim.api.nvim_win_set_cursor, wsym, { hrow, 2 })
    press(symbols.buf, cfg.keys.descend) -- -> upvalue view
    eq('live', symbols.view.level)
    local ut = table.concat(blines(), '\n')
    ok(ut:match('↑ upvalues'), 'the upvalue view is shown')
    ok(ut:match('state') and ut:match('log'), 'both captured names appear')

    vim.cmd('tabclose')
    vim.fn.delete(dir, 'rf')
end)

test('self oracle: the lazy $VIMRUNTIME node extracts + splices on descend', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local ts      = require 'cartograph.providers.treesitter'
    local store   = require 'cartograph.store'
    local source  = require 'cartograph.panes.source'
    local symbols = require 'cartograph.panes.symbols'
    local cfg     = require 'cartograph.config'
    local selfp   = require 'cartograph.providers.self'

    -- a small stand-in for $VIMRUNTIME (keeps the test fast + deterministic)
    local vr = vim.fn.tempname(); vim.fn.mkdir(vr .. '/lua/vim', 'p')
    local fd = assert(io.open(vr .. '/lua/vim/foo.lua', 'w'))
    fd:write('local V = {}\nfunction V.bar () end\nreturn V\n'); fd:close()

    local data = { schema = 1, provider = 'self', root = 'self://loaded',
        roots = {}, nodes = { selfp.lazy_node(vr) }, edges = {}, calls = {},
        stamps = {} }
    store.ingest(data)

    vim.cmd('tabnew')
    local wsrc = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsrc, source.create()); source.attach(wsrc)
    vim.cmd('leftabove vsplit')
    local wsym = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsym, symbols.create()); symbols.attach(wsym)

    symbols.show('files')
    local function blines() return vim.api.nvim_buf_get_lines(symbols.buf, 0, -1, false) end
    local lrow
    for r, l in ipairs(blines()) do if l:match('%$VIMRUNTIME') then lrow = r end end
    ok(lrow, 'the lazy $VIMRUNTIME node shows in the files view')

    pcall(vim.api.nvim_win_set_cursor, wsym, { lrow, 0 })
    press(symbols.buf, cfg.keys.descend) -- extract + splice

    ok(not (store.by_id and store.by_id['$VIMRUNTIME']),
        'the lazy placeholder is gone after loading')
    eq(vr, store.data.roots['VIMRUNTIME'], 'the VIMRUNTIME root is registered')
    local hasfoo = false
    for _, f in ipairs(store.files) do
        if f == 'VIMRUNTIME/lua/vim/foo.lua' then hasfoo = true end
    end
    ok(hasfoo, 'the runtime tree is spliced in under the VIMRUNTIME label')
    eq(vr .. '/lua/vim/foo.lua', store.abs('VIMRUNTIME/lua/vim/foo.lua'),
        'spliced files resolve to disk through the new root')

    vim.cmd('tabclose')
    vim.fn.delete(vr, 'rf')
end)
