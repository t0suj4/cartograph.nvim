-- CART-2042: flowtype.lua's builder sat at Lua's 200-local limit. PUC 5.4's generic `for` holds one more hidden local
-- than LuaJIT's (the to-be-closed slot), so the file did not compile under 5.4 at all ("too many local variables (limit
-- is 200) in function at line 363 near 'in'"), and under LuaJIT it was 0-1 locals from failing. Eight rarely used
-- builder locals moved to G7 (one was unused); measured headroom 5 under 5.4, 8 under LuaJIT. The test keeps a MARGIN:
-- the builder must still compile with 2 more locals in scope, under both.

local function source() local f = assert(io.open('lua/cartograph/flowtype.lua')); local s = f:read('a'); f:close(); return s end
local function with_extra(src, k)
    local names = {}
    for i = 1, k do names[i] = '_margin' .. i end
    local out, n = src:gsub('(local function build%(store, opts%)\n)', '%1local ' .. table.concat(names, ', ') .. '\n', 1)
    assert(n == 1, 'the builder\'s header moved: update this test')
    return out
end

test('flowtype: the builder compiles under LuaJIT with a margin of 2 locals (CART-2042)', function ()
    local f, err = loadstring(with_extra(source(), 2), '=flowtype')
    ok(f, tostring(err))
end)

test('flowtype: the file compiles under PUC Lua 5.4, and with a margin of 2 locals (CART-2042)', function ()
    if vim.fn.executable('luac5.4') ~= 1 then skip 'no luac5.4' end
    local src = source()
    for _, k in ipairs { 0, 2 } do
        local text = k == 0 and src or with_extra(src, k)
        local r = vim.system({ 'luac5.4', '-p', '-' }, { stdin = text, text = true }):wait()
        eq(0, r.code, ('with %d extra locals: %s'):format(k, tostring(r.stderr)))
    end
end)
