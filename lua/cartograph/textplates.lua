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

-- the 9 plate materials (calibrated 2026-07-06; sulfur has no plate). A
-- material is a distinct ENTITY, so the projection reads every material it
-- could own in its canvas and treats a material change as a replace.
M.MATERIALS = { 'concrete', 'copper', 'glass', 'gold', 'iron', 'plastic',
    'steel', 'stone', 'uranium' }

local DEFAULTS = {
    anchor = { x = 300, y = -300 }, -- the cleared concrete pad on nauvis
    -- gold is the highest-contrast plate on the grey concrete canvas; the
    -- SELECTED row (the cursor's node) renders in `highlight` — uranium, the
    -- runner-up, which glows emissive so "you are here" reads at a glance.
    size = 'large', material = 'gold', highlight = 'uranium',
    selected = nil, -- 1-based row to highlight (the cursor row), or nil
    dx = 3, dy = 3, -- large plates are 2x2; 3-tile pitch leaves a gap
    max_cols = 40,  -- truncate over-long names so rows stay legible
    max_rows = 32,  -- cap rows so a big view never blankets the world
}

--- entity prototype name for a size + material.
local function plate_name(size, material)
    return ('textplate-%s-%s'):format(size, material)
end

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
    return plate_name(o.size, o.material)
end

--- Lay a list of labels (one per node, e.g. node.name) as stacked rows of
--- plates. Returns a flat list of desired plates { x, y, v, mat, row, col }.
--- The `selected` row (1-based) renders in the `highlight` material — the
--- rest in `material`. Deterministic and pure — the unit of the "render a
--- node list, mark where I am" contract.
function M.layout(labels, opts)
    local o = withdefaults(opts)
    local plates = {}
    for row, label in ipairs(labels) do
        if o.max_rows and row > o.max_rows then break end
        local mat = (o.selected == row and o.highlight) or o.material
        local vs = M.encode(label)
        local n = math.min(#vs, o.max_cols)
        for col = 1, n do
            -- a space is an ABSENT plate (a gap in the world), not the blank
            -- plate — so skip it, but keep advancing the column so the letters
            -- after it stay in place. reconcile then reclaims any plate a cell
            -- vacated by becoming a space.
            if vs[col] ~= M.V_SPACE then
                plates[#plates + 1] = {
                    x = o.anchor.x + (col - 1) * o.dx,
                    y = o.anchor.y + (row - 1) * o.dy,
                    v = vs[col], mat = mat,
                    row = row, col = col,
                }
            end
        end
    end
    return plates
end

-- ── reconcile: minimal delta against observed world state ───────────────────

local function cell(x, y) return ('%d:%d'):format(math.floor(x + 0.5), math.floor(y + 0.5)) end

--- Diff desired plates against the current world (a list of
--- { x, y, v, u, mat } where u is the unit_number). Returns the minimal write:
---   create  = plates to build       (cell empty, or material changed)
---   revary  = plates to re-letter    (cell occupied, same material, wrong glyph)
---   destroy = plates to remove       (cell no longer wanted, or material changed)
--- A material change can't be done in place (it's a different entity), so it
--- becomes destroy+create. A steady state yields all-empty lists — "update on
--- change" writes only what changed, the ingest_step invariant turned outward.
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
            create[#create + 1] = { x = d.x, y = d.y, v = d.v, mat = d.mat }
        elseif d.mat and cur.mat and cur.mat ~= d.mat then
            -- material change = a different entity: replace it
            destroy[#destroy + 1] = { x = cur.x, y = cur.y, u = cur.u }
            create[#create + 1] = { x = d.x, y = d.y, v = d.v, mat = d.mat }
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

--- The CANVAS the projection owns: the full rectangle any row/col could
--- occupy (anchor + max_cols×max_rows), padded by a tile. The read must
--- cover this, not just the current desired bbox — otherwise SHRINKING the
--- list orphans the vacated rows (they fall outside a tight bbox and never
--- get destroyed). Nothing outside the canvas is ever touched.
function M.canvas_bbox(opts)
    local o = withdefaults(opts)
    return { { o.anchor.x - 1, o.anchor.y - 1 },
        { o.anchor.x + o.max_cols * o.dx + 1, o.anchor.y + o.max_rows * o.dy + 1 } }
end

--- Names of every material's plate at `size`, as a quoted lua list — the
--- projection reads/scans all of them because a highlight row is a different
--- material (entity), and a former material may still linger in the canvas.
local function name_list(size)
    local names = {}
    for _, m in ipairs(M.MATERIALS) do names[#names + 1] = ('%q'):format(plate_name(size, m)) end
    return table.concat(names, ', ')
end

--- Lua that reports current plates in `area` as a JSON list of {x,y,v,u,mat}
--- (mat = the trailing material token of the entity name).
function M.read_lua(area, size, surface)
    return ([[
local s = game.surfaces[%q]
local out = {}
for _, e in ipairs(s.find_entities_filtered{area={{%d,%d},{%d,%d}}, name={%s}}) do
  out[#out+1] = {x=e.position.x, y=e.position.y, v=e.graphics_variation, u=e.unit_number, mat=e.name:match("[^-]+$")}
end
rcon.print(helpers.table_to_json(out))]]):format(
        surface, area[1][1], area[1][2], area[2][1], area[2][2], name_list(size))
end

--- Lua that applies a reconcile delta: destroy, then revary in place, then
--- create (each in its own material). Order matters — free cells first.
function M.apply_lua(delta, size, surface)
    local parts = { ('local s = game.surfaces[%q]'):format(surface),
        'local by = {}',
        ('for _, e in ipairs(s.find_entities_filtered{name={%s}}) do by[e.unit_number]=e end'):format(name_list(size)) }
    for _, p in ipairs(delta.destroy) do
        parts[#parts + 1] = ('if by[%d] and by[%d].valid then by[%d].destroy() end'):format(p.u, p.u, p.u)
    end
    for _, p in ipairs(delta.revary) do
        parts[#parts + 1] = ('if by[%d] and by[%d].valid then by[%d].graphics_variation=%d end'):format(p.u, p.u, p.u, p.v)
    end
    for _, p in ipairs(delta.create) do
        parts[#parts + 1] = ('do local e=s.create_entity{name=%q,position={x=%d,y=%d},force="player"} if e then e.graphics_variation=%d end end')
            :format(plate_name(size, p.mat or 'gold'), p.x, p.y, p.v)
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
    local surface = o.surface or 'nauvis'
    local desired = M.layout(labels, o)
    -- read the whole owned canvas (every material) so a shrunk list reclaims
    -- vacated rows and a moved highlight replaces the right cells
    local area = M.canvas_bbox(o)
    local current = io(M.read_lua(area, o.size, surface)) or {}
    local delta = M.reconcile(desired, current)
    if not M.is_noop(delta) then
        io(M.apply_lua(delta, o.size, surface))
    end
    return delta
end

-- ── live wire (optional; requires cartograph.mcp + a factorio MCP server) ────
-- Everything above is pure. This section is the only part that touches the
-- transport: it turns a cartograph MCP client's `run_lua` tool into the
-- `io(lua) -> decoded` the pure core expects, and keeps ONE connection alive
-- while re-projecting the browser view on every navigation.

--- Wrap an MCP client's run_lua tool as an io(lua) -> decoded. FactoMCP
--- returns the rcon output inside a { result = "<text|json>" } envelope
--- (cartograph's client:call has already JSON-decoded the tool text), so a
--- read needs a second decode; an apply's "ok" is returned as-is.
function M.mcp_io(client, cfg)
    local tool = (cfg and cfg.tool) or 'run_lua'
    local timeout = (cfg and cfg.timeout) or 30000
    return function (lua)
        local r, err = client:call(tool, { code = lua }, timeout)
        if r == nil then error('cartograph.textplates: run_lua failed — ' .. tostring(err)) end
        local out = r
        if type(r) == 'table' and r.result ~= nil then out = r.result end
        if type(out) == 'string' then
            local ok, dec = pcall(vim.json.decode, out)
            if ok then return dec end
        end
        return out
    end
end

--- Connect to the configured factorio MCP server. cfg defaults to
--- config.factorio ({ cmd = {...}, env?, surface?, anchor?, material? }).
--- Returns (client, io) or (nil, err).
function M.connect(cfg)
    cfg = cfg or require('cartograph.config').factorio
    if type(cfg) ~= 'table' or not cfg.cmd then
        return nil, 'no factorio MCP server configured — setup{ factorio = { cmd = {...} } }'
    end
    local client, err = require('cartograph.mcp').connect(cfg)
    if not client then return nil, err end
    return client, M.mcp_io(client, cfg)
end

-- the one live projector (a single connection reused across navigations)
M._live = nil

--- Detach the live projector: unsubscribe from both channels, close the wire.
function M.detach()
    local L = M._live
    if not L then return end
    M._live = nil
    for _, unsub in ipairs(L.unsubs or {}) do pcall(unsub) end
    if L.client then pcall(function () L.client:close() end) end
end

--- Start (or restart) the live projection: connect once, project the current
--- view, and re-project a MINIMAL delta whenever the view changes (navigation)
--- OR the cursor moves to a new row (hover) — so the world tracks both WHAT
--- is in view and WHERE you are (the selected row in the highlight material).
--- `opts` merges over config.factorio (anchor/material/highlight/surface/
--- debounce/max_rows). Returns (state, nil) or (nil, err).
function M.attach(opts)
    M.detach()
    local cfg = require('cartograph.config').factorio or {}
    local proj = vim.tbl_extend('force', {}, cfg, opts or {})
    local client, io = M.connect(proj)
    if not client then return nil, io end

    local store = require 'cartograph.store'
    local L = { client = client, io = io, opts = proj, gen = 0 }
    M._live = L

    local function fire()
        if M._live ~= L or not client.alive then return end
        local view = require('cartograph.panes.symbols').projection(proj.max_rows)
        local o = vim.tbl_extend('force', proj, { selected = view.selected })
        local ok, err = pcall(M.project, io, view.labels, o)
        if not ok then
            vim.notify('cartograph: projection failed — ' .. tostring(err), vim.log.levels.WARN)
            M.detach()
        end
    end

    -- debounce: navigation + hover fire in bursts; coalesce them
    local function schedule()
        L.gen = L.gen + 1
        local mine = L.gen
        vim.defer_fn(function () if M._live == L and mine == L.gen then fire() end end,
            proj.debounce or 250)
    end
    L.unsubs = { store.on_redraw(schedule), store.on_context(schedule) }

    fire() -- initial paint
    return L
end

return M
