-- Unit tests for the builtins registry ([[cartograph.builtins]]): genuine() = a known
-- builtin NOT shadowed by a local/param in scope. The shadow-soundness floor that
-- narrow's type() and localize's stdlib roots consult.

local builtins = require 'cartograph.builtins'

test('builtins: a known global is genuine when unshadowed', function ()
    ok(builtins.genuine('lua', 'type', {}), 'type is a builtin')
    ok(builtins.genuine('lua', 'math', nil), 'math is a builtin (nil bound ok)')
    ok(builtins.genuine('lua', 'setmetatable', {}), 'setmetatable is a builtin')
    ok(builtins.genuine('lua', 'vim', {}), 'vim (nvim runtime) counts')
end)

test('builtins: a shadowed name is NOT genuine', function ()
    ok(not builtins.genuine('lua', 'type', { type = true }), 'type shadowed by a local/param')
    ok(not builtins.genuine('lua', 'math', { math = true }), 'math shadowed')
end)

test('builtins: an unknown name / unknown language is not genuine', function ()
    ok(not builtins.genuine('lua', 'myglobal', {}), 'not a builtin')
    ok(not builtins.genuine('rust', 'type', {}), 'unknown language')
end)
