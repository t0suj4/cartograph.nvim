-- CSR (compressed sparse row): the resident representation for the graph's
-- edge topology — offsets[node] + a flat neighbors[] over an interned 0-based
-- node space. Two interchangeable backends behind ONE interface:
--   * ffi     — LuaJIT uint32 arrays (fastest; nvim always has it)
--   * string  — packed little-endian bytes (any Lua 5.1+, immutable, and the
--               SERIALIZATION-NATIVE form: the bytes ARE the on-disk/wire bytes)
-- Build is an O(n+m) counting sort. Measured (see the design memo): 6.3–6.7
-- B/edge (exact; string==ffi), 3.7–5.4× smaller than the table-of-arrays it
-- replaces (widening with repo size / memory pressure), ~37× faster to build.
-- Neighbor access, two poles (benchmarked): FAST `span`+`at` (~1.05× raw cdata,
-- no alloc) for traversals; CONVENIENCE `neighbors()` (allocates, ~11×) for
-- one-offs. (The callback `each` was dropped — slower than span, less handy
-- than neighbors.)
-- This is the "u32 backend behind an accessor" first step — pure, zero consumer
-- commitment; everything (fold columns, sharding, merge) layers on it.

local M = {}

local ok_ffi, ffi = pcall(require, 'ffi')
M.have_ffi = ok_ffi
M.default_backend = ok_ffi and 'ffi' or 'string'

local byte, char, floor = string.byte, string.char, math.floor

-- ── interner: opaque key → 0-based int id ────────────────────────────────
function M.interner()
    local map, list, n = {}, {}, 0
    return {
        id = function (key)
            local i = map[key]
            if not i then i = n; map[key] = i; list[i + 1] = key; n = n + 1 end
            return i
        end,
        name = function (i) return list[i + 1] end,
        get = function (key) return map[key] end, -- non-mutating: id or nil
        count = function () return n end,
        list = list,
    }
end

-- pack a 0-based Lua int array [0..len-1] into a little-endian u32 byte string
local function pack_u32(arr, len)
    local parts = {}
    for i = 0, len - 1 do
        local x = arr[i]
        parts[i + 1] = char(x % 256, floor(x / 256) % 256,
            floor(x / 65536) % 256, floor(x / 16777216) % 256)
    end
    return table.concat(parts)
end

-- a 0-based u32 reader over a packed byte string
local function string_getter(s)
    return function (i)
        local p = i * 4 + 1
        local a, b, c, d = byte(s, p, p + 3)
        return a + b * 256 + c * 65536 + d * 16777216
    end
end

-- ── CSR object ───────────────────────────────────────────────────────────
local CSR = {}
CSR.__index = CSR

-- out-degree of `node` (0-based)
function CSR:degree(node) return self._go(node + 1) - self._go(node) end

-- FAST PATH: the [lo, hi) bounds of `node`'s neighbor slice in the flat array;
-- read values through the `at` FIELD-closure (not a method → no dispatch):
--   local lo, hi = g:span(n); for j = lo, hi - 1 do use(g.at(j)) end
-- Measured ~1.05× raw cdata, backend-agnostic, zero allocation. Use in
-- traversals/reducers. (`g.at` is set per-object in freeze/unpack.)
function CSR:span(node) return self._go(node), self._go(node + 1) end

-- CONVENIENCE: a materialized neighbor list. ALLOCATES a table per call
-- (~11× the span fast path, measured) — for one-off queries, NEVER hot loops.
function CSR:neighbors(node)
    local t, k, at = {}, 0, self.at
    for j = self._go(node), self._go(node + 1) - 1 do k = k + 1; t[k] = at(j) end
    return t
end

-- resident size in bytes (exact — packed, no per-object overhead)
function CSR:bytes() return (self.n + 1) * 4 + self.m * 4 end

-- serialize to two byte strings (off, nbr). For the string backend these ARE
-- the resident bytes (no copy); for ffi they're packed out.
function CSR:pack()
    if self.backend == 'string' then return self._off_s, self._nbr_s end
    local off, nbr = {}, {}
    for i = 0, self.n do off[i] = self._go(i) end
    for j = 0, self.m - 1 do nbr[j] = self.at(j) end
    return pack_u32(off, self.n + 1), pack_u32(nbr, self.m)
end

local function freeze(off, nbr, n, m, backend)
    local self = setmetatable({ n = n, m = m, backend = backend }, CSR)
    if backend == 'ffi' then
        if not ok_ffi then error('csr: ffi backend requested but ffi unavailable') end
        local o = ffi.new('uint32_t[?]', n + 1)
        local b = ffi.new('uint32_t[?]', m > 0 and m or 1)
        for i = 0, n do o[i] = off[i] end
        for j = 0, m - 1 do b[j] = nbr[j] end
        self._off, self._nbr = o, b -- keep cdata alive
        self._go = function (i) return o[i] end
        self.at = function (j) return b[j] end
    elseif backend == 'string' then
        local os, bs = pack_u32(off, n + 1), pack_u32(nbr, m)
        self._off_s, self._nbr_s = os, bs
        self._go, self.at = string_getter(os), string_getter(bs)
    else
        error('csr: unknown backend ' .. tostring(backend))
    end
    return self
end

-- ── build: parallel 1-based edge arrays from[]/to[] (0-based ids), n nodes ──
function M.build(from, to, n, opts)
    local backend = (opts and opts.backend) or M.default_backend
    local m = #from
    -- degree → exclusive-prefix offsets → scatter (counting sort, O(n+m))
    local off = {}
    for i = 0, n do off[i] = 0 end
    for k = 1, m do local u = from[k]; off[u + 1] = off[u + 1] + 1 end
    for i = 1, n do off[i] = off[i] + off[i - 1] end -- off[i] = start of node i
    local nbr, cur = {}, {}
    for i = 0, n do cur[i] = off[i] end
    for k = 1, m do local u = from[k]; nbr[cur[u]] = to[k]; cur[u] = cur[u] + 1 end
    return freeze(off, nbr, n, m, backend)
end

-- convenience: build from edge records {from=<key>, to=<key>}; both endpoints
-- interned into one 0-based space. Returns csr, interner.
function M.from_edges(edges, opts)
    local it = M.interner()
    local from, to = {}, {}
    for k = 1, #edges do
        local e = edges[k]
        from[k] = it.id(e.from)
        to[k] = it.id(e.to)
    end
    return M.build(from, to, it.count(), opts), it
end

-- load a serialized CSR (string backend) — the cache-read path
function M.unpack(off_bytes, nbr_bytes, n, m)
    local self = setmetatable({ n = n, m = m, backend = 'string' }, CSR)
    self._off_s, self._nbr_s = off_bytes, nbr_bytes
    self._go, self.at = string_getter(off_bytes), string_getter(nbr_bytes)
    return self
end

return M
