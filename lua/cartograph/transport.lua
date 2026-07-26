-- The TRANSPORT layer: WHERE bytes come from, separated from what reads them.
-- store.content's docstring has long promised this ("disk now; a fetch/stream
-- over the wire eventually"), but it only ever covered DISPLAY reads. The
-- extractor acquired its own bytes directly — 6 io.open sites, an inline
-- fs_scandir walk and an fs_stat stamp in providers/treesitter.lua — so a new
-- substrate (a zip, an archive, a wire) would have meant a branch inside each.
-- This is that seam, made real.
--
-- THREE OPS, not one read(). They are separate because their DEPENDENCY
-- FOOTPRINTS differ, which is the whole reason a contract beats a helper:
--
--   list   enumerate a container            (disk: fs_scandir)
--   stamp  a validity key for cache/refresh (disk: mtime+size)
--   read   the bytes                        (disk: io.open)
--
-- For a zip, list and stamp need only the central directory — which is stored
-- UNCOMPRESSED — while read needs inflate. So a transport can be partially
-- capable: enumerable and stampable but not readable (no libz). That is a
-- capability fact source.lua can carry, not a hard failure. A single read()
-- would have hidden the distinction and turned a missing library into a dead
-- corpus.
--
-- WHAT A TRANSPORT IS: a table with `name`, `claims(path)` and the ops it can
-- serve. Registration order decides; disk is the fallback and claims nothing,
-- so it answers whatever no other transport wants. Ops are OPTIONAL — a
-- transport that cannot read returns nil from M.read for its paths, exactly as
-- an unreadable file does, so callers need no new failure branch.
--
-- FIDELITY (step A): disk is the ONLY transport, and its implementation is a
-- behavioural copy of the sites it replaced, deliberately down to the edge
-- cases — including returning nil when a path OPENS but yields no bytes, which
-- is how a directory reads on Linux. That is what makes the refactor provable
-- against the corpus gates rather than merely plausible.

local M = {}

-- ── the disk transport ───────────────────────────────────────────────────────

local disk = {
    name = 'disk',
    -- the fallback: it claims nothing and is chosen only when no registered
    -- transport wants the path
    claims = function () return false end,

    read = function (path)
        local fd = io.open(path, 'r')
        if not fd then return nil end
        -- 'a' matches every site this replaced. A directory opens on Linux and
        -- reads nil; that nil is the answer, not an error to paper over.
        local src = fd:read('a')
        fd:close()
        return src
    end,

    stamp = function (path)
        local st = vim.uv.fs_stat(path)
        if not st then return nil end
        return ('%d:%d:%d'):format(st.mtime.sec, st.mtime.nsec, st.size)
    end,

    --- Directory entries as an iterator yielding (name, type). An unreadable
    --- directory yields nothing rather than erroring — the `while it do` guard
    --- the walk used to carry, moved in here where every transport inherits it.
    --- ORDER IS THE FILESYSTEM'S, preserved: symlink dedup (seen_real) depends
    --- on which alias is visited first.
    dir = function (path)
        local it = vim.uv.fs_scandir(path)
        if not it then return function () return nil end end
        return function () return vim.uv.fs_scandir_next(it) end
    end,

    stat = function (path) return vim.uv.fs_stat(path) end,
    realpath = function (path) return vim.uv.fs_realpath(path) end,
}

M.disk = disk

-- ── the registry ─────────────────────────────────────────────────────────────

local registered = {}

--- Add a transport. Later registrations are asked FIRST, so a specific
--- substrate can shadow a general one. Disk is never in this list; it is the
--- fallback.
--- No production caller yet — disk is the only transport in step A. It exists so
--- that a second substrate is an ADDITION rather than an edit to for_path, and
--- the spec exercises it. With nothing registered, for_path IS "return disk".
function M.register(t)
    assert(type(t) == 'table' and t.name and t.claims,
        'transport: needs { name, claims, ... }')
    table.insert(registered, 1, t)
    return t
end

--- Remove a transport, restoring whatever answered its paths before. Symmetric
--- with register so a substrate can be withdrawn (an unmounted archive, a closed
--- session) without the registry growing forever; the spec is its caller today.
function M.unregister(t)
    for i, r in ipairs(registered) do
        if r == t then table.remove(registered, i); return true end
    end
    return false
end

--- Which transport serves this path. Never nil: disk answers by default.
function M.for_path(path)
    for _, t in ipairs(registered) do
        if t.claims(path) then return t end
    end
    return disk
end

-- ── the front door ───────────────────────────────────────────────────────────
-- Callers use these, never a transport table directly, so routing stays in one
-- place. A transport missing an op behaves as that op failing (nil / empty),
-- which is the same shape as an unreadable path.

--- Whole-file contents as a string, nil when unreadable.
function M.read(path)
    local t = M.for_path(path)
    if not t.read then return nil end
    return t.read(path)
end

--- Contents split into lines, nil when unreadable. Callers that distinguish
--- "tried and failed" from "not tried" keep their own `or false` sentinel.
function M.lines(path)
    local src = M.read(path)
    if not src then return nil end
    return vim.split(src, '\n', { plain = true })
end

--- The validity key for a path, nil when it has none.
function M.stamp(path)
    local t = M.for_path(path)
    if not t.stamp then return nil end
    return t.stamp(path)
end

--- Iterator over a container's entries, yielding (name, type).
function M.dir(path)
    local t = M.for_path(path)
    if not t.dir then return function () return nil end end
    return t.dir(path)
end

--- uv-shaped stat, for callers that need type/size beyond the stamp.
function M.stat(path)
    local t = M.for_path(path)
    return t.stat and t.stat(path) or nil
end

--- Canonical path, or nil where the substrate has no such notion. A transport
--- without link semantics simply never yields type 'link', so callers that
--- resolve aliases never reach this.
function M.realpath(path)
    local t = M.for_path(path)
    return t.realpath and t.realpath(path) or nil
end

return M
