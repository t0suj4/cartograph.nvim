-- JS/TS import BINDS: the local name an import introduces.
--
-- Lua's spec captured this from the start; js/ts never did, so `resolve_module_alias`
-- (BINDING beats corpus name-match) could not fire for JavaScript at all, and a call
-- through an imported name into an OPAQUE BUNDLE was disposed `external` — a
-- project-boundary claim about a file we merely never parsed.
--
-- MEASURED on ghost after this landed: 3278 import edges now carry a bind (was 0),
-- and 386 previously-ambiguous calls resolve — all `refused (ambiguous) => to
-- <target>`, zero regressions.
--
-- THE BUNDLE CASE WAS A MIS-MODEL, since measured across ghost/grocy/sylius/jquery/
-- mootools/desynced: ZERO edges of any kind point at an unparsed file. Ghost's three
-- are `admin-auth.min.js` and two built theme assets, named as served PATHS by
-- serve-public-file.js / ghost_head.js / card-assets.js. A bundle is an OUTPUT
-- ARTIFACT shipped to a browser, so nothing imports it. The fixture below still
-- earns its place — it pins that IF a bundle is imported the disposition is right —
-- but the case that actually occurs is an UNAVAILABLE read of a file genuinely in
-- the graph, which ecosystem_spec drives on a corrupt archive member.

local ts = require 'cartograph.providers.treesitter'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'javascript')
end

