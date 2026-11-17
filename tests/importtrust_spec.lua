-- CART-2126 (its prerequisite): an import edge carries `inferred` when the include is a GUESS — a loader recognised by
-- its NAME (mantis's require_api: a verb named require_* / include_* / load_ with a .php argument) or a computed path
-- matched by its TAIL (CART-0944) — and `via` says which. Nothing read the mark: the store's import index dropped it,
-- and every reader of the import graph took a guessed include as a fact. mantisbt: 2,869 of its 3,294 import edges are
-- hedged, and its 60-module require cycle rests on 487 hedged edges of 490. graph_info states the count, the
-- require-cycle lint says when a cycle rests on hedged edges.

local ts    = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local agent = require 'cartograph.agent'

local function tree(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local P = '<?php\n'

local function setup(files)
    local root = tree(files)
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    return root
end
local function cycles()
    local a = agent.answer(store, 'lint_run', { rules = { 'require-cycle' } })
    local out = {}
    for _, r in ipairs(a.result or {}) do
        if (r.message or ''):find('require cycle', 1, true) then out[#out + 1] = r.message end
    end
    return out
end

test('import trust: a loader-name and a path-tail import carry inferred + via into the store\'s import index (CART-2126)', function ()
    if not parser_available('php') then skip 'no php parser' end
    local root = setup({
        ['core/b_api.php'] = P,
        ['lib/c.php'] = P,
        ['a.php'] = P .. "require_api( 'b_api.php' );\nrequire_once( $g_root . 'c.php' );\nrequire_once( 'core/b_api.php' );\n",
    })
    local by = {}
    for _, r in ipairs(store.imports_in['core/b_api.php'] or {}) do by[#by + 1] = tostring(r.via) .. ':' .. tostring(r.inferred) end
    table.sort(by)
    eq({ 'loader-name:true', 'nil:nil' }, by, 'the name-matched site and the literal one, told apart')
    eq('path-tail', store.imports_in['lib/c.php'][1].via)
    eq(true, store.imports_in['lib/c.php'][1].inferred)
    vim.fn.delete(root, 'rf')
end)

test('import trust: graph_info counts the hedged imports by why (CART-2126)', function ()
    if not parser_available('php') then skip 'no php parser' end
    local root = setup({
        ['core/b_api.php'] = P,
        ['lib/c.php'] = P,
        ['a.php'] = P .. "require_api( 'b_api.php' );\nrequire_once( $g_root . 'c.php' );\nrequire_once( 'core/b_api.php' );\n",
    })
    local note
    for _, n in ipairs(agent.answer(store, 'graph_info', {}).notes or {}) do if n.kind == 'import-trust' then note = n end end
    ok(note, 'the note')
    eq({ imports = 3, hedged = 2, by_via = { ['loader-name'] = 1, ['path-tail'] = 1 } }, note.evidence)
    vim.fn.delete(root, 'rf')
    -- and a graph whose imports are all literal says nothing
    root = setup({ ['x.php'] = P .. "require_once( 'y.php' );\n", ['y.php'] = P })
    for _, n in ipairs(agent.answer(store, 'graph_info', {}).notes or {}) do eq(true, n.kind ~= 'import-trust', 'no hedged import, no note') end
    vim.fn.delete(root, 'rf')
end)

test('import trust: a require cycle through a hedged import says the cycle may not exist; a literal one does not (CART-2126)', function ()
    if not parser_available('php') then skip 'no php parser' end
    local root = setup({
        -- (a_api -> b_api has a LITERAL site beside the name-matched one: that pair is certain)
        ['core/a_api.php'] = P .. "require_api( 'b_api.php' );\nrequire_once( __DIR__ . '/b_api.php' );\n",
        ['core/b_api.php'] = P .. "require_api( 'a_api.php' );\n",
        ['x.php'] = P .. "require_once( 'y.php' );\n",
        ['y.php'] = P .. "require_once( 'x.php' );\n",
    })
    local hedged, plain = nil, nil
    for _, m in ipairs(cycles()) do
        if m:find('a_api', 1, true) then hedged = m elseif m:find('x.php', 1, true) then plain = m end
    end
    ok(hedged and hedged:find('1 of its 2 imports are HEDGED (loader-name 1)', 1, true), tostring(hedged))
    ok(plain and not plain:find('HEDGED', 1, true), 'the literal cycle is stated as before: ' .. tostring(plain))
    vim.fn.delete(root, 'rf')
end)
