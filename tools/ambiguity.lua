-- ambiguity — MEASURE how real implementations decide ambiguous YAML and XML, and SERIALIZE what
-- was learned WITH PROVENANCE (CART-1053).
--
--   nvim --headless -u NONE -l tools/ambiguity.lua [--write] [--joins]
--
-- USER (2026-09-24): "We've collected interesting knowledge, are we able to serialize it with
-- provenance?" The knowledge has the two banked FACT SHAPES ([[cartograph-witness-and-promise]]):
--   WITNESS  one observation: implementation X, at version V, given input I (sha256), produced O at
--            site S, at time T, driven by command C. One sighting settles it for that version+input.
--   PROMISE  a generalization the CODE relies on: `yamlvalue.IMPLEMENTATIONS['pyyaml-safe']` says how
--            PyYAML decides every duplicate, merge and scalar. Evidence can only REFUTE it; its
--            warrants are witnesses, source ports, spec sentences and corpus joins — each named.
-- This file runs every registered implementation on every probe, compares each witness with what
-- the code's profile PREDICTS, and prints the refutations. `--write` stores the result as JSONL in
-- lua/cartograph/spec/knowledge/ambiguity.jsonl (tests/knowledge_spec.lua re-checks every stored
-- witness against the current code, so a change that contradicts a measured fact fails a test).
-- `--joins` also runs the corpus joins (tools/oraclejoin.lua yaml:<impl>, xml, pom) and records
-- their summary lines as warrants — slow (minutes).
--
-- ⚠ DELIBERATELY NOT PROBED: an EXTERNAL entity (JAXP's default parser really reads the file — the
-- XXE shape) and the billion-laughs bomb (a denial of service against this machine). Our own
-- policy for both is pinned in tests/xmlvalue_spec.lua instead.
-- ⚠ yq is a snap here: probe files live under ~/.cache/cartograph/ambiguity, not /tmp.

local REPO = (debug.getinfo(1, 'S').source:match('@(.*)/tools/[^/]+$')) or '.'
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local Y = require 'cartograph.yamlvalue'
local X = require 'cartograph.xmlvalue'
local J = require 'cartograph.oraclejoin'

local WRITE, JOINS = false, false
for _, a in ipairs(arg) do
    if a == '--write' then WRITE = true elseif a == '--joins' then JOINS = true end
end
local OUT = REPO .. '/lua/cartograph/spec/knowledge/ambiguity.jsonl'
local WORK = vim.fn.expand('~/.cache/cartograph/ambiguity')
vim.fn.mkdir(WORK, 'p')
local NOW = os.date('!%Y-%m-%dT%H:%M:%SZ')

local function sh(cmd)
    local r = vim.system(cmd, { text = true }):wait()
    return ((r.stdout or '') .. (r.stderr or '')):gsub('%s+$', ''), r.code
end
local function first_line(s) return (s:match('^[^\n]*') or s) end

