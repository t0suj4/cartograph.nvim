-- The OPEN PATH (cartograph.open) — the integration seam every provider routes
-- through, and the one module no spec drove: 570 lines whose routing decisions
-- and refusals were only ever checked by hand. Covers WHICH provider a target
-- picks, what a mixed root does with the files it cannot honestly include, the
-- session's switch-vs-add rule, and the staged-changes refusal.
--
-- Real opens, not internals: each builds its own tab, so teardown drops the tab
-- and resets the band registry. Oracles (lua-ls/clangd), the cache and the save
-- hook are all off — a spec must not spawn a language server, touch the user's
-- cache dir, or leave an autocmd behind.

local store = require 'cartograph.store'
local session = require 'cartograph.session'
local cfg = require 'cartograph.config'

local function ts_ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.get_string_parser, '', 'lua')
end

local saved
local function hermetic()
    saved = { cache = cfg.cache, refresh = cfg.refresh, luals = cfg.luals,
        clangd = cfg.clangd, parallel = cfg.parallel }
    cfg.cache, cfg.refresh, cfg.luals, cfg.clangd, cfg.parallel
        = false, false, false, false, false
end

local function teardown()
    for k, v in pairs(saved or {}) do cfg[k] = v end
    while vim.fn.tabpagenr('$') > 1 do vim.cmd('silent! tabclose') end
    session.reset()
    store.moveset, store.txn = {}, nil
end

-- open, always tearing down even on failure, and hand back what we learned
local function opened(target)
    hermetic()
    local ok, err = pcall(require('cartograph').open, target)
    local snap = ok and store.data and {
        provider = store.data.provider,
        nodes = #store.data.nodes,
        files = (function ()
            local s = {}
            for _, n in ipairs(store.data.nodes) do
                if n.file then s[n.file] = true end
            end
            return s
        end)(),
        data = store.data,
        bands = #session.list(),
    } or nil
    return ok, err, snap
end

local function forth_root()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/sub', 'p')
    write(root, 'core.fs', { ': double dup + ;', ': quad double double ;' })
    write(root, 'sub/main.fs', { ': main quad ;' })
    return root
end

test('open: a directory routes to the tree-sitter provider', function ()
    if not ts_ready() then teardown(); skip('no lua parser') end
    local root = mkroot('m.lua', 'local function helper() end\nreturn { helper = helper }\n')
    local done, err, snap = opened(root)
    teardown()
    ok(done, 'open succeeded: ' .. tostring(err))
    eq('treesitter', snap.provider, 'a source directory is tree-sitter\'s')
    ok(snap.nodes > 0, 'and it produced nodes')
    vim.fn.delete(root, 'rf')
end)

test('open: a stack-language root routes to the token provider', function ()
    -- no parser needed: the token provider is why these roots work at all
    local root = forth_root()
    local done, err, snap = opened(root)
    teardown()
    ok(done, 'open succeeded: ' .. tostring(err))
    eq('tokens', snap.provider, 'forth is the token provider\'s, not an empty ts graph')
    ok(snap.files['core.fs'] and snap.files['sub/main.fs'],
        'both dialect files are in the graph')
    vim.fn.delete(root, 'rf')
end)

test('open: a MIXED root stays tree-sitter and leaves the dialect files out', function ()
    if not ts_ready() then teardown(); skip('no lua parser') end
    local root = forth_root()
    write(root, 'build.lua', { 'local M = {}', 'function M.go() end', 'return M' })
    local done, err, snap = opened(root)
    teardown()
    ok(done, 'open succeeded: ' .. tostring(err))
    eq('treesitter', snap.provider, 'a mixed root opens through tree-sitter')
    ok(snap.files['build.lua'], 'the ts file is in')
    eq(nil, snap.files['core.fs'],
        'the dialect file is NOT smuggled in under a ts capability claim')
    vim.fn.delete(root, 'rf')
end)

test('open: re-opening the same root SWITCHES instead of re-extracting', function ()
    local root = forth_root()
    hermetic()
    local done1 = pcall(require('cartograph').open, root)
    local first, bands1 = store.data, #session.list()
    local done2 = pcall(require('cartograph').open, root)
    local second, bands2 = store.data, #session.list()
    teardown()
    ok(done1 and done2, 'both opens succeeded')
    eq(1, bands1, 'the first open registers one band')
    eq(1, bands2, 'the second does NOT add a second band for the same root')
    ok(first == second, 'the SAME graph table is repointed — no re-extraction')
    vim.fn.delete(root, 'rf')
end)

test('open: a different root ADDS a band (multi-band session)', function ()
    local a, b = forth_root(), forth_root()
    hermetic()
    pcall(require('cartograph').open, a)
    pcall(require('cartograph').open, b)
    local bands = #session.list()
    teardown()
    eq(2, bands, 'two roots, two bands — the second open does not clobber the first')
    vim.fn.delete(a, 'rf'); vim.fn.delete(b, 'rf')
end)

test('open: staged changes REFUSE a new open rather than stranding the plan', function ()
    local a, b = forth_root(), forth_root()
    hermetic()
    pcall(require('cartograph').open, a)
    store.moveset = { ['core.fs::double@0'] = true } -- a cut waiting to be pasted
    local done, err = pcall(require('cartograph').open, b)
    teardown()
    eq(false, done, 'the open is refused while a move-set is staged')
    ok(tostring(err):find('staged changes pending', 1, true),
        'and it says why, naming the fix: ' .. tostring(err))
    vim.fn.delete(a, 'rf'); vim.fn.delete(b, 'rf')
end)
