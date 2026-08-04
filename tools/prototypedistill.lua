-- prototypedistill — distill Factorio's prototype-api.json into an L2 artifact for
-- the DATA stage ([[cartograph-stdlib-profile]] input adapter; the sibling of
-- tools/factoriodistill.lua, which does the RUNTIME stage). Factorio publishes two
-- declared API exports per version and we only read one; this reads the other.
--
--   nvim --headless -u NONE -l tools/prototypedistill.lua <prototype-api.json> [<suffix>]
-- No network, no graph mutation — pure metadata → a version-keyed .mpack artifact.
--
-- ── WHY THIS IS AN INGREDIENT AND NOT A PORTABILITY TARGET ───────────────────
-- portability.provides adjudicates DOTTED names (`game.print`). The data stage is
-- not addressable that way, for two independent reasons, both measured on the
-- Von-Neumann corpus before this file was written:
--
--   (1) PROTOTYPE TYPENAMES ARE HYPHENATED. `assembling-machine`,
--       `utility-constants`, `electric-energy-interface`, `gui-style`,
--       `autoplace-control` — none is a valid Lua identifier, so mod code can only
--       write `data.raw["assembling-machine"]`. A dotted `data.raw.<typename>` is
--       reachable ONLY for the minority of single-word typenames (item, ammo, lab,
--       recipe). Measured: the whole mod yields 3 dotted data-stage reads
--       (data.raw, data.raw.ammo, data.raw.item) against 68 textual data.raw uses.
--   (2) PROPERTIES ARE TABLE KEYS, not members of a receiver. They appear inside
--       `data:extend{{ type="accumulator", charge_animation=… }}`, so no dotted
--       name exists to adjudicate even in principle.
--
-- Emitting this as a `provides`-shaped profile would therefore adjudicate ~3 names
-- and read as coverage. So it is marked `ingredient = true` and carries the surface
-- the two checks that CAN use it need:
--   · a STRING-SUBSCRIPT check — the literal in `data.raw[<str>]` is a typename, so
--     `typenames` is its answer key ([[cartograph-typed-strings]]: a string used as a
--     data.raw key is typename-typed).
--   · a TABLE-LITERAL KEY check — validate the keys of a `data:extend` constructor
--     against the property set of the prototype named by its own `type=` field. This
--     is where a rename like charge_animation -> chargable_graphics is caught, and it
--     is the real data-stage lint.
--
-- PROPERTIES ARE INHERITED. Each prototype declares `parent`, and a child's usable
-- property set is its own ∪ its ancestors'. We store OWN properties plus the parent
-- edge rather than a flattened set, so a consumer can flatten (and so a diff can
-- attribute a change to the prototype that actually declares it, not to every
-- descendant that inherits it).

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/prototypedistill%.lua$')
package.path = here .. '/../lua/?.lua;' .. here .. '/../lua/?/init.lua;' .. package.path

local API = arg and arg[1]
if not API then
    io.write('usage: nvim --headless -u NONE -l tools/prototypedistill.lua'
        .. ' <prototype-api.json> [<suffix>]\n')
    os.exit(2)
end
local SUFFIX = (arg and arg[2]) or ''
local RUNTIME = 'lua-factorio-proto' .. (SUFFIX ~= '' and ('-' .. SUFFIX) or '')
if vim.fn.filereadable(API) ~= 1 then
    io.write('no prototype-api.json at ' .. API .. '\n'); os.exit(2)
end
local fd = assert(io.open(API, 'r'))
local api = vim.json.decode(fd:read('*a')); fd:close()
if api.stage ~= 'prototype' then
    io.write(('refusing: %s declares stage=%q, expected "prototype" (runtime-api.json'
        .. ' is tools/factoriodistill.lua\'s input)\n'):format(API, tostring(api.stage)))
    os.exit(2)
end

-- typename -> PrototypeName. THE data.raw KEY SET: `data.raw[<typename>]`. Abstract
-- prototypes have no typename (they exist only to be inherited from) and correctly
-- do not appear here — data.raw has no key for them.
local typenames, protos, own_props, parent, n_props = {}, {}, {}, {}, 0
for _, p in ipairs(api.prototypes or {}) do
    protos[p.name] = true
    if p.typename then typenames[p.typename] = p.name end
    if p.parent then parent[p.name] = p.parent end
    for _, pr in ipairs(p.properties or {}) do
        own_props[p.name .. '::' .. pr.name] = pr.optional and 'optional' or 'required'
        n_props = n_props + 1
    end
end
-- the CONCEPT types (EnergySource, ItemProductPrototype, …). Not addressable from mod
-- code at all — a mod writes a table that must SATISFY one — so they are recorded for
-- a future shape-checking consumer and deliberately not part of any name surface.
local concept = {}
for _, t in ipairs(api.types or {}) do concept[t.name] = true end

local profile = {
    schema = 1, runtime = RUNTIME, lang = 'lua', stage = 'prototype',
    -- INGREDIENT for the NAME surface — see the header — and READ AS EXACTLY THAT: it
    -- means "no bare/dotted name lives here", NOT "never a target". This artifact IS
    -- the target of the data-stage diff, so portability.targets() offers it and
    -- portability.target_kinds() classes it `data`, while spec.profile.env_usable
    -- refuses it as an extraction environment. The marker is one question of two, and
    -- filtering the target list ON IT would have dropped this file (CART-0209).
    ingredient = true,
    version = api.application_version, api_version = api.api_version,
    stamp = { source = API, application_version = api.application_version,
        api_version = api.api_version, stage = api.stage },
    typenames = typenames,      -- typename -> PrototypeName  (the data.raw key set)
    prototypes = protos,        -- PrototypeName -> true
    own_props = own_props,      -- "Proto::prop" -> "required"|"optional"  (OWN only)
    parent = parent,            -- PrototypeName -> parent PrototypeName
    concept_types = concept,    -- concept type names, for a future shape checker
}

local out = here .. '/../lua/cartograph/spec/profile/' .. RUNTIME .. '.mpack'
local tmp = out .. '.tmp.' .. vim.fn.getpid()
local wf = assert(io.open(tmp, 'wb'))
wf:write(vim.mpack.encode(profile)); wf:close()
assert(os.rename(tmp, out))

local n_types, n_proto = 0, 0
for _ in pairs(typenames) do n_types = n_types + 1 end
for _ in pairs(protos) do n_proto = n_proto + 1 end
io.write('=== prototypedistill ===\n')
io.write(('  prototype-api %s (api v%s, %s) — %d prototypes, %d concept types\n'):format(
    api.application_version, api.api_version, api.stage, #(api.prototypes or {}),
    #(api.types or {})))
io.write(('  data.raw keys (typenames): %d ; prototypes: %d ; own properties: %d\n')
    :format(n_types, n_proto, n_props))
io.write(('  INGREDIENT — not a portability target (typenames are hyphenated,'
    .. ' properties are table keys; see the header)\n'))
io.write('  wrote ' .. out .. '\n')
