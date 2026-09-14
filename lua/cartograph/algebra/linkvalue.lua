-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ 1 shared file-local(s), each (a) a core module-level local, (b) used
-- here and (c) not defined here — the three conditions, not a guess.
return function (M, SHARED)
local family =
    SHARED.family

--- read a member's key: a reader is nil (the value itself), a { template, hole } pair (the value
--- is matched against the template, an embed inside it parsing a string under another grammar,
--- and the key is the hole's value), or, as the escape hatch, a function(value) -> term | nil
local function read_key(v, reader, env)
    if v == nil then return nil end
    if reader == nil then return v end
    if type(reader) == 'function' then return reader(v) end
    local m = M.match(reader.template, v, env)
    if not m.ok then return nil end
    return m.values[reader.hole]
end

--- is `hole` a primary key of F? true, or false with the duplicated values and their members
function M.primary_key(F, hole, opts)
    F = family(F)
    local seen, dups = {}, {}
    for i, V in ipairs(F.values) do
        local k = read_key(V[hole], opts and opts.read, opts and opts.env)
        if k ~= nil then
            local found = false
            for _, e in ipairs(seen) do
                if M.eq(e.key, k) then
                    found = true
                    e.members[#e.members + 1] = i
                    if #e.members == 2 then dups[#dups + 1] = e end
                end
            end
            if not found then seen[#seen + 1] = { key = k, members = { i } } end
        end
    end
    return #dups == 0, dups
end

--- link(A, B, { from, to, read_from, read_to, complete, env }): the natural join of A.from with B.to
function M.link(A, B, spec)
    A, B = family(A), family(B)
    assert(spec and spec.from and spec.to, 'link: from and to hole names are required')
    local env = spec.env
    local out = { from = spec.from, to = spec.to, tuples = {}, pairs = {}, dangling = {},
        unreadable = { a = {}, b = {} }, ambiguity = {}, fan = 0,
        readers = { from = spec.read_from and (type(spec.read_from) == 'table' and spec.read_from.template) or nil,
                    to = spec.read_to and (type(spec.read_to) == 'table' and spec.read_to.template) or nil },
        complete = spec.complete }
    local bkeys = {}
    for j, V in ipairs(B.values) do
        local k = read_key(V[spec.to], spec.read_to, env)
        if k == nil then out.unreadable.b[#out.unreadable.b + 1] = j else bkeys[#bkeys + 1] = { j = j, key = k } end
    end
    out.is_function = M.primary_key({ template = B.template, values = B.values }, spec.to, { read = spec.read_to, env = env })
    local relatives = {} -- per key value: the a's and the b's, for Codd's points of ambiguity
    for i, V in ipairs(A.values) do
        local k = read_key(V[spec.from], spec.read_from, env)
        if k == nil then
            out.unreadable.a[#out.unreadable.a + 1] = i
        else
            local bs = {}
            for _, e in ipairs(bkeys) do
                if M.eq(e.key, k) then
                    bs[#bs + 1] = e.j
                    out.tuples[#out.tuples + 1] = { a = i, b = e.j, key = k, from = spec.from, to = spec.to }
                end
            end
            local rel
            for _, r in ipairs(relatives) do if M.eq(r.key, k) then rel = r end end
            if not rel then rel = { key = k, a = {}, b = bs }; relatives[#relatives + 1] = rel end
            rel.a[#rel.a + 1] = i
            if #bs == 0 then out.dangling[#out.dangling + 1] = i end
            if #bs > out.fan then out.fan = #bs end
            out.pairs[#out.pairs + 1] = { a = i, b = bs, key = k }
        end
    end
    for _, r in ipairs(relatives) do
        if #r.a > 1 and #r.b > 1 then out.ambiguity[#out.ambiguity + 1] = r end
    end
    return out
end

--- Codd §1.4 normalization, one nonsimple domain: the hedge hole's column of F is a relation of
--- its own. Each member's sequence is matched element by element against T_elem; the parent's
--- primary key is copied down under its own name (opts.key, a simple domain); the child family
--- carries parent and index per row. His two conditions: the key component must be simple, and
--- the nonsimple domains form a tree (each normalize call takes one node of it).
function M.normalize(F, hole, T_elem, opts)
    F = family(F)
    opts = opts or {}
    local key = opts.key -- one hole name or a list (a composite key: Codd's salaryhistory' is keyed by man#, jobdate)
    local keys = type(key) == 'table' and key or (key and { key } or {})
    local rows, unmatched, values = {}, {}, {}
    for i, V in ipairs(F.values) do
        local col = V[hole]
        if type(col) ~= 'table' or col.k ~= 'seq' then
            return nil, ('normalize: hole %s of member %d is not a sequence (a simple domain needs no normalization)'):format(hole, i)
        end
        for _, k in ipairs(keys) do
            local kv = V[k]
            if kv == nil then return nil, ('normalize: member %d has no value for the key %s'):format(i, k) end
            if type(kv) == 'table' and kv.k == 'seq' then
                return nil, ('normalize: the key %s is nonsimple (Codd 1970 §1.4, condition 2)'):format(k)
            end
        end
        for k2, e in ipairs(col.kids) do
            local m = M.match(T_elem, e, opts.env)
            if m.ok then
                local row = {}
                for h, v in pairs(m.values) do row[h] = v end
                for _, k in ipairs(keys) do
                    if row[k] ~= nil then return nil, ('normalize: the element template already has a hole named %s'):format(k) end
                    row[k] = M.copy(V[k])
                end
                values[#values + 1] = row
                rows[#rows + 1] = { parent = i, index = k2, sites = m.sites }
            else
                unmatched[#unmatched + 1] = { parent = i, index = k2, why = m.refusal and m.refusal.why }
            end
        end
    end
    return { template = T_elem, values = values, rows = rows, key = key, from = { hole = hole }, unmatched = unmatched }
end

--- follow links from one member: the set of members at every step, the join composed. A
--- member with no relative is a typed absence: `absent` only when the link's target family
--- was declared complete (spec.complete = true); `unavailable` when complete = 'unavailable';
--- `frontier` otherwise (TENSIONS.md: the reading axis; the link cannot decide completeness).
function M.chain(start, links)
    local members = type(start) == 'table' and start or { start }
    local steps, absences = { { members = members } }, {}
    for si, L in ipairs(links) do
        local nxt, seen = {}, {}
        for _, m in ipairs(members) do
            local found = false
            for _, pr in ipairs(L.pairs) do
                if pr.a == m then
                    for _, j in ipairs(pr.b) do
                        if not seen[j] then seen[j] = true; nxt[#nxt + 1] = j end
                        found = true
                    end
                end
            end
            if not found then
                local kind = L.complete == true and 'absent' or (L.complete == 'unavailable' and 'unavailable') or 'frontier'
                absences[#absences + 1] = { absence = kind, licenses = M.ABSENCE[kind].licenses, at = si, member = m,
                    why = ('member %d: no %s with %s equal to its %s (%s)'):format(m, L.to, L.to, L.from,
                        L.complete == true and 'the target family is complete' or 'the target family was not declared complete') }
            end
        end
        table.sort(nxt)
        members = nxt
        steps[#steps + 1] = { members = members, link = si, fan = L.fan }
    end
    return { steps = steps, members = members, absences = absences, ok = #members > 0 }
end
end
