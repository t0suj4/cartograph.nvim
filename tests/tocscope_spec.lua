-- The .toc scoping adapter: each WoW addon dir is a resolution boundary.
-- Vendored same-named libraries resolve WITHIN their addon; cross-addon
-- names stay unresolved (honest); a plain lua tree (no .toc) keeps one
-- scope and cross-directory resolution intact.

local ts = require 'cartograph.providers.treesitter'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

local function write(root, rel, text)
    local dir = root .. '/' .. (rel:match('^(.*)/[^/]*$') or '')
    vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(root .. '/' .. rel, 'w'))
    fd:write(text)
    fd:close()
end

test('tocscope: vendored libs resolve within their addon', function ()
    if not ready() then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    -- two addons, each vendoring a lib fn with the SAME name
    write(root, 'AddonA/AddonA.toc', '## Title: A\nlib.lua\ncore.lua\n')
    write(root, 'AddonA/lib.lua',
        'function LibFrob(x) return x end\nreturn true')
    write(root, 'AddonA/core.lua',
        'local function useA() return LibFrob(1) end\nreturn { useA }')
    write(root, 'AddonB/AddonB.toc', '## Title: B\nlib.lua\ncore.lua\n')
    write(root, 'AddonB/lib.lua',
        'function LibFrob(x) return x + 1 end\nreturn true')
    write(root, 'AddonB/core.lua',
        'local function useB() return LibFrob(2) end\nreturn { useB }')
    -- an addon calling a name only ANOTHER addon defines
    write(root, 'AddonB/other.lua',
        'local function lonely() return OnlyInA() end\nreturn { lonely }')
    write(root, 'AddonA/only.lua',
        'function OnlyInA() return 1 end\nreturn true')

    local data = ts.extract(root)
    local frobs = {}
    for _, c in ipairs(data.calls) do
        if c.callee == 'LibFrob' then frobs[#frobs + 1] = c end
    end
    eq(2, #frobs, 'both call sites extracted')
    for _, c in ipairs(frobs) do
        local caller_addon = c.file:match('^([^/]+)/')
        ok(c.to, 'LibFrob resolves (was ambiguous whole-tree): ' .. c.file)
        eq(caller_addon, c.to:match('^([^/]+)/'),
            'and to the caller\'s OWN vendored copy')
    end
    for _, c in ipairs(data.calls) do
        if c.callee == 'OnlyInA' then
            eq(nil, c.to, 'cross-addon name stays unresolved — honest')
        end
    end
end)

test('tocscope: a plain lua tree keeps ONE scope', function ()
    if not ready() then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    write(root, 'a/util.lua', 'function Helper() return 1 end\nreturn true')
    write(root, 'b/main.lua',
        'local function go() return Helper() end\nreturn { go }')
    local data = ts.extract(root)
    local hit
    for _, c in ipairs(data.calls) do
        if c.callee == 'Helper' then hit = c end
    end
    ok(hit and hit.to, 'no .toc anywhere: cross-directory resolution intact')
end)

test('factorio: __modname__ requires resolve by info.json identity', function ()
    if not ready() then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    -- mod identity comes from info.json, NOT the dir name (the postprocess
    -- lesson: space-exploration-postprocess lives in space-exploration_0.7.5)
    write(root, 'alpha_1.2.3/info.json', '{"name": "alpha-core", "version": "1.2.3"}')
    write(root, 'alpha_1.2.3/lib/zone.lua', 'local M = {}\nfunction M.hi() return 1 end\nreturn M')
    write(root, 'alpha_1.2.3/control.lua',
        'local Zone = require("__alpha-core__.lib.zone")\nreturn Zone')
    write(root, 'beta_0.1/info.json', '{"name": "beta", "version": "0.1"}')
    write(root, 'beta_0.1/control.lua', table.concat({
        'local Zone = require("__alpha-core__.lib.zone")',      -- dotted
        'local Z2 = require("__alpha-core__/lib/zone.lua")',    -- path form
        'local eng = require("__base__.util")',                 -- engine: honest nil
        'return { Zone, Z2 }',
    }, '\n'))
    local data = ts.extract(root)
    local hits, base = {}, nil
    for _, e in ipairs(data.edges) do
        if e.kind == 'import' then
            hits[#hits + 1] = e.from .. ' -> ' .. e.to
        end
    end
    table.sort(hits)
    eq({
        'alpha_1.2.3/control.lua -> alpha_1.2.3/lib/zone.lua', -- self-ref via __name__
        'beta_0.1/control.lua -> alpha_1.2.3/lib/zone.lua',    -- dotted cross-mod
        'beta_0.1/control.lua -> alpha_1.2.3/lib/zone.lua',    -- path-form cross-mod
    }, hits, 'cross-mod requires resolve; __base__ stays honestly unresolved')
end)

test('factorio: info.json dirs are scope boundaries too', function ()
    if not ready() then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    write(root, 'modx_1.0/info.json', '{"name": "modx"}')
    write(root, 'modx_1.0/a.lua', 'function Shared() return 1 end\nreturn true')
    write(root, 'mody_1.0/info.json', '{"name": "mody"}')
    write(root, 'mody_1.0/a.lua', 'function Shared() return 2 end\nreturn true')
    write(root, 'mody_1.0/b.lua',
        'local function go() return Shared() end\nreturn { go }')
    local data = ts.extract(root)
    for _, c in ipairs(data.calls) do
        if c.callee == 'Shared' then
            ok(c.to and c.to:match('^mody_1%.0/'),
                'bare name resolves within the MOD boundary')
        end
    end
end)
