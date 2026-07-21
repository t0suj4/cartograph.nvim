-- The shape-consumer roster: producer calls/fields -> deref paths + honest
-- escape frontier. The fixture is the at-seam work in miniature: every
-- pattern class the hand-migration hit (for-in over `ipairs(call or {})`,
-- multi-level derefs, `['end']` bracket fields, `range = r` table-store,
-- collector escape, arg escape, alias, list length, shadowing).

local consumers = require 'cartograph.consumers'

local SPEC = { calls = { occurrences = 'list' }, fields = { at = 'any' } }

local SRC = [[
local sites = store.occurrences(caller, id)
local n = #sites
local first = sites[1].start.line
for _, r in ipairs(store.occurrences(from, id) or {}) do
    local l = r.start.line
    local e = r['end'].char
    out[#out + 1] = { line = r.start.line, range = r }
    ranges[#ranges + 1] = r
    emit(r)
    local q = r
    use(q.start.char)
end
for _, r in ipairs(u.at) do
    if r then x = r.start.line end
end
local one = c.at.start.line
local pos = c.at and c.at.start  -- `and` yields child1: a SUB-shape binding
local ln = pos.line              -- reads report the FULL path start.line
render({ line = ln })            -- a derived scalar leaves: rewrite site, not a stop
e.at = {}                        -- producer-side write
table.sort(sites, cmp)
local function f(r)      -- param shadows: r here is NOT a shape
    return r.whatever
end
return sites
]]

local function paths(r)
    local out = {}
    for _, d in ipairs(r.derefs) do out[#out + 1] = d.path end
    table.sort(out)
    return out
end

local function escapes(r)
    local out = {}
    for _, e in ipairs(r.escapes) do out[#out + 1] = e.kind .. ':' .. (e.detail or '') end
    table.sort(out)
    return out
end

test('consumers: deref paths, all binding forms', function ()
    local r = consumers.scan(SRC, 'fix.lua', SPEC)
    ok(r, 'lua parser available')
    eq({
        '#',                -- #sites
        '[].start.line',    -- sites[1].start.line
        'end.char',         -- r['end'].char
        'start',            -- c.at.start (the sub-shape read itself)
        'start.char',       -- q.start.char (alias-carried)
        'start.line',       -- local l = r.start.line
        'start.line',       -- { line = r.start.line }
        'start.line',       -- u.at loop element
        'start.line',       -- c.at.start.line (inline field producer)
        'start.line',       -- pos.line — prefix-tainted sub-shape, FULL path
    }, paths(r), 'every deref path found, incl. alias / bracket / sub-shape prefix')
end)

test('consumers: deref rows carry the rewrite payload (ext + stem)', function ()
    local r = consumers.scan(SRC, 'fix.lua', SPEC)
    local byp = {}
    for _, d in ipairs(r.derefs) do byp[d.path .. '|' .. (d.stem2 or '?')] = d end
    local d = byp['end.char|r']            -- r['end'].char
    ok(d and d.ext and d.ext[1] == d.ext[3], 'bracket-chain ext, single line')
    ok(byp['[].start.line|sites[1]'], 'list-index stem2 (2-seg) is the indexed expr')
    for _, x in ipairs(r.derefs) do
        if x.path == 'start.line' and x.via == 'var:pos' then
            ok(x.pre and not x.stem2, 'prefix-taint row marked pre, no stem: never rewritten')
        end
    end
end)

test('consumers: rooted producer scopes the taint; single-seg deref → stem1', function ()
    local src = table.concat({
        'for _, c in ipairs(data.calls) do local x = c.file end',
        'for _, d in ipairs(counter.calls) do local z = d.file end',
    }, '\n')
    local r = consumers.scan(src, 'x.lua', { rooted = { ['data.calls'] = 'list' } })
    local nfile, stem1
    for _, dr in ipairs(r.derefs) do
        if dr.path == 'file' then nfile = (nfile or 0) + 1; stem1 = dr.stem1 end
    end
    eq(1, nfile, 'rooted data.calls taints ONLY its own loop, not counter.calls')
    eq('c', stem1, 'single-segment stem1 = the record → rewrites to acc(c)')
end)

test('consumers: a LISTMAP producer yields records through map[id] → for-in', function ()
    -- store.calls_to[id] is a map of call LISTS: indexing gives a list, the
    -- for-in over it gives a call record (two hops from the rooted producer)
    local src = 'for _, c in ipairs(store.calls_to[t.id] or {}) do local x = c.file end'
    local r = consumers.scan(src, 'x.lua', { rooted = { ['store.calls_to'] = 'listmap' } })
    local hit
    for _, dr in ipairs(r.derefs) do if dr.path == 'file' then hit = dr end end
    ok(hit, 'the call record reached through map[id] is tracked')
    eq('c', hit.stem1, 'and rewrites as a record-field accessor')
end)

test('consumers: the escape frontier is honest and complete', function ()
    local r = consumers.scan(SRC, 'fix.lua', SPEC)
    eq({
        'arg:emit()',       -- emit(r)
        'arg:sort()',       -- table.sort(sites, cmp): list escapes into the sort
        'derived:line',     -- render({ line = ln }): shape-DERIVED scalar leaves
        'return:',          -- return sites
        'store:range',      -- { range = r }  THE record-passing pattern
        'store:ranges[#ranges + 1]', -- collector escape
        'write:',           -- e.at = {}: the producer side, flagged distinctly
    }, escapes(r), 'every way the value ducks out of scope is a frontier row')
    -- and NOT: use(q.start.char) — a scalar leaves, not the shape
end)

test('consumers: shadowing kills taint; guards are benign', function ()
    local r = consumers.scan(SRC, 'fix.lua', SPEC)
    for _, d in ipairs(r.derefs) do
        ok(d.path ~= 'whatever', 'param-shadowed r not treated as a shape')
    end
    for _, e in ipairs(r.escapes) do
        ok(e.kind ~= 'other', 'no unclassified noise rows in the fixture: '
            .. e.kind .. ':' .. (e.detail or ''))
    end
end)

test('consumers: seed count = producer expressions seen once each', function ()
    local r = consumers.scan(SRC, 'fix.lua', SPEC)
    eq(7, r.seeds, '2 occurrence calls + u.at + c.at x3 + e.at, no double count')
end)

test('consumers: blessed accessors report as SEAMED, not frontier', function ()
    local r = consumers.scan([[
for _, r in ipairs(store.occurrences(a, b) or {}) do
    edit(at.sl(r), at.ec(r))
    emit(r)
end
]], 'fix.lua', { calls = { occurrences = 'list' },
        bless = { sl = true, ec = true } })
    eq({ 'arg:emit()' }, escapes(r), 'only the unseamed read is frontier')
    eq(2, #r.seamed, 'sl()/ec() reads count as migration progress')
    eq('sl()', r.seamed[1].detail)
end)
