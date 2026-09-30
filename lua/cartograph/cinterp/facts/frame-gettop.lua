-- FRAME from the Lua API's own COUNT: lua_gettop's `return top - base` names the thread type (its parameter's) and the
-- frame's fields, top the minuend; the ORIGIN is the field the frame's REBASE subtracts (cartograph.luajs.cpath.frame)
return {
    fact = 'frame',
    needs = { 'units' },
    summary = 'thread type, top / base, origin — from lua_gettop and the stack rebase',
    derive = function (_, got) return require('cartograph.luajs.cpath').frame(got.units) end,
}
