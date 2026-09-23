# ORACLE for cartograph.xmlvalue (CART-1044): Python's ElementTree under the SAME convention —
# @attr keys, repeated children an array, text-only element = its text, mixed text = #text, names
# in the root element's own namespace bare and others {uri}local. Whitespace is XML's S production
# (space, tab, CR, LF) — NOT Unicode \s, which treats U+00A0 as blank (the oracle had that wrong
# once). Reads NUL-separated paths; writes { path: { "value": {root, value} } | { "error" } }.
import json, re, sys
import xml.etree.ElementTree as ET
def split(tag):
    m = re.match(r'^\{([^}]*)\}(.*)$', tag)
    return (m.group(1), m.group(2)) if m else ('', tag)
def conv(el, home):
    uri, local = split(el.tag)
    name = local if (uri == '' or uri == home) else el.tag
    attrs = []
    for k, v in el.attrib.items():
        auri, alocal = split(k)
        attrs.append(('@' + (alocal if auri == '' else k), v))
    kids = list(el)
    text = (el.text or '') + ''.join((c.tail or '') for c in kids)
    if not attrs and not kids:
        return name, text
    o, keys, counts = {}, [], {}
    for k, v in attrs:
        if k not in o: keys.append(k)
        o[k] = v
    for c in kids:
        cn, cv = conv(c, home)
        if cn not in o:
            keys.append(cn); o[cn] = cv; counts[cn] = 1
        else:
            if counts[cn] == 1: o[cn] = {'__a': [o[cn]]}
            counts[cn] += 1
            o[cn]['__a'].append(cv)
    if re.search(r'[^ \t\r\n]', text):
        if '#text' not in o: keys.append('#text')
        o['#text'] = text
    return name, {'__o': [[k, o[k]] for k in keys]}
out = {}
for p in sys.stdin.read().split('\0'):
    if not p: continue
    try:
        root = ET.parse(p).getroot()
        name, value = conv(root, split(root.tag)[0])
        out[p] = {'value': {'__o': [['root', name], ['value', value]]}}
    except Exception as e:
        out[p] = {'error': str(e)[:160]}
json.dump(out, sys.stdout, ensure_ascii=False)
