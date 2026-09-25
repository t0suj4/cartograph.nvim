-- CART-1051: the Maven build layer — a POM as a dialect of XML data.
-- ★ MEASURED ON wildfly / quarkus / hive / hadoop (2,389 POMs, 0 refused; tools/pomtree.lua): every
-- reference resolves or names its class. What the corpora found is pinned here — an EMPTY element
-- that erased the inherited properties (hadoop), the `late` class plugin configuration needs, and
-- a file walk that dropped wildfly's `build/` and `dist/` modules as if they were vendored code.

local P = require 'cartograph.pom'

local function ready()
    if not parser_available('xml') then skip('no xml tree-sitter parser') end
end

-- a tree from a { [rel] = src } map; `exists` answers file activation from the same map
local function tree(files, extra)
    local names = {}
    for k in pairs(files) do names[#names + 1] = k end
    table.sort(names)
    local model = P.read('/nonexistent', names, { read = function(r) return files[r] end })
    model.exists = function(rel) return files[rel] ~= nil or (extra and extra[rel]) or false end
    return model
end

local function pom(body) return '<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion>' .. body .. '</project>' end
local PARENT = pom([[<groupId>g</groupId><artifactId>parent</artifactId><version>1</version><packaging>pom</packaging>
  <modules><module>a</module></modules>
  <properties><x>parent-x</x><y>parent-y</y></properties>
  <dependencies><dependency><groupId>d</groupId><artifactId>shared</artifactId><version>1</version></dependency>
    <dependency><groupId>d</groupId><artifactId>only-parent</artifactId><version>1</version></dependency></dependencies>]])
local CHILD = pom([[<parent><groupId>g</groupId><artifactId>parent</artifactId><version>1</version></parent>
  <artifactId>a</artifactId>
  <properties><x>child-x</x></properties>
  <dependencies><dependency><groupId>d</groupId><artifactId>mine</artifactId><version>2</version></dependency>
    <dependency><groupId>d</groupId><artifactId>shared</artifactId><version>9</version></dependency></dependencies>]])

test('pom: ★ INHERITANCE — groupId/version from <parent>; artifactId, packaging, modules NOT inherited; properties by key', function ()
    ready()
    local m = tree { ['pom.xml'] = PARENT, ['a/pom.xml'] = CHILD }
    eq('pom.xml', m.poms['a/pom.xml'].parent)
    eq('relativePath', m.poms['a/pom.xml'].parent_via) -- the default ../pom.xml
    local e = assert(P.effective(m, 'a/pom.xml'))
    eq('g', e.coords.g); eq('1', e.coords.v); eq('a', e.coords.a)
    eq('jar', e.coords.packaging)                     -- the parent's `pom` is not inherited
    eq(nil, P._get(e.model, 'modules'))
    eq('child-x', P._get(P._get(e.model, 'properties'), 'x'))
    eq('parent-y', P._get(P._get(e.model, 'properties'), 'y'))
end)

test('pom: dependencies merge BY KEY — the child\'s first and winning, then the parent\'s extras', function ()
    ready()
    local m = tree { ['pom.xml'] = PARENT, ['a/pom.xml'] = CHILD }
    local e = assert(P.effective(m, 'a/pom.xml'))
    local got = {}
    for _, d in ipairs(e.deps) do got[#got + 1] = d.a .. '@' .. d.v end
    eq('mine@2,shared@9,only-parent@1', table.concat(got, ','))
end)

test('pom: parent lookup — relativePath checked against the coordinates, else the reactor, else a FRONTIER', function ()
    ready()
    local m = tree {
        ['pom.xml'] = pom('<groupId>g</groupId><artifactId>root</artifactId><version>1</version>'),
        ['p/pom.xml'] = pom('<groupId>g</groupId><artifactId>parent</artifactId><version>1</version>'),
        -- ../pom.xml is `root`, not `parent`: Maven skips it and finds `parent` in the reactor
        ['p/a/pom.xml'] = pom('<parent><groupId>g</groupId><artifactId>parent</artifactId><version>1</version><relativePath>../../pom.xml</relativePath></parent><artifactId>a</artifactId>'),
        ['x/pom.xml'] = pom('<parent><groupId>org.jboss</groupId><artifactId>jboss-parent</artifactId><version>51</version><relativePath/></parent><artifactId>x</artifactId>'),
    }
    eq('p/pom.xml', m.poms['p/a/pom.xml'].parent)
    eq('reactor', m.poms['p/a/pom.xml'].parent_via)
    eq('pom.xml', m.poms['p/a/pom.xml'].parent_mismatch)
    eq(nil, m.poms['x/pom.xml'].parent)
    eq('org.jboss:jboss-parent:51', m.poms['x/pom.xml'].frontier)
end)

test('pom: ★ an EMPTY element contributes nothing — a whitespace-only <properties> does not erase the lineage (hadoop)', function ()
    ready()
    local m = tree { ['pom.xml'] = PARENT,
        ['a/pom.xml'] = pom('<parent><groupId>g</groupId><artifactId>parent</artifactId><version>1</version></parent><artifactId>a</artifactId><properties>\n  </properties><version>${x}</version>') }
    local e = assert(P.effective(m, 'a/pom.xml'))
    eq('parent-x', e.coords.v)
    eq('parent-y', P._get(P._get(e.model, 'properties'), 'y'))
end)

test('pom: ★★ INTERPOLATION reaches every field — packaging from a property a PROFILE sets (hadoop\'s ui modules)', function ()
    ready()
    local src = pom([[<groupId>g</groupId><artifactId>ui</artifactId><version>1</version>
      <packaging>${packagingType}</packaging><properties><packagingType>pom</packagingType></properties>
      <profiles><profile><id>yarn-ui</id><properties><packagingType>war</packagingType></properties></profile></profiles>]])
    local m = tree { ['pom.xml'] = src }
    eq('pom', assert(P.effective(m, 'pom.xml')).coords.packaging)
    eq('war', assert(P.effective(m, 'pom.xml', { profiles = { ['yarn-ui'] = true } })).coords.packaging)
    -- project.* model paths, the super POM's build defaults, and the deprecated unprefixed form
    local m2 = tree { ['pom.xml'] = pom([[<groupId>g</groupId><artifactId>a</artifactId><version>3</version>
      <properties><f>${project.build.finalName}</f><v>${version}</v></properties>]]) }
    local e = assert(P.effective(m2, 'pom.xml'))
    eq('a-3', P._get(P._get(e.model, 'properties'), 'f'))
    eq('3', P._get(P._get(e.model, 'properties'), 'v'))
end)

test('pom: ★★★ HOLES ARE CLASSIFIED — basedir, env, profile, late, beyond, undefined, cycle — each pinned', function ()
    ready()
    local own = pom([[<groupId>g</groupId><artifactId>a</artifactId><version>1</version>
      <properties><b>${project.basedir}/x</b><e>${env.HOME}</e><p>${only.in.profile}</p>
        <u>${nowhere}</u><c1>${c2}</c1><c2>${c1}</c2><ok>${project.version}</ok></properties>
      <build><plugins><plugin><artifactId>surefire</artifactId><configuration><t>${test.cache.data}</t></configuration></plugin></plugins></build>
      <profiles><profile><id>q</id><properties><only.in.profile>1</only.in.profile></properties></profile></profiles>]])
    local e = assert(P.effective(tree { ['pom.xml'] = own }, 'pom.xml'))
    local class = {}
    for _, h in ipairs(e.refs.list) do class[h.expr] = h.class end
    eq('basedir', class['project.basedir'])
    eq('env', class['env.HOME'])
    eq('profile', class['only.in.profile'])
    eq('late', class['test.cache.data'])             -- plugin configuration: the mojo decides
    eq('undefined', class['nowhere'])                -- ★ THE FINDING, and it still fires
    eq('cycle', class['c2'])
    eq(nil, class['project.version'])                -- resolved: no hole
    eq('${nowhere}', P._get(P._get(e.model, 'properties'), 'u')) -- left literal, as Maven does
    -- the same unknown name under an EXTERNAL parent is `beyond`, not a finding
    local ext = pom([[<parent><groupId>org.apache</groupId><artifactId>apache</artifactId><version>35</version><relativePath/></parent>
      <artifactId>a</artifactId><properties><u>${nowhere}</u></properties>]])
    local e2 = assert(P.effective(tree { ['pom.xml'] = ext }, 'pom.xml'))
    eq('beyond', e2.refs.list[1].class)
    eq(e.refs.total, e.refs.resolved + (function() local n = 0; for _, c in pairs(e.refs.holes) do n = n + c end; return n end)())
end)

test('pom: ★ LINKING — a version-less dependency takes it from the lineage, an in-tree BOM, or names its frontier', function ()
    ready()
    local m = tree {
        ['pom.xml'] = pom([[<groupId>g</groupId><artifactId>root</artifactId><version>1</version><packaging>pom</packaging>
          <dependencyManagement><dependencies>
            <dependency><groupId>d</groupId><artifactId>lin</artifactId><version>5</version><scope>test</scope></dependency>
            <dependency><groupId>g</groupId><artifactId>bom</artifactId><version>1</version><type>pom</type><scope>import</scope></dependency>
            <dependency><groupId>ext</groupId><artifactId>bom</artifactId><version>7</version><type>pom</type><scope>import</scope></dependency>
          </dependencies></dependencyManagement>]]),
        ['bom/pom.xml'] = pom([[<groupId>g</groupId><artifactId>bom</artifactId><version>1</version><packaging>pom</packaging>
          <dependencyManagement><dependencies><dependency><groupId>d</groupId><artifactId>viabom</artifactId><version>8</version></dependency></dependencies></dependencyManagement>]]),
        ['a/pom.xml'] = pom([[<parent><groupId>g</groupId><artifactId>root</artifactId><version>1</version></parent><artifactId>a</artifactId>
          <dependencies><dependency><groupId>d</groupId><artifactId>lin</artifactId></dependency>
            <dependency><groupId>d</groupId><artifactId>viabom</artifactId></dependency>
            <dependency><groupId>d</groupId><artifactId>unknown</artifactId></dependency></dependencies>]]),
    }
    local e = assert(P.effective(m, 'a/pom.xml'))
    local by = {}
    for _, d in ipairs(e.deps) do by[d.a] = d end
    eq('5', by.lin.v); eq('managed:pom.xml', by.lin.version_from); eq('test', by.lin.scope)
    eq('8', by.viabom.v); eq('bom:bom/pom.xml', by.viabom.version_from)
    eq(nil, by.unknown.v); eq('frontier:bom ext:bom:7', by.unknown.version_from)
    for _, x in ipairs(e.dm) do ok(x.d.o.scope ~= 'import', 'an import entry is consumed, not managed') end
end)

test('pom: PROFILES AS VANTAGES — activeByDefault yields, `!prop` decides, os waits for a vantage, file reads the tree', function ()
    ready()
    local src = pom([[<groupId>g</groupId><artifactId>a</artifactId><version>1</version>
      <profiles>
        <profile><id>dflt</id><activation><activeByDefault>true</activeByDefault></activation><properties><d>1</d></properties></profile>
        <profile><id>notskip</id><activation><property><name>!skipIt</name></property></activation><properties><n>1</n></properties></profile>
        <profile><id>mac</id><activation><os><family>mac</family></os></activation><properties><o>1</o></properties></profile>
        <profile><id>proto</id><activation><file><exists>${basedir}/src/main/proto</exists></file></activation><properties><f>1</f></properties></profile>
      </profiles>]])
    local m = tree({ ['pom.xml'] = src }, { ['src/main/proto'] = true })
    local e = assert(P.effective(m, 'pom.xml'))
    local props = P._get(e.model, 'properties')
    eq('1', P._get(props, 'n'))                      -- `!skipIt` holds: skipIt is not set
    eq('1', P._get(props, 'f'))                      -- the file is in the tree
    eq(nil, P._get(props, 'd'))                      -- another profile is active: the default yields
    eq(nil, P._get(props, 'o'))
    eq(1, #e.undecided); eq('mac', e.undecided[1].id)
    eq(true, e.lower_bound)
    local e2 = assert(P.effective(m, 'pom.xml', { props = { skipIt = 'true' }, os = { name = 'mac os x' } }))
    local p2 = P._get(e2.model, 'properties')
    eq(nil, P._get(p2, 'n')); eq('1', P._get(p2, 'o')); eq(false, e2.lower_bound)
end)

test('pom: the TREE — reactor vs orphans, links only at an agreeing version (skew counted), no-op overrides', function ()
    ready()
    local m = tree {
        ['pom.xml'] = pom([[<groupId>g</groupId><artifactId>root</artifactId><version>1</version><packaging>pom</packaging>
          <modules><module>a</module><module>b</module></modules><properties><k>v</k></properties>]]),
        ['a/pom.xml'] = pom([[<parent><groupId>g</groupId><artifactId>root</artifactId><version>1</version></parent><artifactId>a</artifactId>
          <properties><k>v</k></properties>]]),
        ['b/pom.xml'] = pom([[<parent><groupId>g</groupId><artifactId>root</artifactId><version>1</version></parent><artifactId>b</artifactId>
          <dependencies><dependency><groupId>g</groupId><artifactId>a</artifactId><version>${project.version}</version></dependency>
            <dependency><groupId>g</groupId><artifactId>a</artifactId><version>0.9</version><classifier>old</classifier></dependency></dependencies>]]),
        ['src/test/resources/fixture/pom.xml'] = pom('<groupId>f</groupId><artifactId>f</artifactId><version>1</version>'),
    }
    local A = P.analyze(m)
    eq(3, #A.reactor); eq(1, #A.orphans)
    eq(1, #A.links); eq('b/pom.xml', A.links[1].from); eq('a/pom.xml', A.links[1].to)
    eq(1, #A.skew); eq('0.9', A.skew[1].want)
    eq(1, #A.noops); eq('k', A.noops[1].key)
end)

test('pom: attach mints POM nodes and parent/module/dependency edges; a second attach is idempotent', function ()
    ready()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/a', 'p')
    local function w(rel, s) local fd = assert(io.open(dir .. '/' .. rel, 'w')); fd:write(s); fd:close() end
    w('pom.xml', PARENT); w('a/pom.xml', CHILD)
    local data = { root = dir, nodes = {}, edges = {} }
    local s = P.attach(data)
    eq(2, s.files); eq(2, s.reactor)
    local kinds = {}
    for _, e in ipairs(data.edges) do kinds[e.pom] = (kinds[e.pom] or 0) + 1 end
    eq(1, kinds.parent); eq(1, kinds.module)
    ok(P.summary(s):find('2 POM', 1, true), P.summary(s))
    P.attach(data)
    eq(2, #data.nodes); eq(2, #data.edges)
    vim.fn.delete(dir, 'rf')
end)

test('pom: ★ the POM walk keeps `build/` and `dist/` — MODULES in a Maven tree (wildfly), not vendored code — and skips target/', function ()
    local dir = vim.fn.tempname()
    for _, d in ipairs({ 'build', 'dist', 'target', 'a/target' }) do vim.fn.mkdir(dir .. '/' .. d, 'p') end
    for _, f in ipairs({ 'pom.xml', 'build/pom.xml', 'dist/pom.xml', 'target/pom.xml', 'a/target/pom.xml' }) do
        local fd = assert(io.open(dir .. '/' .. f, 'w')); fd:write('<project/>'); fd:close()
    end
    eq('build/pom.xml,dist/pom.xml,pom.xml', table.concat(P.find(dir), ','))
    vim.fn.delete(dir, 'rf')
end)

-- ── what Maven's own model builder taught (tools/oraclejoin.lua pom: hadoop 120/121, quarkus
-- 126 judged, 0 disagree; the one difference left is maven.build.timestamp, a build-time fact) ──

local MAVEN_TRAPS = {
    ['pom.xml'] = pom([[<groupId>g</groupId><artifactId>parent</artifactId><version>1</version><packaging>pom</packaging>
      <properties><args>
          -Xmx1g
      </args></properties>
      <dependencies><dependency><groupId>d</groupId><artifactId>ann</artifactId><version>1</version><scope>provided</scope></dependency></dependencies>]]),
    ['a/pom.xml'] = pom([[<parent><groupId>g</groupId><artifactId>parent</artifactId><version>1</version></parent><artifactId>a</artifactId>
      <dependencies>
        <dependency><groupId>d</groupId><artifactId>first</artifactId><version>1</version></dependency>
        <dependency><groupId>d</groupId><artifactId>ann</artifactId><version>1</version></dependency>
        <dependency><groupId>d</groupId><artifactId>last</artifactId><version>1</version></dependency>
      </dependencies>
      <profiles><profile><id>p</id><activation><activeByDefault>true</activeByDefault></activation>
        <dependencies>
          <dependency><groupId>d</groupId><artifactId>extra</artifactId><version>1</version></dependency>
          <dependency><groupId>d</groupId><artifactId>last</artifactId><version>2</version><scope>test</scope></dependency>
        </dependencies></profile></profiles>]]),
}

test('pom: ★ Maven\'s reader TRIMS element text (the oracle found it in 117 of 121 hadoop POMs)', function ()
    ready()
    local e = assert(P.effective(tree(MAVEN_TRAPS), 'a/pom.xml'))
    eq('-Xmx1g', P._get(P._get(e.model, 'properties'), 'args'))
end)

test('pom: ★★ a same-key dependency REPLACES the whole element — a scope-less child does not inherit `provided`', function ()
    ready()
    local e = assert(P.effective(tree(MAVEN_TRAPS), 'a/pom.xml'))
    local by = {}
    for _, d in ipairs(e.deps) do by[d.a] = d end
    eq('compile', by.ann.scope)
end)

test('pom: ★★ profile injection keeps the MODEL\'s order — the profile replaces in place, its extras go last', function ()
    ready()
    local e = assert(P.effective(tree(MAVEN_TRAPS), 'a/pom.xml'))
    local got = {}
    for _, d in ipairs(e.deps) do got[#got + 1] = d.a .. '@' .. d.v end
    eq('first@1,ann@1,last@2,extra@1', table.concat(got, ','))
end)

test('pom: the SYSTEM properties of a vantage decide activation and interpolate after the model\'s own', function ()
    ready()
    local src = pom([[<groupId>g</groupId><artifactId>a</artifactId><version>1</version>
      <properties><j>${java.version}</j><mine>model</mine><m>${mine}</m></properties>
      <profiles><profile><id>j21</id><activation><property><name>java.version</name><value>21</value></property></activation>
        <properties><hit>1</hit></properties></profile></profiles>]])
    local m = tree { ['pom.xml'] = src }
    local e0 = assert(P.effective(m, 'pom.xml'))
    eq('${java.version}', P._get(P._get(e0.model, 'properties'), 'j'))
    eq(1, #e0.undecided)                             -- a system property, and no system told
    local e = assert(P.effective(m, 'pom.xml', { sys = { ['java.version'] = '21', mine = 'system' } }))
    local props = P._get(e.model, 'properties')
    eq('21', P._get(props, 'j'))
    eq('model', P._get(props, 'm'))                  -- the model's own property beats a system one
    eq('1', P._get(props, 'hit'))
end)

test('pom: ★★★ JOINED AGAINST MAVEN ITSELF — the model builder, offline, agrees with the projection on the traps', function ()
    ready()
    if vim.fn.executable('java') ~= 1 or vim.fn.executable('javac') ~= 1 or vim.fn.isdirectory('/usr/share/maven/lib') ~= 1 then
        skip('no java/javac or no system Maven')
    end
    local J = require 'cartograph.oraclejoin'
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/a', 'p')
    for rel, src in pairs(MAVEN_TRAPS) do local fd = assert(io.open(dir .. '/' .. rel, 'w')); fd:write(src); fd:close() end
    local script = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h') .. '/tools/oracles/maven_effective.py'
    local map = assert(J.external({ 'python3', script }, { dir .. '/pom.xml', dir .. '/a/pom.xml' }))
    local model = P.read(dir, { 'pom.xml', 'a/pom.xml' })
    for _, rel in ipairs({ 'pom.xml', 'a/pom.xml' }) do
        local theirs = map[dir .. '/' .. rel]
        ok(theirs and theirs.value, 'maven built ' .. rel .. ': ' .. tostring(theirs and theirs.error))
        local ours = P.projection(assert(P.effective(model, rel)))
        local d = J.first_difference(ours, theirs.value)
        ok(d == nil, rel .. ': ' .. vim.inspect(d))
    end
    vim.fn.delete(dir, 'rf')
end)

-- ── the downloaded POMs (tools/mavenpoms.lua → a LOCAL REPOSITORY), and what the full join taught:
-- hadoop 120/121, hive 80/80, wildfly 278/278, quarkus 1565 agree / 0 disagree / 299 refused by both ──

test('pom: ★★ a coordinate is a PLAIN SEGMENT before it becomes a path or a URL — the tree cannot steer either', function ()
    eq('org/jboss/jboss-parent/51/jboss-parent-51.pom', (P.repo_path('org.jboss', 'jboss-parent', '51')))
    for _, bad in ipairs({ { 'g', 'a', '../../etc' }, { 'g/x', 'a', '1' }, { 'g', 'a', '@project.version@' },
        { '\\io.quarkus', 'a', '1' }, { 'g', 'a', '1..2' }, { 'g', 'a', nil } }) do
        eq(nil, (P.repo_path(bad[1], bad[2], bad[3])))
    end
end)

test('pom: ★★ an EXTERNAL parent and BOM come from the LOCAL REPOSITORY — resolved, not `beyond`', function ()
    ready()
    local repo = vim.fn.tempname()
    local function put(g, a, v, body)
        local rel = assert(P.repo_path(g, a, v))
        vim.fn.mkdir(repo .. '/' .. vim.fn.fnamemodify(rel, ':h'), 'p')
        local fd = assert(io.open(repo .. '/' .. rel, 'w')); fd:write(pom(body)); fd:close()
    end
    -- a FILE activation in a repository POM is false: Maven gives it no basedir (and ours must not crash on one)
    put('org.apache', 'apache', '35', '<groupId>org.apache</groupId><artifactId>apache</artifactId><version>35</version><packaging>pom</packaging><properties><from.apache>yes</from.apache></properties>'
        .. '<profiles><profile><id>f</id><activation><file><exists>${basedir}/pom.xml</exists></file></activation><properties><filed>1</filed></properties></profile></profiles>')
    put('ext', 'bom', '7', '<groupId>ext</groupId><artifactId>bom</artifactId><version>7</version><packaging>pom</packaging><dependencyManagement><dependencies><dependency><groupId>d</groupId><artifactId>x</artifactId><version>3</version></dependency></dependencies></dependencyManagement>')
    local files = { ['pom.xml'] = pom([[<parent><groupId>org.apache</groupId><artifactId>apache</artifactId><version>35</version></parent>
      <groupId>g</groupId><artifactId>a</artifactId><version>1</version><properties><p>${from.apache}</p></properties>
      <dependencyManagement><dependencies><dependency><groupId>ext</groupId><artifactId>bom</artifactId><version>7</version><type>pom</type><scope>import</scope></dependency></dependencies></dependencyManagement>
      <dependencies><dependency><groupId>d</groupId><artifactId>x</artifactId></dependency></dependencies>]]) }
    local m = P.read('/nonexistent', { 'pom.xml' }, { read = function(r) return files[r] end, repo = repo })
    eq('repository', m.poms['pom.xml'].parent_via)
    local e = assert(P.effective(m, 'pom.xml'))
    eq('yes', P._get(P._get(e.model, 'properties'), 'p'))
    eq(nil, P._get(P._get(e.model, 'properties'), 'filed'))
    eq('3', e.deps[1].v); eq('bom:repo:ext:bom:7', e.deps[1].version_from)
    eq(nil, e.frontier)
    eq(1, #m.order)                                  -- the repository is not the tree
    vim.fn.delete(repo, 'rf')
end)

test('pom: ★ a property key written twice is ONE property, the last value (wildfly lra) — not an array', function ()
    ready()
    local e = assert(P.effective(tree { ['pom.xml'] = pom('<groupId>g</groupId><artifactId>a</artifactId><version>1</version><properties><k>1</k><j>x</j><k>2</k></properties>') }, 'pom.xml'))
    eq('2', P._get(P._get(e.model, 'properties'), 'k'))
end)

test('pom: ★★ the BOM cycle guard is the CURRENT CHAIN — an answer does not depend on the order POMs are asked in', function ()
    ready()
    local function imp(a) return '<dependency><groupId>g</groupId><artifactId>' .. a .. '</artifactId><version>1</version><type>pom</type><scope>import</scope></dependency>' end
    local function bom(a, dm) return pom('<groupId>g</groupId><artifactId>' .. a .. '</artifactId><version>1</version><packaging>pom</packaging><dependencyManagement><dependencies>' .. dm .. '</dependencies></dependencyManagement>') end
    local files = {
        ['c/pom.xml'] = bom('c', '<dependency><groupId>d</groupId><artifactId>fromc</artifactId><version>9</version></dependency>'),
        ['b/pom.xml'] = bom('b', imp('c')),
        ['a/pom.xml'] = bom('a', imp('c') .. imp('b')),   -- C first, then B, which imports C again
    }
    local m = tree(files)
    assert(P.effective(m, 'a/pom.xml'))              -- evaluating A first used to cache B WITHOUT C
    local b = assert(P.effective(m, 'b/pom.xml'))
    eq(1, #b.dm); eq('g', 'g')
    eq('d:fromc:jar:', b.dm[1].key)
end)

test('pom: ★ Maven\'s OS FAMILY test — known families have rules, any other is `os.name contains it` (`Linux`)', function ()
    eq(true, P._family_matches('Linux', 'linux', ':'))
    eq(true, P._family_matches('unix', 'linux', ':'))
    eq(false, P._family_matches('windows', 'linux', ':'))
    eq(false, P._family_matches('mac', 'linux', ':'))
    eq(true, P._family_matches('mac', 'mac os x', ':'))
    eq(nil, P._family_matches('unix', nil, ':'))
end)

test('pom: ★ a recursive expression makes the model INVALID, as Maven refuses it — kept for navigation, refused by the projection', function ()
    ready()
    local e = assert(P.effective(tree { ['pom.xml'] = pom('<groupId>g</groupId><artifactId>a</artifactId><version>1</version><properties><s>${s}</s></properties>') }, 'pom.xml'))
    ok(e.invalid and e.invalid:find('recursive', 1, true), tostring(e.invalid))
    local pr, why = P.projection(e)
    eq(nil, pr); ok(why:find('${s}', 1, true), why)
end)

test('pom: a DUPLICATE ATTRIBUTE refuses the POM — Maven\'s MXParser does ("duplicated attributes", measured); the reader kept both', function ()
    ready()
    local src = pom('<groupId>g</groupId><artifactId>a</artifactId><version>1</version><build><plugins><plugin><artifactId>p</artifactId><configuration><x k="1" k="2"/></configuration></plugin></plugins></build>')
    local r, why = P.read_pom(src, 'pom.xml')
    eq(nil, r); ok(why:find('duplicate attribute', 1, true), tostring(why))
end)
