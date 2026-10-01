# ORACLE for cartograph.k8s's DOCUMENT READING (CART-1268): every rendered manifest read by PyYAML's BaseLoader (every
# scalar a string, yamlvalue's contract) and PROJECTED independently of k8s.lua — kind, name, the first container's
# image, every port (container ports, a Service's ports), every soft-edge reference — along the DERIVED paths of
# cartograph's API table (argv[1]: a JSON file { pod: {Kind: path}, refs: [[kind, path, target|false, how]] }).
# SHARED PREMISE, stated: both sides walk the same derived paths; what this joins is the YAML reading and the walk.
# Reads NUL-separated paths on stdin; writes { path: { "value": { "__a": [projection…] } } | { "error": … } }.
import json, sys, yaml
Loader = getattr(yaml, 'CBaseLoader', yaml.BaseLoader)
api = json.load(open(sys.argv[1]))
refs_of = {}
for kind, path, target, how in api['refs']:
    refs_of.setdefault(kind, []).append((path, target or None, how))

def at_path(v, path):
    cur = [v]
    for seg in path.split('.'):
        name, suf = seg, ''
        for s in ('[]', '{}'):
            if seg.endswith(s): name, suf = seg[:-2], s
        nxt = []
        for x in cur:
            y = x.get(name) if isinstance(x, dict) else None
            if y is None: continue
            if suf == '[]': nxt.extend(y if isinstance(y, list) else [])
            else: nxt.append(y)
        cur = nxt
        if not cur: break
    return cur

def labels(v):
    if not isinstance(v, dict): return None
    return {str(k): x for k, x in v.items() if isinstance(x, str)}

def project(d):
    kind = d.get('kind') if isinstance(d.get('kind'), str) else None
    meta = d.get('metadata') if isinstance(d.get('metadata'), dict) else {}
    name = meta.get('name') if isinstance(meta.get('name'), str) else None
    image, ports = None, []
    pp = api['pod'].get(kind)
    if pp:
        pods = at_path(d, pp)
        pod = pods[0] if pods else None
        if isinstance(pod, dict):
            for i, c in enumerate(pod.get('containers') or []):
                if not isinstance(c, dict): continue
                if i == 0 and isinstance(c.get('image'), str): image = c['image']
                for p in c.get('ports') or []:
                    if isinstance(p, dict) and isinstance(p.get('containerPort'), str) and p['containerPort'].isdigit(): ports.append(int(p['containerPort']))
    if kind == 'Service':
        spec = d.get('spec') if isinstance(d.get('spec'), dict) else {}
        for p in spec.get('ports') or []:
            if isinstance(p, dict) and isinstance(p.get('port'), str) and p['port'].isdigit(): ports.append(int(p['port']))
    refs = []
    for path, target, how in refs_of.get(kind or '', []):
        for x in at_path(d, path):
            if how == 'name':
                if isinstance(x, str): refs.append('name %s/%s @%s' % (target, x, path))
            elif how == 'ref':
                if isinstance(x, dict) and isinstance(x.get('name'), str):
                    k = target or (x.get('kind') if isinstance(x.get('kind'), str) else None)
                    if k: refs.append('ref %s/%s @%s%s' % (k, x['name'], path, ' optional' if x.get('optional') == 'true' else ''))
            elif how == 'selector':
                sel = labels(x.get('matchLabels')) if isinstance(x, dict) and 'matchLabels' in x else (labels(x) if path.endswith('{}') else None)
                if sel: refs.append('selector %s{%s} @%s' % (target, ','.join('%s=%s' % kv for kv in sorted(sel.items())), path))
    out = [['kind', kind or ''], ['name', name or ''], ['image', image or ''],
           ['ports', {'__a': [str(p) for p in sorted(set(ports))]}], ['refs', {'__a': sorted(refs)}]]
    return {'__o': out}

out = {}
for p in sys.stdin.read().split('\0'):
    if not p: continue
    try:
        with open(p, encoding='utf-8') as fh:
            docs = [d for d in yaml.load_all(fh, Loader=Loader) if isinstance(d, dict)]
        out[p] = {'value': {'__a': [project(d) for d in docs]}}
    except Exception as e:
        out[p] = {'error': str(e)[:160]}
json.dump(out, sys.stdout, ensure_ascii=False)