-- ── probes ────────────────────────────────────────────────────────────────────────────────
local PROBES = {
    { id = 'yaml/scalars', lang = 'yaml', text = table.concat({
        'no: no', 'on: on', 'yEs: yEs', 'y: y', 'FALSE: FALSE', 'Null: Null', 'tilde: ~', 'empty:',
        'oct: 010', 'lead0: 08', 'oct12: 0o10', 'under: 1_000', 'comma: 1,000', 'sexa: 1:20', 'sexa3: 12:30:45',
        'exp: 1e5', 'expsign: 1.5e+3', 'hex: 0x1F', 'bin: 0b11', 'inf: .inf', 'date: 2001-12-14', 'negzero: -0',
        'plus: +12', 'float: 1.0', '' }, '\n') },
    { id = 'yaml/duplicate-key', lang = 'yaml', text = 'a: 1\na: 2\n' },
    { id = 'yaml/merge-own-before', lang = 'yaml', text = 'b: &b {k: 1, a: 0}\nm:\n  a: 1\n  <<: *b\n  z: 2\n' },
    { id = 'yaml/merge-sequence', lang = 'yaml', text = 'x: &x {k: 1, a: 1}\ny: &y {k: 2, b: 2}\nm:\n  a: 9\n  <<: [*x, *y]\n' },
    { id = 'yaml/keys', lang = 'yaml', text = 'on:\n  push: {}\n200: ok\n' },
    { id = 'yaml/local-tags', lang = 'yaml', text = 'a: !Sub "x-${y}"\ne: !Ref plain\nm: !Custom {k: 1}\n' },
    { id = 'yaml/standard-tags', lang = 'yaml', text = 'b: !!str 010\nc: !!int "12"\nf: !!float "1"\nh: !!null ""\n' },
    { id = 'yaml/bool-tag', lang = 'yaml', text = 'g: !!bool "yes"\n' },
    { id = 'yaml/empty-stream', lang = 'yaml', text = '# only a comment\n' },
    -- duplicates: the VALUE's type changes nothing, the KEY's identity decides (user, 2026-09-24)
    { id = 'yaml/dup-map-map', lang = 'yaml', text = 'a: {x: 1}\na: {y: 2}\n' },
    { id = 'yaml/dup-scalar-map', lang = 'yaml', text = 'a: 1\na: {y: 2}\n' },
    { id = 'yaml/dup-key-true-yes', lang = 'yaml', text = 'true: a\nyes: b\n' },
    { id = 'yaml/dup-key-010-8', lang = 'yaml', text = '010: a\n8: b\n' },
    { id = 'yaml/dup-key-int-str', lang = 'yaml', text = '1: a\n"1": b\n' },
    { id = 'yaml/dup-key-16-0x10', lang = 'yaml', text = '16: a\n0x10: b\n' },
    { id = 'yaml/dup-key-true-1', lang = 'yaml', text = 'true: a\n1: b\n' },
    { id = 'yaml/dup-key-nulls', lang = 'yaml', text = 'null: a\n~: b\n"": c\n' },
    { id = 'yaml/two-merge-keys', lang = 'yaml', text = 'b: &b {k: 1, x: 1}\nc: &c {k: 2, y: 2}\nm:\n  <<: *b\n  <<: *c\n' },
    { id = 'yaml/merge-split', lang = 'yaml', text = 'b: &b {k: 1}\nm:\n  <<: *b\n  z: 0\n  <<: {k: 3}\n' },
    { id = 'xml/duplicate-attribute', lang = 'xml', text = '<a k="first" k="second"/>' },
    { id = 'xml/internal-entity', lang = 'xml', text = '<?xml version="1.0"?>\n<!DOCTYPE a [\n<!ENTITY e "x">\n<!ENTITY n "&e;&e;">\n]>\n<a><s>&e;</s><t>&n;</t></a>\n' },
    { id = 'xml/control-char', lang = 'xml', text = '<a>b\1c</a>' },
}
for _, p in ipairs(PROBES) do
    p.path = WORK .. '/' .. p.id:gsub('/', '__') .. (p.lang == 'yaml' and '.yaml' or '.xml')
    local fd = assert(io.open(p.path, 'wb')); fd:write(p.text); fd:close()
    p.sha256 = vim.fn.sha256(p.text)
end

-- ── implementations: how each is driven, and its exact version ────────────────────────────
local function oracle_typed(cmd)
    return function(probe)
        local map = J.external(cmd, { probe.path })
        local e = map and map[probe.path]
        if not e then return { error = 'the oracle produced nothing' } end
        return e
    end
