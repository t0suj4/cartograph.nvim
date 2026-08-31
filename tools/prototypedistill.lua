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
-- WHERE THE DOCUMENT CAME FROM, for the stamp. apifetch passes the resolved URL; a
-- hand run leaves it nil and the stamp then records only the path it was given, which
-- is the honest state — "we know where this file was, not where it came from".
local ORIGIN = (arg and arg[3]) or nil
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
-- code at all — a mod writes a table that must SATISFY one — so they are recorded
-- here and deliberately not part of any name surface.
--
-- ★ AND THEIR PROPERTIES, WHICH IS THE HALF THAT WAS MISSING (CART-0633). Recording
-- only the NAMES made the data-stage diff one level deep: a mod writes
-- `working_sound = {…}` (a WorkingSound) or `animation = {layers = {{hr_version =
-- …}}}` (an Animation), and no property inside either could be checked against
-- anything. 2.0 removed `hr_version` from all 7 sprite/animation types and the diff
-- was silent on 24 sites in one mod.
local concept, concept_props, concept_parent = {}, {}, {}
for _, t in ipairs(api.types or {}) do
    concept[t.name] = true
    if t.parent then concept_parent[t.name] = t.parent end
    for _, pr in ipairs(t.properties or {}) do
        concept_props[t.name .. '::' .. pr.name] = pr.optional and 'optional' or 'required'
    end
end

-- "Owner::prop" -> the TYPE NAME its value must satisfy, so a consumer can walk a
-- nested write down the type chain. Owners are prototypes AND concepts, because the
-- nesting recurses (`animation` -> Animation -> `layers` -> Animation -> `hr_version`).
--
-- ⚠ ONLY THE FORMS THAT NAME EXACTLY ONE TYPE ARE RECORDED, and the rest are left
-- ABSENT rather than guessed. A plain string names a type; an `array` is TRANSPARENT
-- (its elements have the element type, and a Lua array adds no path segment). A
-- union, a dictionary, a tuple or a literal names zero or several, and a consumer
-- that picked one would adjudicate a property against a type the mod never wrote.
-- Absence here means NOT DECLARED, which is the same contract the rest of the
-- profile keeps — the diff must render it as an unchecked path, never as a pass.
local function type_name(t, depth)
    if type(t) == 'string' then return t end
    if type(t) == 'table' and t.complex_type == 'array' and (depth or 0) < 4 then
        return type_name(t.value, (depth or 0) + 1)
    end
    return nil
end
-- ★★ WHAT A TYPE ACCEPTS, NOT ONLY WHAT IT NAMES (CART-0646). `prop_type` above
-- records the forms naming exactly ONE type and leaves everything else absent, which is
-- the right contract for walking a path — but it threw away the fact that makes the
-- single largest 1.1 -> 2.0 data-stage break visible.
--
-- `RecipePrototype::ingredients` is an array of `IngredientPrototype` in BOTH versions,
-- and IngredientPrototype is a union of ItemIngredientPrototype | FluidIngredientPrototype
-- in BOTH. Nothing about the property or its type NAME moved. What moved is one level
-- further down:
--     1.1  ItemIngredientPrototype = union{ struct, tuple[ItemID, uint16] }
--     2.0  ItemIngredientPrototype = struct
-- The tuple is the `{"copper-plate", 5}` shorthand, and a mod that keeps it does not
-- load. Same for ItemProductPrototype and the `results` shorthand.
--
-- So two closed maps, and deliberately only two:
--   concept_union[Name]  = sorted list of the NAMED alternatives (EnergySource -> its
--                          five sources). This also un-blinds the union-base walk that
--                          CART-0654 works around, without the `Base<X>` spelling guess.
--   concept_forms[Name]  = the STRUCTURAL forms it accepts as a set — struct, tuple,
--                          dictionary, literal, array. A form the origin had and the
--                          target does not is a removal a property-set diff cannot see.
local concept_union, concept_forms = {}, {}
local function opt_name(o)
    if type(o) == 'string' then return o end
    if type(o) == 'table' and o.complex_type == 'type' and type(o.value) == 'string' then
        return o.value
    end
    return nil
