# ORACLE for yamlvalue's `yq` profile (CART-1053): go-yaml v3's TAG for every scalar, as yq reports
# it — TYPES ONLY, because yq's values come from its own parser, not go-yaml's decoder. Duplicate
# keys are KEPT by yq (both pairs reach its JSON), emitted as {"__dup": [...]} like yamlvalue does.
# ⚠ yq is a snap here: it cannot read /tmp (confinement), so inputs must live under $HOME.
# ⚠ Rewrite only `kind == "scalar"`: rewriting an ALIAS node (a `<<: *x` value) to its tag broke
# the merge and made keys vanish — a harness bug the join caught, not yq's.
import json, subprocess, sys
TAGS = {'!!str': 'str', '!!int': 'int', '!!float': 'float', '!!bool': 'bool', '!!null': 'null', '!!timestamp': 'timestamp'}

def pairs(ps):
    keys, vals = [], {}
    for k, v in ps:
        if k in vals:
            if not (isinstance(vals[k], dict) and '__dup' in vals[k]): vals[k] = {'__dup': [vals[k]]}
            vals[k]['__dup'].append(v)
        else:
            keys.append(k); vals[k] = v
    return {'__pairs': [(k, vals[k]) for k in keys]}

KEYTAGS = {}   # key text -> tags seen anywhere in the document (the fallback)
MAPKEYS = {}   # map path -> a queue of that map's ordered [tag, text] key lists (pass B)

# ★ yq TYPES ITS KEYS (`200:` !!int, `true:` !!bool, `~:` !!null; only its JSON output stringifies them).
# A key's tag is read POSITIONALLY from its own map's key list (so `1:` and `"1":` in one map are an
# int and a str, in order); a map yq's path traversal cannot reach — the SHADOWED one of two duplicate
# keys, yq visits only the last — falls back to the key's text anywhere in the document, and where
# that is unknown or ambiguous the oracle says UNMEASURED rather than guess.
def key(k, tags_here):
    if tags_here is not None and k in tags_here: return TAGS.get(tags_here[k], 'tag') + ':' + k
    tags = KEYTAGS.get(k, set())
    if len(tags) == 1: return TAGS.get(next(iter(tags)), 'tag') + ':' + k
    return 'unmeasured:' + k

def canon(v, path='', positional=True):
    if isinstance(v, dict) and '__pairs' in v:
        tags_here = None
        if positional and MAPKEYS.get(path):
            tags_here = {}
            for tag, text in MAPKEYS[path].pop(0):
                tags_here.setdefault(text, tag)   # the FIRST occurrence of a text is the key's tag
        return {'__o': [[key(k, tags_here), canon_dup(x, path + '/' + k if path else k, positional)] for k, x in v['__pairs']]}
    if isinstance(v, list): return {'__a': [canon(x, (path + '/' if path else '') + str(i), positional) for i, x in enumerate(v)]}
    if isinstance(v, str): return TAGS.get(v, 'tag:' + v) if v.startswith('!') else 'str'
    # ⚠ yq's path-based `|=` cannot address the SECOND of two duplicate keys, so that value arrives
    # untagged as raw JSON — typed here by its JSON type (the tool's limit, stated, not hidden)
    if isinstance(v, bool): return 'bool'
    if isinstance(v, int): return 'int'
    if isinstance(v, float): return 'float'
    if v is None: return 'null'
    return 'unknown:' + type(v).__name__

def canon_dup(x, path, positional):
    if isinstance(x, dict) and '__dup' in x:
        n = len(x['__dup'])
        # only the LAST duplicate is reachable by yq's paths; earlier ones are read without positions
        return {'__o': [['__dup', {'__a': [canon(y, path, positional and i == n - 1) for i, y in enumerate(x['__dup'])]}]]}
    return canon(x, path, positional)

out = {}
for p in sys.stdin.read().split('\0'):
    if not p: continue
    r = subprocess.run(['yq', '-o=json', '-I=0', '(.. | select(kind == "scalar")) |= tag', p],
                       capture_output=True, text=True)
    # pass B: every key's tag, per document (`with_entries` would break merges, so it is a second pass)
    rk = subprocess.run(['yq', '-o=json', '-I=0',
                         '[.. | select(kind == "map") | {"p": (path | map(tostring) | join("/")), "k": [keys | .[] | [tag, (. | tostring)]]}]', p],
                        capture_output=True, text=True)
    if r.returncode != 0 or rk.returncode != 0:
        out[p] = {'error': ((r.stderr or '') + (rk.stderr or '') or 'yq failed').replace('\n', ' ')[:200]}; continue
    def stream(s, hook=None):
        dec, i, vals = json.JSONDecoder(object_pairs_hook=hook) if hook else json.JSONDecoder(), 0, []
        while i < len(s):
            while i < len(s) and s[i] in ' \n\r\t': i += 1
            if i >= len(s): break
            v, i = dec.raw_decode(s, i)
            vals.append(v)
        return vals
    try:
        keylists, docs = stream(rk.stdout), []
        for n, v in enumerate(stream(r.stdout, pairs)):
            KEYTAGS.clear(); MAPKEYS.clear()
            for m in (keylists[n] if n < len(keylists) else []):
                if not isinstance(m, dict): continue
                ks = [kv for kv in m.get('k') or [] if isinstance(kv, list) and len(kv) == 2]
                MAPKEYS.setdefault(m.get('p', ''), []).append(ks)
                for tag, text in ks: KEYTAGS.setdefault(text, set()).add(tag)  # `tostring`: RAW text (010, ~)
            docs.append(canon(v))
        out[p] = {'value': {'__a': docs}}
    except Exception as e:
        out[p] = {'error': 'decode: ' + str(e)[:180]}
json.dump(out, sys.stdout, ensure_ascii=False)
