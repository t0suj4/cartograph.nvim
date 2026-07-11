-- The FOLD: calls[] + edges[] + every axis = ONE typed-edge triple table.
-- A resolved call IS an edge; a refused call is a frontier fact. All four
-- edge kinds (ref/use/reg/import) are already (subject, predicate, object)
-- triples with a forward view (uses/imports_out/…) and a backward view
-- (usedby/imports_in/…) in the wide store — this materializes that latent
-- structure as ONE columnar fact table over an interned 0-based node space
-- plus TWO indexes (by-subject, by-object) so every axis reads both
-- directions off the same rows. argv/at/statement detail are DROPPED here
-- (reconstruct-on-demand — ~98% of the wide bytes); this is topology.
--
-- Rung (a) of the CSR ladder: a PURE POST-PASS. Wide data in, folded table
-- out, ZERO consumers changed — measured against the memo's 32.5× prototype
-- and parity-checked against the live store's forward/backward indexes.
--
-- Layout: parallel 1-based columns subj[]/pred[]/obj[] (interned ints).
-- Rows are grouped by subject (by-subject = offsets, no permutation) and a
-- transpose permutation groups them by object (by-object = offsets + perm).
-- Predicate is a column; a per-kind query is a predicate-filtered slice.

local csr = require 'cartograph.csr'

local M = {}

