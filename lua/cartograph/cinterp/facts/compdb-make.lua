-- COMPDB from the tree's own BUILD: a make DRY RUN in src (its default target). Every `-c <file>.c` command, in the
-- directory make was in, gives the unit's -D / -U / -I / -include (a relative -I made absolute); the PRODUCT's units
-- only — those whose object is on the link / archive command naming the MOST objects (not the build's host tools). A
-- variable an include needs and the environment lacks (`include $(ERL_TOP)/make/run_make.mk`) is the ancestor
-- directory where the rest of that path exists. A BUILT (or partly built) tree prints few compile commands: then WHAT-IF every C source were new (`-W`), never `-B` — see below.
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
        -- (★ GNU make REMAKES an out-of-date makefile even under `-n`: every makefile make reads — the main one, each
        -- `include` that exists — is held OLD with `-o`, in every dry run)
        local holds = {}
        for _, name in ipairs({ 'GNUmakefile', 'makefile', 'Makefile' }) do if vim.uv.fs_stat(src .. '/' .. name) then holds[#holds + 1] = name end end
        for p in ('\n' .. mk):gmatch('\n%s*[%-s]?include%s+([^%s\n]+)') do
            if not p:find('$', 1, true) and vim.uv.fs_stat(p:sub(1, 1) == '/' and p or (src .. '/' .. p)) then holds[#holds + 1] = p end
        end
        -- (one dry run -> the product's units: those whose object is on the link / archive naming the MOST objects)
        -- (★★ a dry run is not read-only: under -n GNU make still EXECUTES every recipe line naming $(MAKE) — an
        -- out-of-date generated source's, a makefile's remake — and a makefile's own $(shell …) probes write into the
        -- tree (LuaJIT's tmpunwind.o, whose result is a FLAG). So the tree is an OVERLAY in a private mount namespace:
        -- every write lands in a tmpfs that vanishes with it — the probes succeed, the tree is untouched. A READ-ONLY
        -- tree is not enough: the failed probe drops -DLUAJIT_UNWIND_EXTERNAL. No namespace: a gap, never a run)
        if vim.fn.executable('unshare') ~= 1 or vim.system({ 'unshare', '--user', '--map-root-user', '--mount', 'true' }):wait().code ~= 0 then
            return nil, 'no private mount namespace (unshare --user --mount) to run the make dry run on an overlay'
        end
        local scratch = vim.fn.tempname()
        vim.fn.mkdir(scratch, 'p')
        local SH = 'mount -t tmpfs tmpfs "$1" && mkdir "$1/up" "$1/wk" && mount -t overlay overlay -o "lowerdir=$2,upperdir=$1/up,workdir=$1/wk" "$2" && cd "$2" && shift 2 && exec make "$@"'
        local function dry(extra)
            local cmd = { 'unshare', '--user', '--map-root-user', '--mount', 'sh', '-c', SH, 'sh', scratch, src, '-n', '-k' }
            vim.list_extend(cmd, extra)
            for _, h in ipairs(holds) do vim.list_extend(cmd, { '-o', h }) end
            local h = vim.system(cmd, { cwd = src, text = true, env = env })
            local r = h:wait(300000)
            if not r then h:kill(9); return nil end
            local compiles, links = parse((r.stdout or '') .. '\n' .. (r.stderr or ''), src)
            table.sort(links, function (a, b) return a.n > b.n end)
            local product = links[1]
            local units, seen = {}, {}
            for _, c in ipairs(compiles) do
                if not seen[c.file] and (not product or (c.obj and product.set[c.obj])) then seen[c.file] = true; units[#units + 1] = c end
            end
            table.sort(units, function (a, b) return a.file < b.file end)
            return { units = units, compiles = #compiles, product = product and product.n or nil }
        end
        -- (the plain dry run first; a PARTLY built tree prints only what is out of date — the product's link names
        -- objects no compile makes — and a built one nothing: then WHAT-IF every C source of the tree were new (`-W
        -- <file>` each), and the fuller one. ★ Never `-B`: under -n make still EXECUTES a line naming $(MAKE), and
        -- CPython's Makefile.pre rule runs config.status and `$(MAKE) -f Makefile.pre Makefile` on one — `-B` reached
        -- it through Modules/config.c and re-configured the tree in an endless recursion; -W makes only sources new)
        local best = dry({})
        if not best or #best.units == 0 or (best.product and #best.units < best.product * 0.9) then
            local w = {}
            for _, f in ipairs(vim.fn.globpath(src, '**/*.c', false, true)) do vim.list_extend(w, { '-W', f:sub(#src + 2) }) end
            local all = #w > 0 and dry(w) or nil
            if all and (not best or #all.units > #best.units) then best = all end
        end
        vim.fn.delete(scratch, 'rf') -- (the mount point: empty, the namespace and its tmpfs are gone)
        if not best then return nil, 'the make dry run did not finish in 300 s' end
        if #best.units == 0 then return nil, 'the make dry run prints no `-c <file>.c` command' end
        return { dir = src, env = env, units = best.units, compiles = best.compiles, product = best.product }
    end,
}
