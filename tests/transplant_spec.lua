-- cartograph.transplant — the seam that absorbs `A.transplant` (CART-0912).
--
-- ⚠ THE OPERATOR ITSELF IS THE DONOR'S AND IS TESTED THERE (220 tests in the
-- prototype's own spec). These tests cover the SEAM: that the vendored operator is
-- reachable from a shipped consumer, that source goes in and source comes out, and
-- that a refusal arrives by name rather than as a silent no-change.
local tp = require 'cartograph.transplant'

test('transplant: the edit shown once is derived for a different target', function ()
    local ready, why = tp.available('lua')
    if not ready then return skip('algebra/reader unavailable: ' .. tostring(why)) end
    local out, info = tp.apply(
        'local function f(x) return wrap(x) end',
        'local function f(x) return wrap(x, DEFAULT) end',
        'local function g(y) return wrap(y) end')
    ok(out ~= nil, 'the transplant produced source: ' .. tostring(info))
    eq('local function g(y) return wrap(y, DEFAULT) end', out,
        'the exemplar edit lands on the target under ITS OWN names')
    ok(info and info.kind ~= nil, 'and the operator accounts for what it did: '
        .. tostring(info and info.kind) .. '/' .. tostring(info and info.route))
end)

test('transplant: source in, source out — the reader law is what makes it usable', function ()
    local ready = tp.available('lua')
    if not ready then return skip('algebra/reader unavailable') end
    -- ⚠ A DERIVED TERM MUST PRINT AS REAL SOURCE, not a pretty-printed
    -- approximation: `algebraread`'s law is byte-for-byte, so the target's own
    -- spelling survives. Both sides are one line here because the operator's
    -- context is TOTAL structural agreement — see the degenerate test below.
    local out = tp.apply('local function f(x) return  wrap(x) end',
                         'local function f(x) return  wrap(x, DEFAULT) end',
                         'local function g(y) return  wrap(y) end')
    ok(out ~= nil, 'a derivation happened')
    ok(out and out:find('return  wrap', 1, true) ~= nil,
        "the target's own double space survives — the print is not a reformat: "
        .. tostring(out))
end)

test('transplant: a target that does not AGREE structurally is refused, not overwritten', function ()
    local ready = tp.available('lua')
    if not ready then return skip('algebra/reader unavailable') end
    -- ⚠⚠ THE DANGEROUS DEGENERATE. With no structural agreement there is no
    -- context, the edit classifies as a pure `value` edit, and the operator's
    -- result is the EXEMPLAR'S OWN BODY. A caller applying that would replace the
    -- target with someone else's function instead of editing it.
    local out, why = tp.apply(
        'local function f(x) return wrap(x) end',
        'local function f(x) return wrap(x, DEFAULT) end',
        'local function g(y)\n    -- keep me\n    return wrap(y)\nend')
    eq(nil, out, 'no source is returned for a target that shares no structure')
    ok(why and tostring(why):find('derived nothing', 1, true),
        'and the refusal names the cause rather than shipping the exemplar: '
        .. tostring(why))
end)

test('transplant: the QUIET degenerate — the exemplar\'s variable in the target\'s body', function ()
    local ready = tp.available('lua')
    if not ready then return skip('algebra/reader unavailable') end
    -- ⚠⚠ THE ONE THE FIRST GUARD MISSED, and the dangerous one, because it does
    -- not look wrong. With an extra statement in the target the derivation keeps
    -- the TARGET's signature and splices the EXEMPLAR's variable into the body:
    --     -> local function g(y) return wrap(x, DEFAULT) end
    -- valid Lua, `x` unbound, and NOT equal to b — so a text comparison passes it.
    -- The operator's own `classify` says `value`, which is the real signal.
    local out, why = tp.apply(
        'local function f(x) return wrap(x) end',
        'local function f(x) return wrap(x, DEFAULT) end',
        'local function g(y) local z = y return wrap(z) end')
    eq(nil, out, 'no source is returned when the edit has no context to land in')
    ok(why and tostring(why):find('derived nothing usable', 1, true),
        'and the refusal quotes the classification: ' .. tostring(why))
end)

test('transplant: formatting differences are NOT a degenerate', function ()
    local ready = tp.available('lua')
    if not ready then return skip('algebra/reader unavailable') end
    -- ⚠ THE GUARD MUST NOT OVER-REFUSE. Measured: extra whitespace and a
    -- multi-line body still classify `template` and derive correctly — it is a
    -- COMMENT (a node with no counterpart in the exemplar) that defeats the
    -- agreement, not formatting. A guard that rejected every reformatted target
    -- would refuse most real code.
    local out = tp.apply('local function f(x) return wrap(x) end',
                         'local function f(x) return wrap(x, DEFAULT) end',
                         'local function g(y)\n  return wrap(y)\nend')
    ok(out ~= nil, 'a multi-line target still derives')
    ok(out and out:find('wrap(y, DEFAULT)', 1, true) ~= nil,
        "under the target's OWN variable: " .. tostring(out))
    ok(out and out:find('\n  return', 1, true) ~= nil, 'and keeps its line structure')
end)

test('transplant: a target IDENTICAL to the exemplar legitimately yields b', function ()
    local ready = tp.available('lua')
    if not ready then return skip('algebra/reader unavailable') end
    -- ⚠ THE GUARD ABOVE MUST NOT EAT THIS ONE. Reproducing the exemplar is the
    -- RIGHT answer when the target IS the exemplar, which is why the guard tests
    -- `c ~= a` rather than just `out == b`.
    local same = 'local function f(x) return wrap(x) end'
    local out = tp.apply(same, 'local function f(x) return wrap(x, DEFAULT) end', same)
    eq('local function f(x) return wrap(x, DEFAULT) end', out,
        'the edit applied to its own exemplar is the exemplar edited')
end)

test('transplant: an unreadable input is named, not swallowed', function ()
    local ready = tp.available('lua')
    if not ready then return skip('algebra/reader unavailable') end
    local out, why = tp.apply('local function f(x) return wrap(x) end',
                              'local function f(x) return wrap(x, D) end',
                              'local function g(y) return wrap(y')  -- truncated
    eq(nil, out, 'a target that does not parse yields no source')
    ok(why and tostring(why):find('could not read', 1, true),
        'and the refusal says WHICH input and why: ' .. tostring(why))
end)

test('transplant: availability distinguishes its two repairs', function ()
    local ready, why = tp.available('a-language-with-no-reader')
    eq(false, ready, 'a language with no registered reader is unavailable')
    ok(why and tostring(why):find('reader', 1, true),
        'and says so — not "algebra missing", which is a different fix: ' .. tostring(why))
end)

test('transplant: the report is a PROPOSAL and says it moves nothing', function ()
    local ready = tp.available('lua')
    if not ready then return skip('algebra/reader unavailable') end
    local L = tp.report('local function f(x) return wrap(x) end',
                        'local function f(x) return wrap(x, DEFAULT) end',
                        'local function g(y) return wrap(y) end')
    local txt = table.concat(L, '\n')
    ok(txt:find('proposal only', 1, true), 'the scaffold says it is a proposal')
    ok(txt:find('moves nothing', 1, true),
        'and that transplant derives a term rather than moving a family')
    ok(txt:find('wrap(y, DEFAULT)', 1, true), 'and shows the derived line')
end)
