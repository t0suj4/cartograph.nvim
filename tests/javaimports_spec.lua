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
    return pcall(vim.treesitter.language.add, 'java')
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
