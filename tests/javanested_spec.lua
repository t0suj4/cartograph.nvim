-- CART-1963: java receiver typing keyed a NESTED class by its outer name and an untyped lambda parameter by the field
-- it shadows. Three causes, one per case:
--   · `Outer.Inner<K, V>` (a nested GENERIC) had no base type, so the binder was untyped and the lookup walked out to
--     an outer same-named binder: IndexMetadata.Builder's `ImmutableOpenMap.Builder<…> rolloverInfos` keyed by the
--     outer class's `ImmutableOpenMap rolloverInfos`; `FieldMapper.Parameter<Script> script` by Script.
--   · a nested type keyed by its simple name `Builder` landed on the CALLER's own nested Builder (the same-file tier):
--     the written qualifier now rides the call (qcls) and the target must live in the outer class's file when the tree
--     has one (spec.nested_file) — a target in the caller's file is vetoed, the outer file's one picked.
--   · `(handlers, ignored) -> handlers.addMethod(…)`: an untyped lambda parameter now BINDS its name, with no type.
-- `Map.Entry<K, V>` keys as the JDK's (`Map.Entry::m`, external), never a project class named Entry.
-- elasticsearch/server (batched): 253 calls resolved, 32 retargeted from the caller's own Builder to the outer class's,
-- 67 withdrawn (Map.Entry / Writeable.Reader joined by name to project methods).

local ts = require 'cartograph.providers.treesitter'

local function graph()
    local root = vim.fn.tempname(); vim.fn.mkdir(root .. '/p', 'p')
    local function w(f, t) local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(t); fd:close() end
    w('p/ImmutableOpenMap.java', 'package p;\npublic class ImmutableOpenMap<K, V> {\n  public static class Builder<K, V> {\n    public Builder<K, V> putAllFromMap(java.util.Map<K, V> m) { return this; }\n  }\n  public void putAllFromMap(java.util.Map<K, V> m) {}\n}\n')
    w('p/FieldMapper.java', 'package p;\npublic class FieldMapper {\n  public static class Parameter<T> { public boolean isConfigured() { return true; } }\n}\n')
    w('p/Script.java', 'package p;\npublic class Script { public boolean isConfigured() { return false; } }\n')
    w('p/PathTrie.java', 'package p;\npublic class PathTrie<T> { public void insertOrUpdate(String p, T v, java.util.function.BiFunction<T, T, T> f) {} public void each(java.util.function.Consumer<T> c) {} public void addMethod(String m) {} }\n')
    w('p/MethodHandlers.java', 'package p;\npublic class MethodHandlers { public MethodHandlers addMethod(String m) { return this; } }\n')
    w('p/Entry.java', 'package p;\npublic class Entry { public String getKey() { return "k"; } }\n')
    w('p/Use.java', table.concat({
        'package p;',
        'public class Use {',
        '  public static class Builder { public Builder putAllFromMap(java.util.Map<String, String> m) { return this; } }',
        '  private final FieldMapper.Parameter<Script> script = null;',
        '  private final ImmutableOpenMap.Builder<String, String> infos = null;',
        '  private final PathTrie<MethodHandlers> handlers = new PathTrie<>();',
        '  void a(java.util.Map<String, String> src, java.util.Map.Entry<String, String> e) {',
        '    this.infos.putAllFromMap(src);',                                                         -- 7
        '    boolean c = script.isConfigured();',                                                     -- 8
        '    handlers.insertOrUpdate("x", null, (handlers, ignored) -> handlers.addMethod("GET"));', -- 9
        '    String k = e.getKey();',                                                                 -- 10
        '    handlers.each(handlers -> handlers.addMethod("PUT"));',                                   -- 11: the one-parameter form
        '  }',
        '}', '' }, '\n'))
    return ts.extract(root)
end
local function at(d, line, callee)
    for _, c in ipairs(d.calls) do if c.file == 'p/Use.java' and c.line == line and c.callee == callee then return c end end
end

test('java nested types: Outer.Inner<…> is Inner, and it is the OUTER class\'s Inner — not the caller\'s own (CART-1963)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local d = graph()
    eq('p/ImmutableOpenMap.java::Builder::putAllFromMap@3', at(d, 7, 'putAllFromMap').to, 'not Use.Builder, not ImmutableOpenMap')
    eq('p/FieldMapper.java::Parameter::isConfigured@2', at(d, 8, 'isConfigured').to, 'the raw type, not the type argument')
end)

test('java lambdas: an untyped lambda parameter binds its name — no type borrowed from the field it shadows (CART-1963)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local d = graph()
    for _, line in ipairs { 9, 11 } do
        local c = at(d, line, 'addMethod')
        ok(c.full == nil or not c.full:match('^PathTrie::'), 'line ' .. line .. ' not keyed by the field\'s type: ' .. tostring(c.full))
        ok(c.to ~= 'p/PathTrie.java::PathTrie::addMethod@1', tostring(c.to))
    end
end)

test('java Map.Entry<K, V> is the JDK\'s: never a project class named Entry (CART-1963)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local c = at(graph(), 10, 'getKey')
    eq('Map.Entry::getKey', c.full)
    eq(nil, c.to)
end)