local function build(files)
    local root = vim.fn.tempname()
    for rel, text in pairs(files) do
        local dir = rel:match('^(.*)/[^/]*$')
        vim.fn.mkdir(root .. (dir and '/' .. dir or ''), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end

local function imports_of(data)
    local out = {}
    for _, e in ipairs(data.edges or {}) do
        if e.kind == 'import' then
            out[#out + 1] = { to = e.to, bind = e.bind, from = e.from }
        end
    end
    table.sort(out, function (a, b)
        if a.to ~= b.to then return a.to < b.to end
        return tostring(a.bind) < tostring(b.bind)
    end)
    return out
end

test('js imports: every SINGLE-bind form binds its local name', function ()
    if not ready() then skip 'no javascript parser' end
    local root = build {
        ['a.js'] = 'export default function helper(x) { return x + 1 }\n',
        ['b.js'] = 'export function two() { return 2 }\n',
        ['main.js'] = "import def from './a';\n"
            .. "import * as ns from './b';\n"
            .. "const cjs = require('./a');\n"
            .. "require('./b');\n"
            .. 'export function run() { return def(1) + ns.two() + cjs(2) }\n',
    }
    local imps = imports_of(ts.extract(root))
    local binds = {}
    for _, i in ipairs(imps) do binds[#binds + 1] = tostring(i.bind) end
    table.sort(binds)
    -- default, namespace, CJS declaration; the BARE require binds nothing
    eq({ 'cjs', 'def', 'nil', 'ns' }, binds)
    vim.fn.delete(root, 'rf')
end)

-- ONE EDGE PER SITE. Several query patterns match one import (a namespace import
-- also matches the general form; a CJS require matches both its declaration and the
-- bare call), so without deduping on the @path node every JS corpus gate would move
-- on edge counts alone.
test('js imports: several matching patterns still yield ONE edge per site',
    function ()
    if not ready() then skip 'no javascript parser' end
    local root = build {
        ['t.js'] = 'export function x() { return 1 }\n',
        ['m.js'] = "import * as ns from './t';\nconst c = require('./t');\n"
            .. 'export function go() { return ns.x() + c.x() }\n',
    }
    local imps = imports_of(ts.extract(root))
    eq(2, #imps) -- exactly two import SITES, not four matches
    local binds = {}
    for _, i in ipairs(imps) do binds[#binds + 1] = tostring(i.bind) end
    table.sort(binds)
    eq({ 'c', 'ns' }, binds)
    vim.fn.delete(root, 'rf')
end)

-- NAMED imports bind several names to one edge, and an edge carries one `bind`. They
-- are left uncaptured rather than represented wrongly — a stated gap, so this test
-- pins the CURRENT honest behaviour and will fail loudly if someone half-fixes it.
test('js imports: NAMED imports are a documented gap, not a wrong answer',
    function ()
    if not ready() then skip 'no javascript parser' end
    local root = build {
        ['t.js'] = 'export function one() { return 1 }\nexport function two() { return 2 }\n',
        ['m.js'] = "import { one, two } from './t';\n"
            .. 'export function go() { return one() + two() }\n',
    }
    local imps = imports_of(ts.extract(root))
    eq(1, #imps)          -- the edge exists: the dependency is real
    eq(nil, imps[1].bind) -- ... with no bind, rather than an arbitrary one of two
    vim.fn.delete(root, 'rf')
end)

-- THE WIN this unlocked, and the reason it is worth 386 resolutions on ghost: a
-- BINDING beats a corpus name-match. `svc.init()` where svc is imported resolves to
-- THAT module's init, not to one of the many other `init` methods around.
test('js imports: a bound receiver resolves to the imported module own def',
    function ()
    if not ready() then skip 'no javascript parser' end
    local root = build {
        ['svc/index.js'] = 'class Wrapper { init() { return 1 } }\n'
            .. 'module.exports = new Wrapper()\n',
        ['other.js'] = 'class Decoy { init() { return 2 } }\n'
            .. 'module.exports = new Decoy()\n',
        ['boot.js'] = "const svc = require('./svc');\n"
            .. 'export function boot() { return svc.init() }\n',
    }
    local data = ts.extract(root)
    local call
    for _, c in ipairs(data.calls or {}) do
        if c.callee == 'init' and c.file == 'boot.js' then call = c end
    end
    ok(call ~= nil, 'the call is recorded')
    -- ambiguous by NAME (two init methods), decided by the BINDING
    ok(tostring(call.to):match('^svc/index%.js') ~= nil,
        'resolved into the bound module, not the decoy: ' .. tostring(call.to))
    vim.fn.delete(root, 'rf')
end)

-- THE MOTIVATING CASE. A bundle is a known file we deliberately never parse, so a
-- call through a name bound to it is a FRONTIER, not the project boundary. Two
-- things had to change for this: the bundle became resolvable as an import target
-- (it is a real file, but it was absent from the import fileset, so the edge simply
-- vanished), and the unparsed roster had to be THREADED into the resolution pipeline
-- — extract mints frontier module nodes AFTER the passes run, so deriving the set
-- from the graph saw nothing.
test('js imports: a call into an opaque BUNDLE is a frontier, not the boundary',
    function ()
    if not ready() then skip 'no javascript parser' end
    local root = build {
        ['vendor.min.js'] = 'var a=1;function b(){return 2}\n',
        ['main.js'] = "import lib from './vendor.min.js';\n"
            .. 'export function run() { return lib.doThing(1) }\n',
    }
    local data = ts.extract(root)
    -- the bundle is a known frontier
    local roster = {}
    for _, f in ipairs(data.unparsed or {}) do roster[f] = true end
    eq(true, roster['vendor.min.js'])
    -- the import edge points at it, with the bind
    local imps = imports_of(data)
    eq(1, #imps); eq('vendor.min.js', imps[1].to); eq('lib', imps[1].bind)
    -- and the call through that name is disposed FRONTIER
    local call
    for _, c in ipairs(data.calls or {}) do
        if c.callee == 'doThing' then call = c end
    end
    ok(call ~= nil, 'the call is recorded')
    eq(nil, call.to)                            -- unresolved: never parsed
    eq('frontier', call.ext and call.ext.disp)  -- ... but NOT external
    eq('unread-file', call.ext and call.ext.why)
    -- the user-visible surface agrees: it leaves the external boundary
    local store = require 'cartograph.store'
    store.ingest(data)
    local surface = require('cartograph.externals').surface(store)
    eq(1, surface.unread)
    vim.fn.delete(root, 'rf')
end)
