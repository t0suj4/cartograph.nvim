-- REFRESH-PARITY (discovery, CART-1439): the ORACLE an incremental refresh owes — the same code, two paths, one replay.
-- A sequence of REAL edits (the world's git history: the last `history` commits touching `sub`, each changed Lua file
-- set to its content AT that commit, oldest first) is applied to a scratch WORLD and refreshed after each, once with
-- `refresh.files(rels)` (FULL) and once with `refresh.files(rels, { incremental = true })`, each in its OWN process
-- (cartograph.workload.elsewhere: this toolbelt's code). After every step a DIGEST of the graph — every node (kind,
-- id), edge (kind, from, to) and call resolution (fn, callee, to, refused) as sorted lines, hashed — and the edit's
-- INTERFACE CLASS (the file's named definitions as other files link against them: kind, name, exported, #params;
-- unchanged | added | removed | both). Equal digests at every step = the incremental path is the full one.
-- ⚠ THE WORLD IS WRITTEN: it must be a git checkout with no change to tracked files (refused otherwise), and it is
-- restored (`git checkout -- .`) before and after each replay. Use a scratch clone (`git clone --shared`).
-- CLAIM: every step's digest is equal on both paths (and the replay had at least one step).
local W = require 'cartograph.workload'

local function git(dir, args)
    local cmd = { 'git', '-C', dir }
    for _, a in ipairs(args) do cmd[#cmd + 1] = a end
    local r = vim.system(cmd, { text = true }):wait()
    return r.code == 0 and r.stdout or nil, r.stderr
end

-- the replay: { { rel (relative to the extraction root), after } }, oldest first
local function edits_of(world, sub, n)
    local log = git(world, { 'log', '-n', tostring(n), '--format=%H', '--', sub })
    if not log then return nil, 'git log failed in ' .. world end
    local commits = vim.split(vim.trim(log), '\n', { trimempty = true })
    local out = {}
    for i = #commits, 1, -1 do
        local c = commits[i]
        local names = git(world, { 'diff-tree', '--no-commit-id', '--name-only', '-r', c, '--', sub }) or ''
        for _, path in ipairs(vim.split(vim.trim(names), '\n', { trimempty = true })) do
            -- (any file the extractor reads — its language derived from the path, never a list here)
            if require('cartograph.providers.treesitter').lang_of(path) then
                local after = git(world, { 'show', c .. ':' .. path })
                -- (relative to the extraction root: `sub` = '.' is the repo itself)
                local rel = (sub == '.' or sub == '') and path or path:sub(#sub + 2)
                if after then out[#out + 1] = { rel = rel, after = after, commit = c:sub(1, 8) } end
            end
        end
    end
    return out
end

local function digest(data)
    local rows = {}
    -- (with the node flags RELINK sets — cbarg — or a cutoff that skipped a mark would read as equal)
    for _, n in ipairs(data.nodes) do rows[#rows + 1] = 'N\t' .. tostring(n.kind) .. '\t' .. tostring(n.id) .. (n.cbarg and '\tcb' or '') end
    for _, e in ipairs(data.edges) do rows[#rows + 1] = 'E\t' .. tostring(e.kind) .. '\t' .. tostring(e.from) .. '\t' .. tostring(e.to) end
    local cv = require('cartograph.callview').of(data)
    for i = 1, cv.n do
        local r = cv.get(i, 'refused')
        rows[#rows + 1] = 'C\t' .. tostring(cv.get(i, 'fn')) .. '\t' .. tostring(cv.get(i, 'callee')) .. '\t' .. tostring(cv.get(i, 'to'))
            .. '\t' .. (type(r) == 'table' and (vim.inspect(r):gsub('%s+', ' ')) or tostring(r))
    end
    table.sort(rows)
    -- per FILE too (the file a row belongs to = its first id's file): what the cache's O(diff) save must rewrite
    local per = {}
    for _, r in ipairs(rows) do
        -- (N kind id · E kind from to · C fn callee to refused: a node's id, an edge's FROM, a call's FN; a module-level
        -- call has no fn and lands in '?', which no file owns and the check skips)
        local f
        if r:sub(1, 1) == 'C' then f = r:match('^C\t([^\t]-)::') or '?'
        else f = r:match('^%a\t[^\t]*\t([^\t]-)::') or r:match('^%a\t[^\t]*\t([^\t:]+)') or '?' end
        per[f] = per[f] or {}
        per[f][#per[f] + 1] = r
    end
    local hashes = {}
    for f, rs in pairs(per) do hashes[f] = vim.fn.sha256(table.concat(rs, '\n')) end
    return vim.fn.sha256(table.concat(rows, '\n')), #rows, rows, hashes
end

-- a file's INTERFACE: what other files link against (lines ignored — the remap absorbs shifts)
local function interface(data, rel)
    local s = {}
    for _, n in ipairs(data.nodes) do
        if n.file == rel and n.kind ~= 'module' and n.name then
            s[('%s\t%s\t%s\t%d'):format(n.kind, n.name, tostring(n.exported), #(n.params or {}))] = true
        end
    end
    return s
end
local function class_of(a, b)
    local added, removed = false, false
    for k in pairs(b) do if not a[k] then added = true end end
    for k in pairs(a) do if not b[k] then removed = true end end
    return (added and removed) and 'both' or added and 'added' or removed and 'removed' or 'unchanged'
end

-- ONE replay, in this process (the subprocess side)
local function replay(p)
    local world, sub = p.world, p.sub or 'lua'
    git(world, { 'checkout', '--', '.' })
    local fd = assert(io.open(p.edits_file)); local edits = vim.json.decode(fd:read('a')); fd:close()
    local store = require 'cartograph.store'
    local root = world .. '/' .. sub
    -- (the graph a SAVE meets: extracted, then the open path's enrichment passes — cartograph.postpass, as init.open
    -- runs them — and re-ingested. Without them the first refresh's adapters added every cross-language link at once)
    local data = require('cartograph.providers.treesitter').extract(root)
    store.ingest(data)
    require('cartograph.postpass').run(data, { say = function () end })
    store.ingest(data)
    local refresh = require 'cartograph.refresh'
    local steps = {}
    local _, _, rows0, prev = digest(store.data)
    if p.dump then
        vim.fn.mkdir(p.dump, 'p')
        local d = assert(io.open(('%s/%s-000.txt'):format(p.dump, p.mode), 'w')); d:write(table.concat(rows0, '\n')); d:close()
    end
    local ok, err = pcall(function ()
        for i, e in ipairs(edits) do
            if p.steps and i > tonumber(p.steps) then break end
            local before = interface(store.data, e.rel)
            local f = assert(io.open(root .. '/' .. e.rel, 'w')); f:write(e.after); f:close()
            local t0 = vim.uv.hrtime()
            local stats, why = refresh.files({ e.rel }, p.mode == 'incremental' and { incremental = true } or nil)
            local secs = (vim.uv.hrtime() - t0) / 1e9
            local h, n, rows, per = digest(store.data)
            -- ★ THE PERSISTED SIDE: every file whose rows changed this step must be in stats.dirty, or the O(diff) cache
            -- save keeps its old shard — a difference the in-memory digest cannot show
            local dset, undirty = { [e.rel] = true }, {}
            for _, f in ipairs(stats and stats.dirty or {}) do dset[f] = true end
            -- (only files that HAVE a shard — a stamp: a minted external lives in a pseudo-file like `node` and rides
            -- the manifest, which every save rewrites from the whole graph)
            local stamps = store.data.stamps or {}
            for f, hh in pairs(per) do if stamps[f] and prev[f] ~= hh and not dset[f] then undirty[#undirty + 1] = f end end
            for f in pairs(prev) do if stamps[f] and not per[f] and not dset[f] then undirty[#undirty + 1] = f end end
            table.sort(undirty)
            prev = per
            -- (dump = <dir>: every step's digest lines, per path — what a difference is made of)
            if p.dump then
                vim.fn.mkdir(p.dump, 'p')
                local d = assert(io.open(('%s/%s-%03d.txt'):format(p.dump, p.mode, i), 'w')); d:write(table.concat(rows, '\n')); d:close()
            end
            steps[i] = { rel = e.rel, commit = e.commit, class = class_of(before, interface(store.data, e.rel)), hash = h, rows = n,
                secs = secs, refused = (not stats) and tostring(why) or nil, path = stats and stats.path or nil,
                reused = stats and stats.bindings_reused or nil,
                undirty = #undirty > 0 and undirty or nil }
        end
    end)
    git(world, { 'checkout', '--', '.' })
    if not ok then return { error = 'the replay raised: ' .. tostring(err), steps = steps } end
    return { steps = steps }
end

local function measure(_, p)
    if p.mode then return replay(p) end
    local world = vim.fn.fnamemodify(p.world, ':p'):gsub('/+$', '')
    local st = git(world, { 'status', '--porcelain', '--untracked-files=no' })
    if not st then return { error = world .. ' is not a git checkout' } end
    if vim.trim(st) ~= '' then return { error = world .. ' has uncommitted changes to tracked files: the replay writes and restores them' } end
    local sub = p.sub or 'lua'
    local edits, why = edits_of(world, sub, tonumber(p.history or 20))
    if not edits then return { error = why } end
    if #edits == 0 then return { error = 'no extractable file changed under ' .. sub .. ' in the last commits' } end
    local ef = vim.fn.tempname() .. '-edits.json'
    local fd = assert(io.open(ef, 'w')); fd:write(vim.json.encode(edits)); fd:close()
    local runs = {}
    for _, mode in ipairs({ 'full', 'incremental' }) do
        runs[mode] = W.elsewhere(W.OURS, 'refresh-parity', { world = world, sub = sub, edits_file = ef, mode = mode, timeout = p.timeout,
            steps = p.steps, dump = p.dump })
        if runs[mode].error then os.remove(ef); return { error = mode .. ': ' .. runs[mode].error } end
    end
    os.remove(ef)
    local steps, first, v_undirty = {}, nil, nil
    local classes, secs = {}, { full = 0, incremental = 0 }
    for i, a in ipairs(runs.full.steps) do
        local b = runs.incremental.steps[i] or {}
        local equal = a.hash == b.hash
        if not equal and not first then first = i end
        classes[a.class] = (classes[a.class] or 0) + 1
        secs.full, secs.incremental = secs.full + (a.secs or 0), secs.incremental + (b.secs or 0)
        steps[i] = { rel = a.rel, commit = a.commit, class = a.class, equal = equal, rows = a.rows, rows_b = b.rows,
            secs = a.secs, secs_b = b.secs, path_b = b.path, reused_b = b.reused, refused = a.refused or b.refused,
            undirty = a.undirty, undirty_b = b.undirty }
        if (a.undirty or b.undirty) and not v_undirty then v_undirty = i end
    end
    return { steps = steps, first_difference = first, first_undirty = v_undirty, classes = classes, secs = secs }
end

local E = {
    name = 'refresh-parity',
    kind = 'discovery',
    tags = { 'accept', 'repo' },
    measures = 'CART-1439',
    summary = 'the oracle an incremental refresh owes: the world\'s last `history` commits under `sub` replayed as edits on a scratch WORLD (a clean git checkout; restored after), refreshed FULL and INCREMENTAL in two processes, the graph digest (nodes, edges, call resolutions) compared after every step, with each edit\'s interface class (unchanged | added | removed | both) and both paths\' seconds',
    params = { world = 'string', sub = 'string?', history = 'string?', timeout = 'string?', mode = 'string?', edits_file = 'string?',
        steps = 'string?', dump = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        if #v.steps == 0 then return false, 'no step replayed' end
        if v.first_difference then
            local s = v.steps[v.first_difference]
            return false, ('step %d (%s @%s, interface %s): the incremental graph differs from the full one (%d vs %d rows)'):format(
                v.first_difference, s.rel, tostring(s.commit), s.class, s.rows or -1, s.rows_b or -1)
        end
        if v.first_undirty then
            local s = v.steps[v.first_undirty]
            return false, ('step %d (%s): files whose graph changed are NOT in stats.dirty (the cache save would keep their old shards) — full: %s; incremental: %s'):format(
                v.first_undirty, s.rel, table.concat(s.undirty or {}, ', '), table.concat(s.undirty_b or {}, ', '))
        end
        return true, ('%d steps equal (%s); full %.2f s, incremental %.2f s'):format(#v.steps,
            vim.inspect(v.classes):gsub('%s+', ' '), v.secs.full, v.secs.incremental)
    end,
}

local function in_git() return vim.fn.executable('git') == 1, 'no git' end
E.examples = {
    {
        name = 'two commits replayed on a scratch world: both paths give the same graph after every step, and the world is restored',
        requires = in_git,
        files = { ['lua/a.lua'] = 'local M = {}\nfunction M.f() return 1 end\nreturn M\n', ['lua/b.lua'] = 'local A = require("a")\nreturn A.f()\n' },
        params = function (store)
            local root = store.data.root
            local sh = table.concat({
                'cd "$1" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm base',
                'printf "local M = {}\\nfunction M.f() return 2 end\\nreturn M\\n" > lua/a.lua && git -c user.email=t@t -c user.name=t commit -qam body',
                'printf "local M = {}\\nfunction M.f() return 2 end\\nfunction M.g() return M.f() end\\nreturn M\\n" > lua/a.lua && git -c user.email=t@t -c user.name=t commit -qam add',
                'git checkout -q HEAD~2 -- lua/a.lua && git -c user.email=t@t -c user.name=t commit -qam back' }, ' && ')
            vim.system({ 'bash', '-c', sh, '_', root }):wait()
            return { world = root, history = '3', timeout = '120' }
        end,
        expect = { holds = true, check = function (v)
            local cls, paths = {}, {}
            for _, s in ipairs(v.steps) do cls[#cls + 1] = s.class; paths[#paths + 1] = tostring(s.path_b) end
            -- (the unchanged interface took the CUTOFF; an added / removed name the full relink)
            return #v.steps == 3 and table.concat(cls, ',') == 'unchanged,added,removed'
                and table.concat(paths, ',') == 'cutoff,full,full', vim.inspect(v.steps)
        end },
    },
    {
        -- (an UNRESOLVED call in an untouched file lists the candidates' ids, and an id carries its line: the cutoff must
        -- re-resolve it when a refreshed file defines the name, or its refusal keeps the old line)
        name = 'a body edit that MOVES a definition re-resolves the ambiguous calls naming it elsewhere: their refusal ids follow',
        requires = in_git,
        files = {
            ['lua/a.lua'] = 'local A = {}\nfunction A.match() return 1 end\nreturn A\n',
            ['lua/c.lua'] = 'local C = {}\nfunction C.match() return 2 end\nreturn C\n',
            ['lua/b.lua'] = 'local function use(x) return match(x) end\nreturn use\n',
        },
        params = function (store)
            local sh = table.concat({
                'cd "$1" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm base',
                'printf "local A = {}\\n-- moved down\\n\\nfunction A.match() return 1 end\\nreturn A\\n" > lua/a.lua && git -c user.email=t@t -c user.name=t commit -qam moved',
                'git checkout -q HEAD~1 -- lua/a.lua && git -c user.email=t@t -c user.name=t commit -qam back' }, ' && ')
            vim.system({ 'bash', '-c', sh, '_', store.data.root }):wait()
            return { world = store.data.root, history = '2', timeout = '120' }
        end,
        expect = { holds = true, check = function (v)
            return #v.steps == 2 and v.steps[1].path_b == 'cutoff' and v.steps[2].path_b == 'cutoff', vim.inspect(v.steps)
        end },
    },
}

return E
