-- A PART OF `cartograph.algebra.core` (see core.lua's PARTS). THE KV LENS (CART-1379): the JSON-like values the data
-- adapters read — yamlvalue, xmlvalue, pom, helm — as KEYED TERMS, so the kv family (kv_eq, kv_eq_keyed,
-- kv_generalize) can be DERIVED over the term algebra instead of being a second algebra with its own representation.
-- kv stays the adapters' VIEW (they read `o` / `a` directly; converting them is a migration nobody needs); this is
-- the round trip between the view and the terms, the way cartograph.mixterm is mix's.
--   { o = { k = v }, keys = { … } }  ->  keyed `obj` node of `pair`s (lit key, value), kids in the object's key order
--   { a = { … } }                     ->  `arr` node, positional; a MERGE-KEYED list (opts.keyfield, KEYED.md) when every
--                                         element is an object whose keyfield is a scalar and the list is not empty
--   { null = true }                   ->  `null` node
--   a Lua scalar                      ->  lit of that scalar (its TYPE kept: "1" and 1 stay apart, as kv_ser has them)
-- ⚠ Order: an object's key order rides in its kids (`keys()` sorts — never read the order from it); a merge-keyed
-- list keeps its elements in the order written. The round trip is the oracle (tests/kvterm_spec.lua).
return function (M, SHARED)

-- one value on its own: its lists keyed by their own elements (inside a place every value of a family shares, the
-- FAMILY decides — M.kv_terms; on its own, or inside what will be a hole, this is the encoding)
local function single(x, kf)
    local k = M.kv_kind(x)
    if k == 'scalar' then return M.lit(x) end
    if k == 'null' then return { k = 'null', kids = {} } end
    if k == 'obj' then
        local kids = {}
        for _, key in ipairs(x.keys) do kids[#kids + 1] = { k = 'pair', kids = { M.lit(key), single(x.o[key], kf) } } end
        return { k = 'obj', kids = kids, align = 'keyed' }
    end
    if k == 'arr' then
        local kids = {}
        for i, e in ipairs(x.a) do kids[i] = single(e, kf) end
        local keyed = kf ~= nil and #x.a > 0
        for _, e in ipairs(x.a) do
            if not (M.kv_kind(e) == 'obj' and e.o[kf] ~= nil and M.kv_kind(e.o[kf]) == 'scalar') then keyed = false; break end
        end
        if keyed then return { k = 'arr', kids = kids, align = 'keyed', key = kf } end
        return { k = 'arr', kids = kids }
    end
    error('kv_term: not a kv value (' .. tostring(k) .. ')')
end

--- a FAMILY of kv values -> their terms, one per value. ★ KEYEDNESS IS A FAMILY DECISION (kv_generalize's rule): a list
--- at one place is merge-keyed (opts.keyfield) only when, in EVERY value that has it, it is non-empty and every element
--- is an object whose keyfield is a scalar — one value's list of named objects beside another's unnamed one is
--- positional in both, never a keyed list against a positional one. The places are walked as kv_generalize walks them:
--- objects by key, keyed lists by element key, positional lists by index when their lengths agree; where the values
--- disagree in kind or length the place will be one hole, and each value is encoded on its own.
function M.kv_terms(values, opts)
    opts = opts or {}
    local kf = opts.keyfield
    local n = #values
    local function eligible(x)
        if #x.a == 0 then return false end
        for _, e in ipairs(x.a) do
            if not (M.kv_kind(e) == 'obj' and e.o[kf] ~= nil and M.kv_kind(e.o[kf]) == 'scalar') then return false end
        end
        return true
    end
    local enc
    -- xs[i]: value i at this place (nil where it has none) -> out[i], its term
    enc = function(xs)
        local out, kind = {}, nil
        for i = 1, n do
            if xs[i] ~= nil then
                local k = M.kv_kind(xs[i])
                if kind and kind ~= k then kind = 'mixed' elseif not kind then kind = k end
            end
        end
        if kind == 'mixed' then
            for i = 1, n do if xs[i] ~= nil then out[i] = single(xs[i], kf) end end
        elseif kind == 'scalar' or kind == 'null' then
            for i = 1, n do if xs[i] ~= nil then out[i] = single(xs[i], kf) end end
        elseif kind == 'obj' then
            local keys, seen = {}, {}
            for i = 1, n do if xs[i] then for _, key in ipairs(xs[i].keys) do if not seen[key] then seen[key] = true; keys[#keys + 1] = key end end end end
            local col = {}
            for _, key in ipairs(keys) do
                local sub = {}
                for i = 1, n do sub[i] = xs[i] and xs[i].o[key] end
                col[key] = enc(sub)
            end
            for i = 1, n do
                if xs[i] then
                    local kids = {}
                    for _, key in ipairs(xs[i].keys) do kids[#kids + 1] = { k = 'pair', kids = { M.lit(key), col[key][i] } } end
                    out[i] = { k = 'obj', kids = kids, align = 'keyed' }
                end
            end
        elseif kind == 'arr' then
            local keyed = kf ~= nil
            for i = 1, n do if xs[i] and not eligible(xs[i]) then keyed = false end end
            if keyed then
                local names, seen = {}, {}
                for i = 1, n do if xs[i] then for _, e in ipairs(xs[i].a) do local nm = tostring(e.o[kf]); if not seen[nm] then seen[nm] = true; names[#names + 1] = nm end end end end
                local col = {}
                for _, nm in ipairs(names) do
                    local sub = {}
                    for i = 1, n do
                        if xs[i] then for _, e in ipairs(xs[i].a) do if tostring(e.o[kf]) == nm then sub[i] = e; break end end end
                    end
                    col[nm] = enc(sub)
                end
                for i = 1, n do
                    if xs[i] then
                        local kids = {}
                        for _, e in ipairs(xs[i].a) do kids[#kids + 1] = col[tostring(e.o[kf])][i] end
                        out[i] = { k = 'arr', kids = kids, align = 'keyed', key = kf }
                    end
                end
            else
                local len, same = nil, true
                for i = 1, n do if xs[i] then if len and #xs[i].a ~= len then same = false end; len = len or #xs[i].a end end
                if same then
                    local cols = {}
                    for j = 1, len or 0 do
                        local sub = {}
                        for i = 1, n do sub[i] = xs[i] and xs[i].a[j] end
                        cols[j] = enc(sub)
                    end
                    for i = 1, n do
                        if xs[i] then
                            local kids = {}
                            for j = 1, #xs[i].a do kids[j] = cols[j][i] end
                            out[i] = { k = 'arr', kids = kids }
                        end
                    end
                else
                    for i = 1, n do if xs[i] then out[i] = single(xs[i], kf) end end
                end
            end
        end
        return out
    end
    return enc(values)
end
--- a kv value -> its term (a family of one). opts.keyfield: the merge key that makes a list of objects KEYED
function M.kv_term(v, opts) return M.kv_terms({ v }, opts)[1] end

--- instance i of a kv TEMPLATE (kv_generalize's record: `hole` / `opt` / `ka` / `a` / `o` forms; byid: hole id -> its
--- record with `values`) -> the kv value (KV_ABSENT under an absent presence). ONE function for the native operator
--- and its derivation, so the two records instantiate alike by construction.
function M.kv_instantiate(t, byid, i)
    if type(t) ~= 'table' then return t end
    if t.hole then return byid[t.hole].values[i] end
    if t.opt then
        local p = byid[t.opt.hole].values[i]
        if p ~= true then return M.KV_ABSENT end
        return M.kv_instantiate(t.body, byid, i)
    end
    if t.ka then
        local ob = M.kv_instantiate(t.ka, byid, i)
        if ob == M.KV_ABSENT then return M.KV_ABSENT end
        local a = {}
        for _, key in ipairs(ob.keys) do a[#a + 1] = ob.o[key] end
        return { a = a }
    end
    if t.a then
        local a = {}
        for j, x in ipairs(t.a) do a[j] = M.kv_instantiate(x, byid, i) end
        return { a = a }
    end
    if t.o then
        local o, keys = {}, {}
        for _, key in ipairs(t.keys) do
            local v = M.kv_instantiate(t.o[key], byid, i)
            if v ~= M.KV_ABSENT then o[key] = v; keys[#keys + 1] = key end
        end
        return { o = o, keys = keys }
    end
    return t
end

--- a GENERALIZE RESULT over kv_terms(instances) -> kv_generalize's record { template, holes, n, instantiate }. The view's
--- part: (1) ORDER — keyed nodes come out of generalize in canonical (sorted) key order; kv keeps WRITTEN
--- first-occurrence order and numbers holes in the order its walk meets them (a body's holes before its presence hole),
--- so the decoder walks the instances beside the template and renumbers; (2) KINDS, read off each hole's value vector
--- by kv's own rules — kinds differ: mixed; a presence vector: presence; lists: array; else value — never from the
--- generalizer's notes, so any generalize (the operator or its derivation) decodes alike.
function M.kv_template(g, instances, opts)
    opts = opts or {}
    local kf = opts.keyfield or 'name'
    local n = #instances
    local holes, byid, ren = {}, {}, {}
    local function hole_of(h)
        if ren[h] then return byid[ren[h]] end
        local vals, presence = {}, false
        for i = 1, n do
            local v = g.values[i][h]
            if v ~= nil and (v.k == 'present' or v.k == 'absent') then presence = true end
        end
        local kinds = {}
        for i = 1, n do
            local v = g.values[i][h]
            if v == nil then vals[i] = M.KV_ABSENT
            elseif presence then vals[i] = v.k == 'present'
            else vals[i] = M.term_kv(v); kinds[M.kv_kind(vals[i])] = true end
        end
        local nk = 0
        for _ in pairs(kinds) do nk = nk + 1 end
        local kind = presence and 'presence' or (nk ~= 1 and 'mixed') or (kinds.arr and 'array') or 'value'
        ren[h] = 'h' .. (#holes + 1)
        local e = { id = ren[h], kind = kind, values = vals, sites = {} }
        byid[ren[h]] = e; holes[#holes + 1] = e
        return e
    end
    local function written(subs, keys_of)
        local order, seen = {}, {}
        for i = 1, n do
            if subs[i] ~= M.KV_ABSENT then
                for _, k in ipairs(keys_of(subs[i])) do if not seen[k] then seen[k] = true; order[#order + 1] = k end end
            end
        end
        return order
    end
    local function at(subs, f)
        local out = {}
        for i = 1, n do
            local x = subs[i] ~= M.KV_ABSENT and f(subs[i]) or nil
            out[i] = x == nil and M.KV_ABSENT or x
        end
        return out
    end
    local function member(o, key, body, opt, site)
        if opt then
            local e = hole_of(opt); e.sites[#e.sites + 1] = site .. '?'
            o[key] = { opt = { hole = e.id }, body = body }
        else o[key] = body end
    end
    local dec
    dec = function(t, path, subs)
        if t.k == 'hole' then local e = hole_of(t.h); e.sites[#e.sites + 1] = path; return { hole = e.id } end
        if t.k == 'lit' then return t.v end
        if t.k == 'null' then return { null = true } end
        if t.k == 'obj' then
            local bykey = {}
            for _, p in ipairs(t.kids) do bykey[p.kids[1].v] = p end
            local o, keys = {}, {}
            for _, key in ipairs(written(subs, function (v) return v.keys end)) do
                local p = bykey[key]
                member(o, key, dec(p.kids[2], path .. '.' .. key, at(subs, function (v) return v.o[key] end)), p.opt, path .. '.' .. key)
                keys[#keys + 1] = key
            end
            return { o = o, keys = keys }
        end
        if t.k == 'arr' and t.align then
            local bykey = {}
            for _, el in ipairs(t.kids) do bykey[assert(M.key_of(t, el))] = el end
            local function names(v) local r = {}; for _, x in ipairs(v.a) do r[#r + 1] = tostring(x.o[kf]) end; return r end
            local o, keys = {}, {}
            local base = path .. '[' .. kf .. ']'
            for _, key in ipairs(written(subs, names)) do
                local el = bykey[key]
                local body = dec(el, base .. '.' .. key, at(subs, function (v)
                    for _, x in ipairs(v.a) do if tostring(x.o[kf]) == key then return x end end
                end))
                member(o, key, body, el.opt, base .. '.' .. key)
                keys[#keys + 1] = key
            end
            return { ka = { o = o, keys = keys }, keyfield = kf }
        end
        if t.k == 'arr' then
            local a = {}
            for j, x in ipairs(t.kids) do a[j] = dec(x, path .. '[' .. j .. ']', at(subs, function (v) return v.a[j] end)) end
            return { a = a }
        end
        error('kv_template: not a kv template node (' .. tostring(t.k) .. ')')
    end
    local T = dec(g.template.body, '$', instances)
    return { template = T, holes = holes, n = n, instantiate = function(i) return M.kv_instantiate(T, byid, i) end }
end

--- a term built by kv_term (or a template's ground part) -> the kv value
function M.term_kv(t)
    if t.k == 'lit' then return t.v end
    if t.k == 'null' then return { null = true } end
    if t.k == 'obj' then
        local o, keys = {}, {}
        for _, p in ipairs(t.kids) do
            local key = p.kids[1].v
            o[key] = M.term_kv(p.kids[2]); keys[#keys + 1] = key
        end
        return { o = o, keys = keys }
    end
    if t.k == 'arr' then
        local a = {}
        for i, e in ipairs(t.kids) do a[i] = M.term_kv(e) end
        return { a = a }
    end
    error('term_kv: not a kv term (' .. tostring(t.k) .. ')')
end

end
