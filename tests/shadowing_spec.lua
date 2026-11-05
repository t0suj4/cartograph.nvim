-- A NAME A FUNCTION BINDS ITSELF IS THAT BINDING (CART-0629). The mention pass resolves a non-call mention by the
-- workspace-unique function of its name — a `~` hypothesis — and its lexical guard only ever fenced the CROSS-FILE case,
-- in the languages that declare lexical scopes. So a parameter named like a top-level function was linked to that
-- function: `def same(dir): return len(dir)` gave `same -> dir` at the parameter and at `len(dir)` — measured 2026-11-05
-- in python, zig, haskell, scheme and bash (odin's and erlang's grammars bound it already). The rule: when the mention
-- sits inside a function that binds the name (a parameter or a local of its own), the guess is dropped — whatever the
-- file, whatever the language's scope model. A function that does NOT bind it still links to the top-level one.

local ts = require 'cartograph.providers.treesitter'

local CASES = {
    python = { ['a.py'] = 'def dir(p):\n    return p\n\ndef first():\n    handler = dir\n    return handler\n\ndef same(dir):\n    return len(dir)\n\ndef use():\n    return apply(dir)\n\ndef outer(dir):\n    def inner():\n        return len(dir)\n    return inner\n',
               ['b.py'] = 'from a import *\n\ndef other(dir):\n    return len(dir)\n' },
    haskell = { ['A.hs'] = 'module A where\ndir :: Int -> Int\ndir p = p\nsame :: Int -> Int\nsame dir = keep dir\nkeep :: Int -> Int\nkeep x = x\nuse :: Int\nuse = apply dir\n',
                ['B.hs'] = 'module B where\nimport A\nother :: Int -> Int\nother dir = keep dir\n' },
    javascript = { ['a.js'] = 'function dir(p) { return p; }\nfunction same(dir) { return keep(dir); }\nfunction keep(x) { return x; }\nfunction use() { return apply(dir); }\n' },
}
-- ⚠ NOT COVERED, filed as its own ticket: zig, scheme and bash function nodes carry NO params (fn_params finds no
-- parameter list for their grammars) and bash's `local dir=` is no local of the node, so there is no binder list to
-- consult; zig and bash also reach the target through the CALL-ARGUMENT upgrade (argv k = 'func'), not this pass.
-- (the functions that BIND `dir` — no edge from them to the function `dir`; and the one that does not, which must link)
local BINDS = { same = true, other = true, outer = true, inner = true }

local function edges_into_dir(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, src in pairs(files) do local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(src); fd:close() end
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local dir, name = nil, {}
    for _, n in ipairs(data.nodes) do
        name[n.id] = n.name
        if n.name == 'dir' and (n.kind == 'function' or n.kind == 'method') then dir = n.id end
    end
    local from = {}
    for _, e in ipairs(data.edges) do
        if dir and e.to == dir and e.from ~= dir and e.kind == 'ref' then from[name[e.from] or e.from] = true end
    end
    return dir, from
end

for lang, files in pairs(CASES) do
    test(('shadowing (CART-0629): %s — a parameter / local named like a top-level function is not that function'):format(lang), function ()
        if not parser_available(lang) then skip('no ' .. lang .. ' parser') end
        local dir, from = edges_into_dir(files)
        ok(dir, 'the top-level `dir` is a function node')
        for f in pairs(from) do ok(not BINDS[f], ('%s binds `dir`, and was linked to the function: %s'):format(f, vim.inspect(from))) end
    end)
end

test('shadowing (CART-0629): a function that does NOT bind the name still links to the top-level one', function ()
    for _, lang in ipairs({ 'python', 'haskell', 'javascript' }) do
        if parser_available(lang) then
            local _, from = edges_into_dir(CASES[lang])
            ok(from.use, lang .. ': `use` mentions the function `dir` and must keep its edge: ' .. vim.inspect(from))
            -- (and one written BEFORE a binding function: a range must CONTAIN the mention, both ends checked)
            if lang == 'python' then ok(from.first, 'python: `first` precedes `same` and keeps its edge: ' .. vim.inspect(from)) end
        end
    end
end)

-- (the two shapes hand-checking the corpora found, django-oscar and jquery)
test('shadowing (CART-0629): a plain def INSIDE the binding function rebinds the name — the mention may be it, so it stays', function ()
    if not parser_available('python') then skip 'no python parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/c.py', 'w'))
    fd:write('def receiver(signal, wraps=None):\n    if wraps is None:\n\n        def wraps(*a):\n            return None\n\n    return Mock(wraps=wraps)\n')
    fd:close()
    local data = ts.extract(root); vim.fn.delete(root, 'rf')
    local wraps, linked
    for _, n in ipairs(data.nodes) do if n.name == 'wraps' then wraps = n.id end end
    for _, e in ipairs(data.edges) do if e.kind == 'ref' and e.to == wraps and e.from ~= wraps then linked = true end end
    ok(wraps and linked, '`Mock(wraps=wraps)` may pass the nested def: the edge to it stays')
end)

test('shadowing (CART-0629): a closure VAR named like an object-literal method is the var, not the method', function ()
    if not parser_available('javascript') then skip 'no javascript parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/cb.js', 'w'))
    fd:write('function Callbacks() {\n  var locked = false;\n  var self = {\n    disable: function () { locked = true; },\n    locked: function () { return !!locked; }\n  };\n  return self;\n}\n')
    fd:close()
    local data = ts.extract(root); vim.fn.delete(root, 'rf')
    local name, lockedm = {}, nil
    for _, n in ipairs(data.nodes) do name[n.id] = n.name; if n.name == 'locked' and n.kind ~= 'var' then lockedm = n.id end end
    local into = {}
    for _, e in ipairs(data.edges) do if e.kind == 'ref' and e.to == lockedm then into[#into + 1] = name[e.from] or e.from end end
    ok(lockedm, 'the method `locked` is a node')
    eq({}, into, '`locked = true` and `!!locked` are the closure var: nothing links the method')
end)
