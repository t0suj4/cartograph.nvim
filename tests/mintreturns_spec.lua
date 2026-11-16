-- CART-2110: the profile MINT runs after every resolution pass, so a chained call whose determining call only the mint
-- resolves was decided before that call's return type existed. `xform.querySelectorAll('f').forEach(…)`: the receiver
-- is untyped, the node profile's mint path names ParentNode.querySelectorAll (returns NodeListOf), and forEach stayed
-- refused `vocab` cold, while a warm relink, which starts from the minted node, typed it to NodeListOf.forEach.
-- converse.js: exactly those 3 calls; cold == warm == parallel after the fix.

local ts = require 'cartograph.providers.treesitter'

test('mint then returns: a chain whose head only the mint resolves is typed cold as a warm relink types it (CART-2110)', function ()
    if not parser_available('javascript') then skip 'no javascript parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root .. '/src', 'p')
    local function w(p, t) local fd = assert(io.open(root .. '/' .. p, 'w')); fd:write(t); fd:close() end
    w('package.json', '{ "name": "t", "version": "1.0.0" }\n')
    w('src/a.js', "export function wire(xform) {\n  xform.querySelectorAll('field').forEach((f) => f.remove());\n}\n")
    local data = ts.extract(root); data.root = root
    if data.profile ~= 'node' then skip 'the node profile is not active here' end
    local function fe()
        for _, c in ipairs(data.calls) do if c.callee == 'forEach' then return c end end
    end
    local c = fe()
    eq('node::NodeListOf.forEach', c.to, vim.inspect(c))
    eq('stdlib', c.prov)
    ts.relink(data)
    eq('node::NodeListOf.forEach', fe().to, 'a relink lands the same')
    vim.fn.delete(root, 'rf')
end)
