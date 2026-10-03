-- PARTITION-JOIN (discovery, CART-1412): do two KEYINGS of one population induce the SAME PARTITION?
--
-- The acceptance test for swapping one equality key for another (clones' canon -> the algebra's variant relation):
-- the two keys differ BY CONSTRUCTION, so comparing them is meaningless — what must agree is which items share a
-- key. Written by hand three times in one session (a row join, a partition join, a group digest) before it was this.
--
-- `keys` is Lua SOURCE (code is data by parsing; `@file` reads one) returning
--     { items = function (store) -> list, a = function (item, store) -> key, b = function (item, store) -> key,
--       name = function (item) -> string (optional, for the samples) }
-- and the value reports, for each side, the classes of two or more and the members they cover, then:
--     split    items whose A-class is not one B-class (B separates what A joins)
--     merged   items whose B-class is not one A-class (B joins what A separates)
-- with named samples of each, and the cost per item of each key.
-- CLAIM: split = 0 and merged = 0 — ⚠ AND AT LEAST ONE CLASS ON A SIDE. If neither keying puts two items together,
-- every key is unique on both sides and "they agree" says nothing ([[ask-the-accessor-not-the-container]]: a uniform
-- zero reads as a clean answer); that is refused as VACUOUS, not passed.

local function load_keys(src)
    local chunk, why = load(src, '=partition-join keys')
    if not chunk then return nil, 'the keys do not parse: ' .. tostring(why) end
    local ok, K = pcall(chunk)
    if not ok then return nil, 'the keys raised: ' .. tostring(K) end
    if type(K) ~= 'table' or type(K.items) ~= 'function' or type(K.a) ~= 'function' or type(K.b) ~= 'function' then
        return nil, 'the keys must return { items = fn(store), a = fn(item, store), b = fn(item, store), name = fn(item)? }'
    end
    return K
end

local function measure(store, p)
    local K, why = load_keys(p.keys)
    if not K then return { error = why } end
    local items = K.items(store) or {}
    local show = tonumber(p.show or 3) or 3
    local name = K.name or function (x) return tostring(x) end
    local ka, kb, ta, tb = {}, {}, 0, 0
    for i, x in ipairs(items) do
        local t0 = vim.uv.hrtime()
        local ok, k = pcall(K.a, x, store)
        local t1 = vim.uv.hrtime()
        if not ok then return { error = ('key A raised on %s: %s'):format(name(x), tostring(k)), items = #items } end
        local ok2, k2 = pcall(K.b, x, store)
        local t2 = vim.uv.hrtime()
        if not ok2 then return { error = ('key B raised on %s: %s'):format(name(x), tostring(k2)), items = #items } end
        if k == nil or k2 == nil then return { error = ('a key is nil on %s (A %s, B %s)'):format(name(x), tostring(k), tostring(k2)), items = #items } end
        ka[i], kb[i], ta, tb = k, k2, ta + (t1 - t0), tb + (t2 - t1)
    end
    local function classes(keys)
        local by = {}
        for i, k in ipairs(keys) do by[k] = by[k] or {}; table.insert(by[k], i) end
        local n, m = 0, 0
        for _, l in pairs(by) do if #l >= 2 then n, m = n + 1, m + #l end end
        return by, n, m
    end
    local by_a, ca, ma = classes(ka)
    local by_b, cb, mb = classes(kb)
    local function disagree(by, other)
        local count, sample = 0, {}
        for _, l in pairs(by) do
            for j = 2, #l do
                if other[l[j]] ~= other[l[1]] then
                    count = count + 1
                    if #sample < show then sample[#sample + 1] = name(items[l[1]]) .. '  vs  ' .. name(items[l[j]]) end
                end
            end
        end
        table.sort(sample)
        return count, sample
    end
    local split, ssample = disagree(by_a, kb)
    local merged, msample = disagree(by_b, ka)
    local n = math.max(#items, 1)
    return { items = #items, classes_a = ca, members_a = ma, classes_b = cb, members_b = mb,
        split = split, merged = merged, split_sample = ssample, merged_sample = msample,
        us_a = ta / n / 1e3, us_b = tb / n / 1e3 }
end

return {
    name = 'partition-join',
    kind = 'discovery',
    measures = 'CART-1412',
    summary = 'do two keyings of one population induce the same partition (the acceptance test for swapping an equality key)?',
    params = { keys = 'string', show = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        if v.items == 0 then return false, 'the population is EMPTY — nothing was compared' end
        if v.classes_a == 0 and v.classes_b == 0 then
            return false, ('VACUOUS: no key puts two of the %d items together on either side'):format(v.items)
        end
        return v.split == 0 and v.merged == 0,
            ('%d items; A %d classes / %d members, B %d / %d; split %d, merged %d%s%s'):format(v.items, v.classes_a,
                v.members_a, v.classes_b, v.members_b, v.split, v.merged,
                #v.split_sample > 0 and ('; split: ' .. table.concat(v.split_sample, '; ')) or '',
                #v.merged_sample > 0 and ('; merged: ' .. table.concat(v.merged_sample, '; ')) or '')
    end,
    examples = (function ()
        local FX = { ['r.lua'] = 'local M = {}\nfunction M.aa() return 1 end\nfunction M.bb() return 2 end\n'
            .. 'function M.ccc() return 3 end\nreturn M\n' }
        local ITEMS = 'items = function (store) local o = {}; for _, n in ipairs(store.data.nodes) do '
            .. "if n.kind == 'function' then o[#o + 1] = n end end; return o end, name = function (n) return n.name end"
        local function keys(a, b) return function () return { keys = ('return { %s, a = %s, b = %s }'):format(ITEMS, a, b) } end end
        local LEN = 'function (n) return #(n.name:match("[^.]+$")) end'
        return {
            {
                name = 'two keyings that group alike AGREE although their keys differ (a number and its text)',
                files = FX, params = keys(LEN, 'function (n) return "len" .. #(n.name:match("[^.]+$")) end'),
                expect = { holds = true, check = function (v) return v.classes_a == 1 and v.members_a == 2, ('%d classes'):format(v.classes_a) end },
            },
            {
                name = 'a key that SEPARATES what the other joins is a split, named',
                files = FX, params = keys(LEN, 'function (n) return n.name end'),
                expect = { holds = false, check = function (v) return v.split == 1 and v.merged == 0, ('split %d merged %d'):format(v.split, v.merged) end },
            },
            {
                name = 'a key that JOINS what the other separates is a merge, named',
                files = FX, params = keys('function (n) return n.name end', LEN),
                expect = { holds = false, check = function (v) return v.merged == 1 and v.split == 0, ('split %d merged %d'):format(v.split, v.merged) end },
            },
            {
                name = 'two keys that never put two items together are VACUOUS, not an agreement',
                files = FX, params = keys('function (n) return n.name end', 'function (n) return "x" .. n.name end'),
                expect = { holds = false, check = function (v) return v.classes_a == 0 and v.classes_b == 0, 'classes' end },
            },
            {
                name = 'a key that raises refuses, naming the item',
                files = FX, params = keys(LEN, 'function (n) error("boom") end'),
                expect = { holds = false, check = function (v) return v.error and v.error:find('key B raised', 1, true) ~= nil, tostring(v.error) end },
            },
        }
    end)(),
}
