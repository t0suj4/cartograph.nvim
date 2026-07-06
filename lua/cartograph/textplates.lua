-- Factorio text-plates PROJECTION surface — the "true test" (memory
-- [[cartograph-over-the-wire]] TRUE TEST). It writes the browser's node
-- list INTO a running Factorio world as rows of text-plate entities and
-- reconciles a MINIMAL delta on change (set graphics_variation in place,
-- never rebuild the row) — the store.ingest_step discipline pointed
-- OUTWARD. Here cartograph is the OUTPUT, not the source; the world is a
-- stateful external system reached over a wire, so the write is a delta
-- against observed current state, exactly like the remote write model.
--
-- The core (encode / layout / reconcile) is PURE and transport-agnostic:
-- it never touches the wire, so the whole projection is unit-tested with a
-- fake `io` — no live server (see tests/textplates_spec.lua). The wire is a
-- thin `io(lua) -> decoded` seam wrapping the factorio MCP `run_lua`.
--
-- Glyph table calibrated live against textplates 0.7.2 (2026-07-06): every
-- glyph is a `graphics_variation` index on a shared `simple-entity-with-
-- force`; the item variant only chooses the index at build time, so a
-- scripted placement sets `.graphics_variation` directly. Verified
-- end-to-end by spelling CARTOGRAPH in-world and reading it back.

local M = {}

-- ── the calibrated glyph table ──────────────────────────────────────────────
-- variation 1 = blank/space, 2 = ■, 3..28 = A..Z, 29..38 = 0..9,
-- 39..46 = arrows, 47..52 = brackets, 53..65 = operators, 66..78 = punct.
M.V_SPACE = 1

-- byte -> variation for the ASCII-mappable symbols (letters/digits are ranges)
local SYM = {
    [46] = 68, [44] = 69, [45] = 57, [95] = 57, -- .  ,  -  _(→minus, no glyph)
    [58] = 66, [59] = 67, [47] = 60,            -- :  ;  /
    [40] = 49, [41] = 50, [91] = 47, [93] = 48, -- (  )  [  ]
    [123] = 51, [125] = 52,                     -- {  }
    [62] = 53, [60] = 54, [94] = 55, [61] = 56, -- >  <  ^  =
    [43] = 58, [42] = 59, [37] = 61, [38] = 62, -- +  *  %  &
    [124] = 63, [33] = 64, [63] = 65,           -- |  !  ?
    [39] = 70, [34] = 72, [64] = 74, [35] = 75, -- '  "  @  #
}

--- One character -> its text-plate variation index. Unmapped glyphs (and
--- the underscore, which the mod has no plate for) transliterate to the
--- nearest available; anything else falls back to blank so a row never
--- desyncs its column count.
function M.char_to_variation(c)
    local b = string.byte(c)
    if not b then return M.V_SPACE end
    if b >= 97 and b <= 122 then b = b - 32 end          -- lowercase -> upper
    if b == 32 then return M.V_SPACE end                 -- space
    if b >= 65 and b <= 90 then return 3 + (b - 65) end  -- A-Z
    if b >= 48 and b <= 57 then return 29 + (b - 48) end -- 0-9
    return SYM[b] or M.V_SPACE
end

--- A string -> list of variation indices (one per character).
function M.encode(text)
    local out = {}
    for i = 1, #text do out[i] = M.char_to_variation(text:sub(i, i)) end
    return out
end

-- ── layout: node list -> desired plates ─────────────────────────────────────

local DEFAULTS = {
    anchor = { x = 300, y = -300 }, -- the cleared concrete pad on nauvis
    -- gold is the highest-contrast plate on the grey concrete canvas
    -- (calibrated 2026-07-06; sulfur has no plate — the 9 materials are
    -- concrete/copper/glass/gold/iron/plastic/steel/stone/uranium; uranium
    -- is the runner-up and glows emissive at night).
    size = 'large', material = 'gold',
    dx = 3, dy = 3, -- large plates are 2x2; 3-tile pitch leaves a gap
    max_cols = 40,  -- truncate over-long names so rows stay legible
}

--- Merge caller opts over the defaults (shallow — the anchor is replaced
--- wholesale, not deep-merged, to keep it a value).
local function withdefaults(opts)
    local o = {}
    for k, v in pairs(DEFAULTS) do o[k] = v end
    for k, v in pairs(opts or {}) do o[k] = v end
    return o
end

M.defaults = DEFAULTS

--- entity prototype name for the configured size/material.
function M.entity_name(opts)
    local o = withdefaults(opts)
    return ('textplate-%s-%s'):format(o.size, o.material)
end

