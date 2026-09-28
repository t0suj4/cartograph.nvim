-- cartograph.namespace — WHAT A SESSION OR A TACTIC SEES, AS A VALUE (CART-1160 step 4: mount / resolve).
--
-- A namespace is an ordered list of MOUNT ENTRIES { point, target, opts }. The primitives, all pure — an operation
-- returns a NEW namespace and never edits the one it was given:
--   empty()                         the namespace with nothing mounted
--   mount(ns, point, target, opts)  attach `target` at `point`. A later mount at the SAME point stacks over the
--                                   earlier ones (Linux: it hides them until it is unmounted); `opts.union` makes the
--                                   stack a UNION instead (Plan 9's bind -b / -a): 'before' puts the new layer first,
--                                   'after' last — a consumer reading a union sees every layer, in that order
--   umount(ns, point, target?)      remove the entries at `point` (only the one holding `target`, when given)
--   resolve(ns, address)            the entries of the LONGEST point containing `address`, in precedence order, plus
--                                   the address relative to that point: { layers = { entry... }, point, rest }
--   entries(ns)                     every entry, in mount order (/proc/mounts)
-- ★ THE TARGET IS OPAQUE: a band name, a graph, a directory — the namespace addresses, the consumer interprets. And
-- containment is by PATH SEGMENT: point `/a/b` contains `/a/b` and `/a/b/c`, never `/a/bc`.
-- ⚠ ONE DEPARTURE FROM LINUX, on purpose: the LONGEST point wins whatever the mount order (Linux hides an older mount
-- at /a/b under a newer one at /a). Longest-match-wins is the containment precedence the bands and scoped config
-- (CART-1120) already rest on: the innermost root owns a file, however the roots were opened.
-- ★ UNSHARE IS FREE: keep the old value. That is the whole reason this is a value — the mutable registry it replaces
-- made "see what I see, minus one mount" an operation with an undo, and CART-1159 was that undo forgotten.
local M = {}

local function norm(point)
    point = tostring(point or '')
    if #point > 1 then point = point:gsub('/+$', '') end
    return point
end

--- does `point` contain `address`, and what is left of it? -> rest | nil
local function under(point, address)
    if point == '' or point == '/' then return (address:gsub('^/', '')) end
    if address == point then return '' end
    if address:sub(1, #point + 1) == point .. '/' then return address:sub(#point + 2) end
    return nil
end

function M.empty() return { entries = {} } end

function M.mount(ns, point, target, opts)
    if target == nil then return nil, 'a mount needs a target', 'ill-posed' end
    point = norm(point)
    opts = opts or {}
    local union = opts.union
    if union ~= nil and union ~= 'before' and union ~= 'after' then
        return nil, ('union `%s` is not before | after'):format(tostring(union)), 'ill-posed'
    end
    local out = { entries = {} }
    local entry = { point = point, target = target, opts = opts }
    -- a plain mount at a point already mounted HIDES what was there; the older entries stay, so umount reveals them
    for _, e in ipairs((ns or M.empty()).entries) do out.entries[#out.entries + 1] = e end
    out.entries[#out.entries + 1] = entry
    return out
end

function M.umount(ns, point, target)
    point = norm(point)
    local out = { entries = {} }
    for _, e in ipairs((ns or M.empty()).entries) do
        if not (e.point == point and (target == nil or e.target == target)) then out.entries[#out.entries + 1] = e end
    end
    return out
end

function M.resolve(ns, address)
    address = tostring(address or '')
    local best, rest
    for _, e in ipairs((ns or M.empty()).entries) do
        local r = under(e.point, address)
        if r and (not best or #e.point > #best) then best, rest = e.point, r end
    end
    if not best then return nil, ('nothing is mounted over %s'):format(address), 'frontier' end
    return { point = best, rest = rest, layers = M.layers(ns, best) }
end

--- the layers at `point` in precedence order (first = consulted first)
function M.layers(ns, point)
    point = norm(point)
    local stack = {}
    for _, e in ipairs((ns or M.empty()).entries) do if e.point == point then stack[#stack + 1] = e end end
    -- walk from the oldest up: a plain mount replaces the whole view, a union mount joins it at one end
    local view = {}
    for _, e in ipairs(stack) do
        local u = e.opts and e.opts.union
        if u == 'before' then table.insert(view, 1, e)
        elseif u == 'after' then view[#view + 1] = e
        else view = { e } end
    end
    return view
end

function M.entries(ns)
    local out = {}
    for i, e in ipairs((ns or M.empty()).entries) do out[i] = e end
    return out
end

return M
