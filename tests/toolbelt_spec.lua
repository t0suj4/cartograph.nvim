-- THE TOOLBELT (CART-1152 follow-on): every tactic in lua/cartograph/tactics/ is discovered — no central list — and
-- every one of its EXAMPLES runs here. An example is the entry's usage documentation, so running it is what keeps the
-- documentation true: a tactic whose example stops working fails this spec by name. TOTAL BY CONSTRUCTION: a new
-- file in tactics/ is picked up with nothing to register.
local tb = require 'cartograph.toolbelt'

local function ready()
    return pcall(vim.treesitter.get_string_parser, '', 'lua') and require('cartograph.algebra').available()
end

test('toolbelt: every entry loads, and every example of every entry holds', function ()
    if not ready() then skip 'no lua parser or algebra' end
    local entries, broken = tb.list()
    eq({}, broken, 'no entry is malformed')
    ok(#entries >= 4, 'the toolbelt is discovered from its directory, not an empty glob: ' .. #entries)
    local kinds, bad, n = {}, {}, 0
    for _, e in ipairs(entries) do
        kinds[e.kind] = true
        for _, ex in ipairs(e.examples) do
            n = n + 1
            local okx, why = tb.example(e, ex)
            if not okx then bad[#bad + 1] = ('%s — %s: %s'):format(e.name, ex.name, tostring(why)) end
        end
    end
    ok(kinds.write and kinds.discovery, 'both kinds are present')
    io.write(('  [toolbelt] %d entries, %d examples\n'):format(#entries, n))
    eq({}, bad, 'each example is the usage AND the test')
end)

test('toolbelt: a malformed entry is refused BY NAME, and a failing example is reported, not passed', function ()
    if not ready() then skip 'no lua parser or algebra' end
    local d = vim.fn.tempname(); vim.fn.mkdir(d, 'p')
    local function put(name, text) local fd = assert(io.open(d .. '/' .. name .. '.lua', 'w')); fd:write(text); fd:close() end
    put('no-examples', "return { name = 'no-examples', kind = 'discovery', summary = 's', examples = {}, measure = function () return 1 end, claim = function () return true end }")
    put('misnamed', "return { name = 'other', kind = 'write', summary = 's', examples = { {} }, build = function () end }")
    put('wrong', [[return { name = 'wrong', kind = 'discovery', summary = 's', examples = { { name = 'claims too much', expect = { holds = true } } },
        measure = function () return 0 end, claim = function (v) return v > 0, 'v = ' .. v end }]])
    local entries, broken = tb.list(d)
    ok(broken['no-examples'] and broken['no-examples']:find('at least one example', 1, true), tostring(broken['no-examples']))
    ok(broken.misnamed and broken.misnamed:find('named by its FILE', 1, true), tostring(broken.misnamed))
    eq(1, #entries)
    local okx, why = tb.example(entries[1], entries[1].examples[1])
    eq(false, okx, 'an example whose expectation is false FAILS')
    ok(tostring(why):find('expected the claim to hold', 1, true), tostring(why))
end)