--- Lay a list of labels (one per node, e.g. node.name) as stacked rows of
--- plates. Returns a flat list of desired plates { x, y, v, row, col }.
--- Deterministic and pure — the unit of the "render a node list" contract.
function M.layout(labels, opts)
    local o = withdefaults(opts)
    local plates = {}
    for row, label in ipairs(labels) do
        local vs = M.encode(label)
        local n = math.min(#vs, o.max_cols)
        for col = 1, n do
            plates[#plates + 1] = {
                x = o.anchor.x + (col - 1) * o.dx,
                y = o.anchor.y + (row - 1) * o.dy,
                v = vs[col],
                row = row, col = col,
            }
        end
    end
    return plates
end

-- ── reconcile: minimal delta against observed world state ───────────────────

local function cell(x, y) return ('%d:%d'):format(math.floor(x + 0.5), math.floor(y + 0.5)) end

--- Diff desired plates against the current world (a list of
--- { x, y, v, u } where u is the unit_number). Returns the minimal write:
---   create  = plates to build       (cell empty)
---   revary  = plates to re-letter    (cell occupied, wrong variation)
---   destroy = plates to remove       (cell no longer wanted)
--- A steady state yields all-empty lists — so "update on change" writes
--- only what changed, the ingest_step invariant turned outward.
function M.reconcile(desired, current)
    local have = {}
    for _, p in ipairs(current or {}) do have[cell(p.x, p.y)] = p end

    local create, revary, destroy = {}, {}, {}
    local wanted = {}
    for _, d in ipairs(desired) do
        local k = cell(d.x, d.y)
        wanted[k] = true
        local cur = have[k]
        if not cur then
            create[#create + 1] = { x = d.x, y = d.y, v = d.v }
        elseif cur.v ~= d.v then
            revary[#revary + 1] = { x = d.x, y = d.y, v = d.v, u = cur.u }
        end
    end
    for _, p in ipairs(current or {}) do
        if not wanted[cell(p.x, p.y)] then
            destroy[#destroy + 1] = { x = p.x, y = p.y, u = p.u }
        end
    end
    return { create = create, revary = revary, destroy = destroy }
end

--- True when a delta writes nothing (steady state).
function M.is_noop(delta)
    return #delta.create == 0 and #delta.revary == 0 and #delta.destroy == 0
end

-- ── the wire: thin lua-string seam over the factorio MCP run_lua ─────────────
-- io(lua_string) runs the code in-game and returns the value rcon.print'd
-- (already JSON-decoded by the caller). Kept deliberately small; all the
-- logic above is pure.

--- Bounding box (in tiles) covering a set of plates, padded by one tile.
function M.bbox(plates, opts)
    local o = withdefaults(opts)
    if #plates == 0 then
        return { { o.anchor.x - 1, o.anchor.y - 1 }, { o.anchor.x + 1, o.anchor.y + 1 } }
    end
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(plates) do
        minx, maxx = math.min(minx, p.x), math.max(maxx, p.x)
        miny, maxy = math.min(miny, p.y), math.max(maxy, p.y)
    end
    return { { minx - 1, miny - 1 }, { maxx + 2, maxy + 2 } }
end

--- Lua that reports current plates in `area` as a JSON list of {x,y,v,u}.
function M.read_lua(area, name, surface)
    return ([[
local s = game.surfaces[%q]
local out = {}
for _, e in ipairs(s.find_entities_filtered{area={{%d,%d},{%d,%d}}, name=%q}) do
  out[#out+1] = {x=e.position.x, y=e.position.y, v=e.graphics_variation, u=e.unit_number}
end
rcon.print(helpers.table_to_json(out))]]):format(
        surface, area[1][1], area[1][2], area[2][1], area[2][2], name)
end

--- Lua that applies a reconcile delta: destroy, then revary in place, then
--- create. Order matters — free cells before filling them.
function M.apply_lua(delta, name, surface)
    local parts = { ('local s = game.surfaces[%q]'):format(surface),
        'local by = {}',
        ('for _, e in ipairs(s.find_entities_filtered{name=%q}) do by[e.unit_number]=e end'):format(name) }
    for _, p in ipairs(delta.destroy) do
        parts[#parts + 1] = ('if by[%d] and by[%d].valid then by[%d].destroy() end'):format(p.u, p.u, p.u)
    end
    for _, p in ipairs(delta.revary) do
        parts[#parts + 1] = ('if by[%d] and by[%d].valid then by[%d].graphics_variation=%d end'):format(p.u, p.u, p.u, p.v)
    end
    for _, p in ipairs(delta.create) do
        parts[#parts + 1] = ('do local e=s.create_entity{name=%q,position={x=%d,y=%d},force="player"} if e then e.graphics_variation=%d end end')
            :format(name, p.x, p.y, p.v)
    end
    parts[#parts + 1] = 'rcon.print("ok")'
    return table.concat(parts, '\n')
end

--- Full projection loop: observe current world -> reconcile -> apply.
--- `io(lua) -> decoded` is the only wire touch. Returns the applied delta
--- (for logging / the "wrote N, changed M" telemetry). Pure everywhere
--- except the two io() calls, so a fake io drives it under test.
function M.project(io, labels, opts)
    local o = withdefaults(opts)
    local name = M.entity_name(o)
    local desired = M.layout(labels, o)
    local area = M.bbox(desired, o)
    local current = io(M.read_lua(area, name, o.surface or 'nauvis')) or {}
    local delta = M.reconcile(desired, current)
    if not M.is_noop(delta) then
        io(M.apply_lua(delta, name, o.surface or 'nauvis'))
    end
    return delta
end

return M
