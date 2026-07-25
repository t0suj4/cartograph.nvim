-- Factorio "dead biter brush" PROJECTION medium: paint a raster — an ASCII
-- grid / a drawing — into the world as biter CORPSES, one corpse per ink cell.
-- Same observe → reconcile → apply → verify discipline as the text projection
-- ([[textplates]]), a different MEDIUM: the cell's "kind" is a corpse size (a
-- shade ramp small..behemoth) instead of a glyph, and the input is a bitmap
-- grid, not a row of labels. There is no in-place mutate (a corpse can't
-- change type), so a changed cell is destroy+create.
--
-- HONESTY WRINKLE, embraced: corpses DECAY. A picture made of dead biters is a
-- self-erasing SAMPLE — re-project to refresh it, and the read-back verify
-- reports the drift as it rots. The staleness model has real teeth here.
--
-- The pure core (parse / reconcile / *_lua) never touches the wire; it drives
-- with a fake io under test. The live wire reuses textplates' MCP transport.

local M = {}

-- the shade ramp: digits 1..N in the grid pick a corpse size (light..heavy).
M.SHADES = { 'small-biter-corpse', 'medium-biter-corpse', 'big-biter-corpse',
    'behemoth-biter-corpse' }

local DEFAULTS = {
    anchor = { x = 300, y = -300 },
    dx = 1, dy = 1,                -- one corpse per tile (a fine raster)
    ink = 'small-biter-corpse',    -- the default on/off ink
    max_cols = 160, max_rows = 90, -- the owned canvas bound
}
M.defaults = DEFAULTS

local function withdefaults(opts)
    return require('cartograph.util').defaults(DEFAULTS, opts)
end

--- One grid character -> a corpse kind (or nil for empty). ' ' and '.' are
--- blank; '1'..'9' pick a shade (clamped to the ramp); any other non-blank
--- character is `ink`. So on/off art works, and a graded 1-9 grid gets shading.
function M.char_to_kind(c, ink)
    if c == '' or c == ' ' or c == '.' then return nil end
    local d = tonumber(c:match('^[1-9]$'))
    if d then return M.SHADES[math.min(d, #M.SHADES)] end
    return ink or DEFAULTS.ink
end

--- Parse an ASCII grid (a string, or a list of lines) into desired corpse
--- cells { x, y, kind }. Rows/cols are capped to the owned canvas.
function M.parse(text, opts)
    local o = withdefaults(opts)
    local lines = text
    if type(text) == 'string' then
        lines = {}
        for line in (text .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = line end
    end
    local cells = {}
    for r = 1, math.min(#lines, o.max_rows) do
        local line = lines[r] or ''
        for c = 1, math.min(#line, o.max_cols) do
            local kind = M.char_to_kind(line:sub(c, c), o.ink)
            if kind then
                cells[#cells + 1] = { x = o.anchor.x + (c - 1) * o.dx,
                    y = o.anchor.y + (r - 1) * o.dy, kind = kind }
            end
        end
    end
    return cells
end

local function cell(x, y) return ('%d:%d'):format(math.floor(x + 0.5), math.floor(y + 0.5)) end

--- Diff desired corpse cells against the current world (a list of
--- { x, y, kind }). Corpses can't mutate, so:
---   create  = cell empty, or the corpse there is the wrong kind
---   destroy = cell no longer wanted, or wrong kind (paired with a create)
--- A steady state is all-empty.
function M.reconcile(desired, current)
    local have = {}
    for _, p in ipairs(current or {}) do have[cell(p.x, p.y)] = p end
    local create, destroy, wanted = {}, {}, {}
    for _, d in ipairs(desired) do
        local k = cell(d.x, d.y); wanted[k] = true
        local cur = have[k]
        if not cur then
            create[#create + 1] = { x = d.x, y = d.y, kind = d.kind }
        elseif cur.kind ~= d.kind then
            destroy[#destroy + 1] = { x = cur.x, y = cur.y }
            create[#create + 1] = { x = d.x, y = d.y, kind = d.kind }
        end
    end
    for _, p in ipairs(current or {}) do
        if not wanted[cell(p.x, p.y)] then destroy[#destroy + 1] = { x = p.x, y = p.y } end
    end
    return { create = create, destroy = destroy }
end

function M.is_noop(d) return #d.create == 0 and #d.destroy == 0 end
function M.delta_count(d) return #d.create + #d.destroy end

--- The owned canvas rectangle (anchor + max_cols×max_rows), padded. The read
--- covers all of it so a shrunk drawing reclaims vacated cells.
function M.canvas_bbox(opts)
    local o = withdefaults(opts)
    return { { o.anchor.x - 1, o.anchor.y - 1 },
        { o.anchor.x + o.max_cols * o.dx + 1, o.anchor.y + o.max_rows * o.dy + 1 } }
end

-- every corpse kind, as a quoted lua list for find_entities_filtered
local function name_list()
    local names = {}
    for _, k in ipairs(M.SHADES) do names[#names + 1] = ('%q'):format(k) end
    return table.concat(names, ', ')
end

--- Lua reporting the corpses in `area` as a JSON list of { x, y, kind }.
--- Corpses have no reliable unit_number, so destroy keys by position.
function M.read_lua(area, surface)
    return ([[
local s = game.surfaces[%q]
local out = {}
for _, e in ipairs(s.find_entities_filtered{area={{%d,%d},{%d,%d}}, name={%s}}) do
  out[#out+1] = {x=e.position.x, y=e.position.y, kind=e.name}
end
rcon.print(helpers.table_to_json(out))]]):format(
        surface, area[1][1], area[1][2], area[2][1], area[2][2], name_list())
end

--- Lua applying a delta: destroy the corpse(s) at each vacated cell (a tight
--- box isolates one tile), then create the new corpses.
function M.apply_lua(delta, surface)
    local parts = { ('local s = game.surfaces[%q]'):format(surface) }
    for _, p in ipairs(delta.destroy) do
        parts[#parts + 1] = ('for _, e in ipairs(s.find_entities_filtered{area={{%s,%s},{%s,%s}}, name={%s}}) do e.destroy() end')
            :format(p.x - 0.4, p.y - 0.4, p.x + 0.4, p.y + 0.4, name_list())
    end
    for _, p in ipairs(delta.create) do
        parts[#parts + 1] = ('s.create_entity{name=%q, position={x=%s, y=%s}}')
            :format(p.kind, p.x, p.y)
    end
    parts[#parts + 1] = 'rcon.print("ok")'
    return table.concat(parts, '\n')
end

--- Full projection loop for a raster: observe → reconcile → apply → verify.
--- `io(lua) -> decoded` is the only wire touch (reuse textplates' mcp_io).
function M.project(io, text, opts)
    local o = withdefaults(opts)
    local surface = o.surface or 'nauvis'
    local desired = M.parse(text, o)
    local area = M.canvas_bbox(o)
    local current = io(M.read_lua(area, surface)) or {}
    local delta = M.reconcile(desired, current)
    if not M.is_noop(delta) then io(M.apply_lua(delta, surface)) end
    if o.verify ~= false then -- read-back: corpses decay, so drift is expected over time
        local after = M.is_noop(delta) and current or (io(M.read_lua(area, surface)) or {})
        delta.drift = M.reconcile(desired, after)
        delta.verified = M.is_noop(delta.drift)
    end
    return delta
end

return M
