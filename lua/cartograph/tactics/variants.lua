-- VARIANTS (discovery, CART-1645): does an answer DEPEND on something it should not? Compute the same rows under
-- several VARIANTS — each in its OWN process — and diff them by key against the first. Promoted from six hand scripts
-- of 2026-10-10 (flowtype: three processes, four worklist orders, an unrelated file added, a bigger cap), where the
-- separate processes were the point: LuaJIT seeds its string hash per process, so an in-process A/B shares one seed
-- and agrees perfectly (arktype read 456 / 413 / 422 exact answers in three runs of one input).
-- params: decl (Lua SOURCE; `@file` reads one) returning a table — or function (params) -> table — of
--   variants = { v1, v2, ... }   any values; a table's `name` names it (else tostring). The FIRST is the baseline.
--   rows     = function (variant, params) -> { [key] = value | { value, flag = true } }   runs in the variant's process
--   claim    = 'same' (no row moves) | 'flagged' (a baseline row that moves — changes or disappears — is flagged
--              there; a row the baseline does not have made no claim)   default 'same'
--   control  = the name of a variant that MUST move — the check is live (a dead comparison calls everything stable)
--   repeat_  = N: the baseline computed in N processes (run-to-run determinism)   default 1
-- and root (the tree the rows are about), args (a list of `k=v`) and timeout (seconds per process, default 600):
-- decl / rows receive `params` = { root = root, k = v, ... }.
-- CLAIM: per `claim`, no violation in any variant but the control, and the control moved.
local function repo_of_toolbelt()
    local here = vim.fn.fnamemodify((debug.getinfo(1, 'S').source:gsub('^@', '')), ':p')
    return (here:gsub('/lua/cartograph/tactics/[^/]*$', ''))
end

-- the child: load the declaration, compute one variant's rows, write them as JSON
local RUNNER = [[
local declpath, idx, outpath, ppath = arg[1], tonumber(arg[2]), arg[3], arg[4]
local params = vim.json.decode(io.open(ppath):read('a'))
local d = assert(load(io.open(declpath):read('a'), 'variants-decl', 't'))()
if type(d) == 'function' then d = d(params) end
local rows = d.rows(d.variants[idx], params)
local out = {}
for k, v in pairs(rows) do
    if type(v) == 'table' then out[tostring(k)] = { a = tostring(v[1]), f = v.flag and true or false }
    else out[tostring(k)] = { a = tostring(v), f = false } end
end
local fd = assert(io.open(outpath, 'w')); fd:write(vim.json.encode(out)); fd:close()
]]

local function vname(v) return type(v) == 'table' and tostring(v.name) or tostring(v) end

