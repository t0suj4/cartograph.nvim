-- AB-EQUIVALENCE (discovery, CART-1444): does a code change keep a measurement's OUTPUT — the same answer from the
-- code at a git REF (side A) and the working tree (side B, or a second ref)? The acceptance a performance change
-- owes (CART-1427 / 1434 / 1440 were each accepted this way by hand) as one call.
--   measure   Lua source (`@file` reads one) returning { measure = function (store, p) -> output }: output is a
--             string or a list of lines — what must not change (resolved edges, a report, a digest)
--   corpus    the trees to run it on (a list); each side extracts each corpus with ITS OWN code
--   sorted    '1' compares the lines as SETS — for an output whose order is not part of the answer
-- ★ SIDE A IS `git archive <ref>` UNPACKED INTO A SCRATCH DIRECTORY: git is only READ — no stash, no worktree, the
-- working tree is never touched (the hand ritual `git stash`ed it mid-measurement: harness #35's hazard). Each side
-- runs in its OWN process with its OWN cache and state homes, so one side's graph cache can never serve the other
-- (a change that alters extraction without a cache VERSION bump would otherwise read as "equal"). warm = '1' shares
-- the caller's homes instead (faster; the caller vouches for the caches).
-- Value: { a = { ref, hash }, b = { ref, hash } | 'working tree', runs = { { corpus, equal, a = { lines, secs }, b = { …
-- }, first_difference } } }. CLAIM: every corpus gives the same output on both sides.
local SF = require 'cartograph.tactics.spec-fails'

local function repo_of_toolbelt()
    local here = vim.fn.fnamemodify((debug.getinfo(1, 'S').source:gsub('^@', '')), ':p')
    return (here:gsub('/lua/cartograph/tactics/[^/]*$', ''))
end

local function git(repo, args)
    local cmd = { 'git', '-C', repo }
    for _, a in ipairs(args) do cmd[#cmd + 1] = a end
    local r = vim.system(cmd, { text = true }):wait()
    return r.code == 0 and vim.trim(r.stdout or '') or nil, vim.trim(r.stderr or '')
end

-- the code at `ref`, unpacked read-only from git into `dir` -> hash | nil, why
local function unpack_ref(repo, ref, dir)
    local hash, why = git(repo, { 'rev-parse', '--verify', ref .. '^{commit}' })
    if not hash then return nil, ('`%s` is no commit in %s: %s'):format(ref, repo, why) end
    vim.fn.mkdir(dir, 'p')
    local r = vim.system({ 'bash', '-c', 'git -C "$1" archive "$2" | tar -x -C "$3"', '_', repo, hash, dir }, { text = true }):wait()
    if r.code ~= 0 then return nil, 'git archive failed: ' .. tostring(r.stderr) end
    return hash
end

-- the wrapper each side runs: the caller's measure, its output and its own time written beside it
local WRAPPER = [[
local user = dofile(%q)
return { measure = function (store, p)
    local t0 = vim.uv.hrtime()
    local out = user.measure(store, p)
    local secs = (vim.uv.hrtime() - t0) / 1e9
    local text = type(out) == 'table' and table.concat(out, '\n') or tostring(out)
    local fd = assert(io.open(%q, 'w')); fd:write(text); fd:close()
    fd = assert(io.open(%q, 'w')); fd:write(tostring(secs)); fd:close()
    return {}
end }
]]

local function lines_of(text) return vim.split(text or '', '\n', { plain = true }) end

local function measure(_, p)
    local repo = p.repo or repo_of_toolbelt()
    local scratch = vim.fn.tempname() .. '-ab'
    vim.fn.mkdir(scratch, 'p')
    local v = { runs = {}, faster = p.faster == '1' or nil }
    local function side(name, ref)
        if not ref then return { root = repo, label = 'working tree' } end
        local dir = scratch .. '/' .. name
        local hash, why = unpack_ref(repo, ref, dir)
        if not hash then return nil, why end
        return { root = dir, label = ref, hash = hash }
    end
    local A, why = side('a', p.ref)
    if not A then v.error = why; vim.fn.delete(scratch, 'rf'); return v end
    local B, bwhy = side('b', p.ref_b)
    if not B then v.error = bwhy; vim.fn.delete(scratch, 'rf'); return v end
    v.a, v.b = { ref = A.label, hash = A.hash }, { ref = B.label, hash = B.hash }
    local mfile = scratch .. '/measure.lua'
    local fd = assert(io.open(mfile, 'w')); fd:write(p.measure or ''); fd:close()
    local limit = p.timeout and tonumber(p.timeout) * 1000 or 900000
    local function run(S, corpus, tag)
        local out, secs = scratch .. '/' .. tag .. '.out', scratch .. '/' .. tag .. '.secs'
        local wrapper = scratch .. '/' .. tag .. '-wrapper.lua'
        -- ★ A SIDE THAT IS NOT A CARTOGRAPH CHECKOUT (any Lua project — the optimize loop's world): this toolbelt runs
        -- it, with the side's own `lua/` and root FIRST on package.path, so the measure loads that side's modules
        local tb, prefix = S.root .. '/tools/toolbelt.lua', ''
        if vim.fn.filereadable(tb) == 0 then
            tb = repo_of_toolbelt() .. '/tools/toolbelt.lua'
            prefix = ('package.path = %q .. package.path\n'):format(S.root .. '/lua/?.lua;' .. S.root .. '/lua/?/init.lua;' .. S.root .. '/?.lua;')
        end
        local w = assert(io.open(wrapper, 'w')); w:write(prefix .. WRAPPER:format(mfile, out, secs)); w:close()
        local env = {}
        if p.warm ~= '1' then
            env.XDG_CACHE_HOME, env.XDG_STATE_HOME = scratch .. '/' .. tag .. '-cache', scratch .. '/' .. tag .. '-state'
        end
        local t0 = vim.uv.hrtime()
        local obj, err = SF.exec({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', tb, 'run', '@' .. wrapper, corpus },
            { cwd = S.root, env = env, timeout = limit })
        local wall = (vim.uv.hrtime() - t0) / 1e9
        if not obj then return nil, err end
        if obj.timed_out then return nil, ('%s timed out after %g s on %s (its process group killed)'):format(S.label, limit / 1000, corpus) end
        local f = io.open(out)
        if not f then
            return nil, ('%s produced no output on %s: %s'):format(S.label, corpus, ((obj.stderr or '') .. (obj.stdout or '')):sub(-400))
        end
        local text = f:read('a'); f:close()
        local sf = io.open(secs); local s = sf and tonumber(sf:read('a')); if sf then sf:close() end
        return { lines = lines_of(text), secs = s, wall = wall }
    end
    for i, corpus in ipairs(p.corpus or {}) do
        local a, aw = run(A, corpus, 'a' .. i)
        if not a then v.error = aw; break end
        local b, bw = run(B, corpus, 'b' .. i)
        if not b then v.error = bw; break end
        local la, lb = a.lines, b.lines
        if p.sorted == '1' then
            la, lb = vim.list_slice(la), vim.list_slice(lb)
            table.sort(la); table.sort(lb)
        end
        local first
        for k = 1, math.max(#la, #lb) do
            if la[k] ~= lb[k] then first = { line = k, a = la[k], b = lb[k] }; break end
        end
        v.runs[#v.runs + 1] = { corpus = corpus, equal = first == nil, first_difference = first,
            a = { lines = #a.lines, secs = a.secs, wall = a.wall }, b = { lines = #b.lines, secs = b.secs, wall = b.wall } }
    end
    if p.keep ~= '1' then vim.fn.delete(scratch, 'rf') else v.scratch = scratch end
    return v
end

local E = {
    name = 'ab-equivalence',
    kind = 'discovery',
    tags = { 'accept', 'repo', 'optimize' },
    measures = 'CART-1444',
    summary = 'does a code change keep a measurement\'s output? measure (Lua returning { measure = fn(store, p) -> string | lines }) run on each corpus by the code at ref (git archive: the tree is never touched) and by the working tree (or ref_b), each side in its own process and cache; sorted = 1 compares as sets; warm = 1 shares caches; timeout = seconds per side; faster = 1 also requires B to be faster (a performance change); a side that is not a cartograph checkout (any Lua project) is run by this toolbelt with its own lua/ first',
    params = { ref = 'string', ref_b = 'string?', measure = 'string', corpus = 'list', sorted = 'string?', warm = 'string?',
        timeout = 'string?', repo = 'string?', keep = 'string?', faster = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        if #v.runs == 0 then return false, 'no corpus was measured' end
        local parts = {}
        for _, r in ipairs(v.runs) do
            if not r.equal then
                local d = r.first_difference
                return false, ('%s: outputs DIFFER at line %d — A (%s): %s | B (%s): %s'):format(r.corpus, d.line, v.a.ref,
                    tostring(d.a):sub(1, 120), v.b.ref, tostring(d.b):sub(1, 120))
            end
            -- (faster = 1: the change is a PERFORMANCE change, and equal output alone does not accept it)
            if v.faster and not ((r.b.secs or math.huge) < (r.a.secs or 0)) then
                return false, ('%s: outputs equal, but B (%s) is not faster: A %.3fs / B %.3fs'):format(r.corpus, v.b.ref, r.a.secs or -1, r.b.secs or -1)
            end
            parts[#parts + 1] = ('%s: %d lines equal, A %.2fs / B %.2fs'):format(vim.fn.fnamemodify(r.corpus, ':t'), r.a.lines,
                r.a.secs or -1, r.b.secs or -1)
        end
        return true, table.concat(parts, '; ')
    end,
}

-- a measurement over the corpus a side extracted: its functions' names, sorted (stable across sides of one code)
local NAMES = [[
return { measure = function (store) local out = {}
    for _, n in ipairs(store.data.nodes) do if n.kind == 'function' then out[#out + 1] = n.name end end
    table.sort(out) return out end }
]]
-- a measurement that names its own SIDE's code location: the two sides always differ
local WHERE = [[
return { measure = function () return (debug.getinfo(require('cartograph.store').ingest, 'S').source) end }
]]
-- the same two lines, in an order that depends on the side (side A runs from the unpacked `…-ab/a` tree)
local ORDER = [[
return { measure = function ()
    local src = debug.getinfo(require('cartograph.store').ingest, 'S').source
    if src:find('-ab/a/', 1, true) then return { 'x', 'y' } end
    return { 'y', 'x' } end }
]]
local FILES = { ['m.lua'] = 'local M = {}\nfunction M.alpha() return 1 end\nlocal function beta() return 2 end\nreturn M\n' }
-- the examples read this checkout's git (side A is `git archive HEAD`): outside a git checkout they are SKIPPED, never
-- passed (mutation-check's copy carries a git repo of its own for exactly this)
local function in_git()
    local r = vim.system({ 'git', '-C', repo_of_toolbelt(), 'rev-parse', '--verify', 'HEAD' }, { text = true }):wait()
    return r.code == 0, 'not a git checkout: ' .. repo_of_toolbelt()
end

E.examples = {
    {
        name = 'HEAD against the working tree on a small corpus: the same function names on both sides',
        files = FILES, requires = in_git,
        params = function (store) return { ref = 'HEAD', measure = NAMES, corpus = { store.data.root }, timeout = '120' } end,
        expect = { holds = true, check = function (v) return v.runs[1] and v.runs[1].equal and v.runs[1].a.lines == 2, vim.inspect(v.runs) end },
    },
    {
        name = 'an output that depends on the side DIFFERS — and the first differing line is named',
        files = FILES, requires = in_git,
        params = function (store) return { ref = 'HEAD', measure = WHERE, corpus = { store.data.root }, timeout = '120' } end,
        expect = { holds = false, check = function (v)
            local d = v.runs[1] and v.runs[1].first_difference
            return d and d.a ~= d.b, vim.inspect(v.runs)
        end },
    },
    {
        name = 'sorted = 1 compares lines as SETS: the same lines in another order are equal; compared as written they differ',
        files = FILES, requires = in_git,
        params = function (store) return { ref = 'HEAD', measure = ORDER, corpus = { store.data.root }, sorted = '1', timeout = '120' } end,
        expect = { holds = true, check = function (v)
            local plain = measure(nil, { ref = 'HEAD', measure = ORDER, corpus = v.runs[1] and { v.runs[1].corpus } or {}, timeout = '120' })
            return v.runs[1].equal and plain.runs[1] and not plain.runs[1].equal, 'unsorted: ' .. vim.inspect(plain.runs)
        end },
    },
    {
        name = 'each side runs in its OWN cache home: one side\'s graph cache can never serve the other',
        files = FILES, requires = in_git,
        params = function (store)
            local mine = vim.fn.stdpath('cache')
            local src = ([[return { measure = function ()
                if vim.fn.stdpath('cache') ~= %q then return { 'isolated', 'cache' } end
                return { 'shared' } end }]]):format(mine)
            return { ref = 'HEAD', measure = src, corpus = { store.data.root }, timeout = '120' }
        end,
        expect = { holds = true, check = function (v)
            local r = v.runs[1]
            return r and r.a.lines == 2 and r.b.lines == 2, 'a side ran in the caller\'s cache home: ' .. vim.inspect(v.runs)
        end },
    },
    {
        name = 'a ref that is no commit is refused by name, before anything runs',
        files = FILES, requires = in_git,
        params = function (store) return { ref = 'no-such-ref-for-ab', measure = NAMES, corpus = { store.data.root } } end,
        expect = { holds = false, check = function (v) return (v.error or ''):find('no commit', 1, true) ~= nil, tostring(v.error) end },
    },
}

return E