end
local function record_shape(name, t)
    if type(t) ~= 'table' or not t.complex_type then return end
    if t.complex_type == 'union' then
        local named, forms = {}, {}
        for _, o in ipairs(t.options or {}) do
            local nm = opt_name(o)
            if nm then named[#named + 1] = nm
            elseif type(o) == 'table' and o.complex_type then
                forms[o.complex_type] = true
            end
        end
        if #named > 0 then table.sort(named); concept_union[name] = named end
        if next(forms) then concept_forms[name] = forms end
    else
        -- a NON-union complex type is itself one form (`struct`, `dictionary`, …).
        -- Recording it is what lets a union -> struct narrowing be seen as a LOSS
        -- rather than as two unrelated shapes.
        concept_forms[name] = { [t.complex_type] = true }
    end
end
for _, t in ipairs(api.types or {}) do record_shape(t.name, t.type) end

local prop_type, n_ptype = {}, 0
local function record_types(owner, properties)
    for _, pr in ipairs(properties or {}) do
        local tn = type_name(pr.type)
        -- a property typed as a PROTOTYPE or a CONCEPT is walkable; one typed
        -- `string`/`uint32`/… is a leaf and recording it would only add noise
        if tn and (concept[tn] or protos[tn]) then
            prop_type[owner .. '::' .. pr.name] = tn
            n_ptype = n_ptype + 1
        end
    end
end
for _, t in ipairs(api.types or {}) do record_types(t.name, t.properties) end
for _, pr in ipairs(api.prototypes or {}) do record_types(pr.name, pr.properties) end

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
    -- ⚠ THE SOURCE IS WHERE IT CAME FROM, NOT WHICH TEMP FILE HELD IT. This recorded
    -- the input PATH, so the artifacts on disk named a scratch file from a session that
    -- had ended, and apifetch writes each fetch to a fresh tempname. A stamp is
    -- provenance, and a path that no longer exists is worse than none.
    --
    -- ⚠ THIS DOES NOT MAKE THE ARTIFACT BYTE-REPRODUCIBLE, and it was worth checking
    -- rather than assuming: two runs over the identical document still differ, because
    -- mpack encodes a table in `pairs()` order and that is not stable across processes.
    -- What IS stable is the CONTENT — a decoded deep compare of two runs is 10785
    -- scalars and 0 differences (15053 for the 2.0 artifact). And nothing rests on the
    -- bytes anyway: `profile.stamp_of` is mtime+size, so a re-distil invalidates caches
    -- by construction whatever the encoder does.
    -- ⚠ TWO FACTS, NOT ONE, AND THEY CAN DISAGREE. `origin` is where the document is
    -- published; `input` is the file this artifact was actually distilled from. A local
    -- file that has been edited distils perfectly happily, and an origin URL alone would
    -- vouch for it — so the path is not noise to be replaced, it is the audit trail.
    -- The reverse failure is what prompted this: `source` recorded ONLY the path, so the
    -- shipped artifacts named a tempfile from a session that had ended and a checkout in
    -- an unrelated repo, and neither says where to get the document again.
    -- `origin` is absent for a hand run rather than guessed, and `source` is kept as the
    -- best single answer (origin when known, else the path) so existing readers move.
    stamp = { source = ORIGIN or API, origin = ORIGIN, input = API,
        application_version = api.application_version,
        api_version = api.api_version, stage = api.stage },
    typenames = typenames,      -- typename -> PrototypeName  (the data.raw key set)
    prototypes = protos,        -- PrototypeName -> true
    own_props = own_props,      -- "Proto::prop" -> "required"|"optional"  (OWN only)
    parent = parent,            -- PrototypeName -> parent PrototypeName
    concept_types = concept,    -- ConceptName -> true
    concept_union = concept_union,  -- ConceptName -> sorted named alternatives
    concept_forms = concept_forms,  -- ConceptName -> { struct|tuple|dictionary|… = true }
    concept_props = concept_props, -- "Concept::prop" -> "required"|"optional" (OWN only)
    concept_parent = concept_parent, -- ConceptName -> parent ConceptName
    prop_type = prop_type,      -- "Owner::prop" -> the type its value must satisfy,
                                -- arrays transparent; ABSENT when not exactly one
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
local n_cprops = 0
for _ in pairs(concept_props) do n_cprops = n_cprops + 1 end
io.write(('  concept properties: %d ; walkable property types: %d (CART-0633)\n')
    :format(n_cprops, n_ptype))
local n_union, n_forms = 0, 0
for _ in pairs(concept_union) do n_union = n_union + 1 end
for _ in pairs(concept_forms) do n_forms = n_forms + 1 end
io.write(('  union concepts: %d ; concepts with a declared FORM set: %d (CART-0646)\n')
    :format(n_union, n_forms))
io.write(('  INGREDIENT — not a portability target (typenames are hyphenated,'
    .. ' properties are table keys; see the header)\n'))
io.write('  wrote ' .. out .. '\n')
