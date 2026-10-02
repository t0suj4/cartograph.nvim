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
    -- (the REFERENCE is LuaJIT's INTERPRETER, the manual's semantics: its JIT reads a -0.0 for-step as ascending once a
    -- trace for the loop was recorded with step 0 — `for i = 1, 0, -0.0` then stops after 1 or 2 iterations instead of
    -- running, and whether it does depended on which specs ran before in the same worker: CART-1322)
    jit.off(f, true)
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
    L.install_pack(dir)
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
    -- a numeric for's values: all three EVALUATED, then checked in LuaJIT's order (a numeric string is a number); a
    -- comparison error names two types, or "two X values" when they match (both found by CART-1206's generator)
    fornum = [[
local seen = {}
local function m(f) seen = {}; local ok, e = pcall(f); print(table.concat(seen, ' '), ok, (tostring(e):gsub('^[^:]*:%d+: ', ''))) end
local function p(k) seen[#seen + 1] = type(k); return k end
local got = {}
for i = "0x2", "3" do got[#got + 1] = i end
for i = 1, 3, " 2 " do got[#got + 1] = i end
print(table.concat(got, ' '), type(got[1]))
m(function () for i = 1, nil do end end)
m(function () for i = p(nil), p(2) do end end)
m(function () for i = 1, 2, false do end end)
m(function () for i = p('a'), p('b'), p({}) do end end)
m(function () return 1 < true end)
m(function () return true < false end)
m(function () return {} <= {} end)
m(function () return 'a' < 1 end)
local function run(a, b, s) local got, n = {}, 0; for i = a, b, s do n = n + 1; got[#got + 1] = i; if n > 3 then break end end return table.concat(got, ',') end
for _ = 1, 100 do run(1, 2, 0) end -- (a trace recorded with step 0: LuaJIT's JIT then misreads a -0.0 step — CART-1322)
print(run(1, 2, 0), run(2, 1, 0), run(3, 1, -1), run(1, 2, 0.5), run(1, 1, 0), run(1, 0, -0.0), run(0, 1, -0.0), run(3, 1, -0.5))]],
    -- x ^ y and math.pow are the C LIBRARY's pow, bit for bit (CART-1211): vectors where V8's Math.pow is off by an ulp
    -- (compared EXACTLY against 17-digit literals — print's %.14g would hide it), and the IEEE special cases
    pow = [==[
local V = {
  { 3.7158770758111563, -12.817241509175016, 4.9361249678675062e-8 },
  { 2.0150589074958414, 4.5291983309496189, 23.887987016839414 },
  { 0.92711983685862254, -984.85405458428068, 2.3247073967810972e+32 },
  { 3.1158283960569411, 7.5789225832107547, 5504.9779031645839 },
  { 2.1763869008465719, -9.1227362619445884, 0.00082970289075380446 },
  { 3.3971779689567354, -19.495381775346843, 4.4222775230809010e-11 },
  { 1.6085746213026608, 8.4291556908315428, 54.969922054670768 },
  { -5.4230256616543002, 20.000000000000000, 483986435788476.44 },
  { 2.4852395651967223, 14.083091962637816, 369834.60959044396 },
  { 0.93159995840221121, -2283.8200580798084, 1.8809418757691356e+70 },
  { 3.4121533751760613, -8.0607634754391313, 0.000050510652466665842 },
  { 1.0706751140874640, 6412.7113921151395, 1.5357641436901719e+190 },
  { 3.2278340950557145, -14.129319664554782, 6.4480872971426888e-8 },
  { 2.5213102375230525, 6.1492454179288067, 294.91618444168665 },
  { -1.1244135363634689, 34.000000000000000, 53.887274559877675 },
  { 1.0335513431076342, 9749.0411321849824, 5.2942004196974853e+139 },
  { 2.4868240460162112, 8.6941529895353469, 2752.9521599593786 },
  { -7.4539645123837595, 26.000000000000000, 4.8091723388265955e+22 },
  { 0.028610320208341644, -14.621241132218463, 3.6944816616612521e+22 },
  { 0.96676384046807462, -6921.9489955696890, 4.0874685480939058e+101 },
  { -7.8878999382836410, 23.000000000000000, -4.2668957578930979e+20 },
  { 3.2486885119600752, 7.9396178003162632, 11554.908809733510 },
  { 3.6027360653561269, -17.412918831557040, 2.0295716124318213e-10 },
  { 1.0997654988342476, -5389.6760350228678, 2.5461766740790623e-223 },
}
local bad = 0
for i, v in ipairs(V) do
  if v[1] ^ v[2] ~= v[3] or math.pow(v[1], v[2]) ~= v[3] then bad = bad + 1; print('differs', i) end
end
print(#V, 'vectors', bad, 'differ')
local inf, nan = 1 / 0, 0 / 0
local E = { 0 ^ -1, (-0.0) ^ -1, (-0.0) ^ -2, (-8) ^ (1 / 3), (-2) ^ 3, (-2) ^ 2, inf ^ 0, nan ^ 0, 1 ^ nan, 1 ^ inf, (-1) ^ inf,
  0.5 ^ inf, 2 ^ inf, 2 ^ -inf, 2 ^ 1024, 2 ^ -1075, 2 ^ -1074, 0.5 ^ 0.5, (-inf) ^ 3, (-inf) ^ 2, (-inf) ^ -3, 10 ^ 308, 10 ^ 309,
  1e-310 ^ 0.5, 2.5 ^ 2.5 == 9.8821176880261863 }
local out = {}
for i = 1, #E do out[i] = tostring(E[i]) end
print(table.concat(out, ' '))]==],
    -- a number prints as C's %.14g: exponential when the ROUNDED exponent is < -4 or >= 14 (integers of 15+ digits
    -- included), an exact tie to EVEN, -0 as "-0" (CART-1206's generator found the first two)
    numstr = [[
local out = {}
for _, v in ipairs { 1e14, 99999999999999, 123456789012345, 2^53, 1e15 - 1, 0.0001, 0.00001, 1.5e-5, -0.0, 1 / 3,
    1e100, 123.456, 1e-310, 2^63, -1e14, 2.5 / 2.5 ^ 16, 10 ^ 16 / 16, 0.5, -2.5e-7, 1e15 + 0.5 } do
  out[#out + 1] = tostring(v)
end
print(table.concat(out, ' '))
print(1e14 .. '', -0.0 .. '|', 123456789012345 .. '')
print(tonumber('0x102.5'), -('0x10' .. 2.5), tonumber('0x.8'), tonumber('0x1p4'), tonumber('0xA.8P-1'), tonumber('+0x10'),
  tonumber(' 0x10 '), tonumber('0x'), tonumber('0x.'), tonumber('0x1p'))]],
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
local function va(...) return ... end
local function vb(...) return ...; end
print(select('#', va('x', nil)), va(1, 2), select('#', vb()), vb(3, nil, 4))
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
    L.install_pack(out)
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

test('luajs pack: pow is the HOST C LIBRARY\'s bit for bit, and $fma is C\'s fma — against libm itself (a C oracle compiled here)', function ()
    if vim.fn.executable('gcc') ~= 1 or vim.fn.executable('node') ~= 1 then skip 'no gcc / node' end
    -- the TARGET is glibc's FMA build (its ifunc picks it on an FMA CPU); without FMA the host runs the non-FMA pow,
    -- which differs on ~0.04% of inputs — a different function, so the comparison would be meaningless
    local cpu = io.open('/proc/cpuinfo')
    local flags = cpu and cpu:read('a') or ''
    if cpu then cpu:close() end
    if not flags:find('%sfma%s') then skip 'the host CPU has no FMA: its glibc pow is the non-FMA build, not the one transliterated' end
    local dir = vim.fn.tempname()
    L.install_pack(dir)
    local C = [[
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static uint64_t s = 0x2545F4914F6CDD1Dull;
static uint64_t rnd(void) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
static double dbl(uint64_t u) { double d; memcpy(&d, &u, 8); return d; }
static double unif(double a, double b) { return a + (b - a) * ((rnd() >> 11) * 0x1p-53); }
int main(void) {
  FILE *p = fopen("pow.bin", "wb"), *f = fopen("fma.bin", "wb");
  for (long i = 0; i < 100000; i++) {
    double x, y;
    switch (i % 4) { case 0: x = dbl(rnd()); y = dbl(rnd()); break; case 1: x = unif(0, 4); y = unif(-20, 20); break;
      case 2: x = unif(0.9, 1.1); y = unif(-1e4, 1e4); break; default: x = -unif(0, 8); y = (double)(long)unif(-40, 40); }
    double r[3] = { x, y, pow(x, y) }; fwrite(r, 8, 3, p);
    double a = unif(-4, 4), b = unif(-4, 4), c = (i % 2) ? -a * b : dbl(rnd());
    /* every 10th triple an EXACT TIE: odd a times 2^52 + odd b is 54 bits ending in 1, and a small c keeps it one */
    if (i % 10 == 0) { a = 3 + 2 * (i % 97); b = 0x1p52 + (double)(2 * (i % 1013) + 1); c = 2 * (double)(i % 7) + 2; }
    double q[4] = { a, b, c, fma(a, b, c) }; fwrite(q, 8, 4, f);
  }
  fclose(p); fclose(f); return 0;
}]]
    local fd = assert(io.open(dir .. '/gen.c', 'w')); fd:write(C); fd:close()
    local cc = vim.system({ 'gcc', '-O2', '-fno-builtin', 'gen.c', '-lm', '-o', 'gen' }, { cwd = dir }):wait()
    eq(0, cc.code, cc.stderr)
    eq(0, vim.system({ './gen' }, { cwd = dir }):wait().code)
    local JS = [[
const { pow } = require('./$libmpow.js'); const { $fma } = require('./$fpu.js');
const F = new Float64Array(2), U = new BigUint64Array(F.buffer);
const same = (a, b) => { F[0] = a; F[1] = b; return (Number.isNaN(a) && Number.isNaN(b)) || U[0] === U[1]; };
const rd = n => { const b = require('fs').readFileSync(n); return new Float64Array(b.buffer, b.byteOffset, b.length / 8); };
let p = 0, pv8 = 0, f = 0, fnaive = 0; const P = rd('pow.bin'), Q = rd('fma.bin');
for (let i = 0; i < P.length; i += 3) { if (!same(pow(P[i], P[i + 1]), P[i + 2])) p++; if (!same(Math.pow(P[i], P[i + 1]), P[i + 2])) pv8++; }
for (let i = 0; i < Q.length; i += 4) { if (!same($fma(Q[i], Q[i + 1], Q[i + 2]), Q[i + 3])) f++; if (!same(Q[i] * Q[i + 1] + Q[i + 2], Q[i + 3])) fnaive++; }
console.log(JSON.stringify({ n: P.length / 3, pow: p, v8: pv8, fma: f, naive: fnaive }));]]
    fd = assert(io.open(dir .. '/check.js', 'w')); fd:write(JS); fd:close()
    local r = vim.system({ 'node', 'check.js' }, { cwd = dir, text = true }):wait(300000)
    eq(0, r.code, r.stderr)
    local res = vim.json.decode(r.stdout)
    eq(0, res.pow, 'libm pow, bit for bit (lua/cartograph/luajs/libmpow.js is glibc 2.39 FMA-build pow as gcc 13.3 fuses it — a glibc or compiler change is regenerated with tools/cjs.lua libmpow, CART-1211): ' .. r.stdout)
    eq(0, res.fma, 'C fma, bit for bit: ' .. r.stdout)
    -- the POSITIVE CONTROLS: the sample distinguishes (V8's pow and a naive a*b+c both differ from the library somewhere)
    ok(res.v8 > 0 and res.naive > 0, 'the premise: the inputs separate a wrong implementation from a right one: ' .. r.stdout)
end)

test('luajs pack: $ldexp rounds ONCE and $clz64 is __builtin_clzll — against the C library and gcc (a C oracle compiled here)', function ()
    if vim.fn.executable('gcc') ~= 1 or vim.fn.executable('node') ~= 1 then skip 'no gcc / node' end
    local dir = vim.fn.tempname()
    L.install_pack(dir)
    local C = [[
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static uint64_t s = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
static double dbl(uint64_t u) { double d; memcpy(&d, &u, 8); return d; }
int main(void) {
  FILE *l = fopen("ldexp.bin", "wb"), *z = fopen("clz.bin", "wb");
  for (long i = 0; i < 100000; i++) {
    /* half the exponents land the result SUBNORMAL (below 2^-1022), where scaling in steps rounds twice */
    double x = (i % 3) ? 1 + (rnd() >> 12) * 0x1p-52 : dbl(rnd());
    int n = (i % 2) ? -1022 - (int)(rnd() % 60) : (int)(rnd() % 2200) - 1100;
    double r[3] = { x, (double)n, ldexp(x, n) }; fwrite(r, 8, 3, l);
    uint64_t u = rnd() >> (rnd() % 64); if (!u) u = 1;
    uint64_t q[2] = { u, (uint64_t)__builtin_clzll(u) }; fwrite(q, 8, 2, z);
  }
  fclose(l); fclose(z); return 0;
}]]
    local fd = assert(io.open(dir .. '/gen.c', 'w')); fd:write(C); fd:close()
    local cc = vim.system({ 'gcc', '-O2', '-fno-builtin', 'gen.c', '-lm', '-o', 'gen' }, { cwd = dir }):wait()
    eq(0, cc.code, cc.stderr)
    eq(0, vim.system({ './gen' }, { cwd = dir }):wait().code)
    local JS = [[
const { $ldexp, $clz64 } = require('./$fpu.js');
const F = new Float64Array(2), U = new BigUint64Array(F.buffer);
const same = (a, b) => { F[0] = a; F[1] = b; return (Number.isNaN(a) && Number.isNaN(b)) || U[0] === U[1]; };
const b = n => require('fs').readFileSync(n);
const Lb = b('ldexp.bin'), Zb = b('clz.bin');
const Ld = new Float64Array(Lb.buffer, Lb.byteOffset, Lb.length / 8), Z = new BigUint64Array(Zb.buffer, Zb.byteOffset, Zb.length / 8);
let l = 0, steps = 0, z = 0;
for (let i = 0; i < Ld.length; i += 3) {
  if (!same($ldexp(Ld[i], Ld[i + 1]), Ld[i + 2])) l++;
  if (!same(Ld[i] * 2 ** (Ld[i + 1] + 600) * 2 ** -600, Ld[i + 2])) steps++;
}
for (let i = 0; i < Z.length; i += 2) if (BigInt($clz64(Z[i])) !== Z[i + 1]) z++;
console.log(JSON.stringify({ n: Ld.length / 3, ldexp: l, steps, clz: z }));]]
    fd = assert(io.open(dir .. '/check.js', 'w')); fd:write(JS); fd:close()
    local r = vim.system({ 'node', 'check.js' }, { cwd = dir, text = true }):wait(300000)
    eq(0, r.code, r.stderr)
    local res = vim.json.decode(r.stdout)
    eq(0, res.ldexp, 'C ldexp, bit for bit: ' .. r.stdout)
    eq(0, res.clz, '__builtin_clzll: ' .. r.stdout)
    -- the POSITIVE CONTROL: scaling in two steps (two roundings) differs from the library somewhere in the sample
    ok(res.steps > 0, 'the premise: the inputs separate a twice-rounding ldexp from the library\'s: ' .. r.stdout)
end)

test('luajs pack: tonumber IS LuaJIT\'s lj_strscan (transliterated, lua/cartograph/luajs/strscan.js) — 20,000 generated strings, every result bit-identical to the oracle\'s; a naive Number() differs', function ()
    if vim.fn.executable('node') ~= 1 then skip 'no node' end
    local D = require 'cartograph.luajs.libdiff'
    local dir = vim.fn.tempname()
    L.install_pack(dir)
    local res = assert(D.run({ fn = 'tonumber', n = 20000, dir = dir }))
    eq(20000, res.n)
    eq(0, res.differ, 'the pack against the oracle: ' .. vim.inspect(res.examples))
    -- the POSITIVE CONTROL: the family separates a plausible wrong tonumber from LuaJIT's
    local naive = assert(D.run({ fn = 'tonumber', n = 20000, dir = dir, js_fn = '(s => { const v = Number(s); return Number.isNaN(v) ? undefined : v; })' }))
    ok(naive.differ > 0, 'the premise: a naive tonumber differs somewhere (' .. naive.differ .. ')')
end)

test('luajs pack: tostring of a number IS LuaJIT\'s lj_strfmt_num (transliterated, lua/cartograph/luajs/strfmt.js) — 20,000 generated doubles (exact ties, the %e/%f switch points, subnormals, powers of ten +- ulps), every string the oracle\'s; toPrecision(14) differs', function ()
    if vim.fn.executable('node') ~= 1 then skip 'no node' end
    local D = require 'cartograph.luajs.libdiff'
    local dir = vim.fn.tempname()
    L.install_pack(dir)
    local res = assert(D.run({ fn = 'tostring', n = 20000, dir = dir }))
    eq(20000, res.n)
    eq(0, res.differ, 'the pack against the oracle: ' .. vim.inspect(res.examples))
    local naive = assert(D.run({ fn = 'tostring', n = 20000, dir = dir, js_fn = '(x => x.toPrecision(14))' }))
    ok(naive.differ > 0, 'the premise: a naive %.14g differs somewhere (' .. naive.differ .. ')')
end)

test('luajs: each table constructor takes its SHAPEE\'s representation — ARRAY, RECORD, or MAP for a dictionary', function ()
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
