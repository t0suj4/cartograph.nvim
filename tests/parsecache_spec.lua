-- parsecache: one parse per text, BOUNDED by cached source bytes — the oldest entries go past the budget, the newest
-- always stays, an evicted text parses again, and a node handed out before its entry went keeps working
local pc = require 'cartograph.parsecache'

test('parsecache: past MAX_BYTES the OLDEST texts are evicted; a hit stays a hit, an evicted text parses again', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local saved = pc.MAX_BYTES
    pc.clear()
    pc.MAX_BYTES = 60
    local texts = {}
    for i = 1, 5 do texts[i] = ('local x%d = %d -- %s'):format(i, i, ('pad'):rep(4)) end -- (~28 bytes each)
    local first = pc.root(texts[1], 'lua')
    for i = 2, 5 do pc.root(texts[i], 'lua') end
    local bytes, n = pc.size()
    local s0 = vim.deepcopy(pc.stats)
    local ok1 = pc.peek(texts[5], 'lua') ~= nil
    local gone = pc.peek(texts[1], 'lua') == nil
    pc.root(texts[1], 'lua')
    local reparsed = pc.stats.misses - s0.misses
    local alive = first:type() == 'chunk' and first:named_child(0) ~= nil
    pc.MAX_BYTES = saved
    pc.clear()
    ok(bytes <= 60 and n == 2, ('bounded: %d bytes in %d entries'):format(bytes, n))
    ok(ok1, 'the newest text is cached')
    ok(gone, 'the oldest text was evicted')
    eq(1, reparsed, 'an evicted text is parsed again on its next use')
    ok(alive, 'a node handed out before its entry was evicted still answers (it holds its own tree)')
    ok(s0.evictions >= 3, 'evictions are counted: ' .. s0.evictions)
end)

test('parsecache: one text larger than the budget is still cached (the newest always stays)', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local saved = pc.MAX_BYTES
    pc.clear()
    pc.MAX_BYTES = 10
    local t = 'local big = "' .. ('x'):rep(50) .. '"'
    pc.root(t, 'lua')
    local hit = pc.peek(t, 'lua') ~= nil
    pc.MAX_BYTES = saved
    pc.clear()
    ok(hit, 'cached despite the budget')
end)
