-- COMPDB of a tree with NO build description (no Makefile, CMakeLists.txt or compile_commands.json): every `*.c` of
-- its directory, compiled with no flags
local F = require 'cartograph.cinterp.facts'
return {
    fact = 'compdb',
    summary = 'every *.c of a tree that has no build description, with no flags',
    derive = function (tree)
        local src = vim.fs.normalize(vim.fn.fnamemodify(tree.src, ':p')):gsub('/$', '')
        for _, b in ipairs({ 'Makefile', 'GNUmakefile', 'makefile', 'CMakeLists.txt', 'compile_commands.json' }) do
            if vim.uv.fs_stat(src .. '/' .. b) then return nil, 'the tree has a build description (' .. b .. ')' end
        end
        local units = {}
        for _, p in ipairs(vim.fn.globpath(src, '*.c', false, true)) do units[#units + 1] = { file = vim.fs.normalize(p), flags = {}, cwd = src } end
        if #units == 0 then return nil, 'no *.c in the tree' end
        table.sort(units, function (a, b) return a.file < b.file end)
        return { dir = src, env = {}, units = units, compiles = #units }
    end,
}
