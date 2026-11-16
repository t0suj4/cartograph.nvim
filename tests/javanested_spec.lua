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
