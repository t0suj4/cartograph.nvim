-- SHRINK (discovery, CART-1645): the SMALLEST part of a tree for which a predicate still holds — delta debugging
-- (Zeller's ddmin) over its FILES, or over the LINES of its files. Promoted from a hand loop written twice on
-- 2026-10-10: arktype's 393 files -> the 2 where a comment-only file moved a flow answer, then their 774 lines -> 151
-- (tests/fixtures/flowsched). The predicate is the only part that varies; the search, the materializing of every
-- candidate and the bookkeeping are this entry's.
-- params: root (the tree), pred (Lua SOURCE returning function (dir, items) -> holds[, why]; `@file` reads one — it
-- is called on a scratch directory holding just the candidate), unit = 'file' (default) | 'line', glob (a Lua pattern
-- over relative paths: only matching files are ITEMS — the rest stay whole in every candidate), out (a directory the
-- result is written to).
-- CLAIM: the predicate holds on the whole tree AND on the result, and the result is smaller. ddmin's result is
-- 1-MINIMAL at its last granularity: removing any one remaining chunk of that size breaks the predicate.

-- ddmin over a list: test(subset) -> holds. -> the reduced list, the number of tests run
local function ddmin(items, test)
    local cur, checks, n = items, 0, 2
    local function t(s) checks = checks + 1; return test(s) end
    while #cur >= 2 do
        local chunk = math.ceil(#cur / n)
        local reduced = false
        for i = 1, n do
            local lo, hi = (i - 1) * chunk + 1, math.min(i * chunk, #cur)
            if lo > hi then break end
            local comp = {}
            for j = 1, #cur do if j < lo or j > hi then comp[#comp + 1] = cur[j] end end
            if t(comp) then cur = comp; n = math.max(n - 1, 2); reduced = true; break end
        end
        if not reduced then
            if n >= #cur then break end
            n = math.min(#cur, n * 2)
        end
    end
    return cur, checks
end

local function slurp(path)
    local fd = io.open(path, 'rb')
    if not fd then return nil end
    local s = fd:read('a'); fd:close()
    return s
end

local function spit(path, text)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    local fd = assert(io.open(path, 'wb')); fd:write(text); fd:close()
end

-- every file under root, relative, sorted
local function files_of(root)
    local out = {}
    for _, f in ipairs(vim.fn.globpath(root, '**', false, true)) do
        if vim.fn.isdirectory(f) == 0 then out[#out + 1] = f:sub(#root + 2) end
    end
    table.sort(out)
    return out
end

-- write the candidate: every non-item file whole, the selected items (files, or lines of item files in order)
local function materialize(dir, root, all, isitem, unit, set)
    vim.fn.delete(dir, 'rf')
    vim.fn.mkdir(dir, 'p')
    local lines_of = {}
    if unit == 'line' then for _, it in ipairs(set) do local l = lines_of[it.file] or {}; lines_of[it.file] = l; l[#l + 1] = it end end
    local chosen = {}
    if unit == 'file' then for _, f in ipairs(set) do chosen[f] = true end end
    for _, f in ipairs(all) do
        if not isitem[f] then spit(dir .. '/' .. f, slurp(root .. '/' .. f) or '')
        elseif unit == 'file' then if chosen[f] then spit(dir .. '/' .. f, slurp(root .. '/' .. f) or '') end
        else
            local l = lines_of[f] or {}
            table.sort(l, function (a, b) return a.n < b.n end)
            local t = {}
            for _, it in ipairs(l) do t[#t + 1] = it.text end
            spit(dir .. '/' .. f, #t > 0 and (table.concat(t, '\n') .. '\n') or '')
        end
    end
end

local function measure(_, p)
    if not p.root then return { error = 'shrink: root= is required' } end
    if not p.pred then return { error = 'shrink: pred= is required (Lua source returning function (dir, items) -> holds)' } end
    local root = vim.fn.fnamemodify(p.root, ':p'):gsub('/$', '')
    local chunk, cerr = load(p.pred, 'shrink-pred', 't')
    if not chunk then return { error = 'shrink: the predicate does not load: ' .. tostring(cerr) } end
    local okp, pred = pcall(chunk)
    if not okp or type(pred) ~= 'function' then return { error = 'shrink: pred= must return a function: ' .. tostring(pred) } end
    local unit = p.unit or 'file'
    if unit ~= 'file' and unit ~= 'line' then return { error = "shrink: unit= is 'file' or 'line'" } end
    local all = files_of(root)
    local isitem, items = {}, {}
    for _, f in ipairs(all) do
        if not p.glob or f:match(p.glob) then
            isitem[f] = true
            if unit == 'file' then items[#items + 1] = f
            else
                local n = 0
                for ln in ((slurp(root .. '/' .. f) or '') .. '\n'):gmatch('(.-)\n') do n = n + 1; items[#items + 1] = { file = f, n = n, text = ln } end
                if items[#items] and items[#items].file == f and items[#items].text == '' then items[#items] = nil end
            end
        end
    end
    local scratch = vim.fn.tempname() .. '-shrink'
    local function holds(set)
        materialize(scratch, root, all, isitem, unit, set)
        local ok, h = pcall(pred, scratch, set)
        return ok and h == true
    end
    local v = { unit = unit, start = #items }
    v.whole = holds(items)
    if not v.whole then vim.fn.delete(scratch, 'rf'); v.result, v.checks = items, 1; return v end
    local cur, checks = ddmin(items, holds)
    v.checks = checks + 1
    v.final = holds(cur)
    v.result = {}
    for _, it in ipairs(cur) do v.result[#v.result + 1] = unit == 'file' and it or (it.file .. ':' .. it.n) end
    if p.out then materialize(vim.fn.fnamemodify(p.out, ':p'):gsub('/$', ''), root, all, isitem, unit, cur) end
    vim.fn.delete(scratch, 'rf')
    return v
end

local PRED = [[return function (dir)
    -- holds while the tree still has both b.txt and d.txt
    return vim.fn.filereadable(dir .. '/b.txt') == 1 and vim.fn.filereadable(dir .. '/d.txt') == 1
end]]
local LPRED = [[return function (dir)
    local s = io.open(dir .. '/m.lua'):read('a')
    return s:find('needle', 1, true) ~= nil and s:find('pin', 1, true) ~= nil
end]]

return {
    name = 'shrink',
    kind = 'discovery',
    tags = { 'gate', 'code' },
    summary = 'the smallest set of files (unit=file) or lines (unit=line) of root for which pred still holds — ddmin; pred = Lua source returning function (dir, items) -> holds, called on a scratch copy of each candidate; glob limits the items, out writes the result',
    params = { root = 'string', pred = 'string', unit = 'string?', glob = 'string?', out = 'string?' },
    ddmin = ddmin,
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        if not v.whole then return false, ('the predicate does not hold on the whole tree (%d %ss): nothing to shrink'):format(v.start, v.unit) end
        if not v.final then return false, 'the predicate does not hold on the result' end
        return #v.result < v.start, ('%d -> %d %ss in %d checks'):format(v.start, #v.result, v.unit, v.checks)
    end,
    examples = {
        {
            name = 'five files, the predicate needs two of them: exactly those two remain',
            files = { ['a.txt'] = 'a', ['b.txt'] = 'b', ['c.txt'] = 'c', ['d.txt'] = 'd', ['e.txt'] = 'e' },
            params = function (store) return { root = store.data.root, pred = PRED, glob = '%.txt$' } end,
            expect = { holds = true, check = function (v)
                return table.concat(v.result, ' ') == 'b.txt d.txt', vim.inspect(v.result)
            end },
        },
        {
            name = 'by line: the two lines the predicate reads survive, in their order',
            files = { ['m.lua'] = 'local a = 1\nlocal needle = 2\nlocal b = 3\nlocal c = 4\nreturn pin\n' },
            params = function (store) return { root = store.data.root, pred = LPRED, unit = 'line' } end,
            expect = { holds = true, check = function (v)
                return table.concat(v.result, ' ') == 'm.lua:2 m.lua:5', vim.inspect(v.result)
            end },
        },
        {
            name = 'a predicate the whole tree fails: refused — there is nothing to shrink',
            files = { ['a.txt'] = 'a' },
            params = function (store) return { root = store.data.root, pred = PRED } end,
            expect = { holds = false },
        },
    },
}
