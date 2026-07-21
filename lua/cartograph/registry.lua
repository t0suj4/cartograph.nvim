-- The central NAME REGISTRY — the N-axis top ([[cartograph-record-fold-arc]],
-- [[cartograph-scaling-sharded-index]]). ONE object serving several arcs:
--   * STRUCTURED node-ids: the fold's node-id residue `file::name@line` is a
--     full string PER NODE (the file prefix repeated on every one). Split into
--     (file-id, name-id, line) over interned file/name pools → the prefix is
--     stored ONCE. Win is path-depth-dependent (MEASURED: ~10× on deep-package
--     Java, ~2× on shallow zig/lua — the file prefix is where it concentrates).
--   * CROSS-FOLD dedup: df/flow/argv/at each carry their own name pool today;
--     pointing them at ONE registry dedups the ~half that overlap (measured
--     52-56% union across df ∪ flow ∪ node-short-names).
--   * MERGE ⊤: a shared name dict is what lets folded segments merge WITHOUT an
--     id remap (the [[cartograph-fold-core]] merge lattice's top) — the scale
--     lever fold.merge's ⊥ concat cut is the first step toward.
--
-- TWO ID SPACES (the answer to "do we decode varints when we key on them?"):
--   * HOT / working = fixed-width int = the KEY (hash/join/deref/equality).
--   * COLD / wire = FREQUENCY-ORDERED VARINT (rank 1 = most frequent = 1 byte).
--     Retires the u16-vs-u32 width question: Zipfian mentions average <2 B/slot
--     AND the registry is unbounded (generated/minified names get high ranks =
--     rare = few bytes → cost ∝ usage). Decode ONCE at the cold→hot boundary.
-- This module is PURE (no store/parser dependency) so it always runs; the
-- identity round-trip is the correctness gate, size/varint are measured.

local csr = require 'cartograph.csr'

local M = {}

local floor, char, byte = math.floor, string.char, string.byte

-- ── node-id identity: split / join (the exact, reversible grammar) ───────
-- Node ids are minted as `file '::' mid '@' <line>` (mid may carry a
-- var:/type:/region discriminator — it rides inside mid, so a single split on
-- the FIRST '::' and the LAST '@<digits>' round-trips every shape). Ids that
-- don't match (module = bare file, minted `zig-std::…`, `\0frontier`, DSL ids
-- like `route::x` with no line) return nil → the caller stores them whole.
function M.split(id)
    local file, mid, line = id:match('^(.-)::(.*)@(%d+)$')
    if file then return file, mid, tonumber(line) end
    return nil
end

function M.join(file, mid, line)
    return file .. '::' .. mid .. '@' .. line
end

-- ── frequency-ordered varint (the COLD/wire form) ───────────────────────
-- unsigned LEB128 of one non-negative int
function M.uvarint(x)
    local parts, i = {}, 0
    repeat
        local b = x % 128
        x = floor(x / 128)
        if x > 0 then b = b + 128 end
        i = i + 1; parts[i] = char(b)
    until x == 0
    return table.concat(parts)
end

-- read one varint at 1-based `pos`; returns value, next-pos
function M.read_uvarint(s, pos)
    local result, shift, b = 0, 1, 0
    repeat
        b = byte(s, pos); pos = pos + 1
        result = result + (b % 128) * shift
        shift = shift * 128
    until b < 128
    return result, pos
end

-- pack a sequence of non-negative ints to a varint byte string
function M.pack_varints(ints)
    local parts = {}
    for i = 1, #ints do parts[i] = M.uvarint(ints[i]) end
    return table.concat(parts)
end

-- unpack `count` varints from a byte string
function M.unpack_varints(s, count)
    local out, pos = {}, 1
    for i = 1, count do out[i], pos = M.read_uvarint(s, pos) end
    return out
end

-- frequency remap over a mention sequence: rank[id] = 1..k (1 = most frequent,
-- so it varint-encodes to the fewest bytes), inv[rank] = id (for decode).
-- Deterministic tiebreak (equal freq → smaller id first) so the remap is stable
-- worker==inline (the freeze-time canonical order the two-phase producer plans).
function M.freq_order(seq)
    local freq = {}
    for i = 1, #seq do local id = seq[i]; freq[id] = (freq[id] or 0) + 1 end
    local uniq, k = {}, 0
    for id in pairs(freq) do k = k + 1; uniq[k] = id end
    table.sort(uniq, function (a, b)
        if freq[a] ~= freq[b] then return freq[a] > freq[b] end
        return a < b
    end)
    local rank, inv = {}, {}
    for r = 1, k do rank[uniq[r]] = r; inv[r] = uniq[r] end
    return rank, inv
end

-- ── the registry instance ────────────────────────────────────────────────
local Reg = {}
Reg.__index = Reg

function M.new()
    return setmetatable({ files = csr.interner(), names = csr.interner() }, Reg)
end

-- intern a node-id string → a compact record. Matched ids split into
-- { f = file-id, n = name-id, line }; unmatched ids keep the whole string in
-- the NAME pool as { lit = name-id }. Ids are the HOT fixed-width int keys.
function Reg:add(id)
    local file, mid, line = M.split(id)
    if file then
        return { f = self.files.id(file), n = self.names.id(mid), line = line }
    end
    return { lit = self.names.id(id) }
end

-- exact inverse of add: record → the original node-id string
function Reg:reconstruct(rec)
    if rec.lit ~= nil then return self.names.name(rec.lit) end
    return M.join(self.files.name(rec.f), self.names.name(rec.n), rec.line)
end

-- byte size of the two string pools (the resident cost the split replaces the
-- per-node full strings with): file pool, name pool
function Reg:pool_bytes()
    local fb, nb = 0, 0
    for _, s in ipairs(self.files.list) do fb = fb + #s + 1 end
    for _, s in ipairs(self.names.list) do nb = nb + #s + 1 end
    return fb, nb
end

function Reg:counts() return self.files.count(), self.names.count() end

return M
