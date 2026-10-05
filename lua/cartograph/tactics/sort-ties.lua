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
local function measure(store, p)
    local work, why = require('cartograph.workload').load(p.workload)
    if not work then return { error = why } end
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
            local info = debug.getinfo(2, 'Sl')
            local k = (info and info.short_src or '?') .. ':' .. tostring(info and info.currentline or '?')
            local s = sites[k]
            if not s then s = { site = k, sorts = 0, ties = 0, max = 0 }; sites[k] = s end
            s.sorts, s.ties, s.max = s.sorts + 1, s.ties + ties, math.max(s.max, ties)
        end
    end
    local okr, rerr = pcall(work, store)
    table.sort = real
    if not okr then return { error = 'the workload raised: ' .. tostring(rerr) } end
    local out = {}
    for _, s in pairs(sites) do out[#out + 1] = s end
    real(out, function (a, b) if a.ties ~= b.ties then return a.ties > b.ties end return a.site < b.site end)
    return { sites = out, sorts = nsorts }
end

local E = {
    name = 'sort-ties',
    kind = 'discovery',
    tags = { 'find', 'code' },
    measures = 'CART-1442',
    summary = 'determinism without a rerun: every table.sort a workload makes (workload = Lua returning function (store); @file), the sites whose comparator leaves TIES among distinct elements — there the output order is the input order (nondeterministic when that comes from pairs over table keys)',
    params = { workload = 'string' },
    measure = measure,
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
            return #v.sites == 1 and v.sites[1].ties == 4 and v.sorts == 3, vim.inspect(v)
        end },
    },
    {
        name = 'a run whose sorts are all total: no tie, the claim fails',
        files = { ['a.lua'] = 'return 1\n' }, params = function () return { workload = 'return function () table.sort({ 3, 1, 2 }) end' } end,
        expect = { holds = false, check = function (v) return #v.sites == 0 and v.sorts == 1, vim.inspect(v) end },
    },
}

return E