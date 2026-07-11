-- Range coordinates, eager-but-FOLDED — the seam that became the swap.
-- Occurrence ranges (c.at, e.at lists) and node ranges (n.range) are the
-- same nested {start={line,char}, end={line,char}} type: three tables per
-- range, ~128 MB resident on server. The fold interns every range into
-- four flat coordinate columns and replaces the value with its INDEX; the
-- accessors below are dual-mode (number → column read, table → raw field),
-- so every consumer — all seamed through here by the shape roster + seam
-- rewriter ([[cartograph-shape-roster]]) — reads identically.
--
-- Interning is BY TABLE IDENTITY, which dissolves the banked "all-or-
-- nothing shared pool" hazard: addref aliases c.at tables into e.at lists,
-- and the identity map gives the alias the same index for free. e.at
-- lists mutate IN PLACE (same list table, elements become indexes), so
-- store.occ references stay valid. Same lifecycle as the argv/df folds:
-- fold at ingest, AFTER cache.save encoded raw; idempotent; post-fold
-- arrivals (refresh files, oracle callers, literal highlight ranges)
-- stay raw tables and read through the same accessors.
--
-- The column store is a module-level upvalue (the store is a singleton —
-- one live graph per session); fold() re-points it.

local M = {}

local char, byte, concat = string.char, string.byte, table.concat

-- pack a 1-based number array into an LE-u32 byte string + its getter
-- (the csr.lua discipline: fixed width for RANDOM access — varint would
-- need offsets; coordinates are read by index, not scanned)
local function pack_u32(arr, len)
    local parts = {}
    for i = 1, len do
        local v = arr[i]
        local lo = v % 65536
        parts[i] = char(lo % 256, (lo - lo % 256) / 256,
            (v - v % 65536) / 65536 % 256, (v - v % 16777216) / 16777216 % 256)
    end
    return concat(parts)
end
local function getter(s)
    return function (i)
        local p = (i - 1) * 4 + 1
        local a, b, c, d = byte(s, p, p + 3)
        return a + b * 256 + c * 65536 + d * 16777216
    end
end

local C -- the live column store { sl, sc, el, ec } (packed-string getters)

-- start line / start char / end line / end char of a range
function M.sl(r) if type(r) == 'number' then return C.sl(r) end return r.start.line end
function M.sc(r) if type(r) == 'number' then return C.sc(r) end return r.start.char end
function M.el(r) if type(r) == 'number' then return C.el(r) end return r['end'].line end
function M.ec(r) if type(r) == 'number' then return C.ec(r) end return r['end'].char end

-- whether the range is single-line (the common token case)
function M.oneline(r)
    if type(r) == 'number' then return C.el(r) == C.sl(r) end
    return r.start.line == r['end'].line
end

-- ── the fold: nested range tables → four coordinate columns ──────────────
function M.fold(data)
    if data._atcol then
        C = data._atcol -- re-ingest of an already-folded graph: re-point
        return 0
    end
    local col = { sl = {}, sc = {}, el = {}, ec = {} }
    local seen = {} -- table identity -> index (c.at↔e.at aliasing folds once)
    local n = 0
    local function intern(r)
        local i = seen[r]
        if not i then
            n = n + 1
            local s, e = r.start, r['end']
            col.sl[n], col.sc[n] = s.line, s.char
            col.el[n], col.ec[n] = e.line, e.char
            seen[r] = n
            i = n
        end
        return i
    end
    for _, c in ipairs(data.calls or {}) do
        if type(c.at) == 'table' then c.at = intern(c.at) end
    end
    for _, e in ipairs(data.edges or {}) do
        local at = e.at
        if type(at) == 'table' then
            for i = 1, #at do
                if type(at[i]) == 'table' then at[i] = intern(at[i]) end
            end
        end
    end
    for _, nd in ipairs(data.nodes or {}) do
        if type(nd.range) == 'table' then nd.range = intern(nd.range) end
    end
    -- pack: 4 Lua arrays -> 4 byte strings (16B/range, refs and array
    -- headers gone); the store keeps the getters
    col = { sl = getter(pack_u32(col.sl, n)), sc = getter(pack_u32(col.sc, n)),
        el = getter(pack_u32(col.el, n)), ec = getter(pack_u32(col.ec, n)) }
    data._atcol = col
    C = col
    return n
end

return M
