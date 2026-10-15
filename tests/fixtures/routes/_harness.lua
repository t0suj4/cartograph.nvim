-- the RUNTIME side of the route suite (CART-1711): run one fixture and report which of the prologue's methods ran.
-- The RUNTIME COPY is instrumented — `function A.m(self) return "A" end` (line 3) and B.m (line 4) also set a flag, on
-- the same lines; the analysis reads the file untouched. (A debug hook misses code inside a PUC coroutine — hooks are
-- per thread — and inside a 5.4 finalizer — hooks are off there.) Host functions a fixture's environment provides
-- (WoW's hooksecurefunc) are stubbed here, never in the fixture: the analysis must not see their code.
--   <lua5.1|lua5.4|luajit> _harness.lua <fixture>     nvim --headless -u NONE -l _harness.lua <fixture>
local path = assert(arg[1], 'usage: _harness.lua <fixture.lua>')
RAN__ = {}
function hooksecurefunc(t, name, h)
    if type(t) == 'string' then t, name, h = _G, t, name end
    local orig = t[name]
    t[name] = function (...) local r = { orig(...) }; h(...); return (unpack or table.unpack)(r) end
end
local fd = assert(io.open(path)); local src = fd:read('*a'); fd:close()
local n
src, n = src:gsub('function ([AB])%.m%(self%) return', function (c) return 'function ' .. c .. '.m(self) RAN__.' .. c .. ' = true; return' end)
assert(n == 2, 'the prologue: A.m and B.m on lines 3 and 4')
local f, err = (loadstring or load)(src, '@' .. path)
local ok, e = false, err
if f then ok, e = pcall(f) end
f = nil
collectgarbage(); collectgarbage() -- (finalizers)
io.stdout:write(('RAN %s%s%s\n'):format(RAN__.A and 'A' or '', RAN__.B and 'B' or '', ok and '' or (' ERR ' .. tostring(e):gsub('\n', ' '))))
io.stdout:flush()
