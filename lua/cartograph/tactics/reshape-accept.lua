-- RESHAPE-ACCEPT (discovery, CART-1656): does a provenance reshape keep the tests green? The reshape (rename-field by
-- family, or reshape) is planned and written in a SCRATCH COPY of the repo — never the working tree — and the spec runs
-- there before and after. The acceptance test the provenance claim needs: the analysis proves the rewrite covers every
-- access IT sees; the tests are the independent oracle for the ones it cannot (code built by load(), a C caller).
-- Measured by hand first (2026-10-11): `txn.disk_stamp` (50 rewrites in 33 files) and the tactic result's `applied`
-- (33 in 14 files, the examples' own `want.applied` untouched) — the whole suite green both times.
-- params: verb = rename-field | reshape, with = its k=v arguments (family / positional / define take a comma list),
-- spec = the spec filter (empty: the whole suite), repo (default this cartograph), keep = 1, timeout = seconds per run.
-- CLAIM: the baseline is green, the reshape is planned (a refusal or a decision is no acceptance), and the spec is green
-- after it.
local SF = require 'cartograph.tactics.spec-fails'
local MC = require 'cartograph.tactics.mutation-check'

local LISTS = { family = true, positional = true, define = true }

local function repo_of_toolbelt()
    local here = vim.fn.fnamemodify((debug.getinfo(1, 'S').source:gsub('^@', '')), ':p')
    return (here:gsub('/lua/cartograph/tactics/[^/]*$', ''))
end

local function measure(_, p)
    local repo = p.repo or repo_of_toolbelt()
    local v = { verb = p.verb, spec = p.spec or '' }
    if p.verb ~= 'rename-field' and p.verb ~= 'reshape' then v.error = 'verb is rename-field or reshape'; return v end
    local args, last = {}, nil
    for _, kv in ipairs(p.with or {}) do
        local k, val = tostring(kv):match('^([%w_]+)=(.*)$')
        if k then
            last = k
            if LISTS[k] then args[k] = args[k] or {}; for item in val:gmatch('[^,]+') do args[k][#args[k] + 1] = item end
            else args[k] = val end
        elseif last and LISTS[last] then
            -- (an item without `=` CONTINUES the list before it: the param list is split at commas)
            args[last][#args[last] + 1] = tostring(kv)
        else
            v.error = ('with takes k=v, not `%s`'):format(tostring(kv)); return v
        end
    end
    local root, why = MC.scratch_copy(repo, p.keep)
    if not root then v.error = why; return v end
    v.scratch = root
    local function done() if not p.keep then vim.fn.delete(root, 'rf'); v.scratch = nil end return v end
    local limit = p.timeout and tonumber(p.timeout) * 1000 or nil
    local spec = (p.spec and p.spec ~= '') and p.spec or nil
    local base, bwhy = SF.run(root, spec, limit)
    if not base then v.error = 'baseline: ' .. tostring(bwhy); return done() end
    v.baseline = base
    if base.ran == 0 then v.error = ('the spec RAN NOTHING (%s)'):format(base.summary); return done() end
    if base.failed > 0 then v.error = ('the BASELINE is red (%s): nothing to accept against'):format(base.summary); return done() end
    -- the reshape, planned against the COPY's own graph and written into it (a throwaway world keeps no journal)
    local store = require 'cartograph.store'
    local plan, pwhy, pclass = store.scoped(require('cartograph.providers.treesitter').extract(root), function ()
        return require('cartograph.compose').VERBS[p.verb].plan(store, args)
    end)
    if not plan then v.error = ('the reshape was not planned (%s): %s'):format(tostring(pclass), tostring(pwhy)); v.class = pclass; return done() end
    v.touched = plan.touched
    for rel, text in pairs(plan.edits or {}) do
        local fd = assert(io.open(root .. '/' .. rel, 'wb')); fd:write(text); fd:close()
    end
    v.desc = plan.desc
    local after, awhy = SF.run(root, spec, limit)
    if not after then v.error = 'after: ' .. tostring(awhy); return done() end
    v.after = after
    return done()
end

local FX = {
    ['rec.lua'] = 'local M = {}\nfunction M.mk(n) return { name = n } end\nfunction M.label(r) return r.name end\nreturn M\n',
    ['tests/run.sh'] = SF.FIXTURE['tests/run.sh'],
    ['tests/mini.lua'] = SF.FIXTURE['tests/mini.lua']:gsub("'lib/%?%.lua;'", "'./?.lua;'"),
    ['tests/rec_spec.lua'] = "local check = ...\nlocal R = require('rec')\ncheck(R.label(R.mk('a')) == 'a')\n",
    -- (code the analysis cannot see: a function built by load() reads the field by its old name)
    ['tests/load_spec.lua'] = "local check = ...\nlocal R = require('rec')\nlocal get = load('return function (r) return r.name end')()\ncheck(get(R.mk('a')) == 'a')\n",
}

return {
    name = 'reshape-accept',
    kind = 'discovery',
    tags = { 'gate', 'test', 'code' },
    summary = 'does a provenance reshape keep the tests green? verb = rename-field | reshape, with = its k=v arguments (family / positional / define: comma lists), spec = the spec filter (empty: the whole suite); planned and written in a SCRATCH COPY of repo (default this cartograph), the spec run before and after — the independent oracle for accesses the analysis cannot see',
    params = { verb = 'string', with = 'list', spec = 'string?', repo = 'string?', keep = 'string?', timeout = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        if v.after.failed > 0 then
            return false, ('the reshape BROKE the spec: %s -> %s (%s) — an access the analysis did not see: %s'):format(v.baseline.summary,
                v.after.summary, tostring(v.desc), table.concat(v.after.failures or {}, ', '))
        end
        return true, ('accepted: %s; %s stays green (%s)'):format(tostring(v.desc), v.spec ~= '' and v.spec or 'the suite', v.after.summary)
    end,
    examples = {
        {
            name = 'a rename by provenance the spec exercises: accepted, the spec green before and after',
            files = FX,
            params = function (store) return { verb = 'rename-field', with = { 'family=rec.lua:2', 'field=name', 'to=title' }, spec = 'rec_spec', repo = store.data.root } end,
            expect = { holds = true, check = function (v) return v.after and v.after.failed == 0 and v.scratch == nil and (v.touched or {})[1] == 'rec.lua', vim.inspect(v.touched) end },
        },
        {
            name = 'code built by load() reads the field by its old name — invisible to the analysis — and the spec CATCHES it',
            files = FX,
            params = function (store) return { verb = 'rename-field', with = { 'family=rec.lua:2', 'field=name', 'to=title' }, spec = 'load_spec', repo = store.data.root } end,
            expect = { holds = false, check = function (v) return v.after and v.after.failed > 0, tostring(v.error) end },
        },
        {
            name = 'a reshape the planner refuses is no acceptance — refused by name',
            files = FX,
            params = function (store) return { verb = 'rename-field', with = { 'family=rec.lua:9', 'field=name', 'to=title' }, spec = 'rec_spec', repo = store.data.root } end,
            expect = { holds = false, check = function (v) return tostring(v.error):find('not planned', 1, true) ~= nil, tostring(v.error) end },
        },
    },
}