test('java super: a class is (file, name) — an imported p.a.Bound never reaches the parent of another Bound (CART-1964)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = vim.fn.tempname()
    for _, dir in ipairs { 'p/a', 'p/n', 'p/x' } do vim.fn.mkdir(root .. '/' .. dir, 'p') end
    local function w(f, t) local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(t); fd:close() end
    w('p/a/Bound.java', 'package p.a;\npublic class Bound { }\n')
    w('p/n/Base.java', 'package p.n;\npublic class Base { public int own(int x) { return x; } }\n')
    w('p/n/Holder.java', 'package p.n;\npublic class Holder {\n  public static class Bound extends Base { int run() { return own(1); } }\n}\n')
    w('p/n/Other.java', 'package p.n;\npublic class Other { public int own(int x) { return 0; } }\n')
    w('p/x/Use.java', 'package p.x;\nimport p.a.Bound;\npublic class Use {\n  int go(Bound b) { return b.own(4); }\n}\n')
    local d = ts.extract(root)
    local use, inner
    for _, c in ipairs(d.calls) do
        if c.file == 'p/x/Use.java' and c.callee == 'own' then use = c end
        if c.file == 'p/n/Holder.java' and c.callee == 'own' then inner = c end
    end
    eq(nil, use.to, 'p.a.Bound has no parent: ' .. tostring(use.to))
    eq('p/n/Base.java::Base::own@1', inner.to, 'Holder.Bound\'s own() is still its parent\'s')
    vim.fn.delete(root, 'rf')
end)

test('java super: a nested class extending a SAME-NAMED nested class (Builder extends FieldMapper.Builder) inherits through it (CART-2080)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root .. '/p', 'p')
    local function w(f, t) local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(t); fd:close() end
    w('p/FieldMapper.java', 'package p;\npublic class FieldMapper {\n  int base() { return 0; }\n  public static class Builder {\n    public int init() { return 1; }\n    public int write() { return 2; }\n  }\n}\n')
    w('p/Other.java', 'package p;\npublic class Other {\n  public static class Builder { public int init() { return 2; } public int write() { return 3; } }\n}\n')
    w('p/MyMapper.java', table.concat({
        'package p;',
        'public class MyMapper {',
        '  public static class Builder extends FieldMapper.Builder {',
        '    int go() { return init(); }',                    -- 3: inherited through the same-named parent
        '    public int write() { return super.write(); }',  -- 4: super.write() is NOT this write()
        '  }',
        '}', '' }, '\n'))
    local d = ts.extract(root)
    local row
    for _, e in ipairs(d.extends or {}) do if e.file == 'p/MyMapper.java' then row = e end end
    eq({ 'Builder', 'Builder', 'FieldMapper.Builder' }, { row.child, row.parent, row.written }, 'the clause is a row now')
    local function at2(line, callee) for _, c in ipairs(d.calls) do if c.file == 'p/MyMapper.java' and c.line == line and c.callee == callee then return c end end end
    eq('p/FieldMapper.java::Builder::init@4', at2(3, 'init').to)
    ok(at2(4, 'write').to ~= 'p/MyMapper.java::Builder::write@4', 'super.write() never resolves to the child itself: ' .. tostring(at2(4, 'write').to))
    vim.fn.delete(root, 'rf')
end)

test('java supertypes from OUTSIDE the tree: a JDK-imported one and a library one are marked external (CART-2079)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = vim.fn.tempname()
    for _, dir in ipairs { 'p', 'q' } do vim.fn.mkdir(root .. '/' .. dir, 'p') end
    local function w(f, t) local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(t); fd:close() end
    w('p/Entry.java', 'package p;\npublic interface Entry { String getKey(); }\n')
    w('p/Builder.java', 'package p;\npublic class Builder { public int flush() { return 1; } }\n')
    w('q/E.java', 'package q;\nimport java.util.Map.Entry;\npublic class E implements Entry<String, String> { public String getKey() { return "e"; } }\n')
    w('q/MyLayout.java', 'package q;\nimport org.apache.logging.log4j.core.layout.AbstractStringLayout;\npublic class MyLayout extends AbstractStringLayout.Builder { }\n')
    w('q/Out.java', 'package q;\nimport java.io.ByteArrayOutputStream;\npublic class Out extends ByteArrayOutputStream {\n  public void write(int b) { super.write(b); }\n}\n')
    -- (a LIBRARY superclass is no project class: super.visitField() was keyed ClassVisitor::visitField, the gate let the
    -- tail join through, and it resolved to the caller's own override — 184 such on elasticsearch server)
    w('q/Vis.java', 'package q;\nimport org.objectweb.asm.ClassVisitor;\npublic class Vis extends ClassVisitor {\n  public void visitField() { super.visitField(); }\n}\n')
    local d = ts.extract(root)
    local impl, ext = {}, {}
    for _, e in ipairs(d.implements or {}) do impl[e.child] = e end
    for _, e in ipairs(d.extends or {}) do ext[e.child] = e end
    eq(true, impl.E and impl.E.ext, 'java.util.Map.Entry keeps its row, marked external: not the project\'s Entry')
    eq(true, ext.MyLayout and ext.MyLayout.ext, 'log4j\'s AbstractStringLayout.Builder binds into no file: external')
    local sup
    for _, c in ipairs(d.calls) do if c.file == 'q/Out.java' and c.callee == 'write' then sup = c end end
    eq('java.io.ByteArrayOutputStream::write', sup.full, 'super.write() keeps keying the JDK class')
    eq(nil, sup.to, 'never Out::write itself')
    local vf
    for _, c in ipairs(d.calls) do if c.file == 'q/Vis.java' and c.callee == 'visitField' then vf = c end end
    eq(nil, vf.to, 'super.visitField() on a library superclass never resolves to the override itself: ' .. tostring(vf.to))
    vim.fn.delete(root, 'rf')
end)