end
local PY = 'python3'
local YAML_IMPLS = {
    { id = 'pyyaml-safe', run = oracle_typed({ PY, REPO .. '/tools/oracles/yaml_typed.py', 'pyyaml-safe' }),
      version = function() return sh({ PY, '-c', 'import yaml,sys;print("PyYAML", yaml.__version__, "SafeLoader (pure Python); Python", sys.version.split()[0])' }) end,
      how = 'tools/oracles/yaml_typed.py pyyaml-safe (yaml.load_all, Loader=SafeLoader)',
      sources = { '/usr/lib/python3/dist-packages/yaml/resolver.py', '/usr/lib/python3/dist-packages/yaml/constructor.py' } },
    { id = 'ruamel-safe', run = oracle_typed({ PY, REPO .. '/tools/oracles/yaml_typed.py', 'ruamel-safe' }),
      version = function() return sh({ PY, '-c', 'import ruamel.yaml as r,sys;print("ruamel.yaml", r.__version__, "typ=safe pure; Python", sys.version.split()[0])' }) end,
      how = "tools/oracles/yaml_typed.py ruamel-safe (YAML(typ='safe', pure=True).load_all)",
      sources = { '/usr/lib/python3/dist-packages/ruamel/yaml/resolver.py', '/usr/lib/python3/dist-packages/ruamel/yaml/constructor.py' } },
    { id = 'psych-safe', run = oracle_typed({ 'ruby', REPO .. '/tools/oracles/yaml_typed.rb' }),
      version = function() return sh({ 'ruby', '-rpsych', '-e', 'puts "psych #{Psych::VERSION} (libyaml #{Psych::LIBYAML_VERSION}); ruby #{RUBY_VERSION}"' }) end,
      how = 'tools/oracles/yaml_typed.rb (parse_stream + ToRuby, Restricted loader: Date Time DateTime Symbol, aliases on)',
      sources = { '/usr/lib/ruby/3.2.0/psych/scalar_scanner.rb' } },
    { id = 'yaml-xs', run = oracle_typed({ 'perl', REPO .. '/tools/oracles/yaml_typed.pl' }),
      version = function() return sh({ 'perl', '-MYAML::XS', '-e', 'print "YAML::XS $YAML::XS::VERSION (libyaml ", YAML::XS::LibYAML::libyaml_version(), "); perl $^V\\n"' }) end,
      how = 'tools/oracles/yaml_typed.pl (YAML::XS::LoadFile)' },
    { id = 'yq', run = oracle_typed({ PY, REPO .. '/tools/oracles/yaml_typed_yq.py' }),
      version = function() return sh({ 'yq', '--version' }) end,
      how = "tools/oracles/yaml_typed_yq.py (yq -o=json '(.. | select(kind == \"scalar\")) |= tag'; TYPES ONLY)" },
}

-- XML: each adapter prints the DECIDED document as the xmlvalue convention would, or `rejected: …`
local EXPAT_PY = [[
import json, sys, xml.etree.ElementTree as ET
def conv(el):
    kids = list(el); attrs = [('@' + k, v) for k, v in el.attrib.items()]
    if not kids and not attrs: return el.text or ''
    o = {}
    for k, v in attrs: o[k] = v
    for c in kids: o[c.tag] = conv(c)
    return o
try:
    print(json.dumps(conv(ET.parse(sys.argv[1]).getroot()), ensure_ascii=True))
except Exception as e:
    print('rejected: ' + str(e).splitlines()[0])
]]
local HTML_PY = [[
import json, sys
from html.parser import HTMLParser
class P(HTMLParser):
    def __init__(s): super().__init__(); s.out = {}; s.stack = []; s.data = {}
    def handle_starttag(s, t, a):
        s.stack.append(t)
        if a: s.out['@' + '/'.join(s.stack)] = dict(a)
    def handle_endtag(s, t):
        if s.stack: s.stack.pop()
    def handle_data(s, d):
        if s.stack and d.strip(): s.data['/'.join(s.stack)] = s.data.get('/'.join(s.stack), '') + d
p = P(); p.feed(open(sys.argv[1], encoding='utf-8').read())
print(json.dumps({'attrs': p.out, 'text': p.data}, ensure_ascii=True))
]]
local JAXP_JAVA = [[
import javax.xml.parsers.*; import org.w3c.dom.*; import java.io.File;
public class JaxpProbe { public static void main(String[] a) throws Exception {
  try { Document d = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(new File(a[0]));
    Element r = d.getDocumentElement(); StringBuilder sb = new StringBuilder("{");
    NamedNodeMap at = r.getAttributes(); for (int i = 0; i < at.getLength(); i++) sb.append("\"@").append(at.item(i).getNodeName()).append("\":\"").append(at.item(i).getNodeValue()).append("\",");
    NodeList l = r.getChildNodes(); boolean el = false;
    for (int i = 0; i < l.getLength(); i++) if (l.item(i) instanceof Element) { el = true; sb.append("\"").append(l.item(i).getNodeName()).append("\":\"").append(l.item(i).getTextContent()).append("\","); }
    if (!el && at.getLength() == 0) { System.out.println("\"" + r.getTextContent().replace("\u0001", "\\u0001") + "\""); return; }
    if (sb.charAt(sb.length() - 1) == ',') sb.setLength(sb.length() - 1);
    System.out.println(sb.append("}"));
  } catch (Exception e) { System.out.println("rejected: " + e.getMessage()); } } }
]]
local REXML_RB = [[
require 'rexml/document'; require 'json'
begin
  d = REXML::Document.new(File.read(ARGV[0])); r = d.root
  o = {}; r.attributes.each { |k, v| o['@' + k] = v }
  r.elements.each { |e| o[e.name] = e.text }
  puts(o.empty? ? JSON.generate(r.text) : JSON.generate(o))
rescue Exception => e
  puts 'rejected: ' + e.message.lines.first.strip
end
]]
local function script_impl(argv_of)
    return function(probe)
        local out = sh(argv_of(probe.path))
        return { raw = out }
    end
