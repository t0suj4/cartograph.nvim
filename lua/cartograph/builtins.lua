-- BUILTINS — per-language genuine global builtins (functions + module tables), and the
-- SHADOW-AWARE recognition analyses need before trusting a builtin's semantics.
--
-- Any analysis that leans on a builtin — narrow's `type(x)` type-test, localize's stdlib
-- module roots (`math.floor`), a future `pairs(x)` ⟹ table — must confirm the name is
-- the REAL builtin and not a local/param that SHADOWS it (`local type = …`,
-- `local math = require 'm'`). A shadow makes the builtin's guarantee (type() returns the
-- runtime type; `math` is an always-present non-nil table) false. `genuine(lang, name,
-- bound)` = the name is a known builtin AND not bound in the given scope.
--
-- The set is the target-runtime's always-present globals (Lua stdlib + nvim's `vim`),
-- NOT arbitrary library imports — resolving a required module to its exports is the
-- linker's job ([[cartograph-linker]]); this is the fixed builtin floor.

local M = {}

M.lua = {
    -- global functions
    assert = true, collectgarbage = true, error = true, getmetatable = true,
    ipairs = true, next = true, pairs = true, pcall = true, print = true,
    rawequal = true, rawget = true, rawlen = true, rawset = true, require = true,
    select = true, setmetatable = true, tonumber = true, tostring = true, type = true,
    unpack = true, xpcall = true, load = true, loadstring = true, dofile = true,
    -- always-present module tables (the localize roots)
    math = true, string = true, table = true, os = true, io = true,
    coroutine = true, debug = true, utf8 = true, package = true,
    -- the nvim runtime table (cartograph's target is nvim lua; always present there)
    vim = true,
}

--- is `name` a GENUINE builtin in `lang` here — a known builtin NOT shadowed by a
--- local/param in `bound` (a name→true set of the scope's bound names)?
--- @return boolean
function M.genuine(lang, name, bound)
    local set = M[lang]
    return (set and set[name] and not (bound and bound[name])) and true or false
end

return M
