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
