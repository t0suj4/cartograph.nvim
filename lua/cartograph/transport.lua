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
-- read has a RANGED form (read_range), and that is what makes a container
-- COMPOSABLE over another substrate instead of special-cased inside it: a zip
-- asks its backing transport for byte ranges and never learns whether they came
-- from disk, an archive, or a wire — read_range IS HTTP Range. Optional; a
-- substrate that cannot seek inherits a whole-read-and-slice fallback that is
-- correct and slow. Measured stake on a 201 MB mod archive: reading the trailer
-- as a range is 40.5 ms against 2179 ms and 201 MB resident for the whole file.
--
-- WHAT NOT TO BUILD, measured 2026-07-26: SPAN COALESCING. In that same archive
-- the 165 .lua entries total 132 KB scattered over a 138.8 MB span — 0.1%
-- density — so ONE coalesced span read is 6x SLOWER than 165 separate ranges.
-- The cost driver is round-trip COUNT, not bytes, so the wire lever is
-- multi-range requests plus adjacency-merge for genuinely adjacent ranges. Never
-- bulk prefetch.
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

    --- A BYTE RANGE: at most `len` bytes from 0-based offset `off`. A NEGATIVE
    --- off is a SUFFIX range counted from EOF (HTTP `bytes=-N`), which is the
    --- primitive a container needs to find its trailer without pulling the whole
    --- thing. Semantics pinned by measurement, because they are all reachable:
    ---   · a short read is normal — len past EOF returns what is there
    ---   · at or past EOF, Lua's read returns nil; that is ZERO BYTES AVAILABLE,
    ---     not a failure, so it comes back '' and leaves the error channel
    ---     meaning only "could not determine"
    ---   · seek('end', -n) ERRORS when n exceeds the file, so a suffix range
    ---     clamps to the start rather than failing
    ---   · len <= 0 is '' with no I/O at all
    --- 'rb' here, unlike read()'s 'r': ranges are for binary containers, and this
    --- op has no fidelity constraint to a site it replaced.
    read_range = function (path, off, len)
        if len ~= nil and len <= 0 then return '' end
        local fd, _, errno = io.open(path, 'rb')
        if not fd then
            return nil, (errno == ENOENT) and M.ABSENT or M.UNAVAILABLE
        end
        local pos
        if off and off < 0 then
            local size = fd:seek('end')
            pos = fd:seek('set', math.max(0, (size or 0) + off))
        else
            pos = fd:seek('set', off or 0)
        end
        if not pos then fd:close(); return nil, M.UNAVAILABLE end
        local got = len and fd:read(len) or fd:read('a')
        fd:close()
        return got or ''
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

    --- A byte range. Falls back to a whole read plus a slice when the substrate
    --- cannot seek (a stream, a `git show` pipe) — CORRECT but O(file) per range,
    --- which is exactly why a container transport should implement the op instead
    --- of inheriting this. Callers that care can ask: for_path(p).read_range.
    --- Measured stake: on a 201 MB archive, the trailer via a range is 40.5 ms
    --- against 2179 ms and 201 MB resident for the whole-read path.
    function S.read_range(path, off, len)
        local t = S.for_path(path)
        if t.read_range then return t.read_range(path, off, len) end
        if not t.read then return nil, M.UNAVAILABLE end
        if len ~= nil and len <= 0 then return '' end
        local src, err = t.read(path)
        if not src then return nil, err end
        local start = (off and off < 0) and math.max(0, #src + off) or (off or 0)
        return src:sub(start + 1, len and (start + len) or nil)
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
M.read_range = disk_only.read_range
M.stamp, M.dir = disk_only.stamp, disk_only.dir
M.stat, M.realpath = disk_only.stat, disk_only.realpath
M.spec = disk_only.spec

return M
