-- The absorption ledger's own guards (CART-0889 follow-on). What it measures is
-- cheap to get wrong in ONE direction — undercounting reads as "less absorbed
-- than we are", which is the flattering answer for a gap-finding tool and so the
-- one nobody questions. Both bugs found while building it were undercounts.

local led = dofile(vim.fn.getcwd() .. '/tools/algebraledger.lua')

--- ★★★ THE BINDING SHAPES, which is where both bugs were. Three are already in
--- the tree and a fourth will appear; the ledger counts `A.<arrow>` uses, so a
--- shape it does not recognise contributes ZERO and is indistinguishable from a
--- file that uses nothing.
test('algebraledger: every binding shape in the tree is recognised', function ()
    local cases = {
        ['direct']        = 'local A = alg.load()\nA.partition(x)\n',
        ['with a reason'] = 'local A, why = alg.load()\nA.partition(x)\n',
        ['assert-wrapped']= "local A = assert(alg.load(), 'nope')\nA.partition(x)\n",
        ['through a helper'] =
            'local function need()\n    return alg.load()\nend\nlocal A = need()\nA.partition(x)\n',
    }
    for name, src in pairs(cases) do
        local vars = led._bindings(src)
        ok(vars.A, ('the %s binding is recognised'):format(name))
    end
    -- BOTH SIDES: a file that never loads the algebra binds nothing, or every
    -- local in the tree would count as an algebra handle
    local none = led._bindings('local A = something_else()\nA.partition(x)\n')
    ok(not none.A, 'an unrelated local is not treated as an algebra binding')
end)

