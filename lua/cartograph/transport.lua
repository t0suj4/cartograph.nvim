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

-- ── KINDS: the load-time registry ────────────────────────────────────────────
-- Declared in-file, like source.lua's provider registry and shapes.lua's
-- M.registry — NOT mutated at runtime. A kind is a constructor: config table in,
-- transport out (or nil when the substrate is unavailable, e.g. no libz).
--
-- WHY A KIND NAME AND NOT THE TRANSPORT ITSELF: extraction runs in SPAWNED nvim
-- processes (parallel.lua:149) that receive their job as JSON (worker.lua:17-21).
-- A transport table has function fields and cannot cross vim.json.encode, so the
-- parent ships a DECLARATIVE SPEC and the worker rebuilds it — exactly how a
-- multi-root corpus ships `job.roots` and the worker reconstructs `abs`, and how
-- `job.packs` ships pack NAMES. A module-global registry would simply not exist
-- in a worker: every claimed path would silently fall back to disk.
M.kinds = {
    disk = function () return disk end,
}

-- ── STACKS: composition is a VALUE ───────────────────────────────────────────
-- A stack answers the same op set as a single transport, so it is substitutable
-- for one and callers never learn which they hold: `(opts.transport or
-- transport).read(path)`. Order matters — the first kind that CLAIMS a path
-- serves it, and disk is the implicit tail.
--
-- A transport MISSING an op reports UNAVAILABLE, never ABSENT: "I cannot answer"
-- is not "it is not there", which is the conflation the two kinds exist to
-- prevent (a zip with no libz can list but not read).

local function make(transports, spec)
    local S = { spec = spec }

    --- Which transport serves this path. Never nil: disk answers by default.
    function S.for_path(path)
        for _, t in ipairs(transports) do
            if t.claims(path) then return t end
        end
        return disk
    end

    --- Whole-file contents as a string. Returns (nil, err) when unreadable — see
    --- M.ABSENT / M.UNAVAILABLE. Callers that only branch on nil are unaffected.
    function S.read(path)
        local t = S.for_path(path)
        if not t.read then return nil, M.UNAVAILABLE end
        return t.read(path)
    end

    --- Contents split into lines. Returns (nil, err) when unreadable; callers
    --- that distinguish "tried and failed" from "not tried" keep `or false`.
    function S.lines(path)
        local src, err = S.read(path)
        if not src then return nil, err end
        return vim.split(src, '\n', { plain = true })
    end

    --- The validity key for a path. Returns (nil, err) when it has none.
    function S.stamp(path)
        local t = S.for_path(path)
        if not t.stamp then return nil, M.UNAVAILABLE end
        return t.stamp(path)
    end

    --- Iterator over a container's entries, yielding (name, type).
    function S.dir(path)
        local t = S.for_path(path)
        if not t.dir then return function () return nil end end
        return t.dir(path)
    end

    --- uv-shaped stat, for callers needing type/size beyond the stamp.
    function S.stat(path)
        local t = S.for_path(path)
        return t.stat and t.stat(path) or nil
    end

    --- Canonical path, or nil where the substrate has no such notion. A
    --- transport without link semantics never yields type 'link', so callers
    --- that resolve aliases never reach this.
    function S.realpath(path)
        local t = S.for_path(path)
        return t.realpath and t.realpath(path) or nil
    end

    return S
end

--- Build a live stack from a DECLARATIVE spec: { {kind='zip', …}, {kind='disk'} }.
--- The spec is plain data, so it ships in a jobfile and a worker rebuilds the
--- identical stack. An unknown kind is an error, not a silent fallback to disk —
--- a typo must not degrade a corpus to "everything unreadable but no complaint".
--- A kind that returns nil is SKIPPED: the substrate is genuinely unavailable
--- (no libz), which the ops then report per-path as UNAVAILABLE.
function M.build(spec)
    local ts = {}
    for _, e in ipairs(spec or {}) do
        local kind = M.kinds[e and e.kind]
        if not kind then
            error(('transport: unknown kind %q (have: %s)')
                :format(tostring(e and e.kind), table.concat(vim.tbl_keys(M.kinds), ', ')))
        end
        local t = kind(e)
        if t then ts[#ts + 1] = t end
    end
    return make(ts, spec)
end

-- ── the front door ───────────────────────────────────────────────────────────
-- The module IS a disk-only stack, so a caller with no threaded transport can
-- use `transport.read(path)` unchanged. Derived from make() rather than written
-- twice, so the two can never drift.

local disk_only = make({}, { { kind = 'disk' } })
M.for_path, M.read, M.lines = disk_only.for_path, disk_only.read, disk_only.lines
M.stamp, M.dir = disk_only.stamp, disk_only.dir
M.stat, M.realpath = disk_only.stat, disk_only.realpath
M.spec = disk_only.spec

return M
