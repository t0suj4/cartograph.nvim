-- CART-0675: a java import resolves past a Maven MODULE segment, and refuses what it cannot decide.
-- ★ ACCEPTANCE ON REAL CORPORA (tools/javaimports.lua, the resolver joined against every file's own
-- `package` declaration): at the aggregator root hive 0 -> 47,804 imports resolved, hadoop 0 -> 86,935,
-- wildfly 0 -> 11,896, quarkus 0 -> 47,484, metasfresh 139,264, elasticsearch (gradle) 281,486 —
-- 0 wrong over all seven corpora.
-- Fixtures: tests/fixtures/javamono. single/, multi/ and negative/ are copies of the design corpus's
-- java-monorepo-layout arms (their comments describe the defect as it was); ownroot/ and rootcopy/
-- are ours.

local ts = require 'cartograph.providers.treesitter'
local java = require 'cartograph.spec.java'

local FIX = vim.fn.getcwd() .. '/tests/fixtures/javamono/'

local function has_java()
    return parser_available('java')
end

-- the import edges of an extraction, as `from -> to` strings
local function imports(root)
    local data = ts.extract(FIX .. root)
    local out = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'import' then out[#out + 1] = e.from .. ' -> ' .. e.to end
    end
    table.sort(out)
    return out, data
end

local function set(...)
    local s = {}
    for _, f in ipairs({ ... }) do s[f] = true end
    return s
end

test('javaimports: the module segment — single-module control 1 edge, the aggregator root 1 edge (was 0)', function ()
    if not has_java() then skip 'no java parser' end
    eq({ 'src/main/java/com/example/core/Client.java -> src/main/java/com/example/core/Registry.java' }, (imports('single')))
    eq({ 'mod_app/src/main/java/com/example/app/Client.java -> mod_core/src/main/java/com/example/core/Registry.java' },
        (imports('multi')))
end)

test('javaimports: ★ the negative arm — same FQN in two modules REFUSES, a package tail never matches, the JDK stays frontier', function ()
    if not has_java() then skip 'no java parser' end
    local got, data = imports('negative')
    eq({}, got)
    -- the vacuity guard: the extraction saw all four files, so an empty list is a refusal, not a blind walk
    local files = {}
    for _, n in ipairs(data.nodes) do if n.file then files[n.file] = true end end
    ok(files['mod_app/src/main/java/com/example/app/Client.java'] and files['mod_c/src/main/java/com/other/core/Registry.java'],
        'the importer and the tail collision were both extracted')
end)

test('javaimports: the importer\'s OWN source root decides a duplicate; a copy at the root is a candidate like any other', function ()
    if not has_java() then skip 'no java parser' end
    eq({ 'mod_a/src/java/com/x/app/UseA.java -> mod_a/src/java/com/x/util/Util.java' }, (imports('ownroot')))
    eq({}, (imports('rootcopy')))
end)

test('javaimports: an index root INSIDE a source root still resolves through the shorter suffix', function ()
    if not has_java() then skip 'no java parser' end
    eq({ 'core/Client.java -> core/Registry.java' }, (imports('single/src/main/java/com/example')))
end)

test('javaimports: resolve_import directly — the whole package path, at a directory boundary', function ()
    local files = set('a/src/main/java/com/example/core/Registry.java', 'b/src/main/java/com/other/core/Registry.java',
        'c/src/main/java/xcom/example/core/Registry2.java')
    eq('a/src/main/java/com/example/core/Registry.java', java.resolve_import('com.example.core.Registry', files, 'z/Z.java'))
    eq(nil, java.resolve_import('other.core.Registry2', files, 'z/Z.java'), 'nothing spells other/core/Registry2.java')
    -- `xcom/example/...` does not end in `/com/example/...`: the boundary is a directory, not a character
    -- (ONE such file: two would refuse as a duplicate and pass without the boundary)
    eq(nil, java.resolve_import('com.example.core.Registry2', files, 'z/Z.java'))
    eq(nil, java.resolve_import('java.util.List', files, 'z/Z.java'))
end)

-- CART-0671: an import edge carries the name it BINDS — what fabcensus's pin test and the import-bind resolution passes
-- read. Java has no aliasing: `import a.b.C;` binds C. A WILDCARD binds no name (guessing one is the fabrication the
-- oracle measures): `import static a.b.C.*;` resolves to C.java with no bind, and `import a.b.*;` names a package (no
-- edge). `import static a.b.C.m;` would bind m — it resolves to no file today
test('javaimports: an import edge binds its last segment, and a wildcard binds nothing (CART-0671)', function ()
    if not has_java() then skip 'no java parser' end
    local root = vim.fn.tempname()
    local function w(rel, t)
        vim.fn.mkdir(vim.fs.dirname(root .. '/' .. rel), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    w('src/main/java/a/b/C.java', 'package a.b;\npublic class C { public static void m() {} }\n')
    w('src/main/java/a/b/D.java', 'package a.b;\npublic class D {}\n')
    w('src/main/java/x/Main.java', 'package x;\nimport a.b.C;\nimport a.b.*;\nimport static a.b.C.m;\nimport static a.b.C.*;\n'
        .. 'class Main { void f() { C.m(); m(); } }\n')
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local byline = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'import' then byline[e.at[1].start.line] = { to = e.to, bind = e.bind or false } end
    end
    eq({ to = 'src/main/java/a/b/C.java', bind = 'C' }, byline[1], 'import a.b.C binds C')
    eq(nil, byline[2], 'import a.b.* names a package: no edge')
    ok(byline[3] == nil or byline[3].bind == 'm', 'import static a.b.C.m binds m when it resolves')
    eq({ to = 'src/main/java/a/b/C.java', bind = false }, byline[4], 'import static a.b.C.* binds nothing')
end)

-- CART-0671: what a bound CLASS reaches — its file and its supertypes' files, never what its file imports. Java's import
-- is a dependency, not a re-export (spec.import_reexports = false): the import-hop walk had sent
-- `LegacyReaderContext::indexShard` (inherited from ReaderContext) to RecoveryTarget, two imports away (25 calls on
-- elasticsearch server). A supertype is (file, name), its simple name resolved as Java does: a class merged by simple
-- name had let org.elasticsearch.script.Script reach ValuesSource's nested Script's parents
test('javaimports: a bound class reaches its supertypes (generic, record), not its imports nor a same-named class (CART-0671)', function ()
    if not has_java() then skip 'no java parser' end
    local root = vim.fn.tempname()
    local function w(rel, t)
        vim.fn.mkdir(vim.fs.dirname(root .. '/' .. rel), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    local J = 'src/main/java/'
    w(J .. 'p/b/Listener.java', 'package p.b;\npublic interface Listener<T> { default void delegate(int x) {} }\n')
    w(J .. 'p/a/Chan.java', 'package p.a;\nimport p.b.Listener;\npublic class Chan<R> implements Listener<R> { }\n')
    -- (Ver also implements Local, a same-package interface it does not import: reached by the package, through the
    -- class index of members)
    w(J .. 'p/a/Ver.java', 'package p.a;\nimport p.b.Listener;\npublic record Ver(int id) implements Listener<Ver>, Local { }\n')
    w(J .. 'p/a/Local.java', 'package p.a;\npublic interface Local { default void loc(int x) {} }\n')
    -- (Pair extends Helper, a second top-level class of ITS OWN file; a sibling file's NESTED Helper declares `twin` — the
    -- same-file class wins, as in Java: Pair's Helper is not Nest.Helper)
    w(J .. 'p/a/Pair.java', 'package p.a;\npublic class Pair extends Helper { }\nclass Helper { public void twin(int x) {} }\n')
    w(J .. 'p/a/Nest.java', 'package p.a;\npublic class Nest { static class Helper { public void twin(int x) {} } }\n')
    -- (a second sibling's nested Helper: the super pass's simple-name lookup is then a tie and stays out — CART-1964 —
    -- so the base guard alone decides: the same file's Helper is reached alone; reaching the siblings too is a tie.
    -- ⚠ A class with NO members and no supertype clause is invisible to the walk: Java type declarations are recorded
    -- nowhere — no node, no side table — so such a Helper would fall through to the package)
    w(J .. 'p/a/Nest2.java', 'package p.a;\npublic class Nest2 { static class Helper { public void twin(int x) {} } }\n')
    w(J .. 'p/q/Other.java', 'package p.q;\npublic class Other { public void delegate(int x) {} public void hop(int x) {} }\n')
    -- (Bound imports Other — a dependency: Other::hop is NOT Bound's member)
    -- (Bound has a parent of its own: the super pass's simple-name map sees two parents for `Bound` and stays out, so the
    -- base guard alone decides `b.own` — the super pass's own collision is CART-1964)
    w(J .. 'p/a/Bound.java', 'package p.a;\nimport p.q.Other;\npublic class Bound extends RealBase { Other o; }\n')
    w(J .. 'p/a/RealBase.java', 'package p.a;\npublic class RealBase { }\n')
    w(J .. 'p/z/Hopper.java', 'package p.z;\npublic class Hopper { public void hop(int x) {} }\n')
    -- (a NESTED class also named Bound, elsewhere, extends a class that declares `own`: not the bound Bound's parent)
    w(J .. 'p/n/Holder.java', 'package p.n;\npublic class Holder { public static class Bound extends Base { } }\n')
    w(J .. 'p/n/Base.java', 'package p.n;\npublic class Base { public void own(int x) {} }\n')
    w(J .. 'p/m/Mine.java', 'package p.m;\npublic class Mine { public void own(int x) {} public void loc(int x) {} public void twin(int x) {} }\n')
    w(J .. 'p/x/Use.java', 'package p.x;\nimport p.a.Chan;\nimport p.a.Ver;\nimport p.a.Bound;\nimport p.a.Pair;\n'
        .. 'class Use { void f(Chan<String> c, Ver v, Bound b, Pair p) { c.delegate(1); v.delegate(2); b.hop(3); b.own(4); v.loc(5); p.twin(6); } }\n')
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local got = {}
    local cv = require('cartograph.callview').of(data)
    for i = 1, cv.n do
        if cv.get(i, 'file') == J .. 'p/x/Use.java' then
            local r = cv.get(i, 'refused')
            got[cv.get(i, 'full')] = cv.get(i, 'to') or ('refused ' .. tostring(type(r) == 'table' and r.rule or r))
        end
    end
    eq(J .. 'p/b/Listener.java::Listener::delegate@1', got['Chan::delegate'], 'through a generic interface, a memberless class')
    eq(J .. 'p/b/Listener.java::Listener::delegate@1', got['Ver::delegate'], 'a record\'s interface')
    ok(not tostring(got['Bound::hop']):find('Other', 1, true) and not tostring(got['Bound::hop']):find('Hopper', 1, true),
        'not what Bound\'s file imports: ' .. tostring(got['Bound::hop']))
    ok(not tostring(got['Bound::own']):find('::', 1, true), 'not a same-named class\'s parent: ' .. tostring(got['Bound::own']))
    eq(J .. 'p/a/Local.java::Local::loc@1', got['Ver::loc'], 'a same-package supertype, not imported')
    eq(J .. 'p/a/Pair.java::Helper::twin@2', got['Pair::twin'], 'the same file\'s Helper, not a sibling\'s nested one')
end)
