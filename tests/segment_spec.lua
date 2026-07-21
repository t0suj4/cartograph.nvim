-- Columnar record segment (segment.lua): the wire/cache form of a record list.
-- The gate is EXACT round-trip of the declared fields (str present/absent, int,
-- flags) — a segment must be faithful for the fields it carries, by construction.

local segment = require 'cartograph.segment'

local S = segment.CALL_SCHEMA

test('segment: round-trips the call schema exactly', function ()
    local calls = {
        { file = 'a.lua', callee = 'f', fn = 'a.lua::g@1', full = 'M.f', to = 'a.lua::f@9',
            line = 10, method = true, inferred = false },
        { file = 'a.lua', callee = 'h', fn = 'a.lua::g@1', line = 22 }, -- sparse
        { file = 'b.lua', callee = 'f', line = 0, inferred = true },     -- shared f/a.lua
    }
    local recs = segment.decode(segment.encode(calls, S), S)
    eq(3, #recs)
    -- present strings round-trip; absent stay nil
    eq('a.lua', recs[1].file); eq('f', recs[1].callee); eq('M.f', recs[1].full)
    eq('a.lua::f@9', recs[1].to)                     -- resolution-era string rides too
    eq(nil, recs[2].full); eq(nil, recs[2].to)       -- absent → nil
    eq('b.lua', recs[3].file); eq('f', recs[3].callee) -- pooled once, both resolve
    -- ints
    eq(10, recs[1].line); eq(22, recs[2].line); eq(0, recs[3].line)
    -- flags (method/inferred are BOOLEANS): truthy → true, false/absent → nil
    eq(true, recs[1].method); eq(nil, recs[1].inferred)
    eq(nil, recs[2].method); eq(true, recs[3].inferred)
end)

test('segment: range fields round-trip as coordinate columns', function ()
    local R = { start = { line = 5, char = 2 }, ['end'] = { line = 5, char = 9 } }
    local calls = {
        { file = 'a.lua', line = 1, at = R },
        { file = 'a.lua', line = 2 },                 -- at absent → nil
        { file = 'a.lua', line = 3, at = 42 },        -- non-table (folded) → not carried
    }
    local recs = segment.decode(segment.encode(calls, S), S)
    eq(5, recs[1].at.start.line); eq(2, recs[1].at.start.char)
    eq(5, recs[1].at['end'].line); eq(9, recs[1].at['end'].char)
    eq(nil, recs[2].at, 'absent range → nil')
    eq(nil, recs[3].at, 'non-table range not carried by the segment (residual fallback)')
end)

test('segment: identical strings pool to one entry (the wire win)', function ()
    -- 100 calls in one file, same callee → the pool holds each string ONCE, so
    -- the blob is far smaller than the naive per-record bytes
    local calls = {}
    for i = 1, 100 do
        calls[i] = { file = 'same/long/path/to/file.lua', callee = 'commonName',
            fn = 'same/long/path/to/file.lua::f@1', line = i }
    end
    local blob = segment.encode(calls, S)
    local naive = 0
    for _, c in ipairs(calls) do
        naive = naive + #c.file + #c.callee + #c.fn + 2 -- ~per-record raw string bytes
    end
    -- (the fixed schema adds a per-record column floor — the tiny synthetic
    -- shows ~4x; real corpora hit 8-11x where strings dominate)
    ok(#blob < naive / 3, ('pooled blob %d << naive %d (>3x)'):format(#blob, naive))
    -- and it still round-trips
    local recs = segment.decode(blob, S)
    eq('commonName', recs[50].callee); eq(50, recs[50].line)
end)

test('segment: empty list and empty schema fields are safe', function ()
    eq(0, #segment.decode(segment.encode({}, S), S))
    local only_str = { strs = { 'file' } }
    local recs = segment.decode(segment.encode({ { file = 'x' }, {} }, only_str), only_str)
    eq('x', recs[1].file); eq(nil, recs[2].file)
end)
