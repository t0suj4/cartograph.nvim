-- COMPDB from a COMPILATION DATABASE the build exported (`compile_commands.json`: CMake's
-- -DCMAKE_EXPORT_COMPILE_COMMANDS, bear, meson) — in the tree or one directory below it (a build dir). Every entry's
-- unit, in the directory it compiles in, with its -D / -U / -I / -include (a relative -I made absolute). A database has
-- no link lines, so no product is picked: every unit, once.
return {
    fact = 'compdb',
    summary = 'the units and flags of an exported compile_commands.json',
    derive = function (tree)
        local F = require 'cartograph.cinterp.facts'
        local src = vim.fs.normalize(vim.fn.fnamemodify(tree.src, ':p')):gsub('/$', '')
        local path = vim.uv.fs_stat(src .. '/compile_commands.json') and (src .. '/compile_commands.json')
            or vim.fn.glob(src .. '/*/compile_commands.json', false, true)[1]
        if not path then return nil, 'no compile_commands.json in the tree or a directory below it' end
        local okj, db = pcall(vim.json.decode, F.readfile(path) or '')
        if not okj or type(db) ~= 'table' then return nil, 'compile_commands.json does not parse' end
        local units, seen = {}, {}
        for _, e in ipairs(db) do
            local cwd = e.directory or src
            local toks = e.arguments
            if not toks then toks = {}; for t in (e.command or ''):gmatch('%S+') do toks[#toks + 1] = t end end
            local function abs(p) return p:sub(1, 1) == '/' and p or (cwd .. '/' .. p) end
            local file = vim.fs.normalize(abs(e.file))
            if file:match('%.c$') and not seen[file] then
                seen[file] = true
                local flags, i = {}, 1
                while i <= #toks do
                    local t = toks[i]
                    if t:match('^%-[DU].') then flags[#flags + 1] = t
                    elseif t == '-I' and toks[i + 1] then flags[#flags + 1] = '-I' .. abs(toks[i + 1]); i = i + 1
                    elseif t:match('^%-I.') then flags[#flags + 1] = '-I' .. abs(t:sub(3))
                    elseif t == '-include' and toks[i + 1] then flags[#flags + 1] = '-include'; flags[#flags + 1] = abs(toks[i + 1]); i = i + 1 end
                    i = i + 1
                end
                units[#units + 1] = { file = file, flags = flags, cwd = cwd }
            end
        end
        if #units == 0 then return nil, 'compile_commands.json names no .c unit' end
        table.sort(units, function (a, b) return a.file < b.file end)
        return { dir = src, env = {}, units = units, compiles = #db, database = path }
    end,
}
