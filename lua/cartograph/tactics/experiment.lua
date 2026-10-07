-- EXPERIMENT (discovery, CART-1537): run a DECLARED experiment — a variant, a baseline worktree, instruments, a decision
-- (cartograph.experiment). `decl` is Lua SOURCE returning the declaration (`@file` reads one; the repo's batteries live
-- in tools/experiments/). Each instrument runs as its own process with its cwd in the tree it measures (the trees hold
-- different code); the baseline is a scratch `git worktree` at the declared ref, removed afterwards.
-- params: decl (required), root (default: the repo this toolbelt runs from), timeout (seconds per process, default 3000).
-- CLAIM: the experiment ACCEPTS — every instrument passed.
local X = require 'cartograph.experiment'

local function repo_of_toolbelt()
    local src = debug.getinfo(1, 'S').source:gsub('^@', '')
    return (vim.fn.fnamemodify(src, ':p:h:h:h:h'))
end

local function measure(_, p)
    if not p.decl then return { error = 'experiment: decl= is required (Lua source returning the declaration; @file reads one)' } end
    local chunk, cerr = load(p.decl, 'experiment-decl', 't')
    if not chunk then return { error = 'experiment: the declaration does not load: ' .. tostring(cerr) } end
    local okd, decl = pcall(chunk)
    if not okd or type(decl) ~= 'table' then return { error = 'experiment: the declaration is no table: ' .. tostring(decl) } end
    local root = p.root or repo_of_toolbelt()
    local timeout = tonumber(p.timeout or 3000) * 1000
    local scratch = vim.fn.stdpath('cache') .. '/cartograph-experiment'
    vim.fn.mkdir(scratch, 'p')
    local env = {
        root = root,
        exec = function (dir, argv, vars)
            local e = { GIT_INDEX_FILE = '', GIT_DIR = '', GIT_WORK_TREE = '' } -- (CART-1530: a tree is its own repository)
            for k, v in pairs(vars or {}) do e[k] = v end
            local r = vim.system(argv, { cwd = dir, env = e, text = true, timeout = timeout }):wait()
            return (r.stdout or '') .. (r.stderr or ''), r.code
        end,
        worktree = function (ref)
            local dir = ('%s/%s-%d-%d'):format(scratch, (tostring(ref):gsub('[^%w]', '_')), vim.uv.os_getpid(), vim.uv.hrtime() % 1e9)
            local r = vim.system({ 'git', '-C', root, 'worktree', 'add', '-q', '--detach', dir, ref }, { text = true }):wait()
            if r.code ~= 0 then error('experiment: no worktree at ' .. tostring(ref) .. ': ' .. tostring(r.stderr), 0) end
            return dir
        end,
        drop = function (dir) vim.system({ 'git', '-C', root, 'worktree', 'remove', '--force', dir }):wait() end,
    }
    local ok, res = pcall(X.run, decl, env)
    if not ok then return { error = tostring(res) } end
    return res
end

local E = {
    name = 'experiment',
    kind = 'discovery',
    tags = { 'accept', 'experiment', 'wind-tunnel' },
    measures = 'CART-1537',
    summary = 'run a DECLARED experiment (decl = @file: a variant, a baseline worktree, instruments — tactic / specs / join / ab — and accept-if-all-pass); the repo\'s batteries live in tools/experiments/',
    params = { decl = 'string', root = 'string?', timeout = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        local parts, bad = {}, nil
        for _, r in ipairs(v.rows or {}) do
            parts[#parts + 1] = ('%s %s'):format(r.pass and 'ok' or 'FAIL', r.name)
            if not r.pass and not bad then bad = r.name .. ': ' .. tostring(r.detail) end
        end
        local head = ('%s: %s'):format(tostring(v.name), table.concat(parts, ', '))
        if not v.accept then return false, head .. (bad and (' — first: ' .. bad) or ' — no instrument ran') end
        return true, head
    end,
}

E.examples = {
    {
        name = 'a declaration whose instruments pass ACCEPTS (no baseline: a tactic instrument, run as its own process)',
        files = { ['decl.lua'] = "return { name = 'tiny', instruments = { { name = 'catalog', kind = 'tactic', tactic = 'derive-accept', params = { ops = 'no_such_op' }, expect = 'fails' } } }" },
        params = function (store) return { decl = io.open(store.data.root .. '/decl.lua'):read('a') } end,
        expect = { holds = true, check = function (v) return v.accept and #v.rows == 1 and v.rows[1].pass, vim.inspect(v) end },
    },
    {
        name = 'an instrument that fails REJECTS, naming it',
        files = { ['decl.lua'] = "return { name = 'tiny', instruments = { { name = 'wants-holds', kind = 'tactic', tactic = 'derive-accept', params = { ops = 'no_such_op' } } } }" },
        params = function (store) return { decl = io.open(store.data.root .. '/decl.lua'):read('a') } end,
        expect = { holds = false, check = function (v) return v.accept == false and v.rows[1].pass == false and tostring(v.rows[1].detail):find('no derivation', 1, true) ~= nil, vim.inspect(v) end },
    },
}

return E
