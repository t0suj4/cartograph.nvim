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

-- ── failure has two kinds, and conflating them is unsound ────────────────────
-- Every op returns (value, err). The distinction is NOT ergonomics: the
-- extractor turns "no content" into a CONFIDENT NEGATIVE FACT. Measured on a
-- 2-file fixture — make the callee's file unreadable and its module node
-- disappears, while the call to it is classified `external`, i.e. "this is the
-- project boundary". That claim feeds :CartographExternals, the portability
-- report and the negative-facts linker kind.
--
-- On disk that needs a chmod, so it is nearly unreachable. Over a wire a
-- timeout or a 5xx produces it routinely — a blip would silently redraw the
-- project boundary, and (with no stamp written) a warm open could persist it.
-- So:
--
--   ABSENT       authoritative: ENOENT, HTTP 404. A negative fact MAY be minted.
--   UNAVAILABLE  indeterminate: EACCES, timeout, 5xx, no libz, opened-but-empty.
--                A negative fact MUST NOT be minted. The caller records an
--                opaque FRONTIER instead (data.unparsed + an unparsed module
--                node), which ladder.lua already classifies as "neither
--                resolved nor refused" — the honest state.
M.ABSENT = 'absent'
M.UNAVAILABLE = 'unavailable'

local ENOENT = 2 -- the one errno that means absence; every other means unknown

-- ── the disk transport ───────────────────────────────────────────────────────

local disk = {
    name = 'disk',
    -- the fallback: it claims nothing and is chosen only when no registered
    -- transport wants the path
    claims = function () return false end,

    read = function (path)
        local fd, _, errno = io.open(path, 'r')
        if not fd then
            -- ENOENT is the ONLY authoritative absence. Everything else
            -- (EACCES, EIO, ELOOP, …) means "could not determine", which must
            -- not be reported as absence — see M.ABSENT below.
            return nil, (errno == ENOENT) and M.ABSENT or M.UNAVAILABLE
        end
        -- 'a' matches every site this replaced. A directory OPENS on Linux and
        -- reads nil; that is not absence either, so it is indeterminate too.
        local src = fd:read('a')
        fd:close()
        if src == nil then return nil, M.UNAVAILABLE end
        return src
    end,

    stamp = function (path)
        local st = vim.uv.fs_stat(path)
        if not st then return nil, M.ABSENT end
        -- NOTE: stat succeeds on an unreadable (chmod 000) file, so a file that
        -- cannot be READ can still be STAMPED. That is what keeps an
        -- unavailable file cache-honest: it gets a validity key, and a later
        -- refresh notices when it becomes readable.
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
-- place. A transport MISSING an op reports UNAVAILABLE, never ABSENT: "I cannot
-- answer" is not "it is not there", and that is exactly the conflation the two
-- kinds exist to prevent (a zip with no libz can list but not read).

--- Whole-file contents as a string. Returns (nil, err) when unreadable — see
--- M.ABSENT / M.UNAVAILABLE. Callers that only branch on nil are unaffected.
function M.read(path)
    local t = M.for_path(path)
    if not t.read then return nil, M.UNAVAILABLE end
    return t.read(path)
end

--- Contents split into lines. Returns (nil, err) when unreadable; callers that
--- distinguish "tried and failed" from "not tried" keep their own `or false`.
function M.lines(path)
    local src, err = M.read(path)
    if not src then return nil, err end
    return vim.split(src, '\n', { plain = true })
end

--- The validity key for a path. Returns (nil, err) when it has none.
function M.stamp(path)
    local t = M.for_path(path)
    if not t.stamp then return nil, M.UNAVAILABLE end
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
