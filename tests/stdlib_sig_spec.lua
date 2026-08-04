-- THE BASE RUNTIME'S MEMBER SIGNATURES (CART-0266). Two sources, two tiers, and a
-- soundness ORDER between the rungs that answer a call.
--
-- WHY THIS EXISTS: the top absent callees across every Lua corpus are the stdlib
-- (match 432, concat 222, sort 211, close 193, open 180 on `self`), and each was 100%
-- frontier for a STUB — "if we don't know how to stub it, that is a gap on our side"
-- (user). The NAMES were always known (luadistill introspects them); a stub needs the
-- SIGNATURE, which only a declaration can give.
--
-- WHAT THESE PIN IS THE HEDGE, not the lookup. A member-name match with an unverified
-- receiver is a guess with exactly one candidate, and the difference between that and
-- `table.concat` naming its own namespace has to survive into the answer — otherwise a
-- consumer cannot tell which of its 5020 signatures it may trust.

local pm = require 'cartograph.spec.profile'

test('profile.base_for: a language has a base runtime, and it is a LOOKUP', function ()
    eq('luajit', pm.base_for('lua'), 'lua names its base runtime')
    eq(nil, pm.base_for('ruby'), 'a language with no base artifact says nil')
    eq(nil, pm.base_for(nil), 'and no language answers nothing')
    -- NOT detection, and that is the gap this works around: the activation axis knows
    -- FRAMEWORK shapes (a factorio mod, a rails app) and every Lua repo is a Lua repo,
    -- so nothing selects the base runtime. These lookups are read-side for that reason.
end)

test('profile.member_sig: the rungs answer in SOUNDNESS order', function ()
    local prof = {
        nsset = { table = true, string = true },
        types = { table = {}, string = {} },
        free = { tostring = true },
        sigs = {
            ['table#concat'] = { sig = '(list: table, sep?: string) -> string' },
            ['string#match'] = { sig = '(s: string, pat: string) -> any' },
            tostring = { sig = '(v: any) -> string' },
        },
        canon = { concat = 'table#concat', match = 'string#match' },
    }
    -- 1. THE CALL NAMES ITS OWN NAMESPACE — sound, no receiver typing needed
    local s, how = pm.member_sig(prof, 'concat', 'table.concat')
    ok(s, 'a namespace-rooted call is answered')
    eq('namespace', how, 'and says the root named the namespace')

    -- 2. a bare free function — sound
    local _, how2 = pm.member_sig(prof, 'tostring', nil)
    eq('free', how2, 'a free function answers as itself')

    -- 3. THE HEDGE: `s:match()` has no receiver type, and `match` has exactly one
    -- stdlib owner. A guess with one candidate is still a guess, so it is LABELLED.
    local s3, how3 = pm.member_sig(prof, 'match', 'someString.match')
    ok(s3, 'a unique member name answers')
    eq('unique', how3, 'and the answer is marked as receiver-unverified')

    -- ORDER MATTERS, which is the point of the test: a call that names a namespace must
    -- never fall through to the bare-name rule. `table.nope` is an ABSENCE in a
    -- namespace we know — a stronger statement than "unknown" — and answering it with
    -- some other namespace's `nope` would be the fabrication this artifact exists to
    -- avoid.
    local s4, how4 = pm.member_sig(prof, 'nope', 'table.nope')
    eq(nil, s4, 'a member the namespace lacks is not answered')
    eq('absent-member', how4, 'and the absence is named as one')
end)

test('profile.member_sig: several owners is a SET, never a pick', function ()
    local prof = {
        nsset = { io = true }, types = { io = {} },
        sigs = { ['file#close'] = { sig = '() -> true?' },
                 ['io#close'] = { sig = '(file?: file*) -> true?' } },
        canon = {}, sig_ambiguous = { close = { 'file', 'io' } },
    }
    local s, how, owners = pm.member_sig(prof, 'close', 'fd.close')
    eq(nil, s, 'no signature is invented for a contested name')
    eq('ambiguous', how, 'the answer is that the name is ambiguous')
    eq(2, #owners, 'and the OWNER SET comes back so a caller can render it')
    -- the receiver is what decides, and not having it is the honest frontier here
end)

test('the shipped luajit artifact carries signatures, and the tier says CLAIM',
    function ()
    local prof = pm.load('luajit')
    if not prof then skip('no luajit profile artifact') end
    if not prof.sigs then
        skip('artifact predates CART-0266 (re-run tools/luadistill.lua)')
    end
    -- the tier is not decoration: an @meta docblock is a CLAIM (CART-0240 shipped
    -- annotation-mismatch because docblocks lie), while the NAME set beside it is a
    -- measurement of this interpreter. Both ship; only one is authority on existence.
    eq('annotation', prof.sig_kind, 'signatures are annotation-derived, i.e. a claim')
    ok(prof.sig_source and prof.sig_source ~= '',
        'and the artifact records WHICH source, so a missing signature and a missing'
        .. ' signature SOURCE never render the same')

    -- the census's own top absent callees, which is why this work happened
    local concat = pm.member_sig(prof, 'concat', 'table.concat')
    ok(concat and concat.sig:find('sep', 1, true),
        'table.concat is signed with its params: ' .. tostring(concat and concat.sig))
    ok(#(concat.returns or {}) > 0, 'and with a RETURN, which is what a stub needs')

    -- EXTENSION LIBRARIES MAY NOT ANSWER A BARE NAME. Measured: 176 sites on `self`
    -- were signed `buf#get`/`buf#put` (LuaJIT's require-only string.buffer) and
    -- `profile#start` (jit.profile) against this repo's own cv:get, store:get,
    -- timer:start. Generic member names on an optional extension are the worst
    -- possible source for a name-only rule, so eligibility is DERIVED: the owner must
    -- be a namespace the interpreter presents, or be named as a return type of one.
    eq(nil, (prof.canon or {}).get, 'buf#get cannot sign a bare `get`')
    eq(nil, (prof.canon or {}).put, 'nor buf#put a bare `put`')
    ok((prof.canon or {}).match, 'while string#match still signs a bare `match`')
    -- io's file handle IS reachable — io.open declares it as a return — so a file
    -- method may sign a call, which is the second rung of the eligibility walk
    ok(prof.sigs['file#seek'], 'the file class ships signatures')
    eq('file#seek', (prof.canon or {}).seek, 'and reaches canon via io.open\'s return')
end)

test('luajit: a member of ANOTHER Lua version is not served as this runtime\'s',
    function ()
    local prof = pm.load('luajit')
    if not (prof and prof.sigs) then skip('no CART-0266 artifact') end
    -- string.pack / math.type / table.pack are 5.3+/5.4; LuaJIT has none of them. The
    -- meta declares them behind an `---@version >5.3` TAG — a SECOND version mechanism
    -- beside the #if preprocessor, which annot.lua ignores by name (its tag set is a
    -- whitelist of things that carry a TYPE). THE CROSS-CHECK IS WHAT CAUGHT THEM:
    -- introspection is the authority on existence, the meta on shape.
    for _, k in ipairs({ 'string#pack', 'math#type', 'table#pack' }) do
        eq(nil, prof.sigs[k], k .. ' must not be served as a LuaJIT signature')
        ok((prof.sigs_absent or {})[k],
            k .. ' is RECORDED as declared-but-absent, not dropped')
    end
    eq(nil, (prof.canon or {}).pack, 'and cannot sign a bare `pack` either')
end)