end
local function jaxp_dir()
    local dir = vim.fn.expand('~/.cache/cartograph/xml-oracles')
    vim.fn.mkdir(dir, 'p')
    local src = dir .. '/JaxpProbe.java'
    local fd = assert(io.open(src, 'w')); fd:write(JAXP_JAVA); fd:close()
    if vim.fn.filereadable(dir .. '/JaxpProbe.class') == 0 or vim.fn.getftime(dir .. '/JaxpProbe.class') < vim.fn.getftime(src) then
        sh({ 'javac', '-nowarn', '-d', dir, src })
    end
    return dir
end
-- Maven reads a POM, so the probe is wrapped as one: the ambiguity sits in a property
local function maven_run(probe)
    local body = ({
        ['xml/duplicate-attribute'] = '<properties><p k="first" k="second">v</p></properties>',
        ['xml/internal-entity'] = '<properties><p>&e;</p></properties>',
        ['xml/control-char'] = '<properties><p>b\1c</p></properties>',
    })[probe.id]
    local prolog = probe.id == 'xml/internal-entity' and '<?xml version="1.0"?>\n<!DOCTYPE project [\n<!ENTITY e "x">\n]>\n' or ''
    local dir = WORK .. '/maven__' .. probe.id:gsub('/', '__')
    vim.fn.mkdir(dir, 'p')
    local pom = dir .. '/pom.xml'
    local fd = assert(io.open(pom, 'wb'))
    fd:write(prolog .. '<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion><groupId>g</groupId><artifactId>a</artifactId><version>1</version>' .. body .. '</project>\n')
    fd:close()
    local cache = vim.fn.expand('~/.cache/cartograph/maven-oracle')
    local r = vim.system({ 'java', '-cp', cache .. ':/usr/share/maven/lib/*', 'EffectivePom', dir .. '/out', '', '' },
        { stdin = pom .. '\0', text = true }):wait()
    local f = vim.split(r.stdout or '', '\0', { plain = true })
    return { raw = table.concat(f, ' | '):gsub('%s+$', ''), pom = pom }
