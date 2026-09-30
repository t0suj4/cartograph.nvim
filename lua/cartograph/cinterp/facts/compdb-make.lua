-- COMPDB from the tree's own BUILD: a make DRY RUN in src (its default target). Every `-c <file>.c` command, in the
-- directory make was in, gives the unit's -D / -U / -I / -include (a relative -I made absolute); the PRODUCT's units
-- only — those whose object is on the link / archive command naming the MOST objects (not the build's host tools). A
-- variable an include needs and the environment lacks (`include $(ERL_TOP)/make/run_make.mk`) is the ancestor
-- directory where the rest of that path exists. A BUILT tree prints no compile command: then `-B` (all out of date).
local F = require 'cartograph.cinterp.facts'

local function parse(out, src)
    local compiles, links = {}, {}
    local stack = { src }
    for line in out:gmatch('[^\n]+') do
        local ent = line:match("^make%[%d+%]: Entering directory '(.-)'") or line:match("^make: Entering directory '(.-)'")
        local lv = line:match("^make%[%d+%]: Leaving directory") or line:match("^make: Leaving directory")
        if ent then stack[#stack + 1] = ent
        elseif lv then if #stack > 1 then stack[#stack] = nil end
        else
            local cwd = stack[#stack]
            for cmd in (line .. ';'):gmatch('(.-)[;&|]+') do
                local toks = {}
                for t in cmd:gmatch('%S+') do toks[#toks + 1] = t end
                if toks[1] == 'cd' and toks[2] then cwd = toks[2]:sub(1, 1) == '/' and toks[2] or (cwd .. '/' .. toks[2])
                else
                    local function abs(p) return p:sub(1, 1) == '/' and p or (cwd .. '/' .. p) end
                    local isc, file, obj, flags, objs = false, nil, nil, {}, {}
                    local i = 1
                    while i <= #toks do
                        local t = toks[i]
                        if t == '-c' then isc = true
                        elseif t == '-o' then obj = toks[i + 1] and abs(toks[i + 1]); i = i + 1
                        elseif t:match('^%-[DU].') then flags[#flags + 1] = t
                        elseif t == '-I' and toks[i + 1] then flags[#flags + 1] = '-I' .. abs(toks[i + 1]); i = i + 1
                        elseif t:match('^%-I.') then flags[#flags + 1] = '-I' .. abs(t:sub(3))
                        elseif t == '-include' and toks[i + 1] then flags[#flags + 1] = '-include'; flags[#flags + 1] = abs(toks[i + 1]); i = i + 1
                        elseif t:match('%.c$') and not t:match('^%-') then file = abs(t)
                        elseif t:match('%.o$') then objs[#objs + 1] = abs(t) end
                        i = i + 1
                    end
                    if isc and file then compiles[#compiles + 1] = { file = vim.fs.normalize(file), obj = obj and vim.fs.normalize(obj), flags = flags, cwd = cwd }
                    elseif not isc and #objs >= 2 then
                        local set = {}
                        for _, o in ipairs(objs) do set[vim.fs.normalize(o)] = true end
                        links[#links + 1] = { n = #objs, set = set, cmd = cmd }
                    end
                end
            end
        end
    end
    return compiles, links
end

return {
    fact = 'compdb',
    summary = 'the product\'s compile commands, from a make dry run of the tree',
    derive = function (tree)
        local src = vim.fs.normalize(vim.fn.fnamemodify(tree.src, ':p')):gsub('/$', '')
        local mk = F.readfile(src .. '/Makefile') or F.readfile(src .. '/GNUmakefile') or F.readfile(src .. '/makefile')
        if not mk then return nil, 'no Makefile in the tree' end
        local env = {}
        for var, rest in ('\n' .. mk):gmatch('\n%s*%-?include%s+%$%(([%w_]+)%)(/[^%s\n]+)') do
            if not vim.env[var] and not env[var] and not rest:find('$', 1, true) then
                local d = src
                while #d > 1 do
                    if vim.uv.fs_stat(d .. rest) then env[var] = d; break end
                    d = vim.fn.fnamemodify(d, ':h')
                end
            end
        end
        local compiles, links
        for _, extra in ipairs({ {}, { '-B' } }) do
            local cmd = { 'make', '-n' }
            vim.list_extend(cmd, extra)
            local r = vim.system(cmd, { cwd = src, text = true, env = env }):wait(300000)
            compiles, links = parse((r.stdout or '') .. '\n' .. (r.stderr or ''), src)
            if #compiles > 0 then break end
        end
        if #compiles == 0 then return nil, 'the make dry run prints no `-c <file>.c` command' end
        table.sort(links, function (a, b) return a.n > b.n end)
        local product = links[1]
        local units, seen = {}, {}
        for _, c in ipairs(compiles) do
            if not seen[c.file] and (not product or (c.obj and product.set[c.obj])) then seen[c.file] = true; units[#units + 1] = c end
        end
        table.sort(units, function (a, b) return a.file < b.file end)
        return { dir = src, env = env, units = units, compiles = #compiles, product = product and product.n or nil }
    end,
}
