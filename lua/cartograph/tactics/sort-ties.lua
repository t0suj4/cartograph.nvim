-- SORT-TIES (discovery, CART-1442): DETERMINISM WITHOUT A RERUN — a single-run TIE WITNESS at every table.sort a
-- workload makes. After each sort, adjacent DISTINCT elements the comparator orders neither way (`not lt(a, b) and not
-- lt(b, a)`, `a ~= b`) are TIES: their output order is their INPUT order, so wherever that input comes from `pairs` /
-- `next` over table keys (address order, different every run) the output is nondeterministic. MEASURED as the class
-- of CART-1434: clones.blocks sorted by (length, copies) only, its input filled from pairs over a table-keyed table —
-- found by running it twice, which a long, effectful or observation-fed computation cannot afford.
-- Each site is the sort's CALLER (file:line); a tie is a WITNESS that order rides on input order there, not proof of
-- nondeterminism (a list built in a deterministic order is fine) — read the site's input. A total comparator (a final
-- tie-break on a unique field) makes the site disappear.
-- `workload` = Lua source returning `function (store)` (`@file` reads one).
-- CLAIM: some sort in the run leaves ties among distinct elements.
-- ★ THE SEPARATORS (CART-1444, what `total-order` writes): the element paths — a scalar field (`.id`) or a field of the
-- first member (`[1].file`) — that are NON-NIL and DISTINCT ACROSS EVERY ELEMENT of every sort at the site, so a
-- final tie-break on one of them makes the comparator total. Distinct across the OBSERVED tied pairs is not enough:
-- a tie-break that ties elsewhere leaves the order partial. Derived, never listed; WHICH one to use stays a decision.
local function paths_of(x)
    local out = {}
    if type(x) ~= 'table' then return out end
    local function scalar(v) return type(v) == 'string' or type(v) == 'number' end
    for k, v in pairs(x) do
        if type(k) == 'string' and k:match('^[%a_][%w_]*$') and scalar(v) then out[#out + 1] = '.' .. k end
    end
    if type(x[1]) == 'table' then
        for k, v in pairs(x[1]) do
            if type(k) == 'string' and k:match('^[%a_][%w_]*$') and scalar(v) then out[#out + 1] = '[1].' .. k end
        end
    end
    return out
end
local function at(x, path)
    local v = x
    for step in path:gmatch('[^%.]+') do
        if type(v) ~= 'table' then return nil end
        if step == '[1]' then v = v[1] else v = v[step] end
    end
    return v
end
-- does `path` (one path, or two joined by a comma: a COMPOSITE key) separate every element of `t`?
local function separating(t, path)
    local p1, p2 = path:match('^([^,]+),([^,]+)$')
    local seen, ty = {}, {}
    for i = 1, #t do
        local k
        if p1 then
            local a, b = at(t[i], p1), at(t[i], p2)
            if a == nil or b == nil then return false end
            if (ty[1] and type(a) ~= ty[1]) or (ty[2] and type(b) ~= ty[2]) then return false end
            ty[1], ty[2] = type(a), type(b)
            k = tostring(a) .. '\0' .. tostring(b)
        else
            k = at(t[i], path)
            if k == nil then return false end
            if ty[1] and type(k) ~= ty[1] then return false end
            ty[1] = type(k)
        end
        if seen[k] then return false end
        seen[k] = true
    end
    return true
end

local function measure(store, p)
    local W = require 'cartograph.workload'
    local work, why = W.load(p.workload)
    if not work then return { error = why } end
    local root = store and store.data and store.data.root
    local sites, nsorts = {}, 0
    local real = table.sort
    local function lt_default(a, b) return a < b end
    table.sort = function (t, cmp)
        real(t, cmp)
        nsorts = nsorts + 1
        local lt = cmp or lt_default
        local ties = 0
        for i = 1, #t - 1 do
            local a, b = t[i], t[i + 1]
            if not rawequal(a, b) then
                local ok1, x = pcall(lt, a, b)
                local ok2, y = pcall(lt, b, a)
                -- (elements EQUAL IN CONTENT tie harmlessly: either order prints the same — only a tie between elements that
                -- differ makes the output depend on input order)
                if ok1 and ok2 and not x and not y and not vim.deep_equal(a, b) then ties = ties + 1 end
            end
        end
        if ties > 0 then
            local k = W.site(debug.getinfo(2, 'Sl'), root)
            local s = sites[k]
            if not s then
                s = { site = k, sorts = 0, ties = 0, max = 0, sep = {} }
                -- single paths, and every ORDERED PAIR of them (a composite key: CART-1434's groups are unique only by
                -- (first member's file, its line)) — a pair is offered only when no single path separates
                local ps = paths_of(t[1])
                for _, path in ipairs(ps) do s.sep[path] = true end
                for _, x in ipairs(ps) do for _, y in ipairs(ps) do if x ~= y then s.sep[x .. ',' .. y] = true end end end
                sites[k] = s
            end
            s.sorts, s.ties, s.max = s.sorts + 1, s.ties + ties, math.max(s.max, ties)
            for path in pairs(s.sep) do if not separating(t, path) then s.sep[path] = nil end end
        end
    end
    local okr, rerr = pcall(work, store)
    table.sort = real
    if not okr then return { error = 'the workload raised: ' .. tostring(rerr) } end
    local out = {}
    for _, s in pairs(sites) do
        local sep, single = {}, false
        for path in pairs(s.sep) do if not path:find(',', 1, true) then single = true end end
        for path in pairs(s.sep) do if not (single and path:find(',', 1, true)) then sep[#sep + 1] = path end end
        real(sep, function (a, b) if #a ~= #b then return #a < #b end return a < b end)
        out[#out + 1] = { site = s.site, sorts = s.sorts, ties = s.ties, max = s.max, separators = sep }
    end
    real(out, function (a, b) if a.ties ~= b.ties then return a.ties > b.ties end return a.site < b.site end)
    return { sites = out, sorts = nsorts }
end

local E = {
    name = 'sort-ties',
    kind = 'discovery',
    tags = { 'find', 'code' },
    measures = 'CART-1442',
    summary = 'determinism without a rerun: every table.sort a workload makes (workload = Lua returning function (store); @file), the sites whose comparator leaves TIES among distinct elements — there the output order is the input order (nondeterministic when that comes from pairs over table keys)',
    params = { workload = 'string', code = 'string?', timeout = 'string?' },
    measure = require('cartograph.workload').code_aware('sort-ties', measure),
    claim = function (v)
        if v.error then return false, v.error end
        if #v.sites == 0 then return false, ('no ties in %d sorts'):format(v.sorts) end
        local s = v.sites[1]
        return true, ('%d sort site(s) leave ties (of %d sorts): %s — %d ties over %d sorts'):format(#v.sites, v.sorts, s.site, s.ties, s.sorts)
    end,
}

local WORK = table.concat({
    'return function ()',
    '  local keep = {}',
    '  for i = 1, 6 do keep[{ id = i }] = true end',
    '  local out = {}',
    '  for k in pairs(keep) do out[#out + 1] = { len = k.id % 2, id = k.id } end',
    '  table.sort(out, function (a, b) return a.len < b.len end)', -- (partial: ties among equal len)
    '  local total = {}',
    '  for k in pairs(keep) do total[#total + 1] = { len = k.id % 2, id = k.id } end',
    '  table.sort(total, function (a, b) if a.len ~= b.len then return a.len < b.len end return a.id < b.id end)',
    '  table.sort({ 3, 1, 2 })',
    'end',
}, '\n')

E.examples = {
    {
        name = 'a sort by a PARTIAL key over a pairs-built list leaves ties — witnessed in one run; a total comparator and a sort of numbers leave none',
        files = { ['a.lua'] = 'return 1\n' }, params = function () return { workload = WORK } end,
        expect = { holds = true, check = function (v)
            -- (the site names its FILE exactly, and `.id` — unique across all six — is the one separator; `.len` ties)
            return #v.sites == 1 and v.sites[1].ties == 4 and v.sorts == 3 and v.sites[1].site:match('workload"%]:6$') ~= nil
                and vim.deep_equal(v.sites[1].separators, { '.id' }), vim.inspect(v)
        end },
    },
    {
        name = 'no single field is unique but a PAIR is: the separators are the composite keys, ordered pairs both ways',
        files = { ['a.lua'] = 'return 1\n' },
        params = function () return { workload = table.concat({
            'return function ()',
            '  local keep = {}',
            '  for _, f in ipairs({ "a", "b" }) do for l = 1, 2 do keep[{ f = f, l = l }] = true end end',
            '  local out = {}',
            '  for k in pairs(keep) do out[#out + 1] = { f = k.f, l = k.l, len = 0 } end',
            '  table.sort(out, function (a, b) return a.len < b.len end)',
            'end' }, '\n') } end,
        expect = { holds = true, check = function (v)
            return #v.sites == 1 and vim.deep_equal(v.sites[1].separators, { '.f,.l', '.l,.f' }), vim.inspect(v)
        end },
    },
    {
        name = 'a run whose sorts are all total: no tie, the claim fails',
        files = { ['a.lua'] = 'return 1\n' }, params = function () return { workload = 'return function () table.sort({ 3, 1, 2 }) end' } end,
        expect = { holds = false, check = function (v) return #v.sites == 0 and v.sorts == 1, vim.inspect(v) end },
    },
}

return E