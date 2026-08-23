-- MEMBER-NAME POSITIONS: a name reached through a receiver (CART-0529). The
-- corpus-wide unique-function index holds BARE names, so matching a member name
-- against it is a coincidence of spelling, not evidence about the receiver.
-- Measured on wow_addons: 724 of 2988 reg occurrences sat in member position.
--
-- WHAT SHIPPED IS THE WRITE-POSITION HALF ONLY, and the number is why: vetoing
-- every member name dropped 283 reg edges, and opening the source showed they
-- were mostly GENUINE module-internal calls (`Prat:SetModuleDefaults(module,…)`
-- against `function SetModuleDefaults(self, …)`; `core.add_junk_to_tooltip(…)`
-- where the target file literally assigns `core.add_junk_to_tooltip =
-- add_junk_to_tooltip`). A member name being ASSIGNED TO is different in kind:
-- it is a definition-side key and can never be a reference to the function whose
-- name it borrows. That subset removes 0 edges and 82 occurrences on wow.

local ts = require 'cartograph.providers.treesitter'
local contract = require 'cartograph.spec.contract'

test('memberpos: the slot is registered, and absence is legal', function ()
    ok(contract.SLOTS['member_positions'], 'member_positions has a group')
    -- unlike call_positions, a language may genuinely have no member form:
    -- bash/haskell/scheme have none, and ruby spells `o.prop` with the same
    -- `call` node its call_positions already declares
    for _, lang in ipairs({ 'bash', 'haskell', 'scheme', 'ruby' }) do
        eq(nil, ts.spec[lang].member_positions)
    end
    ok(ts.spec.ruby.call_positions.call, 'ruby covers it as a call position')
end)

test('memberpos: an entry is a FIELD NAME or a named-child INDEX', function ()
    local bad = {}
    for lang, sp in pairs(ts.spec) do
        for nt, v in pairs(sp.member_positions or {}) do
            local t = type(v)
            if not (t == 'string' or (t == 'number' and v >= 0 and v == math.floor(v))) then
                bad[#bad + 1] = ('%s.%s'):format(lang, nt)
            end
        end
    end
    eq({}, bad)
end)

-- ★ THE SHARP CASE, and the reason every entry was probed against its grammar:
-- zig and c/cpp/rust all spell member access `field_expression`, and zig's
-- member is an unnamed child 1 where the others have a `field` field. One
-- node-type name, two relations — exactly what kept ruby and haskell silently
-- broken inside the old call-position list (CART-0499).
test('memberpos: zig field_expression is child 1, c/cpp/rust use the field', function ()
    eq(1, ts.spec.zig.member_positions.field_expression)
    eq('field', ts.spec.c.member_positions.field_expression)
    eq('field', ts.spec.cpp.member_positions.field_expression)
    eq('field', ts.spec.rust.member_positions.field_expression)
end)

-- ★ BRACKET FORMS MUST STAY OUT. `t[k]`'s key is an EXPRESSION, so the mention
-- inside it is a genuine value read; vetoing it would lose a real reference.
test('memberpos: bracket/subscript forms are deliberately absent', function ()
    eq(nil, ts.spec.lua.member_positions.bracket_index_expression)
    eq(nil, ts.spec.php.member_positions.subscript_expression)
    eq(nil, ts.spec.python.member_positions.subscript)
    eq(nil, ts.spec.javascript.member_positions.subscript_expression)
    -- and the dot forms ARE there, so the absences above are a decision
    eq('field', ts.spec.lua.member_positions.dot_index_expression)
    eq('property', ts.spec.javascript.member_positions.member_expression)
end)

-- THE DISCRIMINATING FIXTURE (CART-0528 asks every declaration for one): delete
-- `dot_index_expression` from spec/lua.lua and the first assertion below fails,
-- because `exports.distinctive_handler = distinctive_handler` records BOTH the
-- key and the reference against one edge.
test('memberpos: a definition-side member KEY is not an occurrence', function ()
    local data = ts.extract(vim.fn.getcwd() .. '/tests/fixtures/memberkey')
    local byk = {}
    for _, e in ipairs(data.edges or {}) do
        if e.kind == 'reg' or e.kind == 'ref' then
            byk[e.from .. ' -> ' .. e.to] = e
        end
    end
    local defside = byk['lib.lua -> lib.lua::distinctive_handler@3']
    ok(defside, 'the registration edge exists')
    -- ONE occurrence, and it is the RHS. `exports.distinctive_handler` on the
    -- left of the same line is the key.
    eq(1, #defside.at)
    eq(11, defside.at[1].start.line) -- 0-based: source line 12
    -- POSITIVE CONTROL: a BARE mention in data position is a real registration
    local control = byk['other.lua -> lib.lua::distinctive_handler@3']
    ok(control, 'the bare data registration survives')
    eq(1, #control.at)
end)
