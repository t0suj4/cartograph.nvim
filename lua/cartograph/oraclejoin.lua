-- oraclejoin.lua — A READER JOINED AGAINST AN INDEPENDENT ORACLE, PER INPUT (CART-1044).
--
-- ★ WHY A HARNESS AND NOT ANOTHER SCRIPT. On 2026-09-23 every new reader (yamlvalue, xmlvalue,
-- the locale key sets, the terraform witness, the history prior) was accepted by a join against
-- an independent implementation, and the join was rebuilt five times. EVERY BUG OF THE DAY THAT
-- WAS NOT IN THE CODE WAS IN THAT SCAFFOLDING: the oracle split `git ls-files` on whitespace (five
-- files unopenable), a loader globbed a stray JSON file as a 50th locale, the ORACLE ITSELF was
-- wrong (Python's \S treats U+00A0 as whitespace; XML's does not), and "64 disagree" turned out to
-- be ONE cause read 64 times. This module owns the parts that went wrong.
--
-- ── THE SIX OUTCOMES, per input, and none of them is dropped ─────────────────────────────
--   agree        both read it and the values are equal
--   disagree     both read it and the values differ — carries the FIRST STRUCTURAL DIFFERENCE
--   refused      WE refused it (the reason is kept) while the oracle read it
--   rejected     the ORACLE rejected it while we read it — the leniency question, never silence
--   both         both refused it
--   unopenable   the input could not be read at all — counted, never a crash
-- ★★ DISAGREEMENTS ARE GROUPED BY CAUSE: the first difference is found by walking both values
-- in parallel, and its (kind, normalised path, detail class) is the group key — so a single
-- defect shows up as one group of 64, not as 64 examples. Each group keeps a few examples.
-- ⚠ A JOIN WITH NO AGREEMENT IS VACUOUS, and the report says so rather than printing a table:
-- a join whose two sides never agree is a broken harness far more often than a broken reader.

local M = {}

M.UNOPENABLE = setmetatable({}, { __tostring = function() return 'UNOPENABLE' end })

local function kv_ser(v)
    local A = require('cartograph.algebra').load()
    return A.kv_ser(v)
end

--- the kind of a kv value
local function kind(v)
    if type(v) == 'table' then
        if v.o then return 'object' elseif v.a then return 'array' elseif v.null then return 'null' end
        return 'table'
    end
    return type(v)
end

-- a scalar difference, classified: what KIND of change separates the two texts
local function detail(a, b)
    local sa, sb = tostring(a), tostring(b)
    if sa:gsub('%s', '') == sb:gsub('%s', '') then return 'whitespace' end
    if sa:lower() == sb:lower() then return 'case' end
    if sa:gsub('[^%w]', '') == sb:gsub('[^%w]', '') then return 'punctuation/escapes' end
    if sa:find(sb, 1, true) or sb:find(sa, 1, true) then return 'one contains the other' end
    if sa:find('[\128-\255]') or sb:find('[\128-\255]') then return 'non-ascii content' end
    return 'content'
end
M._detail = detail