end
local XML_IMPLS = {
    { id = 'expat', run = script_impl(function(p) return { PY, '-c', EXPAT_PY, p } end),
      version = function() return sh({ PY, '-c', 'import pyexpat,sys;print(pyexpat.EXPAT_VERSION, "via xml.etree.ElementTree; Python", sys.version.split()[0])' }) end,
      how = 'python3 xml.etree.ElementTree.parse' },
    { id = 'jaxp', run = function(p) local d = jaxp_dir(); return script_impl(function(x) return { 'java', '-cp', d, 'JaxpProbe', x } end)(p) end,
      version = function() return first_line((sh({ 'java', '-version' }))) .. ' (DocumentBuilderFactory defaults)' end,
      how = 'java JaxpProbe (DocumentBuilderFactory.newInstance().newDocumentBuilder().parse)' },
    { id = 'rexml', run = script_impl(function(p) return { 'ruby', '-e', REXML_RB, p } end),
      version = function() return sh({ 'ruby', '-rrexml/document', '-e', 'puts "REXML #{REXML::VERSION}; ruby #{RUBY_VERSION}"' }) end,
      how = 'ruby REXML::Document.new' },
    { id = 'maven', run = maven_run,
      version = function() return first_line((sh({ 'mvn', '-v' }))):gsub('\27%[[%d;]*m', '') .. ' — MXParser via maven-model-builder' end,
      how = 'tools/oracles/maven/EffectivePom.java on the probe wrapped as a POM property' },
    { id = 'html.parser+dict', run = script_impl(function(p) return { PY, '-c', HTML_PY, p } end),
      version = function() return sh({ PY, '-c', 'import sys;print("html.parser; Python", sys.version.split()[0])' }) end,
      how = 'python3 html.parser.HTMLParser, attributes read through dict()' },
}
local SPEC_ONLY = {
    { impl = 'html5', lang = 'xml', claim = X.IMPLEMENTATIONS.html5,
      warrant = { type = 'spec', url = 'https://html.spec.whatwg.org/multipage/parsing.html#attribute-name-state',
          sentence = 'if there is already an attribute on the token with the exact same name, then this is a duplicate-attribute parse error and the new attribute must be removed from the token' } },
}

-- ── what the CODE predicts, per probe, so every witness can refute it ─────────────────────
local function flatten_typed(v, path, out)
    out = out or {}
    if type(v) ~= 'table' then out[path] = v; return out end
    if v.a then for i, x in ipairs(v.a) do flatten_typed(x, path .. '[' .. i .. ']', out) end return out end
    for i, k in ipairs(v.keys) do flatten_typed(v.o[k], path .. '.' .. k, out); out[path .. '#' .. i] = k end
    return out
end

-- the site-by-site outcome of a YAML witness: every leaf (and key order) of the typed tree
local function yaml_sites(entry)
    if entry.error then return { ['$'] = 'rejected' } end
    return flatten_typed(entry.value, '$')
end
local function yaml_predict(probe, impl)
    local t = Y.typed_stream(assert(Y.read(probe.text)), Y.IMPLEMENTATIONS[impl])
    if t == nil then return { ['$'] = 'rejected' } end
    return flatten_typed(t, '$')
end

-- an XML witness is judged on its OUTCOME CLASS per ambiguity kind (the adapters print different
-- shapes, so the class is read from the text): rejected / expanded / literal / first / last / kept
local function xml_class(probe, raw)
    raw = raw or ''
    if probe.id == 'xml/duplicate-attribute' then
        if raw:find('rejected', 1, true) or raw:find('ERR', 1, true) then return 'reject' end
        if raw:find('second', 1, true) and not raw:find('first', 1, true) then return 'last' end
        if raw:find('first', 1, true) and not raw:find('second', 1, true) then return 'first' end
        return 'unclassified: ' .. raw:sub(1, 80)
    elseif probe.id == 'xml/internal-entity' then
        if raw:find('could not resolve entity', 1, true) or raw:find('rejected', 1, true) then return 'reject' end
        if raw:find('xx', 1, true) then return 'expand' end
        if raw:find('&e;', 1, true) or raw:find('&n;', 1, true) then return 'literal' end
        return 'unclassified: ' .. raw:sub(1, 80)
    elseif probe.id == 'xml/control-char' then
        -- ⚠ MAVEN: its PARSER keeps the character; the driver's MavenXpp3Writer then refuses to WRITE
        -- the model ("character 1 is not allowed in output") — the message proves the parse succeeded
        if raw:find('not allowed in output', 1, true) then return 'keep' end
        if raw:find('rejected', 1, true) or raw:find('ERR', 1, true) or raw:find('invalid', 1, true) then return 'reject' end
        return 'keep'
    end
