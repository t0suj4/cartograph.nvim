-- NAMESPACES AS VALUES (CART-1160 step 4): mount / umount / resolve over mount points, pure — an operation returns a
-- new namespace and never edits the one it was given, so unsharing is keeping the old value. The two consumers it
-- replaced hand-rolled scans in are pinned here too: band ownership (session.owning) and the toolbelt's two roots.
local namespace = require 'cartograph.namespace'

local function targets(hit) local t = {}; for i, e in ipairs(hit and hit.layers or {}) do t[i] = e.target end; return t end

test('namespace: a mount returns a NEW value and leaves the old one as it was — unshare is keeping the old value', function ()
    local a = namespace.mount(namespace.empty(), '/w', 'one')
    local b = namespace.mount(a, '/w/sub', 'two')
    eq(1, #namespace.entries(a), 'the old namespace still has one mount')
    eq(2, #namespace.entries(b))
    eq({ 'one' }, targets(namespace.resolve(a, '/w/sub/x.lua')), 'in the old value, the outer mount still owns it')
    eq({ 'two' }, targets(namespace.resolve(b, '/w/sub/x.lua')))
    local c = namespace.umount(b, '/w/sub')
    eq(2, #namespace.entries(b), 'umount is a value too'); eq({ 'one' }, targets(namespace.resolve(c, '/w/sub/x.lua')))
end)

test('namespace: the LONGEST point wins whatever the mount order, and containment is by path segment', function ()
    local inner_first = namespace.mount(namespace.mount(namespace.empty(), '/a/b', 'inner'), '/a', 'outer')
    local outer_first = namespace.mount(namespace.mount(namespace.empty(), '/a', 'outer'), '/a/b', 'inner')
    for _, ns in ipairs { inner_first, outer_first } do
        local hit = namespace.resolve(ns, '/a/b/c/d.lua')
        eq({ 'inner' }, targets(hit)); eq('/a/b', hit.point); eq('c/d.lua', hit.rest)
        eq({ 'outer' }, targets(namespace.resolve(ns, '/a/bc/d.lua')), '/a/bc is not under /a/b')
        eq('', namespace.resolve(ns, '/a/b').rest, 'the point itself is contained, with an empty rest')
    end
    local miss, why, class = namespace.resolve(inner_first, '/elsewhere/x')
    eq(nil, miss); eq('frontier', class); ok(why:find('nothing is mounted', 1, true), why)
    eq({ 'root' }, targets(namespace.resolve(namespace.mount(namespace.empty(), '/', 'root'), '/any/where')), '/ holds everything')
end)

test('namespace: a plain mount HIDES what was at its point until umount reveals it; a UNION joins before or after', function ()
    local ns = namespace.mount(namespace.mount(namespace.empty(), 'p', 'low'), 'p', 'high')
    eq({ 'high' }, targets(namespace.resolve(ns, 'p/x')), 'the newer plain mount hides the older one')
    eq({ 'low' }, targets(namespace.resolve(namespace.umount(ns, 'p', 'high'), 'p/x')), 'and umount of it reveals it')
    local u = namespace.mount(namespace.empty(), 'p', 'base')
    u = namespace.mount(u, 'p', 'after', { union = 'after' })
    u = namespace.mount(u, 'p', 'before', { union = 'before' })
    eq({ 'before', 'base', 'after' }, targets(namespace.resolve(u, 'p/x')), 'every layer, in precedence order')
    eq({ 'hide' }, targets(namespace.resolve(namespace.mount(u, 'p', 'hide'), 'p/x')), 'a plain mount over a union hides all of it')
    local _, why, class = namespace.mount(u, 'p', 'x', { union = 'sideways' })
    eq('ill-posed', class); ok(why:find('sideways', 1, true))
    local _, _, nclass = namespace.mount(u, 'p', nil)
    eq('ill-posed', nclass, 'a mount needs a target')
end)

test('session: band ownership is namespace.resolve — innermost root, and a held namespace is a snapshot', function ()
    local session = require 'cartograph.session'
    local store = require 'cartograph.store'
    local saved = { bands = session.bands, active = session.active, crossings = session.crossings, ns = session.ns, lens = store.capture() }
    session.reset()
    session.begin('/tmp/nsroot', 'project')
    session.begin('/tmp/nsroot/inner', 'project')
    eq('inner', session.owning('/tmp/nsroot/inner/a.lua'))
    eq('nsroot', session.owning('/tmp/nsroot/other/a.lua'))
    eq('nsroot', session.owning('/tmp/nsroot/innerx/a.lua'), 'a sibling that shares a prefix is not inside it')
    local held = session.ns
    session.close('inner')
    eq('nsroot', session.owning('/tmp/nsroot/inner/a.lua'), 'closed: the outer root owns it again')
    eq({ 'inner' }, targets(namespace.resolve(held, '/tmp/nsroot/inner/a.lua')), 'the value held before the close is unchanged')
    session.bands, session.active, session.crossings, session.ns = saved.bands, saved.active, saved.crossings, saved.ns
    store.restore(saved.lens)
end)

test('toolbelt: the two tactic roots are two MOUNTS — the built-in first, the project unioned after it', function ()
    local tb = require 'cartograph.toolbelt'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/.cartograph/tactics', 'p')
    local hit = namespace.resolve(tb.namespace(nil, root), 'tactics')
    eq(2, #hit.layers)
    eq('built-in', hit.layers[1].target.scope); eq(tb.builtin_dir(), hit.layers[1].target.dir)
    eq('project', hit.layers[2].target.scope); eq(tb.project_dir(root), hit.layers[2].target.dir)
    eq(1, #namespace.resolve(tb.namespace(nil, vim.fn.tempname()), 'tactics').layers, 'no project directory, no second mount')
    eq('given', namespace.resolve(tb.namespace('/some/dir'), 'tactics').layers[1].target.scope)
end)
