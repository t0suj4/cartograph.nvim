-- The session: a REGISTRY of open bands, with the store singleton demoted to a
-- LENS on the ACTIVE band ([[cartograph-multiband-session]]). open ADDS a band
-- (never clobbers); switching captures the active band's state into its record
-- and restores another's — so self://loaded + a work corpus (and, later, peer
-- projects) are resident at once. A band RECORD is { name, kind, root, state }
-- where `state` is nil WHILE ACTIVE (it lives in the store lens) and a
-- store.capture() snapshot while stashed.
--
-- The 16 store-require sites and every store.M.fn() are UNCHANGED — the legacy
-- read surface is single-band by construction, and a single-band session never
-- switches (so never capture/restores), keeping the common path byte-identical.
-- Multi-band-native consumers (the LSP handlers, the future federated accessor)
-- take an explicit band; the lens is for the legacy single-band readers.

local store = require 'cartograph.store'

local M = { bands = {}, active = nil }

-- a stable, unique band name from a root: the basename (scheme-stripped),
-- uniquified against the registry.
local function name_for(root)
    local base = (root or '?'):gsub('%w+://', ''):gsub('/+$', ''):match('[^/]+$') or root or 'band'
    local name, i = base, 1
    while M.bands[name] and M.bands[name].root ~= root do
        i = i + 1; name = base .. ':' .. i
    end
    return name
end

--- The registered band whose root == `root` (nil if none).
function M.by_root(root)
    for name, b in pairs(M.bands) do if b.root == root then return name end end
end

--- BEGIN a NEW band's open. Freezes the currently-active band into its record
--- (so the imminent ingest doesn't clobber it), registers the new band, and
--- makes it active. The caller then ingests the new graph into the store, which
--- is now the new band's live lens. Returns the band name.
function M.begin(root, kind)
    if M.active and M.bands[M.active] then M.bands[M.active].state = store.capture() end
    local name = name_for(root)
    M.bands[name] = { name = name, kind = kind or 'project', root = root }
    M.active = name
    return name
end

--- SWITCH to an already-registered band (no re-extract): freeze the active
--- band, thaw the target into the lens. Returns true, or (nil, why).
function M.switch(name)
    if name == M.active then return true end
    local b = M.bands[name]
    if not b then return nil, 'no such band: ' .. tostring(name) end
    if M.active and M.bands[M.active] then M.bands[M.active].state = store.capture() end
    store.restore(b.state or {})
    b.state = nil
    M.active = name
    return true
end

--- Switch to the band owning `root` if it is registered; else nil (the caller
--- opens it fresh via M.begin). The re-open-is-a-switch path.
function M.switch_to_root(root)
    local name = M.by_root(root)
    if name then return M.switch(name) end
    return nil
end

--- Close a band. If it is active, activate another (or leave the lens empty
--- when it was the last). Returns the now-active band name (or nil if none).
function M.close(name)
    local b = M.bands[name]
    if not b then return M.active end
    M.bands[name] = nil
    if M.active ~= name then return M.active end
    -- was active: pick any survivor, else empty the lens
    local nextname = next(M.bands)
    M.active = nil
    if nextname then M.switch(nextname) else store.restore({}) end
    return M.active
end

--- The band OWNING `file` (an abs path) by root containment, else the active
--- band — the verb-routing rule (a command acts on the buffer's band). PROFILE
--- bands are non-routable (S3); until then, every band is routable.
function M.owning(file)
    if not file then return M.active end
    local best
    for name, b in pairs(M.bands) do
        local r = b.root
        if r and file:sub(1, #r + 1) == r .. '/' then
            if not best or #b.root > #M.bands[best].root then best = name end -- innermost root wins
        end
    end
    return best or M.active
end

--- The registry as rows for :CartographBands: { {name, kind, root, active} }.
function M.list()
    local out = {}
    for name, b in pairs(M.bands) do
        out[#out + 1] = { name = name, kind = b.kind, root = b.root, active = (name == M.active) }
    end
    table.sort(out, function (a, c) return a.name < c.name end)
    return out
end

--- Reset the whole session (tests, a clean :Cartograph on nothing).
function M.reset() M.bands, M.active = {}, nil end

return M
