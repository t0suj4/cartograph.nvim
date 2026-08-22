-- CALL POSITIONS: the per-language declaration that replaced an inline or-chain
-- (CART-0499). The old rule was four grammar node-type names plus `nt == 'list'`,
-- shared by every language, and the defects it produced are exactly what these
-- tests fence: a language missing from the list marked NO callees, a language IN
-- the list with a different field name marked none either, and a node-type name
-- that means different things in two grammars leaked across them.

local ts = require 'cartograph.providers.treesitter'
local contract = require 'cartograph.spec.contract'

test('callpos: every treesitter spec that has calls declares its call positions', function ()
    local missing = {}
    for lang, sp in pairs(ts.spec) do
        -- `calls` is the CORE slot saying this language has a call form at all;
        -- if it does, the callee position is not optional — an absent table means
        -- silently zero callee marks, which is the whole defect.
        if sp.calls and not sp.call_positions then missing[#missing + 1] = lang end
    end
    eq({}, missing)
end)

test('callpos: a declared entry is a FIELD NAME or a named-child INDEX, nothing else', function ()
    local bad = {}
    for lang, sp in pairs(ts.spec) do
        for nt, v in pairs(sp.call_positions or {}) do
            local t = type(v)
            if not (t == 'string' or (t == 'number' and v >= 0 and v == math.floor(v))) then
                bad[#bad + 1] = ('%s.%s = %s'):format(lang, nt, tostring(v))
            end
        end
    end
    eq({}, bad)
end)

test('callpos: the slot is registered in the closed contract', function ()
    ok(contract.SLOTS['call_positions'], 'call_positions has a group')
end)

-- ★ THE BASH TRAP, and the reason every entry was probed against the grammar
-- instead of transcribed from the ticket: `command` HAS a `name` field, so
-- `command = 'name'` looks obviously right — but that field holds a
-- `command_name` NODE and the identifier is one level further down. The obvious
-- entry would have matched nothing, silently, on a corpus whose reg edges nobody
-- had pinned.
test('callpos: bash names command_name, NOT command', function ()
    local cp = ts.spec.bash.call_positions
    eq(0, cp.command_name)
    eq(nil, cp.command)
end)

-- ★ THE CROSS-LANGUAGE LEAK. `nt == 'list'` meant "a sexp head is the callee",
-- and it applied to EVERY language because it was one global comparison. Haskell
-- spells a LIST LITERAL `list` too, so the first element of every haskell list
-- was marked a callee and its reference dropped — `chars = [backspace,tab,…]`
-- lost exactly `backspace`. Two grammars, one node-type name, opposite meanings.
test('callpos: `list` is a scheme call position and NOT a haskell one', function ()
    eq(0, ts.spec.scheme.call_positions.list)
    eq(nil, ts.spec.haskell.call_positions.list)
    -- and haskell's own form, which the old global list DID contain while
    -- testing the wrong relation: `apply`'s callee is an unnamed child 0, so the
    -- field-only test never matched and haskell marked no callees at all
    eq(0, ts.spec.haskell.call_positions.apply)
end)

-- ★ THE OTHER HALF OF THE SAME MISTAKE: a node type IN the old list whose
-- grammar names the position differently. ruby's `call` was matched by
-- `nt == 'call'` and then tested against the `function` and `name` fields; ruby
-- calls it `method`.
test('callpos: ruby names the method field, python names the function field', function ()
    eq('method', ts.spec.ruby.call_positions.call)
    eq('function', ts.spec.python.call_positions.call)
end)

-- the six languages the old chain missed, as a roster rather than prose
test('callpos: the languages the inline chain could not see now declare a position', function ()
    local want = {
        php = { 'function_call_expression', 'member_call_expression',
            'scoped_call_expression' },
        java = { 'method_invocation' },
        bash = { 'command_name' },
        rust = { 'call_expression', 'macro_invocation' },
        ruby = { 'call' },
        haskell = { 'apply' },
    }
    for lang, nts in pairs(want) do
        local cp = ts.spec[lang].call_positions or {}
        for _, nt in ipairs(nts) do
            ok(cp[nt] ~= nil, ('%s: %s undeclared'):format(lang, nt))
        end
    end
end)
