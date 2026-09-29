-- THE LUA -> JS EMITTER (cartograph.luajs, CART-1197) under a DIFFERENTIAL oracle: each snippet runs as Lua (with the
-- STANDARD print — tab-joined tostring, not nvim's) and as the emitted JavaScript under node, and the outputs must be
-- byte-identical. Two implementations of one program; the emitter never sees the Lua result.
-- Pinned both ways: a construct with no faithful form is REFUSED by name (and the module still parses), a pack gap is
-- a LOUD LuaBreak at run time (never a quiet approximation), and the representations follow the shape evidence.
local L = require 'cartograph.luajs'
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') and vim.fn.executable('node') == 1 end

--- the snippet as Lua, with the standard print
local function lua_out(src)
    local out = {}
    local env = setmetatable({ print = function (...)
        local t = {}
        for i = 1, select('#', ...) do t[i] = tostring((select(i, ...))) end
        out[#out + 1] = table.concat(t, '\t')
    end }, { __index = _G })
    local f = assert(loadstring(src))
    setfenv(f, env)
    local ok, err = pcall(f)
    if not ok then out[#out + 1] = 'ERROR ' .. tostring(err) end
    return table.concat(out, '\n') .. (#out > 0 and '\n' or '')
end

--- nvim's pure-Lua runtime (vim.split / inspect / fs / uri), transliterated ONCE per run into a cache directory
local VIMRT
local function vimrt()
    if not VIMRT then
        VIMRT = vim.fn.tempname(); vim.fn.mkdir(VIMRT, 'p')
        L.vim_runtime(VIMRT, table.concat(vim.fn.readfile(REPO .. '/lua/cartograph/luajs/pack.js'), '\n'))
    end
    return VIMRT
end

--- the snippet emitted and run under node -> stdout, the emitted js, refusals
local function js_out(src, with_vim)
    local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
    if with_vim then vim.system({ 'cp', '-r', vimrt() .. '/vim', dir .. '/vim' }):wait() end
    vim.fn.writefile(vim.fn.readfile(REPO .. '/lua/cartograph/luajs/pack.js', 'b'), dir .. '/$pack.js', 'b')
    vim.fn.writefile(vim.fn.readfile(REPO .. '/lua/cartograph/luajs/lstrmatch.js', 'b'), dir .. '/$lstrmatch.js', 'b')
    local js, refusals = L.emit(src, 'snippet.lua', { pack = './$pack.js' })
    local fd = assert(io.open(dir .. '/snippet.js', 'wb')); fd:write(js); fd:close()
    local r = vim.system({ 'node', dir .. '/snippet.js' }, { text = true, env = L.run_env(dir) }):wait(120000)
    return (r.stdout or '') .. (r.stderr or ''), js, refusals, r.code
end

local CASES = {
    numbers = [[print(1/3, 2^53, 1e15, 1e16, 0.1, -0.0 == 0, 10 % -3, -7 % 3, 7 % 0 ~= 7 % 0, math.floor(-2.5), 3 == 3.0)]],
    truthiness = [[print(0 and 'zero', '' and 'empty', nil or 'dflt', false or nil, not 0, not nil, 1 and nil)]],
    multi = [[
local function f(...) return select('#', ...), ... end
local n, a, b = f('x', nil)
print(n, a, b, (f(1, 2)))
local function g() return 1, 2, 3 end
local t = { g() }
print(#t, g(), (g()))
print(select(2, 'a', 'b', 'c'))
local u = { 10, 20, 30 }
print(unpack(u))]],
    tables = [[
local t = {}
for i = 1, 5 do t[#t + 1] = i * 1.5 end
print(#t, table.concat(t, ','))
table.insert(t, 1, 'first'); print(t[1], #t, table.remove(t), #t)
local r = { name = 'n' }
r.age = 3
local acc = {}
for k, v in pairs(r) do acc[#acc + 1] = k .. '=' .. tostring(v) end
table.sort(acc)
print(table.concat(acc, ' '))
local seen = {}
for _, w in ipairs({ 'a', 'b', 'a' }) do seen[w] = (seen[w] or 0) + 1 end
print(seen.a, seen.b, seen.c)
local s = { 3, 1, 2 }
table.sort(s, function (x, y) return x > y end)
print(s[1], s[2], s[3])
-- appends through a PARAMETER into a dictionary-shaped table (a Map): # is a cached border (was O(n) per append)
local function put(t, v) t[#t + 1] = v end
local d = {}
d.kind = 'bytes'
for i = 1, 20000 do put(d, i % 7) end
print(#d, d[1], d[20000], d.kind)
d[#d] = nil; d[#d] = nil
print(#d, d[19998])]],
    strings = [[
local s = 'h\195\169llo'
print(#s, s:sub(2, 3):byte(1, 2), s:upper(), s:sub(-3), s:sub(0), s:sub(10))
print(('%5.2f|%-4s|%d|%x|%s'):format(3.14159, 'ab', 42, 255, nil), ('ab'):rep(3, '-'))
print(('hello world'):find('o w', 1, true), ('abc'):find('z', 1, true), string.char(72, 105))
print('a' < 'b', 'Z' < 'a', 'abc' .. 1 .. 2.5, tostring(nil), tostring(true), tonumber('0x10'), tonumber(' 12 '), tonumber('z'))]],
    control = [[
for i = 1, 4 do
  if i % 2 == 0 then goto continue end
  print('odd', i)
  ::continue::
end
for i = 10, 1, -3 do io = nil; print('down', i) end
local j = 0
repeat local k = j; j = j + 1 until k >= 2
print('repeat', j)
local w = 0
while true do w = w + 1; if w > 3 then break end end
print('while', w)]],
    scope = [[
local x = 1
do local x = x + 1; print('inner', x) end
print('outer', x)
local p, q = 1, 2
p, q = q, p
print(p, q)
local fs = {}
for i = 1, 3 do fs[i] = function () return i end end
print(fs[1](), fs[2](), fs[3]())
local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end
print(fact(10))
local obj = { v = 10 }
function obj:get(d) return self.v + d end
print(obj:get(5), obj.get(obj, 1))]],
    metatables = [[
local Class = {}
Class.__index = Class
function Class.new(v) return setmetatable({ v = v }, Class) end
function Class:get() return self.v end
local o = Class.new(4)
print(o:get(), o.missing, getmetatable(o) == Class, rawget(o, 'get'))
local chain = setmetatable({}, { __index = setmetatable({ a = 1 }, { __index = function (t, k) return k .. '!' end }) })
print(chain.a, chain.zz)
local log = {}
local w = setmetatable({ present = 1 }, { __newindex = function (t, k, v) log[#log + 1] = k; rawset(t, k, v * 10) end })
w.present = 2; w.fresh = 3
print(w.present, w.fresh, table.concat(log, ','))
local store = {}
local via = setmetatable({}, { __newindex = store })
via.x = 5
print(rawget(via, 'x'), store.x)
local callable = setmetatable({}, { __call = function (self, a, b) return a + b, 'two' end })
print(callable(2, 3))
local named = setmetatable({}, { __tostring = function () return 'I am named' end })
print(tostring(named), named)
local cc = setmetatable({}, { __concat = function (a, b) return 'cat' end })
print(cc .. 'x', 'x' .. cc)
local eqf = function (a, b) return true end
local e1, e2, e3 = setmetatable({}, { __eq = eqf }), setmetatable({}, { __eq = eqf }), setmetatable({}, { __eq = function () return true end })
print(e1 == e2, e1 == e3, e1 ~= e2, e1 == 1)
local ltmt = { __lt = function (a, b) return a.n < b.n end }
local x1, x2 = setmetatable({ n = 1 }, ltmt), setmetatable({ n = 2 }, ltmt)
print(x1 < x2, x2 < x1, x1 <= x2, x2 >= x1)
local V = { __add = function (a, b) return 'add' end, __unm = function (a) return 'neg' end }
local v = setmetatable({}, V)
print(v + 1, 1 + v, -v)
local lenmt = setmetatable({ 1, 2, 3 }, { __len = function () return 99 end })
print(#lenmt)
local prot = setmetatable({}, { __metatable = 'locked' })
print(getmetatable(prot), pcall(setmetatable, prot, {}))
print(getmetatable('').__index == string, ('x'):rep(2))
local raw = setmetatable({ 'a', 'b' }, { __index = function (t, i) return 'X' end })
local n = 0
for _ in ipairs(raw) do n = n + 1 end
print(n, raw[3], table.concat(raw, '+'), rawequal(raw, raw))]],
    gotos = [[
-- FORWARD past statements (a local declared before the goto stays visible after the label)
local x = 1
if x == 1 then goto skip end
x = 2
::skip::
print('forward', x)
-- BACKWARD: a loop made of a label and a goto
local n = 0
::again::
n = n + 1
if n < 3 then goto again end
print('backward', n)
-- OUT of nested loops to after them
for i = 1, 3 do
  for j = 1, 3 do
    if i * j == 4 then goto out end
  end
end
::out::
print('out')
-- CONTINUE inside repeat-until: the until test still runs
local k, seen = 0, {}
repeat
  k = k + 1
  if k % 2 == 0 then goto cont end
  seen[#seen + 1] = k
  ::cont::
until k >= 5
print('repeat', table.concat(seen, ','))
-- BREAK inside a backward region breaks the REAL loop
local c = 0
while true do
  ::top::
  c = c + 1
  if c == 2 then goto top end
  if c >= 4 then break end
end
print('break', c)
-- NESTED regions (a goto nested in an inner block to an outer label)
for i = 1, 4 do
  do
    if i == 2 then goto nextloop end
    if i == 4 then goto nextloop end
    print('body', i)
  end
  ::nextloop::
end]],
    errors = [[

local ok, err = pcall(function () error({ code = 7 }) end)
print(ok, type(err), err.code)
print(pcall(function () return 1, 2 end))
print(select('#', pcall(error)))]],
    -- the DECLARED RULES match MODULO LAYOUT (no gaps, comments inside an operator), and the forms the repository
    -- itself never writes (`...` as one value, `do end`, `return;`) still have a witness
    rules = [==[
local a, b = 3, 4
print(a+b, a --[[c]] + b, a
  -- a comment inside the operator's layout
  * b, a..b, -a, not a, #'xyz')
local t = { f = 1 }
print(t . f, t [ 'f' ], ( a ), t--[[x]].f)
print(a == 3 and -- r
  b or 0, a~=b, a<=b)
local function v(...) local x = ... return x end
print(v(5, 6))
local function r0() return; end
local function r1() return a; end
local function r2() if a then return end return 1 end
local function r3() end
do end
print(r0(), r1(), r2())
print(select('#', r2()), select('#', r3()), r3())
-- a CALLBACK the pack calls that falls off its end returns no values: nil to the pack, never a truthy empty list
local fell = setmetatable({}, { __index = function () end })
print(fell.x, fell.x and 1 or 2)
print(('abc'):gsub('b', function () end))
local E = { __eq = function () end }
print(setmetatable({}, E) == setmetatable({}, E))
local s = { 3, 1, 2 }
table.sort(s, function (x, y) if x < y then return true end end)
print(table.concat(s, ','))]==],
}

for name, src in pairs(CASES) do
    test('luajs differential: ' .. name .. ' — the emitted JS under node prints exactly what Lua prints', function ()
        if not ready() then skip 'no lua parser / node' end
        local want = lua_out(src)
        local got, js, refusals = js_out(src)
        eq(0, #refusals, vim.inspect(refusals))
        ok(want ~= '' and not want:find('^ERROR'), 'the premise: the Lua side ran: ' .. want)
        eq(want, got, js)
    end)
end

test('luajs differential: the HOST pack — debug.getinfo(1, "S") names the Lua source; io files, os dates, errors as Lua\'s triples', function ()
    if not ready() then skip 'no lua parser / node' end
    local src = [[
local d = os.getenv('LUAJS_T')
print(debug.getinfo(1, 'S').source == '@' .. d .. '/snip.lua', #debug.getinfo(1, 'S').short_src, debug.getinfo(1, 'S').short_src)
local p = d .. '/f.txt'
local f = assert(io.open(p, 'w'))
f:write('line one\n', 'l2 ', 42, '\n', '3.5 rest\n')
print(f:close(), io.type(f), tostring(f))
local r = assert(io.open(p, 'r'))
print(r:read('l'), r:read('L') == 'l2 42\n', r:read('n'), r:read('a'), r:read('a'), r:read('l'))
print(r:seek('set', 5), r:read(3), r:seek('cur'), r:seek('end'))
r:close()
local n = 0
for _ in io.lines(p) do n = n + 1 end
print('lines', n)
local a = io.open(p, 'a'); a:write('appended\n'); a:close()
print(#io.open(p):read('a'))
print(io.open(d .. '/missing.txt'))
print(os.remove(d .. '/missing.txt'))
print(os.rename(p, d .. '/g.txt'), io.open(p) == nil)
print(os.remove(d .. '/g.txt'))
print(os.date('!%Y-%m-%dT%H:%M:%SZ', 0), os.date('!%c', 86400 * 40), os.date('!%x %X %p %a %b %j %A %B', 86400 * 40))
local t = os.date('!*t', 1e9)
print(t.year, t.month, t.day, t.hour, t.min, t.sec, t.wday, t.yday)
print(os.time({ year = 2020, month = 1, day = 1, hour = 0 }) == os.time({ year = 2020, month = 1, day = 1, hour = 0, min = 0 }))
print(type(os.time()), type(os.clock()), os.getenv('LUAJS_NOPE'), os.execute('exit 3'))
io.write('io.write ', 1, ' ', 2.5, '\n')
local dirf = io.open(d)
print(dirf ~= nil, dirf and select(2, dirf:read('a')))
]]
    -- a directory LONG enough that short_src is truncated to Lua's 60-byte chunk id ('...' + the tail)
    local dir = vim.fn.tempname() .. '/' .. ('d'):rep(48); vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(dir .. '/snip.lua', 'w')); fd:write(src); fd:close()
    -- the Lua side: the FILE (so its source is '@<path>'), with the standard print, output to stdout
    local ref = vim.system({ 'nvim', '--headless', '-u', 'NONE', '-l', REPO .. '/tests/fixtures/luaref.lua', dir .. '/snip.lua' },
        { text = true, env = { LUAJS_T = dir } }):wait(60000)
    -- the JS side: emitted beside the pack, LUAJS_SRC_ROOT naming the Lua tree it came from
    local out = vim.fn.tempname(); vim.fn.mkdir(out, 'p')
    vim.fn.writefile(vim.fn.readfile(REPO .. '/lua/cartograph/luajs/pack.js', 'b'), out .. '/$pack.js', 'b')
    vim.fn.writefile(vim.fn.readfile(REPO .. '/lua/cartograph/luajs/lstrmatch.js', 'b'), out .. '/$lstrmatch.js', 'b')
    local js, refusals = L.emit(src, 'snip.lua', { pack = './$pack.js' })
    eq(0, #refusals, vim.inspect(refusals))
    local w = assert(io.open(out .. '/snip.js', 'wb')); w:write(js); w:close()
    local run = vim.system({ 'node', out .. '/snip.js' }, { text = true, env = { LUAJS_T = dir, LUAJS_ROOT = out, LUAJS_SRC_ROOT = dir } }):wait(60000)
    ok((ref.stdout or ''):find('^true'), 'the premise: the Lua side ran and its source matched: ' .. tostring(ref.stdout) .. tostring(ref.stderr))
    eq(ref.stdout, (run.stdout or '') .. (run.stderr or ''))
end)

--- every DISTINCT LITERAL pattern the repository's own Lua passes to find / match / gmatch / gsub (derived from lua/)
local function real_patterns()
    local Q = vim.treesitter.query.parse('lua', [[
      (function_call name: (method_index_expression method: (identifier) @m) arguments: (arguments) @a)
      (function_call name: (dot_index_expression table: (identifier) @lib field: (identifier) @m) arguments: (arguments) @a)
    ]])
    local WANT = { find = true, match = true, gmatch = true, gsub = true }
    local seen, out = {}, {}
    for _, path in ipairs(vim.fs.find(function (n) return n:match('%.lua$') end, { path = REPO .. '/lua', type = 'file', limit = math.huge })) do
        local fd = io.open(path); local src = fd:read('a'); fd:close()
        local root = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
        for _, m in Q:iter_matches(root, src, 0, -1, { all = true }) do
            local name, args, lib
            for id, nodes in pairs(m) do
                local cap, n = Q.captures[id], nodes[1]
                if cap == 'm' then name = vim.treesitter.get_node_text(n, src) elseif cap == 'a' then args = n elseif cap == 'lib' then lib = vim.treesitter.get_node_text(n, src) end
            end
            if name and WANT[name] and args and (lib == nil or lib == 'string') then
                local kids = {}
                for c in args:iter_children() do if c:named() and c:type() ~= 'comment' then kids[#kids + 1] = c end end
                local pn = lib and kids[2] or kids[1]
                if pn and pn:type() == 'string' then
                    local okp, p = pcall(load('return ' .. vim.treesitter.get_node_text(pn, src)))
                    if okp and type(p) == 'string' and not seen[p] then seen[p] = true; out[#out + 1] = p end
                end
            end
        end
    end
    table.sort(out)
    return out
end

test('luajs differential: EVERY real Lua pattern of this repository (find, match, gsub, gmatch over real and edge subjects) — LuaJIT\'s matcher transliterated from C, byte-identical to LuaJIT', function ()
    if not ready() then skip 'no lua parser / node' end
    local pats = real_patterns()
    ok(#pats > 500, 'the premise: the census found the real patterns (' .. #pats .. ')')
    -- SUBJECTS: edges (empty, NUL, high bytes, balanced and unbalanced brackets, whitespace) + real lines of this repo
    local subjects = { '', 'a', ' \t\n x ', 'hello world', 'k=v, x=y', 'f(a(b)c)d', '[[x]]', '%d+', 'x\0y', 'h\195\169llo',
        '/usr/local/lib/lua/5.1/x.lua', 'CamelCase_snake-kebab 42 3.5e-2 0x1F', '"quoted" and \'single\'', '-- comment',
        'a.b.c:d(e, f)', '  \r\n', ('ab'):rep(20) }
    local fd = io.open(REPO .. '/lua/cartograph/luajs.lua'); local own = fd:read('a'); fd:close()
    local k = 0
    for line in own:gmatch('[^\n]+') do k = k + 1; if k % 7 == 0 and #subjects < 60 then subjects[#subjects + 1] = line end end
    local parts = { 'local P = {' }
    for _, p in ipairs(pats) do parts[#parts + 1] = ('%q,'):format(p):gsub('\\\n', '\\n') end
    parts[#parts + 1] = '}\nlocal S = {'
    for _, s in ipairs(subjects) do parts[#parts + 1] = ('%q,'):format(s):gsub('\\\n', '\\n') end
    parts[#parts + 1] = [[}
local function show(ok, ...)
  if not ok then return 'ERR ' .. tostring((...)) end
  local t = {}
  for i = 1, select('#', ...) do t[i] = tostring((select(i, ...))) end
  return table.concat(t, ',')
end
for pi = 1, #P do
  local p = P[pi]
  local row = {}
  for si = 1, #S do
    local s = S[si]
    row[#row + 1] = show(pcall(string.find, s, p))
    row[#row + 1] = show(pcall(string.match, s, p))
    row[#row + 1] = show(pcall(string.gsub, s, p, '<%0>'))
    row[#row + 1] = show(pcall(string.find, s, p, 3)) .. '/' .. show(pcall(string.match, s, p, -3)) .. '/' .. show(pcall(string.find, s, p, 99))
    -- the iterator is stepped through pcall (a C caller): a builtin raised from a LUA caller carries that caller's
    -- position in LuaJIT (`chunk:line: msg`), a gap of the pack recorded apart — this test checks the MATCHER
    local it, c, err = string.gmatch(s, p), 0, nil
    while c <= 1000 do
      local okg, v = pcall(it)
      if not okg then err = v; break end
      if v == nil then break end
      c = c + 1
    end
    row[#row + 1] = err and ('ERR ' .. tostring(err)) or tostring(c)
  end
  -- one LINE per pattern: a newline inside a result is escaped
  print(pi, (table.concat(row, '|'):gsub('\\', '\\\\'):gsub('\n', '\\n')))
end]]
    local prog = table.concat(parts, '\n')
    local want = lua_out(prog)
    local got, _, refusals = js_out(prog)
    eq(0, #refusals, vim.inspect(refusals))
    if want ~= got then
        -- name the FIRST disagreeing pattern, not a megabyte diff
        local wl, gl = vim.split(want, '\n'), vim.split(got, '\n')
        for i = 1, math.max(#wl, #gl) do
            if wl[i] ~= gl[i] then
                local pi = tonumber((wl[i] or gl[i] or ''):match('^(%d+)')) or i
                -- the FIRST disagreeing CELL: its subject and which call
                local wc, gc = vim.split(wl[i] or '', '|', { plain = true }), vim.split(gl[i] or '', '|', { plain = true })
                for c = 1, math.max(#wc, #gc) do
                    if wc[c] ~= gc[c] then
                        local si, call = math.floor((c - 1) / 5) + 1, ({ 'find', 'match', 'gsub', 'find/match with init', 'gmatch count' })[(c - 1) % 5 + 1]
                        error(('pattern #%d %q, subject %q, %s:\n  lua: %s\n  js:  %s'):format(pi, tostring(pats[pi]), tostring(subjects[si]), call, tostring(wc[c]), tostring(gc[c])), 0)
                    end
                end
                error(('pattern #%d %q disagrees (line %d)'):format(pi, tostring(pats[pi]), i), 0)
            end
        end
    end
    eq(#pats, select(2, want:gsub('\n', '')), 'one line per pattern')
end)

test('luajs differential: the VIM host pack — nvim\'s own runtime transliterated, the C-backed members declared — prints what the REAL vim API prints', function ()
    if not ready() then skip 'no lua parser / node' end
    local dir = vim.fn.tempname(); vim.fn.mkdir(dir .. '/sub', 'p')
    for _, f in ipairs { 'b', 'a' } do local fd = assert(io.open(dir .. '/' .. f, 'w')); fd:write(f); fd:close() end
    vim.env.LUAJS_SCAN = dir
    local src = [==[
print(vim.inspect(vim.split('a,b,,c', ',')), vim.inspect(vim.split('a b  c', ' ', { trimempty = true })), vim.inspect(vim.split('x.y', '.', { plain = true })))
print(vim.trim('  hi \n'), vim.startswith('foobar', 'foo'), vim.endswith('foobar', 'bar'), vim.pesc('a.b*c'))
local t = vim.list_extend({ 1, 2 }, { 3, 4 }, 2, 2)
print(#t, t[3], vim.tbl_count({ a = 1, b = 2 }), vim.tbl_contains({ 'x', 'y' }, 'y'), vim.tbl_isempty({}), vim.islist({ 1, 2 }), vim.islist({ a = 1 }))
local keys = vim.tbl_keys({ b = 1, a = 2, c = 3 }); table.sort(keys); print(table.concat(keys, ','))
print(vim.inspect(vim.tbl_map(function (v) return v * 2 end, { 1, 2, 3 })), vim.inspect(vim.tbl_filter(function (v) return v > 1 end, { 1, 2, 3 })))
print(vim.inspect(vim.tbl_extend('force', { a = 1, b = 2 }, { b = 3 })), vim.inspect(vim.tbl_deep_extend('force', { a = { x = 1 } }, { a = { y = 2 } })))
local orig = { a = { 1, { 2 } } }; local cp = vim.deepcopy(orig); print(cp ~= orig, cp.a ~= orig.a, cp.a[2][1], vim.deep_equal(cp, orig))
local parts = {}; for p in vim.gsplit('a:b:c', ':') do parts[#parts + 1] = p end; print(table.concat(parts, '|'))
print(vim.inspect({ 1, 'two', { three = 3 }, [10] = 'ten', f = true }))
print(vim.uri_from_fname('/tmp/a b.txt'), vim.uri_to_fname('file:///tmp/a%20b.txt'))
print(vim.fs.joinpath('a', 'b', 'c.lua'), vim.fs.basename('/a/b/c.lua'), vim.fs.dirname('/a/b/c.lua'), vim.fs.normalize('/a//b/../c'))
local P = '/a/b/c.tar.gz'
print(vim.fn.fnamemodify(P, ':t'), vim.fn.fnamemodify(P, ':h'), vim.fn.fnamemodify(P, ':r'), vim.fn.fnamemodify(P, ':e'), vim.fn.fnamemodify(P, ':t:r'), vim.fn.fnamemodify('/a/b/', ':h'), vim.fn.fnamemodify('/a', ':h'), vim.fn.fnamemodify('x', ':h'), vim.fn.fnamemodify('.bashrc', ':r'), vim.fn.fnamemodify('.bashrc', ':e'), vim.fn.fnamemodify('rel', ':p') == vim.fn.getcwd() .. '/rel')
print(vim.fn.sha256('abc'), vim.fn.isdirectory('/tmp'), vim.fn.isdirectory('/nonexistent'), vim.fn.executable('sh'), vim.fn.executable('no-such-binary-x'), vim.fn.has('nvim'), vim.fn.has('nonsense-feature'))
local d = vim.json.decode('{"a":[1,null,{"b":true}],"c":"x\\u00e9"}')
print(type(d.a), #d.a, d.a[2] == vim.NIL, d.a[3].b, d.c, #d.c, vim.json.encode({ 1, 2, 'a/b' }), vim.json.encode({}), vim.json.encode(vim.empty_dict()), vim.json.encode('\t"é"'))
local function hex(s) return (s:gsub('.', function (c) return ('%02x'):format(c:byte()) end)) end
print(hex(vim.mpack.encode({ 1, -1, 1.5, 2^40, 'x', true, vim.NIL })), hex(vim.mpack.encode({})))
local md = vim.mpack.decode(vim.mpack.encode({ a = { 1, vim.NIL, 'z' }, b = 2.5 }))
print(md.a[3], md.a[2] == vim.NIL, md.b, tostring(vim.NIL), type(vim.NIL), pcall(vim.mpack.decode, '\x92\x01'))
local st = vim.uv.fs_stat('/tmp'); print(st.type, type(st.size), type(st.mtime.sec), vim.uv.fs_stat('/nonexistent'))
print(type(vim.uv.hrtime()), vim.uv.os_uname().sysname)
local h = vim.uv.fs_scandir(os.getenv('LUAJS_SCAN'))
local ents = {}
while true do local n, ty = vim.uv.fs_scandir_next(h); if not n then break end; ents[#ents + 1] = n .. ':' .. ty end
print(table.concat(ents, ' '))
local r = vim.system({ 'sh', '-c', 'printf out; printf err >&2; exit 3' }, { text = true }):wait()
print(r.code, r.stdout, r.stderr)
vim.env.LUAJS_VIMTEST = 'set'; print(vim.env.LUAJS_VIMTEST, vim.env.LUAJS_NOPE_X, vim.log.levels.WARN)
]==]
    local want = lua_out(src)
    local got, _, refusals = js_out(src, true)
    eq(0, #refusals, vim.inspect(refusals))
    ok(want ~= '' and not want:find('ERROR'), 'the premise: the real vim side ran: ' .. want)
    if want ~= got then
        local wf, gf = vim.fn.tempname(), vim.fn.tempname()
        vim.fn.writefile(vim.split(want, '\n'), wf); vim.fn.writefile(vim.split(got, '\n'), gf)
        error('the vim host pack disagrees with the real vim API:\n' .. vim.system({ 'diff', wf, gf }, { text = true }):wait().stdout, 0)
    end
    -- and an EDITOR member aborts BY NAME at the read — never a quiet nil
    local ed = js_out('print(pcall(function () return vim.api.nvim_get_current_buf() end))\n', true)
    ok(ed:find('vim.api.nvim_get_current_buf (the editor)', 1, true), ed)
    -- and pcall does NOT swallow it: a break is not a Lua error (a quiet `false, <message>` would hide it)
    ok(not ed:find('^false') and ed:find('LuaBreak', 1, true), 'the break escapes pcall: ' .. ed)
end)

test('luajs differential: vim.TREESITTER — the C binding over the bridge + nvim\'s own treesitter Lua: every node, sexpr, queries with predicates, descendants — what nvim prints', function ()
    if not ready() then skip 'no lua parser / node' end
    if not L.bridge() then skip 'no tree-sitter source to build the bridge from' end
    local src = [==[
local SAMPLES = {
  { 'lua', 'local x = f(1, "s") -- c\nfunction M.g(a, ...) if a then return a end end\nlocal t = { k = 1, [2] = 3 }\n' },
  { 'javascript', 'const a = (x) => x + 1;\nclass K extends B { m() { return this.v?.w; } }\n' },
  { 'c', 'int main(int argc, char **argv) { return argc > 1 ? 0 : 1; }\n' },
  { 'lua', 'local broken = (\nx = ' },
}
local function walk(n, depth, out)
  local sr, sc, sb, er, ec, eb = n:range(true)
  out[#out + 1] = ('%s%s [%d,%d,%d]-[%d,%d,%d] n=%s m=%s e=%s err=%s kids=%d named=%d'):format(('  '):rep(depth), n:type(), sr, sc, sb, er, ec, eb,
    tostring(n:named()), tostring(n:missing()), tostring(n:extra()), tostring(n:has_error()), n:child_count(), n:named_child_count())
  for c, field in n:iter_children() do
    if field then out[#out + 1] = ('%s field %s'):format(('  '):rep(depth + 1), field) end
    walk(c, depth + 1, out)
  end
end
for _, s in ipairs(SAMPLES) do
  local lang, text = s[1], s[2]
  local root = vim.treesitter.get_string_parser(text, lang):parse()[1]:root()
  local out = {}
  walk(root, 0, out)
  print(lang, #out)
  print(table.concat(out, '\n'))
  print('sexpr', root:sexpr())
  print('parent', root:named_child(0) and root:named_child(0):parent():type(), root:parent(), tostring(root))
  local d = root:named_descendant_for_range(0, 7, 0, 8)
  print('desc', d and d:type(), d and vim.treesitter.get_node_text(d, text), root:descendant_for_range(0, 0, 0, 1):type())
  local li = vim.treesitter.language.inspect(lang)
  local ns = 0; for _ in pairs(li.symbols) do ns = ns + 1 end
  print('lang', li.abi_version, #li.fields, ns)
end
local text = 'local a = foo(1)\nlocal b = bar(2)\nlocal foo = 3\n'
local root = vim.treesitter.get_string_parser(text, 'lua'):parse()[1]:root()
local q = vim.treesitter.query.parse('lua', [[
  (function_call name: (identifier) @fn (#eq? @fn "foo"))
  (function_call name: (identifier) @any)
  ((identifier) @big (#lua-match? @big "^%l%l%l$"))
  ((identifier) @lm (#lua-match? @lm "^b"))
  ((identifier) @one (#any-of? @one "a" "b"))
]])
for id, node in q:iter_captures(root, text) do
  print('cap', q.captures[id], node:type(), vim.treesitter.get_node_text(node, text), node:range())
end
for pattern, match in q:iter_matches(root, text, 0, -1) do
  local names = {}
  for id, nodes in pairs(match) do names[#names + 1] = q.captures[id] .. '=' .. vim.treesitter.get_node_text(nodes[1], text) end
  table.sort(names)
  print('match', pattern, table.concat(names, ' '))
end
print(pcall(vim.treesitter.query.parse, 'lua', '(nope_kind) @x'))
-- the cursor's MATCH LIMIT is part of the semantics: a small limit changes nvim's own answer (0 / 2 / 42 here)
local ltext = 'f(a, b, c, d, e, g, h)\n'
local lroot = vim.treesitter.get_string_parser(ltext, 'lua'):parse()[1]:root()
for _, qs in ipairs { '(arguments (identifier) @x (identifier) @y)', '(arguments (_) @x (_) @y (_) @z)' } do
  local lq = vim.treesitter.query.parse('lua', qs)
  local counts = {}
  for _, limit in ipairs { 1, 2, 256 } do local n = 0; for _ in lq:iter_captures(lroot, ltext, 0, -1, { match_limit = limit }) do n = n + 1 end; counts[#counts + 1] = n end
  print('limit', qs, table.concat(counts, ' '))
end
]==]
    local want = lua_out(src)
    local got, _, refusals = js_out(src, true)
    eq(0, #refusals, vim.inspect(refusals))
    ok(want ~= '' and not want:find('^ERROR'), 'the premise: the real nvim side ran: ' .. want:sub(1, 300))
    -- ⚠ the query-error line carries the calling Lua file's position (`…/query.lua:374: `) — a known pack gap; compare after it
    local function strip(s) return (s:gsub('[^\n\t]*query%.lua:%d+: ', '')) end
    if strip(want) ~= strip(got) then
        local wf, gf = vim.fn.tempname(), vim.fn.tempname()
        vim.fn.writefile(vim.split(strip(want), '\n'), wf); vim.fn.writefile(vim.split(strip(got), '\n'), gf)
        error('vim.treesitter disagrees with nvim:\n' .. vim.system({ 'diff', wf, gf }, { text = true }):wait().stdout:sub(1, 3000), 0)
    end
end)

test('luajs: a construct with no faithful form is REFUSED by name, the module still parses, and a pack gap BREAKS loudly at run time', function ()
    if not ready() then skip 'no lua parser / node' end
    -- (every Lua goto now has a structured form; an ATTRIBUTE is the construct still refused)
    local out, js, refusals = js_out('print(1)\nlocal x <const> = 2\nprint(x)\n')
    ok(#refusals >= 1 and refusals[1].kind == 'attribute', vim.inspect(refusals))
    ok(js:find('$abort("attribute', 1, true), 'the refusal sits at its place')
    ok(out:find('LuaBreak', 1, true) or out:find('no faithful JS form', 1, true), 'running it reaches the refusal loudly: ' .. out)
    local out2 = js_out("print(('%q'):format('x'))\n")
    ok(out2:find('no faithful JS form: string.format %q', 1, true), 'a pack gap is a named break, never an approximation: ' .. out2)
    eq('1\t2\n', (js_out('print(1, 2)\n')), 'and the translatable side runs')
end)

test('luajs: the LOCAL half is DECLARED RULES — every rule compiles and FIRES on this spec\'s differential sources; a rule that drops a hole does not compile; a source the reader refuses refuses by name', function ()
    if not ready() then skip 'no lua parser / node' end
    local Rules = require 'cartograph.luajs.rules'
    for k in pairs(Rules.hits) do Rules.hits[k] = nil end
    for _, src in pairs(CASES) do L.emit(src, 'case.lua') end
    local dead = {}
    for i, c in ipairs(Rules.all()) do if (Rules.hits[i] or 0) == 0 then dead[#dead + 1] = c.lua end end
    eq({}, dead, 'a rule no differential source reaches has no witness')
    local okc, why = pcall(Rules.compile, { lua = 'a + b', js = '$add(a)' })
    ok(not okc and tostring(why):find('hole b is dropped', 1, true), tostring(why))
    local _, refusals = L.emit('local x = \n', 'bad.lua')
    ok(#refusals == 1 and refusals[1].kind == 'read', vim.inspect(refusals))
end)

test('luajs: each table constructor takes its SHAPE\'s representation — ARRAY, RECORD, or MAP for a dictionary', function ()
    if not ready() then skip 'no lua parser / node' end
    local _, js = js_out([[
local a = {}
a[#a + 1] = 1
local r = { name = 'x' }
print(r.name)
local d = {}
local k = 'q'
d[k] = 1
print(a[1], d.q)]])
    ok(js:find('let a = $arr()', 1, true), js)
    ok(js:find('let r = $rec("name", "x")', 1, true), js)
    ok(js:find('let d = $map()', 1, true), js)
end)
