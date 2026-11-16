-- CART-2084: discovery REPORTS a registry from call shapes; to LINK, a discovered binding's handler argument must be a
-- function by the graph's own rules — the argument's upgrade target, or an identifier its BINDER says names a function
-- (treesitter._arg_is_fn / _arg_may_name: a parameter never), or a php array callable — and always in the call's own
-- language. A discovered `answer(<fn>, <name>)` had read `agent.answer(store, 'graph_info')` as registering a function
-- named `store`, linking every caller's `store` PARAMETER to irinterp.lua's local `store`: discovery-only ref edges on
-- our tree 287 -> 3 (the 3 are a fixture's real registrations), ghost 54 -> 1 (a listener referencing itself), desynced
-- 31 unchanged (its export side is right; its 22 wrong IMPORT-side edges are the ticket's open half).

local ts, xl = require 'cartograph.providers.treesitter', require 'cartograph.xlang'

local function tree(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, t in pairs(files) do local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close() end
    return root
end
local BIND = { export = { verb = 'hook', fn = 1, name = 2 }, import = { verb = 'fire', name = 1 } }
local function refs_to(root, discovered, pat)
    local data = ts.extract(root); data.root = root
    xl.link(data, { vim.tbl_extend('force', {}, BIND, { discovered = discovered or nil }) })
    local out = {}
    for _, e in ipairs(data.edges) do if e.kind == 'ref' and e.to:match(pat) then out[#out + 1] = e.from .. ' -> ' .. e.to end end
    table.sort(out)
    return out
end

test('xdisc bar: a PARAMETER passed to a discovered registry never links to another file\'s same-named function; a declared binding still does (CART-2084)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['reg.lua'] = 'local M = {}\nlocal t = {}\nfunction M.hook(fn, key) t[key] = fn end\nfunction M.fire(key) return t[key]() end\nreturn M\n',
        ['a.lua'] = "local R = require 'reg'\nlocal function setup(store)\n  R.hook(store, 'alpha')\nend\nreturn setup\n",
        ['b.lua'] = "local R = require 'reg'\nlocal function go() return R.fire('alpha') end\nreturn go\n",
        ['c.lua'] = 'local M = {}\nfunction M.x() end\nlocal function store() return 1 end\nM.store = store\nreturn M\n' })
    eq({}, refs_to(root, true, '::store@'), 'discovered: the parameter `store` names no function')
    ok(#refs_to(root, false, '::store@') > 0, 'declared: the binding keeps its name fallback (a person vouched for it)')
    vim.fn.delete(root, 'rf')
end)

test('xdisc bar: a same-file function passed BY NAME at module scope is a real registration, and its importer links (CART-2084)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['reg.lua'] = 'local M = {}\nlocal t = {}\nfunction M.hook(fn, key) t[key] = fn end\nfunction M.fire(key) return t[key]() end\nreturn M\n',
        ['a.lua'] = "local R = require 'reg'\nlocal function on_beta() return 2 end\nR.hook(on_beta, 'beta')\nreturn {}\n",
        ['b.lua'] = "local R = require 'reg'\nlocal function go() return R.fire('beta') end\nreturn go\n" })
    local got = refs_to(root, true, '::on_beta@')
    ok(vim.tbl_contains(got, 'b.lua::go@1 -> a.lua::on_beta@1'), 'the importer reaches the registered function: ' .. vim.inspect(got))
    vim.fn.delete(root, 'rf')
end)

test('xdisc bar: a php array callable resolves only within php — never to another language\'s same-named function (CART-2084)', function ()
    if not (parser_available('php') and parser_available('lua')) then skip 'no php / lua parser' end
    local root = tree({
        ['r.php'] = '<?php\nfunction setup() {\n  hook(array("Logger", "logit"), "alpha");\n}\nfunction go() { return fire("alpha"); }\n',
        ['l.lua'] = 'local M = {}\nfunction M.y() end\nlocal function logit() return 1 end\nM.logit = logit\nreturn M\n' })
    eq({}, refs_to(root, true, '^l%.lua::logit@'), 'php\'s `logit` callable is no lua function')
    vim.fn.delete(root, 'rf')
end)
