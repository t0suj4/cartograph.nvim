-- ALLOC-CENSUS (discovery, CART-1656): which TABLE CONSTRUCTORS allocate most under a workload — the census a
-- representation experiment starts from. Every `{…}` under the repo's lua/ is wrapped, in a SCRATCH COPY (mutation-
-- check's copy), in a call to a global counter (`(__CTF("file:line:col", {…}))` — a global, never an upvalue, so a
-- function at the 60-upvalue limit still compiles; every rewritten file is compile-checked); the workload runs against
-- the copy and each process writes its counts at exit. roster = 1 joins each hot site to flowtype's access roster of
-- the repo (closed world): reshapable / escaped / partial / shared — which route a representation change can take.
-- Its first run (2026-10-11, workload = one extract + solve of lua/cartograph) found 16 M of 27 M tables were
-- `ipairs(t or {})` fallbacks in flowtype's solve loop: removed in 935e310, ~8% faster (ab-equivalence).
-- params: workload = Lua source (`@file` reads one) run by `nvim -l` with the copy first on the runtimepath (arg[1] =
-- the copy's root), top = rows (default 25), roster = 1, repo (default this cartograph), keep = 1, timeout = seconds.
-- CLAIM: the workload ran and something was counted.
local MC = require 'cartograph.tactics.mutation-check'
local tsutil = require 'cartograph.spec.tsutil'

local function repo_of_toolbelt()
    local here = vim.fn.fnamemodify((debug.getinfo(1, 'S').source:gsub('^@', '')), ':p')
    return (here:gsub('/lua/cartograph/tactics/[^/]*$', ''))
end

local COUNTER = [[
-- (alloc-census instrumentation: count table allocations per constructor site; written at exit to $CTOUT/<pid>.tsv)
local counts = {}
local function f(id, t) counts[id] = (counts[id] or 0) + 1; return t end
local out = os.getenv('CTOUT')
if out then
    vim.api.nvim_create_autocmd('VimLeavePre', { callback = function ()
        local fd = io.open(out .. '/' .. vim.fn.getpid() .. '.tsv', 'a')
        if fd then for k, v in pairs(counts) do fd:write(k, '\t', v, '\n') end; fd:close() end
    end })
end
return f
]]

--- wrap every table constructor of one file's text -> new text, sites | nil (it would not compile)
local function instrument(src, rel)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
    if not ok then return nil end
    local tree = parser:parse()[1]:root()
    local ins, n = {}, 0
    local function walk(nd)
        if nd:type() == 'table_constructor' then
            local _, _, s = nd:start(); local _, _, e = nd:end_(); local l, c = nd:start()
            ins[#ins + 1] = { pos = s, text = ('(__CTF(%q,'):format(rel .. ':' .. l .. ':' .. c) }
            ins[#ins + 1] = { pos = e, text = '))', close = true }
            n = n + 1
        end
        for _, ch in tsutil.inext, nd, -1 do walk(ch) end
    end
    walk(tree)
    -- (inserted right to left on the ORIGINAL offsets; at one offset an outer constructor's close goes after an inner
    -- one's — closes before opens, so `{{}}` nests)
    table.sort(ins, function (a, b) if a.pos ~= b.pos then return a.pos > b.pos end return (a.close and 1 or 0) < (b.close and 1 or 0) end)
    local out = src
    for _, i in ipairs(ins) do out = out:sub(1, i.pos) .. i.text .. out:sub(i.pos + 1) end
    out = "__CTF = __CTF or require('cartograph._ctcount'); " .. out
    if not loadstring((out:gsub('^#![^\n]*', ''))) then return nil end
    return out, n
end

local function measure(_, p)
    local repo = p.repo or repo_of_toolbelt()
    local v = { rows = {}, total = 0 }
    if not p.workload then v.error = 'workload = Lua source run against the instrumented copy'; return v end
    local root, why = MC.scratch_copy(repo, p.keep)
    if not root then v.error = why; return v end
    local function done() if not p.keep then vim.fn.delete(root, 'rf') else v.scratch = root end return v end
    vim.fn.mkdir(root .. '/lua/cartograph', 'p')
    local fd = assert(io.open(root .. '/lua/cartograph/_ctcount.lua', 'w')); fd:write(COUNTER); fd:close()
    local nfile, nsite, skipped = 0, 0, {}
    for _, path in ipairs(vim.fn.globpath(root .. '/lua', '**/*.lua', false, true)) do
        if not path:match('_ctcount%.lua$') then
            local rel = path:sub(#root + 2)
            local rf = io.open(path, 'rb'); local src = rf:read('a'); rf:close()
            local out, n = instrument(src, rel)
            if out then
                local wf = assert(io.open(path, 'wb')); wf:write(out); wf:close()
                nfile, nsite = nfile + 1, nsite + n
            else skipped[#skipped + 1] = rel end
        end
    end
    v.files, v.sites, v.skipped = nfile, nsite, skipped
    local wl = root .. '/.alloc-census-workload.lua'
    local wfd = assert(io.open(wl, 'w')); wfd:write(p.workload); wfd:close()
    local outdir = root .. '/.alloc-census-out'
    vim.fn.mkdir(outdir, 'p')
    local r = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '--cmd', 'set rtp^=' .. root, '-l', wl, root },
        { text = true, cwd = root, env = { CTOUT = outdir }, timeout = tonumber(p.timeout or 1800) * 1000 }):wait()
    if r.code ~= 0 then v.error = ('the workload failed (%s): %s'):format(tostring(r.code), ((r.stderr or '') .. (r.stdout or '')):sub(-400)); return done() end
    local counts = {}
    for _, f in ipairs(vim.fn.globpath(outdir, '*.tsv', false, true)) do
        for line in io.lines(f) do
            local id, n = line:match('^(.-)\t(%d+)$')
            if id then counts[id] = (counts[id] or 0) + tonumber(n); v.total = v.total + tonumber(n) end
        end
    end
    local ids = {}
    for id in pairs(counts) do ids[#ids + 1] = id end
    table.sort(ids, function (a, b) return counts[a] > counts[b] or (counts[a] == counts[b] and a < b) end)
    local top = tonumber(p.top or 25)
    for i = 1, math.min(top, #ids) do
        local id = ids[i]
        local file, l, c = id:match('^(.-):(%d+):(%d+)$')
        local text = ''
        local lf = io.open(repo .. '/' .. file)
        if lf then local k = 0; for line in lf:lines() do if k == tonumber(l) then text = vim.trim(line:sub(tonumber(c) + 1)):sub(1, 80) break end; k = k + 1 end; lf:close() end
        v.rows[#v.rows + 1] = { site = file .. ':' .. (tonumber(l) + 1) .. ':' .. (tonumber(c) + 1), count = counts[id], text = text, key = 'tbl:' .. id }
    end
    if p.roster == '1' and #v.rows > 0 then
        -- (the route a representation change can take, from the repo's own access roster)
        local store = require 'cartograph.store'
        local R = store.scoped(require('cartograph.providers.treesitter').extract(repo), function ()
            return require('cartograph.flowtype').solve(store, { open = false, accesses = true })
        end)
        local st = {}
        for _, a in ipairs(R.accesses or {}) do
            local k = 0 for _ in pairs(a.sites) do k = k + 1 end
            for s in pairs(a.sites) do
                local x = st[s] or { n = 0 }; st[s] = x
                x.n = x.n + 1
                if a.partial or a.top then x.partial = true end
                if a.kind == 'dynamic' and a.keystr then x.dynamic = true end
                if k > 1 then x.shared = true end
            end
        end
        for _, row in ipairs(v.rows) do
            local x = st[row.key]
            row.route = not x and 'not followed' or R.escaped_sites[row.key] and 'escaped' or x.partial and 'partial'
                or x.dynamic and 'string-keyed (a map)' or x.shared and 'shared' or 'reshapable'
        end
    end
    return done()
end

local FX = {
    ['lua/hot.lua'] = 'local M = {}\nfunction M.run(n)\n  local s = 0\n  for i = 1, n do local t = { i, i + 1 }; s = s + t[1] end\n  local once = { total = s }\n  return once.total\nend\nreturn M\n',
}

return {
    name = 'alloc-census',
    kind = 'discovery',
    tags = { 'measure', 'optimize', 'code' },
    summary = 'which TABLE CONSTRUCTORS allocate most under a workload: every {…} under lua/ counted in a scratch copy (a global counter, compile-checked), workload = Lua source run against the copy (arg[1] = its root); top = rows; roster = 1 adds the route a representation change can take (reshapable / escaped / partial / shared)',
    params = { workload = 'string', top = 'string?', roster = 'string?', repo = 'string?', keep = 'string?', timeout = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        if v.total == 0 then return false, ('the workload allocated nothing in the %d instrumented file(s): it may not load the code'):format(v.files or 0) end
        local head = {}
        for i = 1, math.min(5, #v.rows) do local r = v.rows[i]; head[#head + 1] = ('%d %s%s'):format(r.count, r.site, r.route and (' [' .. r.route .. ']') or '') end
        return true, ('%d tables from %d sites in %d files; top: %s'):format(v.total, #v.rows, v.files, table.concat(head, '; '))
    end,
    examples = {
        {
            name = 'the constructor in the loop is the hot one: counted per iteration, and ranked first',
            files = FX,
            params = function (store) return { repo = store.data.root, workload = "require('hot').run(100)", roster = '1' } end,
            expect = { holds = true, check = function (v)
                local r = v.rows[1]
                return r and r.site == 'lua/hot.lua:4:29' and r.count == 100 and v.rows[2] and v.rows[2].count == 1 and r.route ~= nil, vim.inspect(v.rows)
            end },
        },
        {
            name = 'a workload that does not load the instrumented code counts nothing — refused, it measured nothing',
            files = FX,
            params = function (store) return { repo = store.data.root, workload = 'local x = 1' } end,
            expect = { holds = false },
        },
    },
}