--- The export list and its grouping are DERIVED from the prototype's own source,
--- so a stale hand-written table cannot creep back in. This pins that the parse
--- actually finds arrows and attributes them to the right section.
test('algebraledger: exports are attributed to the prototype\'s own sections', function ()
    local alg = require 'cartograph.algebra'
    local path = alg.path()
    local fd = path and io.open(path, 'r')
    if not fd then skip('prototype not present') end
    local src = fd:read('*a'); fd:close()

    local sect, order, of = led.exports(src)
    ok(#order > 10, 'the prototype has many sections, got ' .. #order)
    ok(of.transplant, '`transplant` is found as an export')
    ok(tostring(of.transplant):find('transplant'),
        'and lands in the transplant section, not the preamble: ' .. tostring(of.transplant))
    ok(of.partition and tostring(of.partition):find('MDL'),
        '`partition` lands in the MDL section: ' .. tostring(of.partition))
    -- a term constructor and an operator must not share a section, or the
    -- "6 of 159" framing the grouping exists to prevent comes back
    ok(of.lit ~= of.transplant, 'constructors and operators are grouped apart')
    ok(#sect[of.lit] > 1, 'the terms section holds several constructors')
end)

--- ★★★ THE DENOMINATOR MUST SURVIVE THE SPLIT IT IS MEASURING (CART-0918).
--- Reading the surface from `core.lua` alone was right while the algebra was one
--- file and wrong the moment adaptation began: 12 exports moved out and the
--- ledger read 159 -> 147 with the numerator untouched, so absorption "improved"
--- for moving code. That is the flattering direction, and this file's own header
--- says the flattering direction is the one nobody questions.
test('algebraledger: the export surface is the DIRECTORY, so a split does not shrink it', function ()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local function put(name, body)
        local fd = assert(io.open(dir .. '/' .. name, 'w')); fd:write(body); fd:close()
    end
    local HDR = '-- \226\148\128\226\148\128 %s \226\148\128\226\148\128\n'

    -- before the split: one file, two sections, three exports
    put('core.lua', HDR:format('terms')
        .. 'function M.lit(v) end\nfunction M.name(n) end\n'
        .. HDR:format('hopau')
        .. 'function M.hoau(a, b) end\n')
    local _, _, of1, files1 = led.exports_dir(dir)
    local n1 = 0; for _ in pairs(of1) do n1 = n1 + 1 end
    eq(1, #files1)
    eq(3, n1)

    -- after: the second section has MOVED, exactly as the move-set carries it
    -- (the `-- ── title ──` header travels with the text, which is why the
    -- grouping needs no second authority)
    put('core.lua', HDR:format('terms')
        .. 'function M.lit(v) end\nfunction M.name(n) end\n')
    put('hopau.lua', HDR:format('hopau') .. 'function M.hoau(a, b) end\n')
    put('origin.lua', 'return { sha256 = "x" }\n')   -- the stamp exports nothing
    local sect2, order2, of2, files2 = led.exports_dir(dir)
    local n2 = 0; for _ in pairs(of2) do n2 = n2 + 1 end
    eq(2, #files2, 'the stamp is not counted as a source')
    eq(n1, n2, 'the export surface is UNCHANGED by the split')
    eq('hopau', of2.hoau, 'and the moved arrow keeps its section')
    ok(#sect2['terms'] == 2 and #sect2['hopau'] == 1, 'both sections survive')
    -- core sorts first, so the section order still reads like the original file.
    -- ⚠ order[1] is the `(preamble)` pseudo-section every file opens with — the
    -- ORDER of the real sections is the claim, not the first slot.
    local at = {}
    for i, t in ipairs(order2) do at[t] = i end
    ok(at['terms'] < at['hopau'], 'core.lua\'s sections come first')
    vim.fn.delete(dir, 'rf')
end)

--- ★★★ EVERY NAME ON THE MODULE TABLE, NOT EVERY `function M.x` (CART-0911).
--- The original predicate was one pattern and the tree holds four shapes. This
--- asserts all four AND the negative — because a widened predicate that also
--- swallows a CALL would inflate the denominator, which is the failure the
--- previous fix (CART-0918) exists to prevent.
test('algebraledger: exports are every module-table name, classified arrow vs value', function ()
    local src = table.concat({
        '-- \226\148\128\226\148\128 terms \226\148\128\226\148\128',
        'function M.lit(v) end',          -- the shape it always saw
        'M.is_hole = is_hole',            -- an ALIAS of a local function
        'M.dig = function (t) end',       -- an arrow written the other way round
        'M.rigidity = {}',                -- a NAMESPACE table: data on the table
        'M.rigidity.lcs = function (a, b) end',  -- and an arrow UNDER it
        'M.RUNGS = { "confirmed" }',      -- data that is part of the contract
        'M.KV_ABSENT = setmetatable({}, {})',
        'M.grammar("sh", { x = 1 })',     -- ⚠ a CALL, not an export
        '  M.indented = thing',           -- ⚠ not at module level
    }, '\n')
    local _, _, of, kind = led.exports(src)

    eq('arrow', kind['lit'])
    eq('arrow', kind['is_hole'], 'an alias is an arrow')
    eq('arrow', kind['dig'], 'a function literal is an arrow')
    eq('arrow', kind['rigidity.lcs'], 'a namespaced function is an arrow')
    eq('value', kind['rigidity'], 'the namespace table itself is data')
    eq('value', kind['RUNGS'])
    eq('value', kind['KV_ABSENT'], 'a sentinel is part of the contract, not an arrow')

    -- ⚠ THE NEGATIVES. `M.grammar(...)` INVOKES an export, and an indented
    -- assignment is not on the module table at all.
    eq(nil, of['grammar'], 'a call is not an export')
    eq(nil, of['indented'], 'an indented assignment is not a module-table name')

    -- and every one of them is attributed to the section it sits in
    eq('terms', of['is_hole'])
end)

--- ★★★ A DEFINITION OUTRANKS AN ASSIGNMENT, ACROSS FILES (CART-0911 follow-on).
--- After a split, `core.lua` carries `M.x = mod.x` (the re-export our own
--- move-set writes) while the extracted file carries `function M.x`. Taking the
--- first sighting classified our re-export as DATA and filed the name under
--- core.lua's last section: measured, a split moved the breakdown from
--- 168 arrow/9 value to 156/21 while the total held — the kind and the section
--- were wrong in exactly the names that moved.
test('algebraledger: a definition beats a re-export, for both kind and section', function ()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local function put(name, body)
        local fd = assert(io.open(dir .. '/' .. name, 'w')); fd:write(body); fd:close()
    end
    local HDR = '-- \226\148\128\226\148\128 %s \226\148\128\226\148\128\n'

    put('core.lua', HDR:format('terms')
        .. 'function M.lit(v) end\n'
        .. HDR:format('leftovers')
        .. "local hopau = require 'x.hopau'\n"
        .. 'M.hoau = hopau.hoau\n')            -- the re-export, in the LAST section
    put('hopau.lua', HDR:format('hopau') .. 'function M.hoau(a, b) end\n')

    local sect, _, of, _, kind = led.exports_dir(dir)
    eq(2, (function () local n = 0; for _ in pairs(of) do n = n + 1 end; return n end)(),
        'the re-export and the definition are ONE name, not two')
    eq('arrow', kind['hoau'], 'the definition decides the kind')
    eq('hopau', of['hoau'], 'and the section — not the one the re-export sits in')
    eq(0, #(sect['leftovers'] or {}), 'the re-export leaves no ghost behind')
    vim.fn.delete(dir, 'rf')
end)

--- ★★★ THE WARNING MUST STILL FIRE (CART-0910). It was a search for arrow NAMES
--- anywhere in the text, and the 168 arrow names include `name`, `at`, `apply`,
--- `copy`, `size`, `ref` and `match` — so it fired on all three files that touch
--- the algebra and on none of them was it right. MEASURED: 15 "hits" in
--- `agent.lua`, which is a verb catalogue full of `.name` fields. A warning
--- wrong on every run since it shipped is the inverse of a fence that never
--- fires and costs the same — nobody reads the line.
--- ⚠ SO THE POSITIVE CASE IS THE ASSERTION THAT MATTERS. Silencing a false alarm
--- by deleting the check would pass every negative test ever written.
test('algebraledger: the unbound warning is structural — it fires on a hidden binding', function ()
    local root = vim.fn.tempname()
    for _, d in ipairs({ '/lua/cartograph', '/tools', '/tests' }) do
        vim.fn.mkdir(root .. d, 'p')
    end
    local function put(rel, body)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(body); fd:close()
    end
    -- the seam, so `seam_api` has something to derive from
    put('lua/cartograph/algebra.lua',
        '\nfunction M.load() end\nfunction M.available() end\nfunction M.term(e) end\n')

    -- ⚠ THE POSITIVE: it loads the algebra and binds it in a shape `bindings`
    -- does not model, so its arrow uses are invisible and MUST be announced
    put('lua/cartograph/hidden.lua', table.concat({
        "local alg = require 'cartograph.algebra'",
        'local holder = {}',
        'holder.A = alg.load()',          -- not a `local X = ...load()`
        'holder.A.partition(x)',
    }, '\n'))
    local t1 = led.uses(root, { partition = true })
    eq(0, t1.lua.partition or 0, 'the use really is invisible to the counter')
    eq(1, #led.unbound, 'and the file is announced: ' .. vim.inspect(led.unbound))
    ok(tostring(led.unbound[1]):find('hidden.lua', 1, true))

    -- ⚠ THE NEGATIVES, one per false-alarm source measured on the real tree:
    --   a seam-only consumer (agent.lua asks `available()` and nothing else)
    --   a file whose fixtures SPELL a load in a STRING (this spec does)
    --   prose in a comment naming an arrow
    put('lua/cartograph/hidden.lua', '-- removed\n')
    put('lua/cartograph/seamonly.lua', table.concat({
        "local alg = require 'cartograph.algebra'",
        'local ok = alg.available()',
        'local t = alg.term({ k = "name" })',
        'local row = { name = 1, at = 2, size = 3, apply = 4 }',  -- arrow NAMES as fields
    }, '\n'))
    -- ⚠ THE FIXTURE'S SHAPE IS THE TEST. Written as `local F = { direct = "..." }`
    -- this passes for the WRONG REASON: the line starts with `local` and ends in
    -- `load(`, so `bindings` claims it as a binding and the warning is skipped
    -- without the stripping ever being consulted. The real spec spells its
    -- fixtures as INDENTED TABLE KEYS, which `bindings` cannot see — that is the
    -- shape that reached the old arrow-name search, so it is the shape to pin.
    put('tests/fixtures_spec.lua', table.concat({
        "local alg = require 'cartograph.algebra'",
        'local F = {',
        "    ['direct'] = 'local A = alg.load()\\nA.partition(x)\\n',",
        '}',
        '-- prose: alg.load() gives you A.partition',
    }, '\n'))
    led.uses(root, { partition = true })
    eq(0, #led.unbound, 'no false alarm: ' .. vim.inspect(led.unbound))
    vim.fn.delete(root, 'rf')
end)

--- ★★★ PROSE NAMES ARROWS, AND PROSE IS NOT A CONSUMER (CART-0921). The uses
--- scan read the RAW text, so `-- replayable by `A.replay_edit`` in a comment
--- counted as a shipped consumer. MEASURED when the real consumer finally landed
--- and the number did NOT move: SHIPPED 26 counting comments, 23 counting code;
--- HARNESS 4 -> 6 and TEST 3 -> 4, their only lua/ "use" being prose.
--- ⚠ THE FLATTERING DIRECTION, for the second time in this tool — absorption
--- reads FURTHER ALONG than it is, which is the error nobody questions.
test('algebraledger: an arrow named only in a COMMENT is not a consumer', function ()
    local root = vim.fn.tempname()
    for _, d in ipairs({ '/lua/cartograph', '/tools', '/tests' }) do
        vim.fn.mkdir(root .. d, 'p')
    end
    local function put(rel, body)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(body); fd:close()
    end
    put('lua/cartograph/algebra.lua', '\nfunction M.load() end\n')

    -- prose and a string mention it; nothing calls it
    put('lua/cartograph/talker.lua', table.concat({
        "local alg = require 'cartograph.algebra'",
        'local A = alg.load()',
        '-- see A.partition for the MDL split',
        'local doc = "A.partition groups the members"',
        'local x = A.generalize(1, 2)',      -- the ONE real use
    }, '\n'))

    local t = led.uses(root, { partition = true, generalize = true })
    eq(nil, t.lua.partition, 'a comment and a string are not consumers')
    ok((t.lua.generalize or 0) > 0, 'and a real call still counts')
end)
