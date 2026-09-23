# ORACLE for cartograph.yamlvalue (CART-1044): PyYAML's CBaseLoader — every scalar a string, the
# same contract yamlvalue keeps. Reads NUL-separated paths on stdin; writes one JSON object
# { path: { "value": { "__a": [documents…] } } | { "error": "…" } } on stdout.
import json, sys, yaml
Loader = getattr(yaml, 'CBaseLoader', yaml.BaseLoader)
def pairs(v):
    if isinstance(v, dict): return {'__o': [[str(k), pairs(x)] for k, x in v.items()]}
    if isinstance(v, list): return {'__a': [pairs(x) for x in v]}
    if v is None: return ''
    return str(v)
out = {}
for p in sys.stdin.read().split('\0'):
    if not p: continue
    try:
        with open(p, encoding='utf-8') as fh:
            out[p] = {'value': {'__a': [pairs(d) for d in yaml.load_all(fh, Loader=Loader)]}}
    except Exception as e:
        out[p] = {'error': str(e)[:160]}
json.dump(out, sys.stdout, ensure_ascii=False)
