-- CART-1983 (from flowpath FLOW-0052): "where and how does flowtype translate a call of the builtin loadstring?" — the
-- answer lived in `fname == 'loadstring'` comparisons, a STRING LITERAL equal to the name: no call, no reference, no
-- mention, so `mentions` answered 35 files and nothing placed it. `sites { kind = 'literal' }` lists each string literal
-- whose content is the name, confirmed by parsing, with its enclosing function, and ranks the functions in a note. On
-- our own tree: flowtype.lua::callv holds 3 of the 5.

local ts    = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local agent = require 'cartograph.agent'

local function setup()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(rel, t) local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close() end
    w('dispatch.lua', table.concat({
        'local M = {}',
        'function M.handle(fname, args)',
        "  if fname == 'load' or fname == 'loadstring' then",         -- 3: a literal
        '    return "loadstring"',                                     -- 4: double quotes
        '  end',
        '  -- the loadstring branch above handles literals',          -- 6: a COMMENT is no literal
        "  local s = 'loadstrings'",                                   -- 7: a longer string is not the name
        'end',
        'function M.other() return [[loadstring]] end',                -- 9: a long string
        'function M.run(src) return loadstring(src) end',              -- 10: a CALL, not a literal
        'return M', '' }, '\n'))
    w('b.js', 'function pick(k) { return k === "loadstring"; }\n')
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    return root
end

test('sites literal: every string literal equal to the name, with its enclosing function; comments, longer strings and calls are not (CART-1983)', function ()
    if not (parser_available('lua') and parser_available('javascript')) then skip 'no lua / javascript parser' end
    local root = setup()
    local a = agent.answer(store, 'sites', { name = 'loadstring', kind = 'literal' })
    eq(true, a.ok, vim.inspect(a.refusal))
    local got = {}
    for _, r in ipairs(a.result) do got[#got + 1] = ('%s:%d %s %s'):format(r.file, r.line, r.kind, tostring(r.fn)) end
    eq({ 'b.js:1 literal b.js::pick@0', 'dispatch.lua:3 literal dispatch.lua::M.handle@1',
        'dispatch.lua:4 literal dispatch.lua::M.handle@1', 'dispatch.lua:9 literal dispatch.lua::M.other@8' }, got)
    local l3 = "  if fname == 'load' or fname == 'loadstring' then"
    eq(l3:find("'loadstring'", 1, true), a.result[2].col, 'a 1-based column at the opening quote')
    local rank
    for _, n in ipairs(a.notes) do if n.kind == 'literal-by-function' then rank = n end end
    ok(rank and rank.evidence.functions[1].fn == 'dispatch.lua::M.handle@1' and rank.evidence.functions[1].sites == 2,
        'the dispatch function ranks first: ' .. vim.inspect(rank))
    vim.fn.delete(root, 'rf')
end)

test('sites literal: only on request — the default kinds list the call, never a literal; a file narrows; none is absent (CART-1983)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = setup()
    local d = agent.answer(store, 'sites', { name = 'loadstring' })
    for _, r in ipairs(d.result) do ok(r.kind ~= 'literal', 'a literal is not a use: ' .. vim.inspect(r)) end
    ok(#d.result >= 1 and d.result[1].kind == 'call', 'the call at line 10 is a site')
    local f = agent.answer(store, 'sites', { name = 'loadstring', kind = 'literal', file = 'b.js' })
    if parser_available('javascript') then eq(1, #f.result) end
    eq('absent', agent.answer(store, 'sites', { name = 'nowhere_named', kind = 'literal' }).absence)
    vim.fn.delete(root, 'rf')
end)

test('sites literal: the enclosing function is the INNERMOST one — a literal in a nested function names it, not its outer (CART-1983)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/n.lua', 'w'))
    fd:write('local M = {}\nfunction M.outer()\n  local function pick(k)\n    return k == "loadstring"\n  end\n  return pick\nend\nreturn M\n')
    fd:close()
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local a = agent.answer(store, 'sites', { name = 'loadstring', kind = 'literal' })
    eq(1, #a.result)
    ok(tostring(a.result[1].fn):match('pick'), 'the nested function, not M.outer: ' .. tostring(a.result[1].fn))
    vim.fn.delete(root, 'rf')
end)
