-- MUTANT (discovery, CART-1645): does a CHECK catch a mutation — when the check is not a spec but another DISCOVERY
-- (a `variants` comparison over a real corpus, an oracle score)? mutation-check asks a spec; the CART-1643 taint rules
-- were each NEEDED on arktype / lua/cartograph and pinned by no spec, so the plan that proves them refused on this
-- step by name. The mutation is EXACTLY the text given, at its one site (mutation-check's ground mode), in a scratch
-- copy of the repo (mutation-check's copy: its history readable, not writable); the discovery runs with `repo` = the
-- copy, so the processes it starts load the mutated code.
-- params: file, before, after (the mutation), use (the discovery's name — it must take `repo`), with (a list of
-- `k=v` params for it; a value `@path` reads that file), repo (default this cartograph), keep = 1 keeps the copy.
-- CLAIM: the discovery HOLDS on the unmutated copy (a check that already fails catches everything) and does NOT hold on
-- the mutant — the mutation is caught. A SURVIVOR is the claim failing, with both answers.
local MC = require 'cartograph.tactics.mutation-check'

local function repo_of_toolbelt()
    local here = vim.fn.fnamemodify((debug.getinfo(1, 'S').source:gsub('^@', '')), ':p')
    return (here:gsub('/lua/cartograph/tactics/[^/]*$', ''))
end

local function measure(store, p)
    local tb = require 'cartograph.toolbelt'
    local e, lwhy = tb.load(p.use)
    if not e then return { error = 'mutant: ' .. tostring(lwhy) } end
    if e.kind ~= 'discovery' then return { error = ('mutant: `%s` is a %s, not a discovery'):format(p.use, tostring(e.kind)) } end
    if not (e.params or {}).repo then return { error = ('mutant: `%s` takes no `repo`, so it cannot be pointed at the mutated copy'):format(p.use) } end
    local raw = {}
    for _, kv in ipairs(p.with or {}) do
        local k, val = tostring(kv):match('^([%w_]+)=(.*)$')
        if not k then return { error = ('mutant: with takes k=v, not `%s`'):format(tostring(kv)) } end
        if val:sub(1, 1) == '@' then
            local fd = io.open(val:sub(2)); if not fd then return { error = 'mutant: cannot read ' .. val } end
            val = fd:read('a'); fd:close()
        end
        raw[k] = val
    end
    local repo = p.repo or repo_of_toolbelt()
    local root, why = MC.scratch_copy(repo, p.keep)
    if not root then return { error = 'mutant: ' .. tostring(why) } end
    local v = { use = p.use, file = p.file }
    local function done() if not p.keep then vim.fn.delete(root, 'rf') else v.scratch = root end return v end
    local function ask()
        raw.repo = root
        local q, qwhy = tb.coerce(store, e, raw)
        if not q then return nil, qwhy end
        local okm, value = pcall(e.measure, store, q)
        if not okm then return nil, 'the discovery raised: ' .. tostring(value) end
        local holds, cwhy = e.claim(value)
        return { holds = holds and true or false, why = cwhy }
    end
    local base, bwhy = ask()
    if not base then v.error = 'baseline: ' .. tostring(bwhy); return done() end
    v.baseline = base
    if not base.holds then v.error = 'the BASELINE does not hold (' .. tostring(base.why) .. '): a failing check catches every mutation'; return done() end
    local E = require 'cartograph.edit'
    local path = root .. '/' .. p.file
    local fd = io.open(path, 'rb'); local text = fd and fd:read('a'); if fd then fd:close() end
    if not text then v.error = 'no file ' .. p.file .. ' in the copy'; return done() end
    local state, cwhy = E.classify(text, p.before, p.after)
    if state ~= 'pending' then v.error = 'the mutation did not APPLY: ' .. tostring(cwhy or state); return done() end
    local out = assert(io.open(path, 'wb')); out:write(E.apply_to(text, p.before, p.after)); out:close()
    local mut, mwhy = ask()
    if not mut then v.error = 'mutant: ' .. tostring(mwhy); return done() end
    v.mutated = mut
    v.caught = not mut.holds
    return done()
end

local MOD = 'return { val = function (v) return 1 end }\n'
local REDDECL = [[return function () return { variants = { 'a', 'b' },
    rows = function (v) return { x = v } end } end]]
local DECL = [[return function (params) return { variants = { 'a', 'b' },
    rows = function (v) return { x = require('zzmod').val(v) } end } end]]

return {
    name = 'mutant',
    kind = 'discovery',
    tags = { 'gate', 'test' },
    summary = 'does a DISCOVERY catch a mutation? file, before/after = the mutation (exact text, one site), use = the discovery (it must take repo), with = k=v params for it (@path reads a file); runs it on a scratch copy before and after the mutation — the baseline must hold, the mutant must not',
    params = { file = 'string', before = 'string', after = 'string', use = 'string', with = 'list?', repo = 'string?', keep = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        if v.caught then return true, ('CAUGHT by %s: baseline %s; mutant %s'):format(v.use, tostring(v.baseline.why), tostring(v.mutated.why)) end
        return false, ('SURVIVED %s: the mutant still holds — %s'):format(v.use, tostring(v.mutated.why))
    end,
    examples = {
        {
            name = 'a mutation that makes the rows depend on the variant: `variants` catches it',
            files = { ['lua/zzmod.lua'] = MOD },
            params = function (store) return { file = 'lua/zzmod.lua', before = 'return 1 end', after = "return v == 'b' and 2 or 1 end",
                use = 'variants', with = { 'decl=' .. DECL }, repo = store.data.root } end,
            expect = { holds = true },
        },
        {
            name = 'a mutation the check cannot see: it SURVIVES, and says so',
            files = { ['lua/zzmod.lua'] = MOD },
            params = function (store) return { file = 'lua/zzmod.lua', before = 'return 1 end', after = 'return 0 + 1 end',
                use = 'variants', with = { 'decl=' .. DECL }, repo = store.data.root } end,
            expect = { holds = false },
        },
        {
            name = 'a check that already FAILS unmutated: refused — it would call every mutation caught',
            files = { ['lua/zzmod.lua'] = MOD },
            params = function (store) return { file = 'lua/zzmod.lua', before = 'return 1 end', after = 'return 2 end',
                use = 'variants', with = { 'decl=' .. REDDECL }, repo = store.data.root } end,
            expect = { holds = false, check = function (v) return tostring(v.error):find('BASELINE does not hold', 1, true) ~= nil, tostring(v.error) end },
        },
        {
            name = 'a mutation whose text is not in the file: refused — it did not apply',
            files = { ['lua/zzmod.lua'] = MOD },
            params = function (store) return { file = 'lua/zzmod.lua', before = 'return 7 end', after = 'return 8 end',
                use = 'variants', with = { 'decl=' .. DECL }, repo = store.data.root } end,
            expect = { holds = false, check = function (v) return tostring(v.error):find('did not APPLY', 1, true) ~= nil, tostring(v.error) end },
        },
    },
}
