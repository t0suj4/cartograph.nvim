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

-- ★ AN INCLUDER BY ITS BODY (CART-2126). mantis's require_api had its 2,823 edges from its NAME (via loader-name). The
-- body proves the verb an includer and says which parameter ends the path: require_api's $g_core_path is a global (the
-- path's tail is matched, via path-tail); a rooted prefix (`__DIR__ . '/lib/'`) gives an exact edge; a wrapper named
-- nothing like a loader gets its edges; a require_* verb whose body provably includes nothing (mantis's require_css,
-- which records a stylesheet) loses its name-matched edge; one that hands its parameter on keeps it.
local WRAP = {
    ['core.php'] = P .. "function require_api( $p_api_name ) { global $g_core_path; require_once( $g_core_path . $p_api_name ); }\n"
        .. "function load_lib( $f ) { require_once( __DIR__ . '/lib/' . $f ); }\n"
        .. "function bring( $what ) { global $g_x; include_once( $g_x . $what ); }\n"
        .. "function require_css( $p_path ) { global $g_css; $g_css[$p_path] = is_array( $p_path ); }\n"
        .. "function require_wrap( $p ) { require_api( $p ); }\n"
        .. "function require_mystery( $p ) { mystery_fn( $p ); }\n"
        .. "function relay( $p ) { global $g_r; $p = 'fixed.php'; require_once( $g_r . $p ); }\n",
    ['lib/q.php'] = P,
    ['core/bug_api.php'] = P,
    ['lib/x.php'] = P,
    ['other/x.php'] = P,
    ['plugins/graph_api.php'] = P,
    ['css/status_config.php'] = P,
    ['page.php'] = P .. "require_api( 'bug_api.php' );\nload_lib( 'x.php' );\nbring( 'graph_api.php' );\n"
        .. "require_css( 'status_config.php' );\nrequire_wrap( 'bug_api.php' );\n"
        .. "require_mystery( 'bug_api.php' );\nrelay( 'q.php' );\n",
}
local function page_edges()
    local out = {}
    for _, e in ipairs(store.data.edges) do
        if e.kind == 'import' and e.from == 'page.php' then
            local l = e.at and e.at[1] and require('cartograph.at').sl(e.at[1])
            out[#out + 1] = ('%d %s %s'):format(l, e.to, tostring(e.via))
        end
    end
    table.sort(out)
    return out
end
-- (require_mystery calls a function this tree does not define: it MAY include, so its name-matched edge stays; relay
-- writes its parameter before the include, so the argument is not the path: no includer, no edge)
local WANT = { '1 core/bug_api.php path-tail', '2 lib/x.php nil', '3 plugins/graph_api.php path-tail',
    '5 core/bug_api.php loader-name', '6 core/bug_api.php loader-name' }

test('import trust: an includer is recognised by its BODY — upgraded, exact, added, withdrawn, kept (CART-2126)', function ()
    if not parser_available('php') then skip 'no php parser' end
    local root = setup(WRAP)
    eq(WANT, page_edges(), 'require_api by its body (path-tail); load_lib exact; bring added; require_css withdrawn; '
        .. 'require_wrap hands its parameter on, so its name-matched edge stays')
    -- relink runs the pass again: nothing is added twice, nothing comes back
    ts.relink(store.data)
    eq(WANT, page_edges(), 'idempotent under relink')
    vim.fn.delete(root, 'rf')
end)

test('import trust: the body derivation is the same through parallel extraction (CART-2126)', function ()
    if not parser_available('php') then skip 'no php parser' end
    local root = tree(WRAP)
    local inline = ts.extract(root)
    local done
    require('cartograph.parallel').extract(root, { workers = 2, on_done = function (d) done = d end })
    vim.wait(120000, function () return done ~= nil end, 50)
    local function sig(d)
        local t = {}
        for _, e in ipairs(d.edges) do if e.kind == 'import' then t[#t + 1] = e.from .. '>' .. e.to .. ':' .. tostring(e.via) end end
        table.sort(t)
        return t
    end
    ok(done, 'parallel finished')
    eq(sig(inline), sig(done))
    vim.fn.delete(root, 'rf')
end)

test('import trust: the body pass run twice on one graph adds nothing twice (CART-2126)', function ()
    if not parser_available('php') then skip 'no php parser' end
    local root = tree(WRAP)
    local data = ts.extract(root)
    local idx = {}
    for _, n in ipairs(data.nodes) do idx[n.id] = n end
    local cv = require('cartograph.callview').of(data)
    local before = #data.edges
    ts._wrapper_imports(data, cv, idx)
    eq(before, #data.edges, 'a second run over its own result changes nothing')
    vim.fn.delete(root, 'rf')
end)
