-- :checkhealth cartograph — is the wiring in place, and how much of
-- the optional machinery is available? Everything degrades honestly;
-- this just says WHAT will degrade before you find out mid-browse.

local M = {}

local LANGS = { 'lua', 'c', 'cpp', 'python', 'javascript', 'typescript',
    'php', 'ruby', 'java', 'go', 'rust', 'haskell', 'scheme',
    'vue', 'svelte' }

function M.check()
    local h = vim.health
    h.start('cartograph')

    if vim.fn.has('nvim-0.10') == 1 then
        h.ok('nvim ' .. tostring(vim.version()))
    else
        h.error('nvim >= 0.10 required (tree-sitter query APIs)')
    end

    -- tree-sitter parsers: each missing one is a language that opens
    -- as frontier modules instead of a graph
    local have, missing = {}, {}
    for _, lang in ipairs(LANGS) do
        -- language.add reports failure by RETURN VALUE, not by error
        if vim.treesitter.language.add(lang) then
            have[#have + 1] = lang
        else
            missing[#missing + 1] = lang
        end
    end
    if #have > 0 then
        h.ok('parsers: ' .. table.concat(have, ' '))
    end
    if #missing > 0 then
        h.warn('parsers missing: ' .. table.concat(missing, ' ')
            .. ' — those languages extract nothing (install via'
            .. ' nvim-treesitter, e.g. :TSInstall ' .. missing[1] .. ')')
    end

    -- nvim-treesitter itself: the vue/svelte injections use its custom
    -- query directives, and parallel workers inherit its runtimepath
    local nts = false
    for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
        if p:find('nvim%-treesitter') then nts = true break end
    end
    if nts then
        h.ok('nvim-treesitter on runtimepath (container SFCs + workers covered)')
    else
        h.warn('nvim-treesitter not found — vue/svelte files degrade to'
            .. ' frontier modules; parallel workers may lack parsers')
    end

    -- cache codec: string.buffer is the fast path, mpack the fallback
    if pcall(require, 'string.buffer') then
        h.ok('string.buffer available (fast shard codec)')
    else
        h.info('string.buffer unavailable — shard cache falls back to vim.mpack')
    end

    -- the yaml parser powers the Ansible adapter (notify↔handler + includes)
    if pcall(vim.treesitter.get_string_parser, '', 'yaml') then
        h.ok('yaml parser present (Ansible notify/handler + include graph works)')
    else
        h.info('yaml parser missing — Ansible analysis is skipped'
            .. ' (:TSInstall yaml to enable)')
    end

    -- optional oracles
    local clangd = vim.fn.executable('clangd') == 1
        or vim.fn.executable(vim.fn.expand('~/.local/bin/clangd')) == 1
    if clangd then
        h.ok('clangd found (C/C++ call edges can be PROVEN, not just name-matched)')
    else
        h.info('clangd not found — C/C++ stays name-matched (~); optional')
    end
    local luals = vim.fn.executable('lua-language-server') == 1
        or vim.fn.executable(vim.fn.expand(
            '~/.local/lib/lua-language-server/bin/lua-language-server')) == 1
    if luals then
        h.ok('lua-language-server found (stock; lua ~ edges can be settled by references)')
    else
        h.info('lua-language-server not found — lua stays name-matched (~); optional')
    end
    if vim.fn.executable('git') == 1 then
        h.ok('git found (cartograph.history available)')
    else
        h.info('git not found — the history/archaeology tool is unavailable')
    end
end

return M