-- predicate ids (dense, stable within a build; the fold's "kind" column)
M.PRED = { ref = 0, use = 1, reg = 2, import = 3, refused = 4 }
M.PRED_NAME = { [0] = 'ref', 'use', 'reg', 'import', 'refused' }

-- the FLAGS column (u8/row): the honesty model, folded — and the VM's write
-- medium ([[graph-vm-type-resolution]]). WITHOUT it a confident edge and a
-- name-matched ~ hypothesis are indistinguishable, and invariant #3 (uniform
-- honesty) dies at the fold boundary. Layout, tier space RESERVED for the VM:
--   bit 0 (0x01)  INFERRED  — the ~ tier (name-matched, not confident)
--   bits 1-3      REFUSAL RULE (refused rows) — see M.RULE
--   bit 4  (0x10) TYPE_INFERRED — the graph-VM resolved it via a return-type
--                 summary (the honesty ladder's middle rung, stronger than ~)
--   bit 5  RESERVED for the VM ladder (runtime-confirmed)
--   bits 6-7 RESERVED for provenance (which pass set it)
M.FLAG = { INFERRED = 1, TYPE_INFERRED = 16 }
M.RULE = { none = 0, ambiguous = 1, blocked = 2, vocab = 3,
    aperture = 4, samefile = 5, other = 6 }
M.RULE_NAME = { [0] = 'none', 'ambiguous', 'blocked', 'vocab',
    'aperture', 'samefile', 'other' }
local RULE_SHIFT = 2 -- rule occupies bits 1-3 → value * 2

local floor, char, byte = math.floor, string.char, string.byte

local function pack_u32(arr, len) -- 1-based arr[1..len] → LE u32 bytes
    local parts = {}
    for i = 1, len do
        local x = arr[i]
        parts[i] = char(x % 256, floor(x / 256) % 256,
            floor(x / 65536) % 256, floor(x / 16777216) % 256)
    end
    return table.concat(parts)
end

-- 0-based offset array [0..len-1] → LE u32 bytes, and its reader
local function pack_u32_off(arr, len)
    local parts = {}
    for i = 0, len - 1 do
        local x = arr[i]
        parts[i + 1] = char(x % 256, floor(x / 256) % 256,
            floor(x / 65536) % 256, floor(x / 16777216) % 256)
    end
    return table.concat(parts)
end
local function u32_reader(s)
    return function (i)
        local p = i * 4 + 1
        local a, b, c, d = byte(s, p, p + 3)
        return a + b * 256 + c * 65536 + d * 16777216
    end
end

local Fold = {}
Fold.__index = Fold

-- rows [lo,hi) of `subj`'s facts (0-based node id); read pred/obj by row
function Fold:subj_span(subj)
    local go = self._so
    return go(subj), go(subj + 1)
end
-- rows [lo,hi) into the OBJECT permutation for `obj`; perm(j) → a fact row
function Fold:obj_span(obj)
    local go = self._oo
    return go(obj), go(obj + 1)
end

-- forward slice: objects reached from `subj` via predicate `pred` (0-based
-- node ids; nil pred = all). Returns a fresh list (convenience, not a hot
-- loop — hot loops walk subj_span + the columns directly). `no_self` drops
-- self-loops: recursion IS a real fact (stored), but the reachability/heat/
-- lint VIEW excludes it, exactly as the wide store's uses/usedby do.
function Fold:out(subj, pred, no_self)
    local lo, hi = self:subj_span(subj)
    local out, k = {}, 0
    for r = lo, hi - 1 do
        local o = self.obj[r + 1]
        if (not pred or self.pred[r + 1] == pred)
            and not (no_self and o == subj) then
            k = k + 1; out[k] = o
        end
    end
    return out
end

-- backward slice: subjects that reach `obj` via `pred` (the free reverse —
-- callers/used-by/imported-by/registrants, one machinery)
function Fold:incoming(obj, pred, no_self)
    local lo, hi = self:obj_span(obj)
    local out, k = {}, 0
    for r = lo, hi - 1 do
        local row = self._perm(r) -- 0-based fact row
        local s = self.subj[row + 1]
        if (not pred or self.pred[row + 1] == pred)
            and not (no_self and s == obj) then
            k = k + 1; out[k] = s
        end
    end
    return out
end

-- resident/serialized size of the folded core, exact (3 u32 columns + the
-- u8 flags column + 2 offset arrays + the object permutation)
function Fold:bytes()
    local cols = self.m * 4 * 3 + self.m      -- subj/pred/obj (u32) + flag (u8)
    local idx = (self.n + 1) * 4 * 2 + self.m * 4 -- 2 offsets + 1 perm
    return cols + idx
end

-- the certainty of a specific edge (subject→object via pred, 0-based ids):
-- 'confident' | 'inferred' | nil (no such edge). O(out-degree) point query.
function Fold:tier(subj, obj, pred)
    local lo, hi = self:subj_span(subj)
    for r = lo, hi - 1 do
        if self.obj[r + 1] == obj and (not pred or self.pred[r + 1] == pred) then
            local f = self.flag[r + 1]
            if f >= M.FLAG.TYPE_INFERRED and f % 32 >= M.FLAG.TYPE_INFERRED then
                return 'type-inferred'
            end
            return (f % 2 == 1) and 'inferred' or 'confident'
        end
    end
    return nil
end

-- the refusal rules at `subj` (frontier facts): a list of rule NAMES, the
-- honest "what did we decline to resolve here, and why"
function Fold:refusals(subj)
    local lo, hi = self:subj_span(subj)
    local out, k = {}, 0
    for r = lo, hi - 1 do
        if self.pred[r + 1] == M.PRED.refused then
            local rule = floor(self.flag[r + 1] / 2) % 8
            k = k + 1; out[k] = M.RULE_NAME[rule] or 'other'
        end
    end
    return out
end

-- byte size of the interned node-name string table (the only non-columnar
-- part; the wide form repeats these strings on every edge/call record)
function Fold:string_bytes()
    local total = 0
    for _, s in ipairs(self.names) do total = total + #s + 1 end -- +len prefix
    return total
end

-- ── build: wide data → folded triple table ──────────────────────────────
function M.build(data)
    local it = csr.interner()
    -- intern every node first so isolated nodes exist and ids are stable in
    -- emission order (the memo's stable-id principle; layout ≠ identity)
    for _, n in ipairs(data.nodes or {}) do it.id(n.id) end
    local SENTINEL = it.id('\0frontier') -- refused calls point here

    local subj, pred, obj, flag, m = {}, {}, {}, {}, 0
    local function emit(s, p, o, f)
        m = m + 1
        subj[m] = it.id(s); pred[m] = p; obj[m] = it.id(o); flag[m] = f or 0
    end
    local skipped_edge, skipped_refused = 0, 0

    for _, e in ipairs(data.edges or {}) do
        local p = M.PRED[e.kind]
        if p and e.from and e.to then
            emit(e.from, p, e.to,
                (e.inferred and M.FLAG.INFERRED or 0)
                + (e.tinf and M.FLAG.TYPE_INFERRED or 0))
        else
            skipped_edge = skipped_edge + 1
        end
    end
    -- refused calls = frontier facts (sentinel object), only per-fn ones
    -- (top-level refusals have no subject to hang on — counted, not folded).
    -- The rule rides the flags nibble: an aperture frontier and an ambiguous
    -- one are DIFFERENT honesty, and the fold must keep the distinction.
    for _, c in ipairs(data.calls or {}) do
        if c.refused then
            if c.fn then
                local rule = M.RULE[c.refused.rule] or M.RULE.other
                emit(c.fn, M.PRED.refused, '\0frontier', rule * RULE_SHIFT)
            else
                skipped_refused = skipped_refused + 1
            end
        end
    end

    local n = it.count()

    -- by-subject: counting sort on subj → offsets + a stable grouping. We
    -- sort the fact rows into subject order so a subject's rows are one
    -- contiguous slice (offsets only). Keeps subj/pred/obj aligned.
    local off = {}
    for i = 0, n do off[i] = 0 end
    for k = 1, m do off[subj[k] + 1] = off[subj[k] + 1] + 1 end
    for i = 1, n do off[i] = off[i] + off[i - 1] end
    local order, cur = {}, {}
    for i = 0, n do cur[i] = off[i] end
    for k = 1, m do
        local u = subj[k]
        order[cur[u] + 1] = k   -- 1-based fact row at 0-based slot cur[u]
        cur[u] = cur[u] + 1
    end
    -- permute the columns into subject order (so subj_span reads directly)
    local s2, p2, o2, f2 = {}, {}, {}, {}
    for slot = 1, m do
        local k = order[slot]
        s2[slot] = subj[k]; p2[slot] = pred[k]; o2[slot] = obj[k]; f2[slot] = flag[k]
    end
    subj, pred, obj, flag = s2, p2, o2, f2

    -- by-object: transpose — offsets over obj + a permutation of rows
    local ooff = {}
    for i = 0, n do ooff[i] = 0 end
    for k = 1, m do ooff[obj[k] + 1] = ooff[obj[k] + 1] + 1 end
    for i = 1, n do ooff[i] = ooff[i] + ooff[i - 1] end
    local perm, ocur = {}, {}
    for i = 0, n do ocur[i] = ooff[i] end
    for k = 1, m do
        local v = obj[k]
        perm[ocur[v] + 1] = k - 1  -- store 0-based fact row
        ocur[v] = ocur[v] + 1
    end

    -- freeze offsets as u32 byte strings (serialization-native), with
    -- closures over them; columns stay Lua arrays for now (the row explosion
    -- the memo warns about is argv/statement detail, not these 3 columns)
    local off_s = pack_u32_off(off, n + 1)
    local ooff_s = pack_u32_off(ooff, n + 1)
    local perm_s = pack_u32(perm, m)

    local self = setmetatable({
        n = n, m = m, it = it, names = it.list,
        subj = subj, pred = pred, obj = obj, flag = flag,
        sentinel = SENTINEL,
        skipped_edge = skipped_edge, skipped_refused = skipped_refused,
        _so = u32_reader(off_s), _oo = u32_reader(ooff_s),
        _perm = u32_reader(perm_s),
        _off_s = off_s, _ooff_s = ooff_s, _perm_s = perm_s,
    }, Fold)
    return self
end

return M