local function measure(_, p)
    if not p.decl then return { error = 'variants: decl= is required (Lua source returning { variants, rows, claim })' } end
    local chunk, cerr = load(p.decl, 'variants-decl', 't')
    if not chunk then return { error = 'variants: the declaration does not load: ' .. tostring(cerr) } end
    local params = { root = p.root and vim.fn.fnamemodify(p.root, ':p'):gsub('/$', '') or nil }
    for _, kv in ipairs(p.args or {}) do
        local k, val = tostring(kv):match('^([%w_]+)=(.*)$')
        if not k then return { error = ('variants: args takes k=v, not `%s`'):format(tostring(kv)) } end
        params[k] = val
    end
    local okd, d = pcall(chunk)
    if okd and type(d) == 'function' then okd, d = pcall(d, params) end
    if not okd or type(d) ~= 'table' or type(d.variants) ~= 'table' or type(d.rows) ~= 'function' or #d.variants == 0 then
        return { error = 'variants: the declaration needs variants = { ... } and rows = function: ' .. tostring(d) }
    end
    local claim = d.claim or 'same'
    if claim ~= 'same' and claim ~= 'flagged' then return { error = "variants: claim is 'same' or 'flagged'" } end
    local dir = vim.fn.tempname() .. '-variants'
    vim.fn.mkdir(dir, 'p')
    local function put(name, text) local fd = assert(io.open(dir .. '/' .. name, 'w')); fd:write(text); fd:close(); return dir .. '/' .. name end
    local runner, declpath, ppath = put('runner.lua', RUNNER), put('decl.lua', p.decl), put('params.json', vim.json.encode(params))
    local repo, timeout = repo_of_toolbelt(), tonumber(p.timeout or 600) * 1000
    local function rows_of(idx, tag)
        local outp = dir .. '/rows-' .. tag .. '.json'
        local r = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '--cmd', 'set rtp^=' .. repo, '-l', runner,
            declpath, tostring(idx), outp, ppath }, { text = true, timeout = timeout }):wait()
        local fd = io.open(outp)
        if r.code ~= 0 or not fd then return nil, ('variant %s: the process failed (%s): %s'):format(tag, tostring(r.code), ((r.stderr or '') .. (r.stdout or '')):sub(1, 400)) end
        local s = fd:read('a'); fd:close()
        return vim.json.decode(s)
    end
    local base, berr = rows_of(1, vname(d.variants[1]) .. '#1')
    if not base then vim.fn.delete(dir, 'rf'); return { error = berr } end
    local nbase = 0
    for _ in pairs(base) do nbase = nbase + 1 end
    local v = { claim = claim, control = d.control, baseline = vname(d.variants[1]), rows = nbase, runs = {} }
    local runs = {}
    for r = 2, tonumber(d.repeat_ or 1) do runs[#runs + 1] = { idx = 1, name = vname(d.variants[1]) .. '#' .. r } end
    for i = 2, #d.variants do runs[#runs + 1] = { idx = i, name = vname(d.variants[i]) } end
    for _, run in ipairs(runs) do
        local rows, rerr = rows_of(run.idx, run.name)
        if not rows then vim.fn.delete(dir, 'rf'); return { error = rerr } end
        local moved, violations, ex = 0, 0, {}
        local keys = {}
        for k in pairs(base) do keys[k] = true end
        for k in pairs(rows) do keys[k] = true end
        for k in pairs(keys) do
            local a, b = base[k], rows[k]
            if not a or not b or a.a ~= b.a then
                moved = moved + 1
                -- (under `flagged` a row ABSENT from the baseline made no claim there: only a present, unflagged one is
                -- violated — by changing or by disappearing)
                local bad = claim == 'same' or (a ~= nil and not a.f)
                if bad then
                    violations = violations + 1
                    if #ex < 5 then ex[#ex + 1] = ('%s: %s -> %s'):format(k, a and a.a or 'absent', b and b.a or 'absent') end
                end
            end
        end
        v.runs[#v.runs + 1] = { name = run.name, moved = moved, violations = violations, examples = ex }
    end
    vim.fn.delete(dir, 'rf')
    return v
end

local function claim(v)
    if v.error then return false, v.error end
    local bad, ctl, parts = {}, nil, {}
    for _, r in ipairs(v.runs) do
        parts[#parts + 1] = ('%s moved %d (%d violating)'):format(r.name, r.moved, r.violations)
        if r.name == v.control then ctl = r
        elseif r.violations > 0 then bad[#bad + 1] = r.name .. ': ' .. table.concat(r.examples, '; ') end
    end
    local head = ('%d rows of %s; '):format(v.rows, v.baseline) .. table.concat(parts, ', ')
    if v.control and not ctl then return false, head .. ' — the control `' .. v.control .. '` is not a variant' end
    if ctl and ctl.moved == 0 then return false, head .. ' — the CONTROL did not move: this comparison cannot fail, so it shows nothing' end
    if #bad > 0 then return false, head .. ' — ' .. table.concat(bad, ' | ') end
    return true, head
end

local SAME = [[return { variants = { 'a', 'b', 'c' }, rows = function () return { x = 1, y = 'two' } end }]]
local MOVES = [[return { variants = { 'a', 'b' }, rows = function (v) return { x = 1, y = v == 'b' and 'other' or 'two' } end }]]
local FLAGGED = [[return { claim = 'flagged', variants = { 'a', 'b' },
    rows = function (v) return { x = 1, y = { v == 'b' and 'other' or 'two', flag = true } } end }]]
local UNFLAGGED = [[return { claim = 'flagged', variants = { 'a', 'b' },
    rows = function (v) return { x = v == 'b' and 9 or 1, y = { 'two', flag = true } } end }]]
local APPEARS = [[return { claim = 'flagged', variants = { 'a', 'b' },
    rows = function (v) local r = { x = 1 }; if v == 'b' then r.z = 'new' end; return r end }]]
local VANISHES = [[return { claim = 'flagged', variants = { 'a', 'b' },
    rows = function (v) local r = { x = 1 }; if v == 'a' then r.z = 'claim' end; return r end }]]
local LIVE = [[return { variants = { 'a', 'b', 'shuffled' }, control = 'shuffled',
    rows = function (v) return { x = 1, y = v == 'shuffled' and 'moved' or 'two' } end }]]
local DEAD = [[return { variants = { 'a', 'b', 'shuffled' }, control = 'shuffled', rows = function () return { x = 1 } end }]]
local PROCESS = [[return { variants = { 'set', 'read' }, rows = function (v)
    -- each variant in its OWN process: a global the first one sets is not there for the second
    if v == 'set' then _G.LEAK = 'leaked' end
    return { g = tostring(rawget(_G, 'LEAK') or 'clean') }
end }]]

return {
    name = 'variants',
    kind = 'discovery',
    tags = { 'gate', 'measure' },
    summary = 'compute the same rows under several variants, each in its own process, and diff them by key against the first: claim same (nothing moves) or flagged (what moves is flagged); a control variant must move; repeat_ = N recomputes the baseline in N processes',
    params = { decl = 'string', root = 'string?', args = 'list?', timeout = 'number?' },
    measure = measure,
    claim = claim,
    examples = {
        {
            name = 'rows that do not depend on the variant: nothing moves',
            params = { decl = SAME },
            expect = { holds = true },
        },
        {
            name = 'a row that depends on the variant: the claim fails and names it',
            params = { decl = MOVES },
            expect = { holds = false, check = function (v) return v.runs[1].violations == 1, vim.inspect(v.runs) end },
        },
        {
            name = 'claim flagged: a moving row flagged in the baseline is allowed, an unflagged one is not',
            params = { decl = FLAGGED },
            expect = { holds = true },
        },
        {
            name = 'claim flagged: an UNFLAGGED row that moves violates it',
            params = { decl = UNFLAGGED },
            expect = { holds = false },
        },
        {
            name = 'claim flagged: a row the baseline does not have made no claim — it may appear',
            params = { decl = APPEARS },
            expect = { holds = true },
        },
        {
            name = 'claim flagged: an unflagged baseline row that DISAPPEARS violates it',
            params = { decl = VANISHES },
            expect = { holds = false },
        },
        {
            name = 'a control that moves: the comparison is live, and the others still hold',
            params = { decl = LIVE },
            expect = { holds = true },
        },
        {
            name = 'a control that does NOT move: refused — the comparison could not have failed',
            params = { decl = DEAD },
            expect = { holds = false },
        },
        {
            name = 'each variant runs in its own process: a global the first sets is not there for the second (one process would say `leaked` twice)',
            params = { decl = PROCESS },
            expect = { holds = false, check = function (v)
                return v.runs[1].examples[1] == 'g: leaked -> clean', vim.inspect(v.runs)
            end },
        },
    },
}
