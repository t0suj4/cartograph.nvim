-- L2 environment profile: FACTORIO's Lua ([[cartograph-stdlib-profile]] P2).
-- Factorio embeds Lua 5.2 with a SUBTRACTIVE+ADDITIVE surface — the archetype
-- the layering design wanted (additive AND subtractive, version-keyed). Unlike
-- zig-std (distilled from source), there is no local Factorio source to extract,
-- so this is HAND-AUTHORED from the documented environment; it stays a reviewable
-- Lua module (the loader accepts .lua profiles alongside distilled .mpack).
--
-- Measured ROI (2026-07-19, factorio corpus, 9763 non-ambiguous unresolved
-- calls): bare Lua-stdlib 32.5% + Factorio globals 13.2% = ~46% NEW soundly-
-- external, + ~25% namespace refinement — all WITHOUT receiver typing, because
-- these calls are global-rooted or bare-stdlib. Contrast zig-std's 1.2%
-- (compiler = bare local-typed receivers). This is the honesty lever, keyed.
--
-- Faces: (a) the flat `free`/`namespaces` projections feed the L2 vocab/prefix
-- gate NOW (a rooted-or-bare call becomes stdlib-tier external); (b) `types`
-- (members) seed the future type-precise + LSP/band face once API receivers are
-- typed. ret/full-API-member enumeration deferred (needs runtime-api.json).

-- space-separated member list → { name = {} } set (ret unread in v1 = honest)
local function kw(s) local t = {}; for w in s:gmatch('%S+') do t[w] = {} end; return t end

-- Lua 5.2 base GLOBALS Factorio keeps (bare, callable without a namespace).
-- SUBTRACTED by Factorio: dofile, loadfile, module, io/os as free (os is a
-- restricted namespace, io removed) — deliberately absent so a `dofile(...)`
-- call stays honestly unresolved, not falsely blessed as stdlib.
local FREE = {
    'assert', 'collectgarbage', 'error', 'getmetatable', 'ipairs', 'next',
    'pairs', 'pcall', 'print', 'rawequal', 'rawget', 'rawlen', 'rawset',
    'select', 'setmetatable', 'tonumber', 'tostring', 'type', 'unpack', 'xpcall',
    'require', 'load', 'loadstring',
    -- Factorio ADDITIONS to the base environment
    'log', 'table_size', 'localised_print', 'localized_print',
}

-- namespace → the members Factorio exposes. For the prefix gate only the KEY
-- (namespace root) matters; members give the future type-precise/LSP face.
-- Lua 5.2 stdlib namespaces (Factorio keeps string/table/math/coroutine/debug/
-- bit32; os is a RESTRICTED subset; io/package are removed → not present).
local TYPES = {
    string = { members = kw('byte char dump find format gmatch gsub len lower match rep reverse sub upper') },
    table  = { members = kw('concat insert remove sort pack unpack') },
    math   = { members = kw('abs acos asin atan atan2 ceil cos cosh deg exp floor fmod frexp ldexp log log10 max min modf pow rad random randomseed sin sinh sqrt tan tanh huge pi maxinteger mininteger') },
    os     = { members = kw('clock date difftime time') }, -- Factorio-restricted
    coroutine = { members = kw('create isyieldable resume running status wrap yield') },
    debug  = { members = kw('getinfo traceback') },
    bit32  = { members = kw('arshift band bnot bor btest bxor extract lrotate lshift replace rrotate rshift') },
    -- Factorio LIBRARY namespaces shipped in __core__/lualib
    serpent = { members = kw('block line dump load') },
    util    = { members = kw('table by_pixel by_pixel_hr distance moveposition direction_to positiontostr formattime') },
    -- Factorio RUNTIME GLOBALS (single-instance API objects). Enumerating every
    -- member needs runtime-api.json; as PREFIX namespaces they already gate all
    -- `<global>.member()` calls to external. A few hot members seeded for later.
    game        = { members = kw('print players surfaces forces tick create_surface get_player') },
    script      = { members = kw('on_event on_init on_load on_configuration_changed on_nth_tick generate_event_name raise_event register_metatable') },
    defines     = { members = {} }, -- a nested constant tree (defines.direction.north): prefix-only
    rendering   = { members = {} },
    settings    = { members = {} },
    prototypes  = { members = {} },
    data        = { members = kw('extend') }, -- data stage (data.lua)
    remote      = { members = kw('call add_interface remove_interface') },
    commands    = { members = kw('add_command remove_command') },
    rcon        = { members = kw('print') },
    helpers     = { members = kw('table_to_json json_to_table') },
    storage     = { members = {} }, -- the mod's persisted table (2.0; was `global`)
}

-- derived flat projections (built once at load): the vocab gate + prefix set.
local free, namespaces, nsset, vocab = {}, {}, {}, {}
for _, n in ipairs(FREE) do free[n] = {}; vocab[n] = true end
for T, t in pairs(TYPES) do
    namespaces[#namespaces + 1] = T
    nsset[T] = true
    for m in pairs(t.members) do vocab[m] = true end
end

return {
    schema = 1, runtime = 'lua-factorio', lang = 'lua', version = '2.0',
    stamp = 'hand-authored',
    types = TYPES, free = free, namespaces = namespaces, nsset = nsset,
    vocab = vocab,
}
