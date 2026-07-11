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
