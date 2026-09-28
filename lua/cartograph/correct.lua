-- cartograph.correct — DID YOU MEAN: candidate corrections for an invocation's arguments (CART-1152).
--
-- USER (2026-09-28): "I wonder if ill-posed could be fixed like a typo (did you mean?)". This module only PROPOSES.
-- It enumerates the values an argument could have meant, and the caller (the tactic runner) keeps the ones for
-- which the VERB ITSELF, with every guard, accepts the corrected call. That is the LCF split again: the corrector is
-- untrusted, and the verb plus its guards are the kernel. A corrector that tried to judge validity would be a second
-- copy of every verb's preconditions.
--
-- An adapter (compose.VERBS) declares which of its arguments are correctable and of what kind:
--   `correct = { ref = 'ref' }` (one durable ref) or `{ seed_refs = 'refs' }` (a list, corrected one element at a time)
--
-- ★ SAFE vs UNSAFE, and why a ref needs the distinction. A durable ref carries a WITNESS, and the witness is a SHAPE
-- fingerprint (refs.witness: parameter count, each statement's def/use/dependency counts, callee names), NOT a body
-- hash. MEASURED: `return x * 2` and `return x + 1` share one. So a witness match is evidence only when it is
-- CONCLUSIVE, meaning no other function in the graph has that shape:
--   the same name AND the same witness elsewhere          -> it MOVED: safe
--   a witness match that is conclusive                    -> the same shape, nothing else has it: safe
--   a witness match that is NOT conclusive, or no witness -> the witness cannot decide, so the NAME does:
--                                                            safe within the slip budget (a hand-typed ref)
--   a witness that DIFFERS from the ref's                 -> the ref's own evidence contradicts it: UNSAFE
-- The runner applies ONLY a unique safe candidate, and otherwise hands the candidates over as a decision.
-- MEASURED (CART-1152): after a move, a stale ref to M.dbl resolved to the neighbour M.keep, and a write adapter moved
-- M.keep. An unsafe candidate is the same failure one step removed.
local M = {}

local near = require 'cartograph.near'

local function fns(store)
    local out = {}
    for _, n in ipairs(store.data.nodes or {}) do
        if n.kind == 'function' or n.kind == 'method' then out[#out + 1] = n end
    end
    return out
end

--- candidate refs for `ref` (one that did not resolve cleanly): { { value = fresh ref, d, why, safe } }
local function ref_candidates(store, ref)
    if type(ref) ~= 'table' or type(ref.name) ~= 'string' then return {} end
    local out, seen = {}, {}
    local all = fns(store)
    -- how many functions share each witness: a shape held by several decides nothing
    local shape_count = {}
    for _, n in ipairs(all) do
        local w = (store.ref_of(n.id) or {}).witness
        if w then shape_count[w] = (shape_count[w] or 0) + 1 end
    end
    local function add(n, d, why, source)
        if seen[n.id] then return end
        local fresh = store.ref_of(n.id)
        if not fresh then return end
        seen[n.id] = true
        local match = ref.witness ~= nil and fresh.witness == ref.witness
        local conclusive = match and shape_count[fresh.witness] == 1
        local safe
        if match and n.name == ref.name then safe = true              -- moved
        elseif conclusive then safe = true                            -- a shape nothing else has
        elseif ref.witness == nil or match then safe = d <= near.cap(ref.name) -- the name decides
        else safe = false end                                         -- the ref's own witness contradicts it
        out[#out + 1] = { value = fresh, d = d, why = why, safe = safe, source = source,
            contradicts = (ref.witness ~= nil and not match) or nil }
    end
    -- (1) the same name AND the same shape somewhere else: it MOVED
    if ref.witness then
        for _, n in ipairs(all) do
            if n.file ~= ref.file and n.name == ref.name and store.ref_of(n.id).witness == ref.witness then
                add(n, 0, ('%s moved to %s (the same name and shape)'):format(ref.name, n.file), 'moved')
            end
        end
    end
    -- (2) a near name in the SAME file: a typo in the name
    local names, by_name = {}, {}
    for _, n in ipairs(all) do
        if n.file == ref.file then
            names[#names + 1] = n.name
            by_name[n.name] = by_name[n.name] or {}
            table.insert(by_name[n.name], n)
        end
    end
    for _, c in ipairs(near.within(ref.name, names)) do
        for _, n in ipairs(by_name[c.value]) do add(n, c.d, ('%s is %d edit(s) from %s in %s'):format(c.value, c.d, ref.name, n.file), 'near') end
    end
    -- (2b) the ref's SHAPE under another name in the same file: a possible RENAME (inferred — the witness is a shape)
    if ref.witness then
        for _, n in ipairs(all) do
            if n.file == ref.file and n.name ~= ref.name and store.ref_of(n.id).witness == ref.witness then
                add(n, near.dist(ref.name, n.name, 99), ('%s has the ref\'s shape in %s — renamed?'):format(n.name, n.file), 'renamed')
            end
        end
    end
    -- (3) the exact name in ANOTHER file: a typo in the file (or a move whose body changed — the witness says which)
    for _, n in ipairs(all) do
        if n.file ~= ref.file and n.name == ref.name then add(n, 0, ('%s is defined in %s, not %s'):format(ref.name, n.file, tostring(ref.file)), 'elsewhere') end
    end
    table.sort(out, function (a, b)
        if a.safe ~= b.safe then return a.safe end
        if a.d ~= b.d then return a.d < b.d end
        return tostring(a.value.file) .. a.value.name < tostring(b.value.file) .. b.value.name
    end)
    return out
end

--- is the symbol a WITNESSED ref names GONE — no function of that name left in its file, none of that name anywhere
--- with its shape, and its shape nowhere in its file under another name (that would be a possible rename)? A witness means the ref was taken from a real node, so this is a deletion or a move nobody
--- recorded, not a typo: the caller is told it is gone, and near names are information, never the answer.
function M.gone(store, ref)
    if type(ref) ~= 'table' or not ref.witness or not ref.name then return false end
    for _, n in ipairs(fns(store)) do
        local w = (store.ref_of(n.id) or {}).witness
        if n.name == ref.name and (n.file == ref.file or w == ref.witness) then return false end
        -- its shape still in its file under another name: a possible rename, not a deletion
        if n.file == ref.file and w == ref.witness then return false end
    end
    return true
end

M.KINDS = {}

--- a single ref argument
function M.KINDS.ref(store, value)
    local id, note = store.resolve_ref(value or {})
    if id and not note then return {} end -- it resolves cleanly: nothing to correct
    return ref_candidates(store, value)
end

--- a list of refs: each element that does not resolve cleanly, corrected on its own
function M.KINDS.refs(store, value)
    local out = {}
    for i, ref in ipairs(value or {}) do
        for _, c in ipairs(M.KINDS.ref(store, ref)) do
            local list = {}
            for j, r in ipairs(value) do list[j] = r end
            list[i] = c.value
            out[#out + 1] = { value = list, d = c.d, why = ('seed %d: %s'):format(i, c.why), safe = c.safe, element = i,
                source = c.source, contradicts = c.contradicts, was = ref, now = c.value }
        end
    end
    return out
end

local function copy(t) local o = {}; for k, v in pairs(t) do o[k] = v end; return o end

--- every single-argument correction of `args` that `spec.correct` declares: { { args, arg, from, to, d, why, safe } },
--- nearest first, at most `limit` (default 8). ONE argument per candidate: a correction that changes two things at
--- once is a different request, not a typo.
function M.suggest(store, spec, args, limit)
    local out = {}
    for arg, kind in pairs((spec or {}).correct or {}) do
        local gen = M.KINDS[kind]
        if gen then
            for _, c in ipairs(gen(store, args[arg])) do
                local a = copy(args)
                a[arg] = c.value
                out[#out + 1] = { args = a, arg = arg, from = args[arg], to = c.value, d = c.d, why = c.why, safe = c.safe,
                    source = c.source, contradicts = c.contradicts, was = c.was or args[arg], now = c.now or c.value }
            end
        end
    end
    table.sort(out, function (a, b) if a.safe ~= b.safe then return a.safe end return a.d < b.d end)
    local lim = limit or 8
    while #out > lim do out[#out] = nil end
    return out
end

return M