--- ★ THE FIRST STRUCTURAL DIFFERENCE between two kv values, or nil when equal.
--- @return table|nil diff { path, kind = 'type'|'missing-key'|'extra-key'|'length'|'value'|'order', ours, theirs, detail }
function M.first_difference(ours, theirs, path)
    path = path or '$'
    local ko, kt = kind(ours), kind(theirs)
    if ko ~= kt then return { path = path, kind = 'type', ours = ko, theirs = kt, detail = ko .. ' vs ' .. kt } end
    if ko == 'object' then
        local seen = {}
        for _, k in ipairs(theirs.keys) do
            seen[k] = true
            if ours.o[k] == nil then return { path = path .. '.' .. k, kind = 'missing-key', theirs = k, detail = 'the oracle has it, we do not' } end
        end
        for _, k in ipairs(ours.keys) do
            if not seen[k] then return { path = path .. '.' .. k, kind = 'extra-key', ours = k, detail = 'we have it, the oracle does not' } end
        end
        for _, k in ipairs(theirs.keys) do
            local d = M.first_difference(ours.o[k], theirs.o[k], path .. '.' .. k)
            if d then return d end
        end
        for i, k in ipairs(theirs.keys) do
            if ours.keys[i] ~= k then return { path = path, kind = 'order', detail = 'the same keys in another order' } end
        end
        return nil
    end
    if ko == 'array' then
        if #ours.a ~= #theirs.a then
            return { path = path, kind = 'length', ours = #ours.a, theirs = #theirs.a, detail = ('%d vs %d elements'):format(#ours.a, #theirs.a) }
        end
        for i = 1, #theirs.a do
            local d = M.first_difference(ours.a[i], theirs.a[i], path .. '[' .. i .. ']')
            if d then return d end
        end
        return nil
    end
    if ours == theirs then return nil end
    if ko == 'null' then return nil end
    return { path = path, kind = 'value', ours = ours, theirs = theirs, detail = detail(ours, theirs) }
end

-- the group key: kind + a normalised path (indices dropped, the last three segments) + detail
local function cause_key(d)
    local p = d.path:gsub('%[%d+%]', '[]')
    local segs = {}
    for s in p:gmatch('[^.]+') do segs[#segs + 1] = s end
    if #segs > 3 then p = '…' .. table.concat({ segs[#segs - 2], segs[#segs - 1], segs[#segs] }, '.') end
    return ('%s at %s (%s)'):format(d.kind, p, d.detail or '?')
end
M._cause_key = cause_key

--- ★★ RUN A JOIN.
--- @param spec table {
---   inputs  = { id | {id=, …} },                       -- the population
---   read    = function(input) -> value | nil, why | M.UNOPENABLE,
---   oracle  = function(input) -> value | nil, why,      -- or `oracle_map = { [id] = {value=} | {error=} }`
---   eq      = function(a, b) -> bool,                   -- default: kv_ser equality
---   examples = n (per group, default 3) }
--- @return table report { counts, groups (sorted by size), refusals, rejections, vacuous }
function M.run(spec)
    local counts = { total = 0, agree = 0, disagree = 0, refused = 0, rejected = 0, both = 0, unopenable = 0 }
    local groups, order, refusals, rejections = {}, {}, {}, {}
    local keep = spec.examples or 3
    local eq = spec.eq or function(a, b) return kv_ser(a) == kv_ser(b) end
    for _, input in ipairs(spec.inputs) do
        local id = type(input) == 'table' and input.id or input
        counts.total = counts.total + 1
        local ok_r, ours, why = pcall(spec.read, input)
        if not ok_r then ours, why = nil, 'the reader RAISED: ' .. tostring(ours) end
        local theirs, owhy
        if spec.oracle_map then
            local e = spec.oracle_map[id]
            if e == nil then theirs, owhy = nil, 'the oracle produced nothing for this input'
            elseif e.error then theirs, owhy = nil, e.error
            else theirs = e.value end
        else
            local ok_o
            ok_o, theirs, owhy = pcall(spec.oracle, input)
            if not ok_o then theirs, owhy = nil, 'the oracle RAISED: ' .. tostring(theirs) end
        end
        if ours == M.UNOPENABLE or why == M.UNOPENABLE then
            counts.unopenable = counts.unopenable + 1
        elseif ours == nil and theirs == nil then
            counts.both = counts.both + 1
        elseif ours == nil then
            counts.refused = counts.refused + 1
            refusals[#refusals + 1] = { id = id, why = tostring(why) }
        elseif theirs == nil then
            counts.rejected = counts.rejected + 1
            rejections[#rejections + 1] = { id = id, why = tostring(owhy) }
        elseif eq(ours, theirs) then
            counts.agree = counts.agree + 1
        else
            counts.disagree = counts.disagree + 1
            local d = M.first_difference(ours, theirs) or { path = '$', kind = 'unequal', detail = 'eq() says unequal, no structural difference' }
            local key = cause_key(d)
            local g = groups[key]
            if not g then g = { cause = key, n = 0, examples = {} }; groups[key] = g; order[#order + 1] = key end
            g.n = g.n + 1
            if #g.examples < keep then
                g.examples[#g.examples + 1] = { id = id, path = d.path, ours = d.ours, theirs = d.theirs }
            end
        end
    end
    local list = {}
    for _, k in ipairs(order) do list[#list + 1] = groups[k] end
    table.sort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.cause < b.cause end)
    return { counts = counts, groups = list, refusals = refusals, rejections = rejections,
        vacuous = counts.agree == 0 and counts.total > 0 }
end

--- The report as lines.
function M.lines(r, opts)
    opts = opts or {}
    local c = r.counts
    local out = {}
    if r.vacuous then out[#out + 1] = '⚠ VACUOUS JOIN: no input agrees — suspect the harness (the convention, the paths, the oracle) before the reader' end
    out[#out + 1] = ('%d inputs: agree %d | disagree %d in %d cause(s) | refused by us %d | rejected by the oracle %d | both refused %d | unopenable %d')
        :format(c.total, c.agree, c.disagree, #r.groups, c.refused, c.rejected, c.both, c.unopenable)
    for _, g in ipairs(r.groups) do
        out[#out + 1] = ('  DISAGREE ×%d  %s'):format(g.n, g.cause)
        for _, e in ipairs(g.examples) do
            out[#out + 1] = ('      %s  %s: ours %s | oracle %s'):format(e.id, e.path, vim.inspect(e.ours):sub(1, 60), vim.inspect(e.theirs):sub(1, 60))
        end
    end
    local n = opts.show or 5
    for i = 1, math.min(n, #r.refusals) do out[#out + 1] = ('  refused by us: %s — %s'):format(r.refusals[i].id, r.refusals[i].why:sub(1, 120)) end
    if #r.refusals > n then out[#out + 1] = ('  … %d more refusals'):format(#r.refusals - n) end
    for i = 1, math.min(n, #r.rejections) do out[#out + 1] = ('  rejected by the oracle: %s — %s'):format(r.rejections[i].id, r.rejections[i].why:sub(1, 120)) end
    if #r.rejections > n then out[#out + 1] = ('  … %d more rejections'):format(#r.rejections - n) end
    return out
end

--- JSON's ordered-pairs encoding (`{"__o": [[k, v]…]}`, `{"__a": […]}`) into kv values: the wire
--- form an external oracle writes, because a JSON object's key order does not survive decoding.
function M.kv_from_json(v)
    if type(v) == 'table' then
        if v.__o then
            local o, keys = {}, {}
            for _, p in ipairs(v.__o) do
                if o[p[1]] == nil then keys[#keys + 1] = p[1] end
                o[p[1]] = M.kv_from_json(p[2])
            end
            return { o = o, keys = keys }
        end
        if v.__a then
            local a = {}
            for i, x in ipairs(v.__a) do a[i] = M.kv_from_json(x) end
            return { a = a }
        end
    end
    if v == vim.NIL then return { null = true } end
    return v
end

--- ★ AN EXTERNAL ORACLE: a command that reads the input paths NUL-SEPARATED on stdin and writes
--- one JSON object { [path] = { value } | { error } } on stdout. NUL, not newlines or spaces: a path
--- may contain either, and splitting on whitespace is exactly the bug this module was built after.
--- @return table|nil map, string|nil why
function M.external(cmd, paths)
    local input = table.concat(paths, '\0') .. '\0'
    local res = vim.system(cmd, { stdin = input, text = true }):wait()
    if res.code ~= 0 then return nil, ('the oracle exited %d: %s'):format(res.code, (res.stderr or ''):sub(1, 300)) end
    local ok, decoded = pcall(vim.json.decode, res.stdout)
    if not ok or type(decoded) ~= 'table' then return nil, 'the oracle did not write a JSON object' end
    local out = {}
    for k, e in pairs(decoded) do
        if type(e) == 'table' and e.error then out[k] = { error = e.error }
        -- `partial` (an oracle's own caveat on a value it did produce) travels with the value
        elseif type(e) == 'table' then out[k] = { value = M.kv_from_json(e.value), partial = e.partial == true or nil } end
    end
    return out
end

--- git's own file list, NUL-separated (`-z`), so a name with a space or newline stays one name.
function M.ls_files(dir, pattern)
    local cmd = { 'git', '-C', dir, 'ls-files', '-z' }
    if pattern then cmd[#cmd + 1] = pattern end
    local res = vim.system(cmd, { text = true }):wait()
    local out = {}
    for f in (res.stdout or ''):gmatch('([^%z]+)') do out[#out + 1] = f end
    return out
end

return M
