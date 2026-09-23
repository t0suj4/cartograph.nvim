# ORACLE for cartograph.pom (CART-1051): the effective model from MAVEN'S OWN MODEL BUILDER
# (tools/oracles/maven/EffectivePom.java over the system Maven's jars, compiled once into the user
# cache), OFFLINE — parents and BOMs resolve only inside the tree, nothing is fetched, no build
# extension loads. Reads NUL-separated pom paths; writes { path: {"value": PROJECTION} | {"error"} }.
# "partial": true marks a model Maven assembled although imported BOMs outside the tree could not
# be read — their entries are missing on BOTH sides (cartograph names them as a frontier).
#
# ★ THE PROJECTION is what cartograph.pom CLAIMS, not the whole model (the model builder also
# injects the super POM's repositories, build directories, resources, ...):
#   coords       groupId, artifactId, version, packaging
#   properties   every property, keys sorted
#   dependencies "g:a:type:classifier|version|scope|optional", in order
#   managed      "g:a:type:classifier|version|scope", sorted (imports included, import entries gone)
#   modules      in order
# The one normalisation: the POM's absolute directory is written ${basedir} (a checkout fact).
import json, os, subprocess, sys, tempfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'maven', 'EffectivePom.java')
CP = '/usr/share/maven/lib/*'
CACHE = os.path.join(os.environ.get('XDG_CACHE_HOME') or os.path.expanduser('~/.cache'), 'cartograph', 'maven-oracle')
# the POMs the user chose to download (tools/mavenpoms.lua), in Maven's layout; read-only here
LOCAL_REPO = os.path.join(os.environ.get('XDG_CACHE_HOME') or os.path.expanduser('~/.cache'), 'cartograph', 'maven-central')

def compiled():
    cls = os.path.join(CACHE, 'EffectivePom.class')
    if not os.path.exists(cls) or os.path.getmtime(cls) < os.path.getmtime(SRC):
        os.makedirs(CACHE, exist_ok=True)
        subprocess.run(['javac', '-nowarn', '-cp', CP, '-d', CACHE, SRC], check=True, stderr=subprocess.DEVNULL)
    return CACHE

def local(tag): return tag.split('}', 1)[1] if '}' in tag else tag
def child(el, name):
    if el is None: return None
    for c in el:
        if local(c.tag) == name: return c
    return None
def text(el, name, default=None):
    c = child(el, name)
    return c.text if c is not None and c.text is not None else default
def kids(el, name):
    return [c for c in el if local(c.tag) == name] if el is not None else []

def project(root, basedir):
    def norm(s): return s.replace(basedir, '${basedir}') if isinstance(s, str) else s
    def dep(d, with_optional):
        key = '%s:%s:%s:%s' % (text(d, 'groupId', ''), text(d, 'artifactId', ''), text(d, 'type', 'jar'), text(d, 'classifier', ''))
        parts = [key, norm(text(d, 'version', '')), text(d, 'scope', 'compile')]
        if with_optional: parts.append(text(d, 'optional', 'false'))
        return '|'.join(parts)
    props = child(root, 'properties')
    pl = sorted(((local(c.tag), norm(c.text or '')) for c in (props if props is not None else [])))
    deps = [dep(d, True) for d in kids(child(root, 'dependencies'), 'dependency')]
    dm = sorted(dep(d, False) for d in kids(child(child(root, 'dependencyManagement'), 'dependencies'), 'dependency'))
    mods = [m.text or '' for m in kids(child(root, 'modules'), 'module')]
    coords = [[k, norm(text(root, k, 'jar' if k == 'packaging' else ''))] for k in ('groupId', 'artifactId', 'version', 'packaging')]
    return {'__o': [['coords', {'__o': coords}], ['properties', {'__o': [[k, v] for k, v in pl]}],
                    ['dependencies', {'__a': deps}], ['managed', {'__a': dm}], ['modules', {'__a': mods}]]}

paths = [p for p in sys.stdin.read().split('\0') if p]
out = {}
with tempfile.TemporaryDirectory() as tmp:
    r = subprocess.run(['java', '-cp', compiled() + ':' + CP, 'EffectivePom', tmp, os.environ.get('POM_PROFILES', ''),
                        os.environ.get('POM_LOCAL_REPO', LOCAL_REPO)],
                       input='\0'.join(paths).encode(), capture_output=True, check=True)
    f = r.stdout.decode('utf-8').split('\0')
    i, missing = 0, []
    while i < len(f) and f[i]:
        if f[i] == 'MISSING':
            missing.append(f[i + 1]); i += 2; continue
        kind, p, rest = f[i], f[i + 1], f[i + 2]
        i += 3
        if kind in ('OK', 'PARTIAL'):
            try: out[p] = {'value': project(ET.parse(rest).getroot(), os.path.dirname(p))}
            except Exception as e: out[p] = {'error': 'projection: ' + str(e)[:140]}
            if kind == 'PARTIAL' and 'value' in out[p]: out[p]['partial'] = True
        else:
            out[p] = {'error': rest[:200]}
# `--missing`: print only the coordinates neither the tree nor the local repository had
if '--missing' in sys.argv:
    json.dump(sorted(set(missing)), sys.stdout)
else:
    json.dump(out, sys.stdout, ensure_ascii=False)
