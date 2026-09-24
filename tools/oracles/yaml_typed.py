# ORACLE for yamlvalue's implementation PROFILES (CART-1053): what PyYAML's SafeLoader or ruamel's
# safe loader ACTUALLY LOADS, every scalar as "type:value" in yamlvalue.typed()'s canonical form.
#   python3 yaml_typed.py pyyaml-safe|ruamel-safe   (NUL-separated paths on stdin)
# writes { path: {"value": {"__a": [doc, ...]}} | {"error"} }. Canonical: int in decimal ('big' from
# 2^53, where a double stops being exact), float by %.17g (inf/-inf/nan/-0), bool true/false, null,
# a date or datetime 'timestamp'; keys typed the same way (a YAML 1.1 `on:` is a boolean key).
import datetime, json, math, sys

def canon(v):
    if v is None: return 'null'
    if isinstance(v, bool): return 'bool:' + ('true' if v else 'false')
    if isinstance(v, int): return 'int:' + ('big' if abs(v) >= 2 ** 53 else '%d' % v)
    if isinstance(v, float):
        if math.isnan(v): return 'float:nan'
        if math.isinf(v): return 'float:' + ('inf' if v > 0 else '-inf')
        if v == 0 and math.copysign(1, v) < 0: return 'float:-0'
        return 'float:' + ('%.17g' % v)
    if isinstance(v, (datetime.date, datetime.datetime)): return 'timestamp'
    if isinstance(v, str): return 'str:' + v
    if isinstance(v, bytes): return 'binary'
    if isinstance(v, dict): return {'__o': [[canon_key(k), canon(x)] for k, x in v.items()]}
    if isinstance(v, (list, tuple)): return {'__a': [canon(x) for x in v]}
    if isinstance(v, set): return {'__a': sorted(canon(x) for x in v)}
    return 'unknown:' + type(v).__name__

def canon_key(k):
    c = canon(k)
    return c if isinstance(c, str) else json.dumps(c)

mode = sys.argv[1]
if mode == 'pyyaml-safe':
    import yaml
    load_all = lambda src: list(yaml.load_all(src, Loader=yaml.SafeLoader))
elif mode == 'ruamel-safe':
    from ruamel.yaml import YAML
    y = YAML(typ='safe', pure=True)
    load_all = lambda src: list(y.load_all(src))
else:
    sys.exit('unknown mode ' + mode)

out = {}
for p in sys.stdin.read().split('\0'):
    if not p: continue
    try:
        with open(p, encoding='utf-8') as f: src = f.read()
        out[p] = {'value': {'__a': [canon(d) for d in load_all(src)]}}
    except Exception as e:
        out[p] = {'error': (type(e).__name__ + ': ' + str(e)).replace('\n', ' ')[:200]}
json.dump(out, sys.stdout, ensure_ascii=False)
