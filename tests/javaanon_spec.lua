-- CART-2124: a method declared inside an ANONYMOUS class body or an enum-constant body is keyed to the named class
-- around it (`Outer::execute`), so the name joins resolved calls from anywhere onto it: 1,258 calls on elasticsearch
-- server, e.g. `masterClient().execute(..)` landing on an anonymous ClusterStateUpdateTask's execute. An anonymous
-- class's members are named only from INSIDE its body: such a member stays in the name indexes (for a receiver of
-- unknown type it is a possible runtime target, and keeps the join ambiguous), but it is never the resolved target of
-- a call outside its body; a call inside takes the member of the innermost body around it that declares the name.

local ts = require 'cartograph.providers.treesitter'

local function tree(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local function call(data, file, line, key)
    for _, c in ipairs(data.calls) do
        if c.file == file and c.line == line and (c.full or c.callee) == key then return c end
    end
end

local A = table.concat({
    'package p;',                                                                                         -- 0
    'public class A {',                                                                                   -- 1
    '  Object t() { return new Task() { int onlyAnon() { return 1; } int helper(int s) { return s; }',    -- 2
    '    int go() { return helper(1) + onlyAnon(); } }; }',                                               -- 3
    '  int run() { return onlyAnon(); }',                                                                 -- 4
    '  int helper(int s) { return 0; }',                                                                  -- 5
    '  Object u() { return new Task() { int v(int a) { return a; } int v(String b) { return 0; }',        -- 6
    '    int w() { return v(1); } }; }',                                                                  -- 7
    '  enum E { X { int k() { return hh(); } int hh() { return 1; } }, Y; int k() { return 0; } int z() { return k(); } }', -- 8
    '}',
}, '\n') .. '\n'

local function check(data, how)
    local anon_helper, anon_only
    for _, n in ipairs(data.nodes) do
        if n.id == 'A.java::A::helper@2' then anon_helper = n end
        if n.id == 'A.java::A::onlyAnon@2' then anon_only = n end
    end
    ok(anon_helper and anon_helper.cpath == '' and anon_helper.abody, how .. ': the anonymous member carries its body')
    local c = call(data, 'A.java', 4, 'A::onlyAnon')
    eq(nil, c.to, how .. ': run() is outside the body — onlyAnon is no member of A: ' .. tostring(c.to))
    eq('blocked', c.refused and c.refused.rule, how)
    eq(anon_helper.id, call(data, 'A.java', 3, 'A::helper').to, how .. ': inside, the body\'s own helper shadows A.helper')
    eq(anon_only.id, call(data, 'A.java', 3, 'A::onlyAnon').to, how .. ': inside, its own onlyAnon')
    local v = call(data, 'A.java', 7, 'A::v')
    eq(nil, v.to, how .. ': two v in the body: overloads, refused')
    local ek = call(data, 'A.java', 8, 'E::k')
    local ekn
    for _, n in ipairs(data.nodes) do if n.name == 'E::k' and n.cpath == 'A.E' then ekn = n end end
    eq(ekn and ekn.id, ek and ek.to, how .. ': k() in E reaches E.k, never constant X\'s override')
    local hh = call(data, 'A.java', 8, 'E::hh')
    ok(hh and hh.to and hh.to:match('::E::hh@8'), how .. ': inside constant X\'s body, its own hh: ' .. tostring(hh and hh.to))
end

test('java anon: an anonymous body\'s member is reached only from inside it; inside, it shadows the outer class (CART-2124)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['A.java'] = A })
    local data = ts.extract(root); data.root = root
    check(data, 'extract')
    for _, c in ipairs(data.calls) do c.to = nil; c.refused = nil; c.prov = nil end
    ts.relink(data)
    check(data, 'relink')
    local config = require 'cartograph.config'
    local was = config.federated_resolve
    config.federated_resolve = true
    for _, c in ipairs(data.calls) do c.to = nil; c.refused = nil; c.prov = nil end
    local okr, err = pcall(ts.relink, data)
    config.federated_resolve = was
    assert(okr, err)
    check(data, 'federated relink')
    vim.fn.delete(root, 'rf')
end)

test('java anon: no later pass resolves a call onto an anonymous member from another file (CART-2124)', function ()
    if not parser_available('java') then skip 'no java parser' end
    -- minimised from elasticsearch server MissingValues.java -> ValuesSource.java's anonymous Numeric
    local root = tree({
        ['VS.java'] = 'package p;\npublic class VS {\n  int bytesValues() { return 0; }\n  public static class Numeric extends VS {\n'
            .. '    static Numeric make() { return new Numeric() { int bytesValues() { return 1; } }; }\n  }\n}\n',
        ['MV.java'] = 'package p;\nclass MV { int f(VS.Numeric n) { return n.bytesValues(); } }\n',
    })
    local data = ts.extract(root); data.root = root
    local anon
    for _, n in ipairs(data.nodes) do if n.cpath == '' and n.name:match('::bytesValues$') then anon = n end end
    ok(anon, 'the anonymous member')
    for _, c in ipairs(data.calls) do
        ok(c.to ~= anon.id, ('%s:%d %s reached the anonymous member'):format(c.file, c.line, tostring(c.full)))
    end
    for _, e in ipairs(data.edges) do
        ok(not (e.to == anon.id and e.from:match('^MV%.java')), 'no reference edge from MV.java to it')
    end
    for _, c in ipairs(data.calls) do c.to = nil; c.refused = nil; c.prov = nil end
    ts.relink(data)
    for _, c in ipairs(data.calls) do
        ok(c.to ~= anon.id, ('relink: %s:%d %s reached the anonymous member'):format(c.file, c.line, tostring(c.full)))
    end
    vim.fn.delete(root, 'rf')
end)

test('java anon: the pass veto refuses a call a later pass resolved onto an anonymous member, and adds no edge (CART-2124)', function ()
    -- the RESOLVE_PASSES driver itself, with a pass that lands a call on an anonymous member from outside its body
    local anon = { id = 'X.java::X::m@3', name = 'X::m', file = 'X.java', cpath = '', abody = { 2, 10, 5, 3 } }
    local rows = { { file = 'Y.java', line = 1, full = 'X::m', fn = 'Y.java::Y::f@1',
        at = { start = { line = 1, char = 4 }, ['end'] = { line = 1, char = 5 } } } }
    local refs = {}
    local data = { calls = rows, edges = {}, nodes = { anon } }
    local ctx = { data = data, node_index = { [anon.id] = anon }, exact = {}, tail = {},
        addref = function (from, to) refs[#refs + 1] = from .. '>' .. to end }
    local passes = ts.RESOLVE_PASSES
    local saved = {}
    for i, p in ipairs(passes) do saved[i] = p end
    for i = #passes, 1, -1 do passes[i] = nil end
    passes[1] = { name = 'probe', run = function (x)
        x.cv.set(1, 'to', anon.id); x.addref('Y.java::Y::f@1', anon.id, rows[1].at, false); return 1 end }
    local okr, err = pcall(ts._run_resolve_passes, ctx)
    for i = #passes, 1, -1 do passes[i] = nil end
    for i, p in ipairs(saved) do passes[i] = p end
    assert(okr, err)
    eq(nil, rows[1].to, 'refused')
    eq('blocked', rows[1].refused and rows[1].refused.rule)
    eq({}, refs, 'the reference was not added')
end)
