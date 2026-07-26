-- L2 environment profile: FACTORIO 1.1 — the PREVIOUS environment, so a port can be
-- expressed as a DIFF rather than as an absence.
--
-- WHY THIS EXISTS. Scoring code against one profile can only say "the target does not
-- hold this name", which is weak: it cannot tell a name the target REMOVED from a
-- name the artifact never modelled. With both ends present, portability.diff reports
-- STATUS CHANGES — `game.entity_prototypes` was in 1.1 and is gone in 2.0 — and a
-- change is evidence in a way an absence is not.
--
-- MEASURED, 1.1.110 vs 2.0.72: api_version 5 vs 6, 97 classes vs 148, 7 global
-- objects vs 9 (2.0 adds `helpers` and `prototypes`), and LuaGameScript alone went
-- from 133 members to 74. `entity_prototypes`, `item_prototypes` and `active_mods`
-- are all present here and absent there — the three the read surface flagged on the
-- Von Neumann mod.
--
-- EXPRESSED AS A DELTA, not a copy. The Lua-5.2 half of the environment is identical
-- between the two, so it is reused from the 2.0 module rather than duplicated; what
-- this file states is exactly what CHANGED. A second hand-maintained copy of the
-- stdlib surface would drift, and the drift would look like a version difference.

local base = require 'cartograph.spec.profile.lua-factorio'

-- ── the 1.1 → 2.0 environment delta, as data ─────────────────────────────────
-- `global` was the mod's persisted table in 1.1; 2.0 renamed it to `storage`. That
-- single rename is the largest mechanical item in any 1.1 → 2.0 port (44 reads on the
-- Von Neumann mod), and it is visible ONLY because both ends are named.
local ADDED_IN_2_0 = { storage = true, helpers = true, prototypes = true }
local ONLY_IN_1_1 = { global = true }

local function copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

local types, nsset, namespaces, vocab = copy(base.types), {}, {}, copy(base.vocab)
for name in pairs(ADDED_IN_2_0) do types[name] = nil end
for name in pairs(ONLY_IN_1_1) do types[name] = types[name] or { members = {} } end
for T, t in pairs(types) do
    nsset[T] = true
    namespaces[#namespaces + 1] = T
    for m in pairs(t.members or {}) do vocab[m] = true end
end
table.sort(namespaces)

-- the api artifact for THIS version (tools/factoriodistill.lua <api.json> 11)
-- NB the artifact and this module are named `-11`, not `-1.1`: a Lua module name is
-- a PATH, so a dot in it makes require look for `lua-factorio-1/1.lua`. The profile
-- loader tries require BEFORE its .mpack fallback, so a dotted name silently loads
-- nothing at all — which is how the first version of this file returned nil.
local api = require('cartograph.spec.profile').load('lua-factorio-api-11')
local mint_path, sigs, api_g2c, api_members, api_complete, api_version
if api and api.global2class and api.members then
    local g2c, members, free_fns = api.global2class, api.members, api.free or {}
    api_version = api.version
    api_g2c, api_members, api_complete = g2c, members, api.complete
    sigs = {}
    for k, v in pairs(api.sigs or {}) do sigs[k] = v end
    for k, v in pairs(api.free_sigs or {}) do sigs[k] = v end
    mint_path = function (callee, full, why)
        if why ~= 'stdlib' then return nil end
        if full then
            local recv, m = full:match('^([%w_]+)%.([%w_]+)$')
            if recv and g2c[recv] and members[g2c[recv] .. '::' .. m] then
                return g2c[recv] .. '::' .. m
            end
            if full:find('%.') then return nil end
        end
        if free_fns[callee] then return callee end
        return nil
    end
end

return {
    schema = 1, runtime = 'lua-factorio-11', lang = 'lua',
    version = api_version or '1.1', stamp = 'hand-authored delta over lua-factorio',
    types = types, free = copy(base.free), namespaces = namespaces, nsset = nsset,
    vocab = vocab,
    mint = api ~= nil, mint_path = mint_path, sigs = sigs,
    sig_kind = api and 'factorio' or nil,
    global2class = api_g2c, api_members = api_members, api_complete = api_complete,
}
