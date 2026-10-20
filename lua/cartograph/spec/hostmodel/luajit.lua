-- The LuaJIT HOST MODEL (CART-1785): what C builtins DO, said as plain Lua — read by flowtype as code (a host call
-- `owner.name(…)` / `name(…)` whose key is here calls the body instead of the signature's return types). Each body is a
-- SUPPLIED premise about a C function: the dump names every one a call ran (`contracts.host_models`, clause `host-model`).
-- Language intrinsics (rawget / rawset / setmetatable / getmetatable / getfenv / setfenv / pcall / next / select /
-- unpack …) are the solve's own and take no model. Keys are the profile's signature keys (`owner#name`).

-- (THE registry: one table — every debug.getregistry() returns the same one, never a new table)
local REG = {}

return {
    -- table.remove(list [, pos]): removes an element of list and RETURNS it
    ['table#remove'] = function (list, pos) return list[pos or #list] end,
    -- table.move(a1, f, e, t [, a2]): copies a1[f..e] into a2 (a1 when absent) from t on, and RETURNS that target
    ['table#move'] = function (a1, f, e, t, a2)
        local d = a2 or a1
        for i = f, e do d[t + i - f] = a1[i] end
        return d
    end,
    ['debug#getregistry'] = function () return REG end,
    -- (debug's variants ignore __metatable / the caller's level: the intrinsics' answers hold what they return)
    ['debug#getmetatable'] = function (o) return getmetatable(o) end,
    ---@diagnostic disable-next-line: deprecated
    ['debug#getfenv'] = function (o) return getfenv(o) end,
}
