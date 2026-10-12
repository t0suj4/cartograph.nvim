-- ENCAPSULATE (write, CART-1664): ENCAPSULATE FIELD by the shape roster — every read of a record shape's fields that
-- the roster proves (consumers.lua, seeded by the shape's PRODUCERS) is rerouted through an accessor module, so the
-- representation can change behind it. A SAFE rewrite is applied (the accessors are identity on the raw record); a
-- RISKY one — a file that OWNS the representation, a multi-line or partial chain — is a ROW the plan stops on
-- (`decision`), answered by decide = <key>=rewrite|skip. Its first use: 27 range derefs moved onto cartograph.at
-- (d153177). Whether the field is then CLOSED (every escape answered) is encapsulate-closure's question.
local T = require('cartograph.tactic').T

local FILES = {
    ['lua/rng.lua'] = "local M = {}\nfunction M.mk(a, b, c, d) return { start = { line = a, char = b }, ['end'] = { line = c, char = d } } end\nreturn M\n",
    ['lua/acc.lua'] = "local M = {}\nfunction M.sl(r) return r.start.line end\nfunction M.sc(r) return r.start.char end\nfunction M.el(r) return r['end'].line end\nfunction M.ec(r) return r['end'].char end\nreturn M\n",
    ['lua/use.lua'] = "local R = require 'rng'\nlocal M = {}\nfunction M.width(a, b)\n  local r = R.mk(a, 0, a, b)\n  return r['end'].char - r.start.char, r.start.line\nend\nreturn M\n",
    ['lua/own.lua'] = "local R = require 'rng'\nlocal M = {}\nfunction M.top(a) local r = R.mk(a, 0, a, 1); return r.start.line end\nreturn M\n",
}
local BASE = { calls = { 'mk' }, rw = { 'start.line=sl', 'start.char=sc', 'end.line=el', 'end.char=ec' }, mod = 'acc:acc', owners = { 'own%.lua$' } }
local function with(t) return vim.tbl_extend('force', vim.deepcopy(BASE), t or {}) end
-- the risky row's key in the fixture (the roster's own position of own.lua's deref)
local function own_key(root)
    local E = require 'cartograph.encapsulate'
    local a = require('cartograph.optapply').encapsulate_args(BASE)
    a.files = { 'lua/rng.lua', 'lua/acc.lua', 'lua/use.lua', 'lua/own.lua' }
    for _, r in ipairs(E.plan(root, a).rows) do if r.file == 'lua/own.lua' then return r.key end end
end

return {
    name = 'encapsulate',
    kind = 'write',
    tags = { 'code', 'refactor', 'optimize' },
    summary = 'ENCAPSULATE FIELD by the shape roster: every read of a record shape the roster proves (seeded by its producers: calls = name[=kind], fields = name | base.field) is rerouted through an accessor module (rw = suffix=accessor,…; mod = module:binding; the binding added at the top of each file); the accessors are identity on the raw record, so a safe rewrite cannot change behaviour. A RISKY rewrite (an owner of the representation — owners = patterns, default the store\'s —, a multi-line or partial chain) STOPS on a decision row: decide = <file:line:col>=rewrite|skip',
    params = { calls = 'list?', fields = 'list?', bless = 'list?', rw = 'list', mod = 'string', owners = 'list?', decide = 'list?', policy = 'string?' },
    build = function (p) return T.step('encapsulate', { calls = p.calls, fields = p.fields, bless = p.bless, rw = p.rw, mod = p.mod, owners = p.owners, decide = p.decide, policy = p.policy }) end,
    examples = {
        {
            name = 'a safe deref is rerouted (and the accessor bound at the top); an OWNER file\'s deref stops the plan on a decision — nothing is written',
            files = FILES,
            params = with(),
            expect = { status = 'stopped', applied = 0, check = function (root, r)
                local why = tostring(r and (r.why or r.error) or '')
                local use = io.open(root .. '/lua/use.lua'):read('a')
                return why:find('lua/own.lua:', 1, true) ~= nil and why:find('owner file', 1, true) ~= nil and not use:find('acc.sc', 1, true), why
            end },
        },
        {
            name = 'answered: decide = <own.lua key>=rewrite — both files read through the accessor, and the module still answers the same',
            files = FILES,
            params = function (store) return with({ decide = { own_key(store.data.root) .. '=rewrite' } }) end,
            expect = { status = 'done', applied = 1, check = function (root)
                local use = io.open(root .. '/lua/use.lua'):read('a')
                local own = io.open(root .. '/lua/own.lua'):read('a')
                local ok = use:find("local acc = require 'acc'", 1, true) and use:find('acc.ec(r) - acc.sc(r), acc.sl(r)', 1, true)
                    and own:find('return acc.sl(r)', 1, true)
                if not ok then return false, use .. '\n' .. own end
                -- (and it ANSWERS the same: width(3, 7) is 7, 3 before; load the rewritten modules and ask)
                local saved = package.path
                package.path = root .. '/lua/?.lua;' .. package.path
                for _, m in ipairs { 'rng', 'acc', 'use', 'own' } do package.loaded[m] = nil end
                local okc, w, l = pcall(function () return require('use').width(3, 7) end)
                local okt, t = pcall(function () return require('own').top(5) end)
                for _, m in ipairs { 'rng', 'acc', 'use', 'own' } do package.loaded[m] = nil end
                package.path = saved
                return okc and okt and w == 7 and l == 3 and t == 5, ('width -> %s %s, top -> %s'):format(tostring(w), tostring(l), tostring(t))
            end },
        },
        {
            name = 'policy = auto: the owner row is answered by rule (rewrite: identity on the raw record), nothing stops, and the plan says how many the policy answered',
            files = FILES,
            params = with({ policy = 'auto' }),
            expect = { status = 'done', applied = 1, check = function (root)
                local own = io.open(root .. '/lua/own.lua'):read('a')
                return own:find('return acc.sl(r)', 1, true) ~= nil, own
            end },
        },
        {
            name = 'answered skip: the owner keeps its raw read, the rest is rerouted',
            files = FILES,
            params = function (store) return with({ decide = { own_key(store.data.root) .. '=skip' } }) end,
            expect = { status = 'done', applied = 1, check = function (root)
                local own = io.open(root .. '/lua/own.lua'):read('a')
                return own:find('return r.start.line', 1, true) ~= nil, own
            end },
        },
    },
}
