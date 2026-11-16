-- CART-2109: the cbarg pre-scan marks a function passed as an ARGUMENT VALUE (it is then no bare same-file call
-- target), keyed by name — and it crossed LANGUAGES. On brotardcast an erlang pattern variable `E`
-- (`binary_to_list(E)` at a clause its fn did not cover) marked the one JavaScript `const E = () => …` in the tree,
-- in relink's pre-scan only: the parallel graph resolved E's 15 calls `local_callable` (inferred) where inline said
-- `base`. Both pre-scans now require the argument's language to reach the definition (M._join_lang_ok).

local ts = require 'cartograph.providers.treesitter'

test('cbarg: an argument in ANOTHER language never marks a function cbarg — inline and relink alike (CART-2109)', function ()
    if not (parser_available('javascript') and parser_available('python')) then skip 'no javascript / python parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(p, t) local fd = assert(io.open(root .. '/' .. p, 'w')); fd:write(t); fd:close() end
    w('a.js', 'function outer() {\n  const pickup = () => 1;\n  return pickup();\n}\n')
    w('m.py', 'print(pickup)\n') -- a module-level python argument with the same name
    local data = ts.extract(root); data.root = root
    local function state()
        local node, call
        for _, n in ipairs(data.nodes) do if n.name == 'pickup' then node = n end end
        for _, c in ipairs(data.calls) do if c.file == 'a.js' and c.callee == 'pickup' then call = c end end
        return node, call
    end
    local n, c = state()
    eq(nil, n.cbarg, 'inline: not a callback argument')
    eq({ n.id, 'base' }, { c.to, c.prov })
    for _, x in ipairs(data.calls) do x.to, x.prov, x.inferred = nil, nil, nil end
    ts.relink(data)
    n, c = state()
    eq(nil, n.cbarg, 'relink: not a callback argument either')
    eq({ n.id, 'base' }, { c.to, c.prov })
    vim.fn.delete(root, 'rf')
end)
