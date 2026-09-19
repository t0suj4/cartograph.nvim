-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ 1 shared file-local(s), each (a) a core module-level local, (b) used
-- here and (c) not defined here — the three conditions, not a guess.
return function (M, SHARED)
local family, is_hole, unpack =
    SHARED.family, SHARED.is_hole, SHARED.unpack

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
--- a COMPOSITE key (Codd §1.3: a primary key may be composite; LINK.md's limit): `holes` a list
--- of hole names, the key value a seq of the components, each read through its own reader
--- (a list aligned with the holes) or one reader for all; compared by `eq`, componentwise
--- how a key (one hole or a list of holes) is named in a message: `man` or `(man, jobdate)`
function M.key_name(holes)
    if type(holes) ~= 'table' then return tostring(holes) end
    return '(' .. table.concat(holes, ', ') .. ')'
end
local function read_keyv(V, holes, reader, env)
    if type(holes) ~= 'table' then return read_key(V[holes], reader, env) end
    local parts = {}
    for i, h in ipairs(holes) do
        local r = reader
        if type(reader) == 'table' and reader.template == nil then r = reader[i] end -- a list of readers indexed like the holes; a nil entry reads the value as it is
        local v = read_key(V[h], r, env)
        if v == nil then return nil end
        parts[i] = v
    end
    return M.seq(parts)
end
--- is `hole` (or a list of holes, a composite key) a primary key of F? true, or false with the
--- duplicated values and their members
function M.primary_key(F, hole, opts)
    F = family(F)
    local seen, dups = {}, {}
    for i, V in ipairs(F.values) do
        local k = read_keyv(V, hole, opts and opts.read, opts and opts.env)
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
        read = { from = spec.read_from, to = spec.read_to }, -- the specs themselves, for the cascade's inverse (CASCADE.md)
        complete = spec.complete }
    local bkeys = {}
    for j, V in ipairs(B.values) do
        local k = read_keyv(V, spec.to, spec.read_to, env)
        if k == nil then out.unreadable.b[#out.unreadable.b + 1] = j else bkeys[#bkeys + 1] = { j = j, key = k } end
    end
    out.is_function = M.primary_key({ template = B.template, values = B.values }, spec.to, { read = spec.read_to, env = env })
    local relatives = {} -- per key value: the a's and the b's, for Codd's points of ambiguity
    for i, V in ipairs(A.values) do
        local k = read_keyv(V, spec.from, spec.read_from, env)
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
-- ── CASCADE: the update rule over a link (SQL-92 §11.8, CASCADE.md) ────────────────────
-- `link(A, B, {from, to})` is A's foreign key `from` referencing B's key `to`. A value edit on
-- a referenced member's key (classified on B by PROPAGATE.md's classify) cascades: in every
-- MATCHING ROW (an A member joined to that B member, read off the link computed BEFORE the
-- edit, §11.8 general rule 4) the corresponding component of `from` is written to the new
-- key (rule 6.a.i). The referenced key must be unique (syntax rule 2: `is_function`) and stay
-- unique. A key read through a reader is written through the reader's inverse: the old value
-- matched, the key hole replaced, the template instantiated, so the value's other parts
-- survive; a function reader has no inverse. A's domain at the written hole follows
-- PROPAGATE.md: derived widens and is reported, supplied refuses. Nothing is applied: the
-- result carries the rows, previews and a commit closure, all rows by default.
local function reader_at(spec, x) if type(spec) == 'table' and spec.template == nil then return spec[x] end; return spec end
local function write_key(v, reader, new, env)
    if reader == nil then return new end
    if type(reader) == 'function' then return nil, 'a function reader has no inverse; give a {template, hole} reader' end
    local m = M.match(reader.template, v, env)
    if not m.ok then return nil, 'the old value does not read through the reader: ' .. (m.refusal and m.refusal.why or 'no match') end
    local W = {}
    for h, x in pairs(m.values) do W[h] = x end
    W[reader.hole] = new
    local r = M.instantiate(reader.template, W, env)
    if not r.ok then return nil, 'the reader does not write the new key: ' .. M.unfold_why(r) end
    return r.term
