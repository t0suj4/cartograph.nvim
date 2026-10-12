-- ENCAPSULATE-CLOSURE (discovery, CART-1664): is a record shape's field CLOSED behind its accessor — the precondition
-- for switching its PRODUCER to another representation? Closed = no deref left to reroute (encapsulate has run), no
-- risky row unanswered, and every ESCAPE (the record passed as an argument, stored, returned, indexed raw) answered
-- decide = <key>=ok (the reader on the far side goes through the accessor). Same seeds and answers as encapsulate.
local E = require 'cartograph.encapsulate'
local OA = require 'cartograph.optapply'

local function measure(store, p)
    -- (root = <dir> with no graph — the world `-` — lists the files itself: the roster needs no graph, and building one
    -- was 43 of the 62 s a closure check took on cartograph)
    local root = p.root and vim.fn.fnamemodify(p.root, ':p'):gsub('/+$', '') or (store and store.data and store.data.root)
    if not root then return { error = 'no world: pass root = <dir> (or a graph root)' } end
    local a = OA.encapsulate_args(p)
    if not (a.mod and next(a.rw)) then return { error = 'rw = suffix=accessor,… and mod = module:binding are required' } end
    a.files = {}
    if p.root then
        for _, f in ipairs(vim.fn.glob(root .. '/lua/**/*.lua', false, true)) do a.files[#a.files + 1] = f:sub(#root + 2) end
    else
        for _, f in ipairs(store.files or {}) do if f:match('%.lua$') then a.files[#a.files + 1] = f end end
    end
    table.sort(a.files)
    -- (an `ok` answer closes an escape; encapsulate's answers count too)
    local pl = (p.policy == 'auto') and E.plan_auto(root, a) or E.plan(root, a)
    return { reroute = #pl.rewrites, risky = pl.rows, escapes = pl.escapes,
        closed = #pl.rewrites == 0 and #pl.rows == 0 and #pl.escapes == 0, text = E.render(pl.escapes), decisions = pl.decisions }
end

local FILES = {
    ['lua/rng.lua'] = "local M = {}\nfunction M.mk(a, b) return { start = { line = a, char = b } } end\nreturn M\n",
    ['lua/acc.lua'] = "local M = {}\nfunction M.sl(r) return r.start.line end\nreturn M\n",
    ['lua/use.lua'] = "local R = require 'rng'\nlocal acc = require 'acc'\nlocal M = {}\nfunction M.f(a) local r = R.mk(a, 0); M.keep = r; return acc.sl(r) end\nreturn M\n",
}
local BASE = { calls = { 'mk' }, rw = { 'start.line=sl' }, mod = 'acc:acc' }

return {
    name = 'encapsulate-closure',
    kind = 'discovery',
    tags = { 'code', 'refactor' },
    summary = 'is a record shape CLOSED behind its accessor (root = <dir> with the world `-`: no graph is built, the roster lists the files itself) (the precondition for changing its representation)? no deref left to reroute, no risky row unanswered, and every ESCAPE — argument, store, return, raw index — answered decide = <key>=ok; same seeds as encapsulate (calls / fields, rw, mod, owners, decide)',
    params = { calls = 'list?', fields = 'list?', bless = 'list?', rw = 'list', mod = 'string', owners = 'list?', decide = 'list?', policy = 'string?', root = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        if v.closed then return true, 'closed: every read goes through the accessor and every escape is answered' end
        return false, ('open: %d deref(s) to reroute, %d risky row(s), %d escape(s) unanswered (decide = <key>=ok):\n%s'):format(v.reroute, #v.risky, #v.escapes, v.text)
    end,
    examples = {
        {
            name = 'a record stored into a module field ESCAPES: open, the row named; answered ok, closed',
            files = FILES,
            params = BASE,
            expect = { status = 'failed', check = function (v)
                return v.closed == false and #v.escapes >= 1 and v.text:find('lua/use.lua:', 1, true) ~= nil, vim.inspect(v.escapes)
            end },
        },
        {
            name = 'policy = auto: a file whose `.at` is ANOTHER shape (a tree position, never read as a range) is answered other, and root = <dir> needs no graph',
            files = {
                ['lua/rng.lua'] = "local M = {}\nfunction M.mk(a, b) return { start = { line = a, char = b } } end\nreturn M\n",
                ['lua/acc.lua'] = "local M = {}\nfunction M.sl(r) return r.start.line end\nreturn M\n",
                ['lua/pos.lua'] = "local M = {}\nfunction M.walk(t, keep) local p = t.at; keep[#keep + 1] = p; return #p end\nreturn M\n",
            },
            params = function (store) return { root = store.data.root, fields = { 'at' }, rw = { 'start.line=sl' }, mod = 'acc:acc', policy = 'auto' } end,
            expect = { status = 'done', check = function (v)
                local other
                for _, d in ipairs(v.decisions or {}) do if d.key == 'lua/pos.lua' and d.answer == 'other' then other = true end end
                return v.closed == true and other == true, vim.inspect(v)
            end },
        },
        {
            name = 'policy = auto FOLLOWS an argument into its callee in another file: the escape is answered followed, and the callee\'s raw read joins the roster (a deref to reroute — open until rerouted)',
            files = {
                ['lua/rng.lua'] = "local M = {}\nfunction M.mk(a) return { start = { line = a } } end\nreturn M\n",
                ['lua/acc.lua'] = "local M = {}\nfunction M.sl(r) return r.start.line end\nreturn M\n",
                ['lua/show.lua'] = "local M = {}\nfunction M.line_of(x) return x.start.line end\nreturn M\n",
                ['lua/use.lua'] = "local R = require 'rng'\nlocal S = require 'show'\nlocal M = {}\nfunction M.f(a) local r = R.mk(a); return S.line_of(r) end\nreturn M\n",
            },
            params = function (store) return { root = store.data.root, calls = { 'mk' }, rw = { 'start.line=sl' }, mod = 'acc:acc', policy = 'auto' } end,
            expect = { status = 'failed', check = function (v)
                local followed
                for _, d in ipairs(v.decisions or {}) do if d.rule == 'followed:line_of' then followed = true end end
                return followed == true and v.reroute == 1 and #v.escapes == 0, vim.inspect(v)
            end },
        },
        {
            name = 'every escape answered ok: closed',
            files = FILES,
            params = function (store)
                local a = OA.encapsulate_args(BASE)
                a.files = { 'lua/rng.lua', 'lua/acc.lua', 'lua/use.lua' }
                local keys = {}
                for _, e in ipairs(E.plan(store.data.root, a).escapes) do keys[#keys + 1] = e.key .. '=ok' end
                return vim.tbl_extend('force', BASE, { decide = keys })
            end,
            expect = { status = 'done', check = function (v) return v.closed == true, vim.inspect(v) end },
        },
    },
}
