-- CART-2123: a receiver typed through a VARIABLE of a SIMPLE nested class name. thrift's
-- `for (_Fields field : EnumSet.allOf(_Fields.class)) byName.put(field.getFieldName(), field)` in every struct's _Fields
-- enum — 574 calls on hive's metastore — was refused samefile among the file's 574 `_Fields::getFieldName`. A local's /
-- parameter's / loop variable's type is scoped at the call's own class chain, so the lexical lookup names its path; a
-- FIELD's type is scoped at the field's class and is left undecided. And a loop / catch / resource variable records its
-- QUALIFIED type (tyq) as the others do: `for (FieldMapper.Builder b : ..)` read as a bare `Builder` named the enclosing
-- MultiFields.Builder.

local ts = require 'cartograph.providers.treesitter'

local function tree(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local function call(data, file, line, callee)
    for _, c in ipairs(data.calls) do
        if c.file == file and c.line == line and c.callee == callee then return c end
    end
end

local F = table.concat({
    'package p;',                                                                            -- 0
    'public class F {',                                                                      -- 1
    '  public static class a_args {',                                                        -- 2
    '    public enum _Fields implements org.apache.thrift.TFieldIdEnum {',                   -- 3
    '      X;',                                                                              -- 4
    '      static {',                                                                        -- 5
    '        for (_Fields field : java.util.EnumSet.allOf(_Fields.class)) {',                -- 6
    '          field.getFieldName();',                                                       -- 7
    '        }',                                                                             -- 8
    '      }',                                                                               -- 9
    '      public String getFieldName() { return "x"; }',                                    -- 10
    '    }',                                                                                 -- 11
    '  }',                                                                                   -- 12
    '  public static class b_args {',                                                        -- 13
    '    public enum _Fields implements org.apache.thrift.TFieldIdEnum {',                   -- 14
    '      Y;',                                                                              -- 15
    '      public String getFieldName() { return "y"; }',                                    -- 16
    '    }',                                                                                 -- 17
    '    _Fields held;',                                                                     -- 18
    '    String h() { return held.getFieldName(); }',                                        -- 19
    '    String p(_Fields f) { return f.getFieldName(); }',                                  -- 20
    '  }',                                                                                   -- 21
    '}',
}, '\n') .. '\n'

local M = table.concat({
    'package p;',                                                                            -- 0
    'public class FieldMapper {',                                                            -- 1
    '  public abstract static class Builder { abstract Object build(Object ctx); }',         -- 2
    '  public static class MultiFields {',                                                   -- 3
    '    public static class Builder {',                                                     -- 4
    '      java.util.Map<String, FieldMapper.Builder> fieldBuilders;',                       -- 5
    '      Object build(Object main, Object ctx) {',                                         -- 6
    '        for (FieldMapper.Builder builder : fieldBuilders.values()) { builder.build(ctx); }', -- 7
    '        return null;',                                                                  -- 8
    '      }',                                                                               -- 9
    '    }',                                                                                 -- 10
    '  }',                                                                                   -- 11
    '}',
}, '\n') .. '\n'

test('java binder path: a loop variable / parameter of a simple nested class names its lexical class; a field is left undecided (CART-2123)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['F.java'] = F })
    local data = ts.extract(root); data.root = root
    local loop = call(data, 'F.java', 7, 'getFieldName')
    eq('F.a_args._Fields', loop.cpath, 'the loop variable inside a_args._Fields: its own enclosing class')
    eq('F.java::_Fields::getFieldName@10', loop.to, 'a_args._Fields.getFieldName, never b_args\'s')
    local par = call(data, 'F.java', 20, 'getFieldName')
    eq('F.b_args._Fields', par.cpath, 'a parameter in b_args: b_args._Fields')
    eq('F.java::_Fields::getFieldName@16', par.to)
    local fld = call(data, 'F.java', 19, 'getFieldName')
    eq(nil, fld.cpath, 'a FIELD\'s type is scoped at its declaring class: not decided here')
    eq(nil, fld.to, 'and the samefile refusal stands: ' .. tostring(fld.to))
    vim.fn.delete(root, 'rf')
end)

test('java binder path: a loop variable records its QUALIFIED type — FieldMapper.Builder is not the enclosing MultiFields.Builder (CART-2123)', function ()
    if not parser_available('java') then skip 'no java parser' end
    -- minimised from elasticsearch server FieldMapper.java:759
    local root = tree({ ['FieldMapper.java'] = M })
    local data = ts.extract(root); data.root = root
    local c = call(data, 'FieldMapper.java', 7, 'build')
    eq('FieldMapper.Builder', c.qcls, 'the qualified type rides as qcls')
    eq('FieldMapper.java::Builder::build@2', c.to, 'FieldMapper.Builder.build: ' .. tostring(c.to))
    vim.fn.delete(root, 'rf')
end)

test('java binder path: inside an anonymous body a variable\'s type is not undecidable — the earlier reading stands (CART-2123)', function ()
    if not parser_available('java') then skip 'no java parser' end
    -- minimised from elasticsearch server RecoveryListener.java: `listener.onRecoveryDone(..)` inside an anonymous listener
    local root = tree({ ['G.java'] = table.concat({
        'package p;',                                                                                  -- 0
        'public class G {',                                                                            -- 1
        '  interface L { void done(int a); void done(int a, int b); }',                                -- 2
        '  static L wrap(L listener) {',                                                               -- 3
        '    return new L() { public void done(int a) { listener.done(a); } public void done(int a, int b) {} };', -- 4
        '  }',                                                                                         -- 5
        '}',
    }, '\n') .. '\n' })
    local data = ts.extract(root); data.root = root
    local c = call(data, 'G.java', 4, 'done')
    eq(nil, c.cpath, 'not decided here, and not marked undecidable')
    eq('G.java::L::done@2', c.to, 'L.done(int), by its one-argument count: ' .. tostring(c.to))
    vim.fn.delete(root, 'rf')
end)