end
function M.cascade(L, A, B, j, C, opts)
    opts = opts or {}
    A, B = family(A), family(B)
    local env = opts.env
    if not L.is_function then
        return nil, ('cascade: %s is not a key of the referenced family (SQL-92 §11.8 syntax rule 2: the referenced columns are a unique key)'):format(M.key_name(L.to))
    end
    if not C or C.kind ~= 'value' then return nil, ('cascade: the edit is %s, not a value edit; only a key value cascades'):format(tostring(C and C.kind)) end
    local tos = type(L.to) == 'table' and L.to or { L.to }
    local froms = type(L.from) == 'table' and L.from or { L.from }
    local changed = {}
    for _, c in ipairs(C.changed) do for x, h in ipairs(tos) do if h == c.h then changed[x] = c end end end
    if next(changed) == nil then return nil, ('cascade: no component of the key %s changed'):format(M.key_name(L.to)) end
    local read_to, read_from = L.read and L.read.to, L.read and L.read.from
    local oldk = read_keyv(B.values[j], L.to, read_to, env)
    local newk = read_keyv(C.values, L.to, read_to, env)
    if newk == nil then return nil, 'cascade: the new key does not read through the reader' end
    for j2, V in ipairs(B.values) do
        if j2 ~= j and M.eq(read_keyv(V, L.to, read_to, env) or M.seq {}, newk) then
            return nil, ('cascade: the new key %s is already the key of member %d; the referenced key must stay unique'):format(M.show(newk), j2)
        end
    end
    local rows = {}
    for _, t in ipairs(L.tuples) do if t.b == j then rows[#rows + 1] = t.a end end
    local newparts = type(L.to) == 'table' and newk.kids or { newk }
    local values, widened, T = {}, {}, A.template
    for _, a in ipairs(rows) do
        local W = {}
        for h, v in pairs(A.values[a]) do W[h] = v end
        for x in pairs(changed) do
            local fh = froms[x]
            local nv, why = write_key(W[fh], reader_at(read_from, x), newparts[x], env)
            if nv == nil then return nil, ('cascade: member %d of the referencing family, hole %s: %s'):format(a, fh, why) end
            W[fh] = nv
        end
        local r = M.instantiate(T, W, env)
        if not r.ok and #r.rejected > 0 then
            for _, x in ipairs(r.rejected) do
                local h = x:match('^([^:]+):')
                if not T.holes[h] or T.holes[h].origin == 'supplied' then
                    return nil, ('cascade: member %d: a supplied domain refuses the new key: %s'):format(a, x)
                end
                if T == A.template then T = M.copy(T) end
                local from = M.show_domain(T.holes[h].domain)
                T.holes[h].domain = M.widen(T.holes[h].domain, W[h])
                widened[#widened + 1] = { h = h, member = a, from = from, to = M.show_domain(T.holes[h].domain) }
            end
            r = M.instantiate(T, W, env)
        end
        if not r.ok then return nil, ('cascade: member %d does not instantiate with the new key: %s'):format(a, M.unfold_why(r)) end
        values[a] = W
    end
    return {
        key = { from = oldk, to = newk }, rows = rows, values = values, template = T, widened = widened,
        preview = function(a) return M.instantiate(T, values[a], env).term end,
        commit = function(members)
            local set = {}
            for _, a in ipairs(members or rows) do set[a] = true end
            local new = {}
            for a, V in ipairs(A.values) do new[a] = (set[a] and values[a]) and values[a] or V end
            return new
        end,
    }
end
--- the delete rule (§11.8 general rule 5.a.i): a referenced member dropped marks its matching
--- rows; in the algebra a member removal drops the value row (KEYED.md), so these are the
--- referencing members that would dangle
function M.cascade_delete(L, j)
    local rows = {}
    for _, t in ipairs(L.tuples) do if t.b == j then rows[#rows + 1] = t.a end end
    return { rows = rows, why = #rows > 0 and ('%d matching row(s) of the referencing family would dangle'):format(#rows) or 'no matching row' }
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
                    why = ('member %d: no %s with %s equal to its %s (%s)'):format(m, M.key_name(L.to), M.key_name(L.to), M.key_name(L.from),
                        L.complete == true and 'the target family is complete' or 'the target family was not declared complete') }
            end
        end
        table.sort(nxt)
        members = nxt
        steps[#steps + 1] = { members = members, link = si, fan = L.fan }
    end
    return { steps = steps, members = members, absences = absences, ok = #members > 0 }
end

-- ── readers: a family read from a live source (SQLITE.md) ──────────────────────────────
-- A reader is the axis along which kinds of data enter the algebra: code through an
-- adapter, keyed documents through kv_generalize, text through a grammar, and a live source
-- through this contract. A database table is the purest case: a Codd relation IS a family
-- (LINK.md), so the declared columns are the SUPPLIED template, the rows are the members
-- whose column summaries are the DERIVED template, and a foreign key is a `link`. What
-- liveness adds is three facts a file never needed: where the rows were observed (`via`),
-- a stamp for the moment they were read (a live fact does not outlive its stamp), and the
-- absence split: a source that cannot be reached is `unavailable`, a source that answered
-- with nothing is `absent` only when the reading was complete. Nothing here does I/O; the
-- reader object does, and this section only reads what it returns.
--
-- reader = { via = string, complete = bool,
--            stamp = function() -> string | nil, why,
--            read  = function(key, opts) -> { ok = true, columns, rows, strict, truncated }
--                                        | { ok = false, absence = 'unavailable'|'absent', why } }
-- `columns` are SQLite's `PRAGMA table_info` rows ({ name, type, notnull, pk }); `rows` are
-- maps column -> value with `<column>:t` holding the storage class `typeof()` reported.

--- datatype3 §3.1: the affinity of a declared type, five rules in order (INT; CHAR/CLOB/TEXT;
--- empty or BLOB; REAL/FLOA/DOUB; else NUMERIC). "FLOATING POINT" is INTEGER by rule 1 and
--- "STRING" is NUMERIC, both as the document says.
function M.affinity(decl)
    local d = (decl or ''):upper()
    if d:find('INT', 1, true) then return 'integer' end
    if d:find('CHAR', 1, true) or d:find('CLOB', 1, true) or d:find('TEXT', 1, true) then return 'text' end
    if d == '' or d:find('BLOB', 1, true) then return 'blob' end
    if d:find('REAL', 1, true) or d:find('FLOA', 1, true) or d:find('DOUB', 1, true) then return 'real' end
    return 'numeric'
end
-- the storage classes a column of each affinity can hold (datatype3 §3): an affinity is a
-- preference, not a constraint. TEXT stores numbers as text; NUMERIC and INTEGER keep text
-- that will not convert; REAL forces integers to floating point; BLOB prefers nothing.
local AFFINITY_CLASSES = {
    text = { 'text', 'blob' }, numeric = { 'integer', 'real', 'text', 'blob' },
    integer = { 'integer', 'real', 'text', 'blob' }, real = { 'real', 'text', 'blob' },
    blob = { 'integer', 'real', 'text', 'blob' },
}
-- STRICT tables (stricttables.html §2): the datatype is enforced; ANY prefers nothing
local STRICT_CLASSES = { INT = { 'integer' }, INTEGER = { 'integer' }, REAL = { 'real' }, TEXT = { 'text' }, BLOB = { 'blob' },
    ANY = { 'integer', 'real', 'text', 'blob' } }
--- the supplied domain of a column: the set of storage classes its declaration admits, NULL
--- included unless NOT NULL. Under STRICT the declared type is exact.
function M.column_domain(col, strict)
    local classes
    if strict then classes = STRICT_CLASSES[(col.type or ''):upper()] or STRICT_CLASSES.ANY
    else classes = AFFINITY_CLASSES[M.affinity(col.type)] end
    local list = {}
    for _, c in ipairs(classes) do list[#list + 1] = c end
    if not (col.notnull == 1 or col.notnull == true) then list[#list + 1] = 'null' end
    return M.kinds(list)
end
--- a cell as a term: the storage class is the node kind so column summaries see it
--- (a column of `lit`s would summarize to {lit} whatever the classes). A blob's class is
--- carried and its bytes are not: the shell's rendering is not the value, so the node has
--- no payload and the family cannot be instantiated back into such a row.
function M.cell(class, v)
    if class == 'null' then return M.node('null') end
    if class == 'blob' then return M.node('blob') end
    if class ~= 'integer' and class ~= 'real' and class ~= 'text' then return nil, 'unknown storage class ' .. tostring(class) end
    return M.node(class, M.lit(v))
end
--- the family of one table: T's holes are the columns with SUPPLIED domains from the
--- declaration; `derived` is the same body with the domains re-derived from the rows;
--- `narrowed` lists the columns whose rows say less than the declaration admits.
--- Rows are read in the order given; `keys` are the declared primary key columns.
function M.table_family(desc)
    local cols = desc.columns or {}
    if #cols == 0 then return nil, 'no columns' end
    local kids, domains, keys = {}, {}, {}
    for _, c in ipairs(cols) do
        kids[#kids + 1] = M.hole(c.name)
        domains[c.name] = M.column_domain(c, desc.strict)
        if (c.pk or 0) > 0 then keys[c.pk] = c.name end
    end
    local T = M.template(M.node('row', unpack(kids)), domains)
    local values, refused, rowid = {}, {}, {}
    for i, r in ipairs(desc.rows or {}) do
        local V = {}
        rowid[i] = r['rowid:']
        for _, c in ipairs(cols) do
            local cell, why = M.cell(r[c.name .. ':t'] or 'null', r[c.name])
            if not cell then refused[#refused + 1] = { row = i, column = c.name, why = why } else V[c.name] = cell end
        end
        values[i] = V
    end
    -- the derived template: same body, every domain opened and re-summarized from the rows
    -- (rederive keeps a SUPPLIED domain as it stands, so the copy is re-labelled first)
    local derived = M.copy(T)
    for h in pairs(derived.holes) do derived.holes[h].domain = M.open(); derived.holes[h].origin = 'derived' end
    derived = M.rederive_domains(derived, values)
    local narrowed = {}
    for _, c in ipairs(cols) do
        local d, s = derived.holes[c.name].domain, T.holes[c.name].domain
        if #values > 0 and not M.entails(s, d) then narrowed[#narrowed + 1] = c.name end
    end
    table.sort(narrowed)
    return { template = T, derived = derived, values = values, n = #values, keys = keys, refused = refused, rowid = rowid,
        narrowed = narrowed, table = desc.table, complete = desc.complete ~= false, source = desc.source }
end
--- read one key through a reader: stamp first (an unstamped live fact is `unavailable`),
--- then the rows; a truncated read is not complete, so `chain` types its misses `frontier`.
function M.read(reader, key, opts)
    opts = opts or {}
    assert(type(reader) == 'table' and type(reader.read) == 'function', 'read: a reader with a read function is required')
    local stamp, swhy
    if reader.stamp then stamp, swhy = reader.stamp() end
    if not stamp then
        return { ok = false, absence = 'unavailable', licenses = M.ABSENCE.unavailable.licenses,
            why = 'no stamp for ' .. tostring(reader.via) .. ': ' .. tostring(swhy or 'the reader has no stamp'), via = reader.via }
    end
    local r = reader.read(key, opts)
    if not r.ok then
        -- a declared kind passes through (a SQL error the shell reports is `refused`, not
        -- `unavailable`); an undeclared one is `unavailable`
        local a = M.ABSENCE[r.absence] and r.absence or 'unavailable'
        if a == 'absent' and reader.complete ~= true then a = 'frontier' end
        return { ok = false, absence = a, licenses = M.ABSENCE[a].licenses, why = r.why, via = reader.via, stamp = stamp }
    end
    local F, why = M.table_family { table = key, columns = r.columns, rows = r.rows, strict = r.strict,
        complete = (reader.complete == true) and not r.truncated,
        source = { via = reader.via, stamp = stamp, origin = 'observed', truncated = r.truncated or false } }
    if not F then return { ok = false, absence = 'absent', licenses = M.ABSENCE.absent.licenses, why = why, via = reader.via, stamp = stamp } end
    F.ok = true
    return F
end
--- is a read family still the source's current state? The reader's stamp is compared, never
--- the rows: a changed source with equal rows is still stale (the reading must be redone).
function M.fresh(F, reader)
    if not (F and F.source and F.source.stamp) then return false, 'unstamped: a live fact without a stamp is a guess wearing a cache\'s clothes' end
    local now, why = reader.stamp()
    if not now then return false, 'no stamp now: ' .. tostring(why) end
    if now ~= F.source.stamp then return false, ('stale: read at %s, source at %s'):format(F.source.stamp, now) end
    return true
end
-- 'sql': the table a statement names, parse only. Enough for a code family to link to a
-- catalog by table name (cartograph's dblink audit); not a SQL grammar.
M.grammar('sql', {
    parse = function(s)
        if type(s) ~= 'string' then return nil end
        local u = s:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
        local verb, tbl = u:match('^([Ss][Ee][Ll][Ee][Cc][Tt]) .- [Ff][Rr][Oo][Mm] ["`]?([%w_]+)')
        if not verb then verb, tbl = u:match('^([Ii][Nn][Ss][Ee][Rr][Tt]) [Ii][Nn][Tt][Oo] ["`]?([%w_]+)') end
        if not verb then verb, tbl = u:match('^([Uu][Pp][Dd][Aa][Tt][Ee]) ["`]?([%w_]+)') end
        if not verb then verb, tbl = u:match('^([Dd][Ee][Ll][Ee][Tt][Ee]) [Ff][Rr][Oo][Mm] ["`]?([%w_]+)') end
        if not verb then return nil end
        return M.node('sql', M.name(verb:lower()), M.lit(tbl))
    end,
    print = function() return nil end,
})

-- ── the SQL WRITER (REGISTRY.md; SQL-92 §13.10 <update statement: searched>): the first
-- writer for a non-text store. A statement is a TERM under the `sql_q` grammar, whose print
-- writes cells by their storage class (M.cell's nodes: text single-quoted with quotes
-- doubled, integer and real raw, null as NULL; a blob carries no bytes and refuses) and
-- identifiers double-quoted with quotes doubled (the bridge's rule), and whose parse is the
-- `sql` grammar's, so the reader verifies the writer: the printed statement reads back with
-- its verb and its table. The UPDATE is a generator template (KEYED.md's principle: a fast
-- path is a template that produces the store's text), its instance the table's surgery the
-- way hunks are a file's.
local function sql_ident(name) return '"' .. tostring(name):gsub('"', '""') .. '"' end
local function sql_print(t)
    local function go(x)
        if x.k == 'ident' then return sql_ident(x.kids[1].v) end
        if x.k == 'text' then return "'" .. tostring(x.kids[1].v):gsub("'", "''") .. "'" end
        if x.k == 'integer' or x.k == 'real' then return tostring(x.kids[1].v) end
        if x.k == 'null' then return 'NULL' end
        if x.k == 'blob' then error('sql_q: a blob column cannot be written: the cell carries its class and not its bytes') end
        if x.k == 'lit' then return tostring(x.v) end
        if x.k == 'assign' then return go(x.kids[1]) .. ' = ' .. go(x.kids[2]) end
        if x.k == 'eq' then return go(x.kids[1]) .. ' = ' .. go(x.kids[2]) end
        if x.k == 'set' or x.k == 'where' then
            local parts = {}
            for _, c in ipairs(x.kids) do parts[#parts + 1] = go(c) end
            return table.concat(parts, x.k == 'set' and ', ' or ' AND ')
        end
        if x.k == 'update' then return 'UPDATE ' .. go(x.kids[1]) .. ' SET ' .. go(x.kids[2]) .. ' WHERE ' .. go(x.kids[3]) .. ';' end
        if is_hole(x) then error('sql_q: unfilled hole ' .. tostring(x.h)) end
        error('sql_q: no print for ' .. tostring(x.k))
    end
    return go(t)
end
M.grammar('sql_q', {
    print = function(t) local ok, text = pcall(sql_print, t); if ok then return text end return nil end,
    parse = function(str) return M.grammars.sql.parse(str) end,
})
--- the generator: UPDATE <table> SET <assignments> WHERE <conditions>
M.SQL_UPDATE = M.template(M.node('update', M.hole 'table', M.node('set', M.hole('assigns', true)), M.node('where', M.hole('conds', true))))
--- the surgery of one row: the UPDATE that turns row j of the table family F (as M.read
--- returns it: values, keys, rowid, table) into W. The SET clause holds the columns whose
--- cell changed; the WHERE names the row by the declared primary key's OLD values (F.keys,
--- cascade's `key.from`), or by rowid when the table declares none. Refuses by name a row
--- with nothing to write (§13.10 rule 4, "no data"), a blob column, a family with no table.
--- Returns { term, sql, table, columns, verified } where verified is the parse-back: the
--- reader names the verb UPDATE and the table.
function M.table_update(F, j, W, env)
    if not F.table then return nil, 'table_update: the family names no table' end
    local V = F.values[j]
    if not V then return nil, ('table_update: no row %s'):format(tostring(j)) end
    local assigns, columns = {}, {}
    for _, h in ipairs(M.hole_names(F.template)) do
        if W[h] ~= nil and not M.eq(V[h], W[h]) then
            if W[h].k == 'blob' or V[h].k == 'blob' then return nil, ('table_update: column %s: a blob column cannot be written'):format(h) end
            assigns[#assigns + 1] = M.node('assign', M.node('ident', M.lit(h)), M.copy(W[h]))
            columns[#columns + 1] = h
        end
    end
    if #assigns == 0 then return nil, 'table_update: no data: no column of the row changed' end
    local conds = {}
    if F.keys and #F.keys > 0 then
        for _, k in ipairs(F.keys) do conds[#conds + 1] = M.node('eq', M.node('ident', M.lit(k)), M.copy(V[k])) end
    elseif F.rowid and F.rowid[j] then
        conds[#conds + 1] = M.node('eq', M.node('ident', M.lit 'rowid'), M.node('integer', M.lit(F.rowid[j])))
    else
        return nil, 'table_update: the row has neither a declared key nor a rowid'
    end
    local r = M.instantiate(M.SQL_UPDATE, { table = M.node('ident', M.lit(F.table)), assigns = M.seq(assigns), conds = M.seq(conds) }, env)
    if not r.ok then return nil, 'table_update: ' .. M.unfold_why(r) end
    local sql = M.grammars.sql_q.print(r.term)
    if not sql then return nil, 'table_update: the statement does not print' end
    local back = M.grammars.sql_q.parse(sql)
    local verb = back and back.kids and back.kids[1] and (back.kids[1].n or back.kids[1].v) -- the sql grammar names the verb as a name node
    local verified = verb ~= nil and tostring(verb):upper() == 'UPDATE' and back.kids[2] and tostring(back.kids[2].v) == F.table
    return { term = r.term, sql = sql, table = F.table, columns = columns, verified = verified and true or false }
end
end