end
local XML_KIND = { ['xml/duplicate-attribute'] = 'duplicate-attribute', ['xml/internal-entity'] = 'entity', ['xml/control-char'] = 'control-char' }

-- ── run ───────────────────────────────────────────────────────────────────────────────────
local rows, witnesses, refutations = {}, 0, {}
rows[#rows + 1] = { kind = 'run', observed_at = NOW, host = first_line((sh({ 'uname', '-srm' }))), tool = 'tools/ambiguity.lua' }
for _, p in ipairs(PROBES) do rows[#rows + 1] = { kind = 'input', id = p.id, lang = p.lang, sha256 = p.sha256, text = p.text } end

for _, impl in ipairs(YAML_IMPLS) do
    rows[#rows + 1] = { kind = 'implementation', id = impl.id, lang = 'yaml', version = (impl.version()), how = impl.how, sources = impl.sources }
    local ids = {}
    for _, p in ipairs(PROBES) do
        if p.lang == 'yaml' then
            local seen = yaml_sites(impl.run(p))
            local want = yaml_predict(p, impl.id)
            local sites = {}
            for site in pairs(seen) do sites[#sites + 1] = site end
            table.sort(sites)
            for _, site in ipairs(sites) do
                local o = seen[site]
                -- a spot the ORACLE could not measure (yq cannot reach a shadowed duplicate) is a GAP, never a witness
                if site:find('unmeasured:', 1, true) or tostring(o):find('unmeasured:', 1, true) then
                    rows[#rows + 1] = { kind = 'gap', impl = impl.id, input = p.id, site = site, outcome = o, why = 'the oracle cannot measure this spot', observed_at = NOW }
                    goto next_site
                end
                do
                local row = { kind = 'witness', impl = impl.id, input = p.id, site = site, outcome = o, observed_at = NOW }
                row.id = 'w:' .. vim.fn.sha256(impl.id .. p.id .. site .. tostring(o)):sub(1, 12)
                rows[#rows + 1] = row
                witnesses = witnesses + 1
                ids[#ids + 1] = row.id
                if want[site] ~= o then
                    refutations[#refutations + 1] = ('%s %s %s: witnessed %s, the code predicts %s'):format(impl.id, p.id, site, tostring(o), tostring(want[site]))
                end
                end
                ::next_site::
            end
            local gapped = false
            for site in pairs(seen) do if site:find('unmeasured:', 1, true) then gapped = true end end
            for site in pairs(want) do
                if seen[site] == nil and not gapped then refutations[#refutations + 1] = ('%s %s %s: the code predicts %s, not witnessed'):format(impl.id, p.id, site, tostring(want[site])) end
            end
        end
    end
    impl.witness_ids = ids
end

for _, impl in ipairs(XML_IMPLS) do
    rows[#rows + 1] = { kind = 'implementation', id = impl.id, lang = 'xml', version = (impl.version()), how = impl.how }
    local ids = {}
    for _, p in ipairs(PROBES) do
        if p.lang == 'xml' then
            local res = impl.run(p)
            local cls = xml_class(p, res.raw)
            local kind = XML_KIND[p.id]
            local row = { kind = 'witness', impl = impl.id, input = p.id, site = kind, outcome = cls, raw = res.raw, observed_at = NOW }
            row.id = 'w:' .. vim.fn.sha256(impl.id .. p.id .. tostring(cls)):sub(1, 12)
            rows[#rows + 1] = row
            witnesses = witnesses + 1
            ids[#ids + 1] = row.id
            local want = X.IMPLEMENTATIONS[impl.id][kind]
            if kind == 'duplicate-attribute' and want == 'last' then want = 'last' end
            if want ~= cls then refutations[#refutations + 1] = ('%s %s: witnessed %s, the code predicts %s'):format(impl.id, p.id, cls, want) end
        end
    end
    impl.witness_ids = ids
end

-- promises: the code's profiles, each with its warrants
local join_lines = {}
if JOINS then
    local function join(name, extra)
        local cmd = { 'nvim', '--headless', '-u', 'NONE', '-l', REPO .. '/tools/oraclejoin.lua', name, '--show', '0' }
        for _, e in ipairs(extra or {}) do cmd[#cmd + 1] = e end
        local out = sh(cmd)
        return out:match('(%d+ inputs: [^\n]*)') or first_line(out)
    end
    for _, impl in ipairs(YAML_IMPLS) do join_lines['yaml:' .. impl.id] = join('yaml:' .. impl.id) end
    join_lines.xml = join('xml')
end
local refuted_by = {}
for _, r in ipairs(refutations) do local who = r:match('^(%S+)'); refuted_by[who] = (refuted_by[who] or 0) + 1 end
for _, impl in ipairs(YAML_IMPLS) do
    local warrants = { { type = 'witnesses', ids = impl.witness_ids, refuted = refuted_by[impl.id] or 0 } }
    if impl.sources then warrants[#warrants + 1] = { type = 'source-port', files = impl.sources } end
    if impl.id == 'yaml-xs' then
        -- stated, not observed: the oracle PRINTS keys as strings because Perl has no other kind
        warrants[#warrants + 1] = { type = 'language-fact', fact = 'a Perl hash key is a string and a hash has no order, so keys are str: and sorted' }
    end
    if join_lines['yaml:' .. impl.id] then warrants[#warrants + 1] = { type = 'corpus-join', join = 'yaml:' .. impl.id, result = join_lines['yaml:' .. impl.id], observed_at = NOW } end
    rows[#rows + 1] = { kind = 'promise', subject = impl.id, lang = 'yaml', code = "cartograph.yamlvalue.IMPLEMENTATIONS['" .. impl.id .. "']", claim = Y.IMPLEMENTATIONS[impl.id], warrants = warrants }
end
for _, impl in ipairs(XML_IMPLS) do
    local warrants = { { type = 'witnesses', ids = impl.witness_ids, refuted = refuted_by[impl.id] or 0 } }
    if impl.id == 'expat' and join_lines.xml then warrants[#warrants + 1] = { type = 'corpus-join', join = 'xml', result = join_lines.xml, observed_at = NOW } end
    rows[#rows + 1] = { kind = 'promise', subject = impl.id, lang = 'xml', code = "cartograph.xmlvalue.IMPLEMENTATIONS['" .. impl.id .. "']", claim = X.IMPLEMENTATIONS[impl.id], warrants = warrants }
end
for _, s in ipairs(SPEC_ONLY) do
    rows[#rows + 1] = { kind = 'promise', subject = s.impl, lang = s.lang, code = "cartograph.xmlvalue.IMPLEMENTATIONS['" .. s.impl .. "']", claim = s.claim, warrants = { s.warrant } }
end

print(('%d witnesses from %d YAML and %d XML implementations over %d probes; %d refutation(s) of the code\'s profiles')
    :format(witnesses, #YAML_IMPLS, #XML_IMPLS, #PROBES, #refutations))
for _, r in ipairs(refutations) do print('  REFUTED ' .. r) end
for k, v in pairs(join_lines) do print(('  join %-18s %s'):format(k, v)) end
if WRITE then
    vim.fn.mkdir(vim.fn.fnamemodify(OUT, ':h'), 'p')
    local fd = assert(io.open(OUT, 'w'))
    for _, r in ipairs(rows) do fd:write(vim.json.encode(r), '\n') end
    fd:close()
    print(('wrote %d rows to %s'):format(#rows, OUT))
end
