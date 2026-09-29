// cartograph/luajs/pack.js — THE TEMPLATE PACK the Lua -> JS emitter (cartograph.luajs) expands into (CART-1197).
//
// Each entry is the JS form of ONE Lua construct, written to be faithful for EVERY runtime type (never "right if the
// inferred type is right"). Anything a Lua program can do that an entry does not cover FAILS LOUDLY (`$abort`, a
// thrown LuaBreak naming the construct) — never a silent approximation: a translation that runs and means something
// else is the worst outcome, and a loud failure is a break the differential test can count.
//
// REPRESENTATIONS (user decisions 2026-09-29):
//   nil        undefined
//   string     a BYTE STRING: a JS string whose chars are bytes 0-255 (so #, sub, byte, find offsets are Lua's)
//   table      by SHAPE, chosen per allocation site by the emitter from its uses (tools/jsshape.lua):
//                ARRAY   a JS array, 1-BASED (slot 0 unused): #t = length - 1, holes allowed, trailing nils trimmed
//                RECORD  Object.create(null): STRING keys only (no prototype, so `__proto__` is data)
//                MAP     a JS Map: every other key type (numbers, booleans, tables, functions)
//              ★ A SHAPE IS AN OPTIMIZATION, NEVER A CORRECTNESS BET: a key the shape cannot hold (a string on an
//              ARRAY, a number on a RECORD) goes to the table's SIDE Map (a hidden property), and every accessor —
//              rawget, rawset, #, pairs, next — reads both. MEASURED why: an UNBOUND constructor is judged by its entries
//              alone and escapes by definition (inspect.lua's `return { n = 0 }` is then written `buf[buf.n] = s`), so
//              any shape evidence can be incomplete; a wrong guess now costs speed, not a wrong answer.
//   function   a JS function; multiple returns are an MV (`$mv`), unwrapped by `$1` / spread by `$all`
//   metatable  held in a WeakMap keyed by the table's identity (META), so a table's own representation is untouched.
//              Honoured as Lua 5.1 / LuaJIT does: __index / __newindex on a RAW miss, __call, __tostring, __concat,
//              arithmetic (__add … __unm), __eq (only when BOTH operands are tables sharing the same __eq), __lt / __le,
//              __metatable. __len does NOT fire on a table (5.1 — measured in-tree under LuaJIT), so it is ignored.
//              __mode is held STRONGLY: GC-driven removal is not deterministically observable, so never removing is a
//              faithful subset of what Lua may do.
'use strict';
const path = require('path');
const fs = require('fs');
const nodeos = require('os');
const child = require('child_process');

class LuaError extends Error { constructor(value) { super(typeof value === 'string' ? value : 'error object'); this.value = value; } }
class LuaBreak extends Error { constructor(what) { super('[luajs] no faithful JS form: ' + what); this.what = what; } }
const $abort = what => { throw new LuaBreak(what); };

// ── truthiness and the value-returning and/or ────────────────────────────────────────────────────────────────────
const $t = v => v !== undefined && v !== null && v !== false;
const $and = (a, b) => ($t(a) ? b() : a);
const $or = (a, b) => ($t(a) ? a : b());

// ── multiple values ──────────────────────────────────────────────────────────────────────────────────────────────
class MV { constructor(v) { this.v = v; } }
const $mv = (...v) => (v.length === 1 ? v[0] : new MV(v));
const $1 = x => (x instanceof MV ? x.v[0] : x);
const $all = x => (x instanceof MV ? x.v : [x]);
/** the values of an expression list adjusted to n (a missing value is nil) */
const $adj = (n, vals) => { const o = vals.slice(0, n); while (o.length < n) o.push(undefined); return o; };

// ── tables ───────────────────────────────────────────────────────────────────────────────────────────────────────
const SIDE = Symbol('lua.side'); // the keys a table's SHAPE cannot hold, in a Map
const side = t => t[SIDE];
const side_of = t => { let m = t[SIDE]; if (m === undefined) { m = new Map(); Object.defineProperty(t, SIDE, { value: m, enumerable: false }); } return m; };
const trim = a => { while (a.length > 1 && a[a.length - 1] === undefined) a.length--; return a; };
const $arr = (...items) => trim([undefined, ...items]);
const $rec = (...pairs) => { const o = Object.create(null); for (let i = 0; i < pairs.length; i += 2) if (pairs[i + 1] !== undefined) o[pairs[i]] = pairs[i + 1]; return o; };
const $map = (...pairs) => { const m = new Map(); for (let i = 0; i < pairs.length; i += 2) if (pairs[i + 1] !== undefined) m.set(key(pairs[i]), pairs[i + 1]); return m; };
/** a Map constructor's multi-valued last positional entry: values from position `at` on (a nil stops nothing — it is a hole) */
const $mappos = (m, at, ...vals) => { vals.forEach((v, i) => { if (v !== undefined) m.set(at + i, v); }); return m; };
const isRec = t => t !== null && typeof t === 'object' && !Array.isArray(t) && !(t instanceof Map) && !(t instanceof MV) && Object.getPrototypeOf(t) === null;
const isTable = t => Array.isArray(t) || t instanceof Map || isRec(t);
const key = k => {
  if (k === undefined) throw new LuaError('table index is nil');
  if (typeof k === 'number' && Number.isNaN(k)) throw new LuaError('table index is NaN');
  return k;
};
const META = new WeakMap();
const mt_of = v => (v !== null && typeof v === 'object' || typeof v === 'function' ? META.get(v) : (typeof v === 'string' ? STRING_MT : undefined));
const meta = (v, name) => { const mt = mt_of(v); return mt === undefined ? undefined : rawget(mt, name); };
function rawget(t, k) {
  if (t instanceof Map) return t.get(k);
  if (Array.isArray(t)) { if (typeof k === 'number' && Number.isInteger(k) && k >= 1) return t[k]; const m = side(t); return m === undefined ? undefined : m.get(k); }
  if (isRec(t)) { if (typeof k === 'string') return t[k]; const m = side(t); return m === undefined ? undefined : m.get(k); }
  throw new LuaError("bad argument #1 to 'rawget' (table expected, got " + $type(t) + ')');
}
function $idx(t, k) {
  // a table: its raw value, else its __index (a function is called, a table is indexed — the chain may continue)
  if (isTable(t)) {
    const v = rawget(t, k);
    if (v !== undefined) return v;
    const h = meta(t, '__index');
    if (h === undefined) return undefined;
    return typeof h === 'function' ? $1(h(t, k)) : $idx(h, k);
  }
  if (typeof t === 'object' && t !== null && META.has(t)) {
    // USERDATA (a host object: a file handle) is indexed only through its metatable's __index
    const h = meta(t, '__index');
    if (h !== undefined) return typeof h === 'function' ? $1(h(t, k)) : $idx(h, k);
  }
  return idx_raw(t, k);
}
function idx_raw(t, k) {
  if (isTable(t)) return rawget(t, k);
  if (typeof t === 'string') return STRING[k];
  // the KEY is named, as Lua names the field (a nil `vim` read as vim.fn says "reading 'fn'")
  throw new LuaError('attempt to index a ' + $type(t) + " value (reading '" + String(k) + "')");
}
function $set(t, k, v) {
  // __newindex fires only when the key is ABSENT (a raw nil)
  if (isTable(t) && rawget(t, k) === undefined) {
    const h = meta(t, '__newindex');
    if (h !== undefined) { if (typeof h === 'function') h(t, k, v); else $set(h, k, v); return; }
  }
  rawset(t, k, v);
}
function rawset(t, k, v) {
  key(k);
  if (t instanceof Map) { if (v === undefined) mdel(t, k); else t.set(k, v); return; }
  if (Array.isArray(t)) {
    if (typeof k === 'number' && Number.isInteger(k) && k >= 1) { t[k] = v; if (v === undefined) trim(t); return; }
    if (v === undefined) { const m = side(t); if (m !== undefined) mdel(m, k); } else side_of(t).set(k, v);
    return;
  }
  if (isRec(t)) {
    if (typeof k === 'string') { if (v === undefined) delete t[k]; else t[k] = v; return; }
    if (v === undefined) { const m = side(t); if (m !== undefined) mdel(m, k); } else side_of(t).set(k, v);
    return;
  }
  throw new LuaError('attempt to index a ' + $type(t) + ' value');
}
// ★ A CACHED BORDER per Map (BORDER: every key 1..b is present): `#` extends from it, a delete at k <= b lowers it to
// k-1 (the invariant holds). MEASURED 2026-09-29: the from-1 border search was 43.7% of an extraction under node —
// `parts[#parts + 1] = …` appends were O(n) each (the shape census had flagged exactly this hazard)
const BORDER = new WeakMap();
const mborder = m => { let b = BORDER.get(m) || 0; while (m.get(b + 1) !== undefined) b++; BORDER.set(m, b); return b; };
const mdel = (m, k) => { m.delete(k); if (typeof k === 'number') { const b = BORDER.get(m); if (b !== undefined && k <= b) BORDER.set(m, k - 1); } };
function $len(x) {
  if (typeof x === 'string') return x.length;
  if (Array.isArray(x)) return x.length - 1;
  if (x instanceof Map) return mborder(x);
  if (isRec(x)) { const m = side(x); return m === undefined ? 0 : mborder(m); }
  throw new LuaError('attempt to get length of a ' + $type(x) + ' value');
}
/** a method call obj:m(...): a string's methods are the string library; a table's are its fields */
function $m(obj, name, ...args) {
  const f = typeof obj === 'string' ? STRING[name] : $idx(obj, name);
  if (typeof f !== 'function' && meta(f, '__call') === undefined) throw new LuaError("attempt to call method '" + name + "' (a " + $type(f) + ' value)');
  return $call(f, obj, ...args);
}
function $call(f, ...args) {
  if (typeof f === 'function') return f(...args);
  const h = meta(f, '__call');
  if (h !== undefined) return $call(h, f, ...args);
  throw new LuaError('attempt to call a ' + $type(f) + ' value');
}

// ── arithmetic and strings ───────────────────────────────────────────────────────────────────────────────────────
const num = (x, op) => {
  if (typeof x === 'number') return x;
  if (typeof x === 'string') { const n = $tonumber(x); if (n !== undefined) return n; }
  throw new LuaError('attempt to perform arithmetic on a ' + $type(x) + ' value');
};
const numish = x => typeof x === 'number' || (typeof x === 'string' && $tonumber(x) !== undefined);
/** an arithmetic operator: numbers (and numeric strings) directly, else the first operand's metamethod, then the second's */
const arith = (event, f) => (a, b) => {
  if (numish(a) && numish(b)) return f(num(a), num(b));
  const h = meta(a, event) !== undefined ? meta(a, event) : meta(b, event);
  if (h !== undefined) return $1($call(h, a, b));
  return f(num(a), num(b)); // raises Lua's arithmetic error
};
const $add = arith('__add', (a, b) => a + b);
const $sub = arith('__sub', (a, b) => a - b);
const $mul = arith('__mul', (a, b) => a * b);
const $div = arith('__div', (a, b) => a / b);
const $mod = arith('__mod', (a, b) => a - Math.floor(a / b) * b);
// pow is the C LIBRARY's, as LuaJIT's is (lj_vmmath.c calls libm pow — glibc here): Arm's optimized-routines pow in
// glibc's FMA build, TRANSLITERATED from C with the compiler's own contractions ($libmpow.js, tools/cjs.lua libmpow).
// V8's Math.pow differs from it in the last ulp on 268,366 of 4,000,784 measured inputs; this one on 0 (CART-1211)
const LIBM = require('./$libmpow.js');
const $pow = arith('__pow', (a, b) => LIBM.pow(a, b));
const $neg = a => { if (numish(a)) return -num(a); const h = meta(a, '__unm'); if (h !== undefined) return $1($call(h, a, a)); return -num(a); };
/** Lua's number to string IS LuaJIT's lj_strfmt_num — `%.14g` by LuaJIT's OWN formatter (lj_strfmt_wfnum, which
 *  x64 LuaJIT runs for every number: no integer fast path without DUALNUM), TRANSLITERATED from C ($strfmt.js,
 *  tools/cjs.lua strfmt, CART-1211). Checked by tools/libdiff.lua tostring: 0 of 200,000 generated doubles differ
 *  (exact decimal ties, the %e/%f switch points, subnormals, every power of ten +- ulps). */
const STRFMT = require('./$strfmt.js');
function $numstr(n) { return STRFMT.numstr(n); }

const cstr = x => {
  if (typeof x === 'string') return x;
  if (typeof x === 'number') return $numstr(x);
  throw new LuaError('attempt to concatenate a ' + $type(x) + ' value');
};
const catable = x => typeof x === 'string' || typeof x === 'number';
const $cat = (a, b) => {
  if (catable(a) && catable(b)) return cstr(a) + cstr(b);
  const h = meta(a, '__concat') !== undefined ? meta(a, '__concat') : meta(b, '__concat');
  if (h !== undefined) return $1($call(h, a, b));
  return cstr(a) + cstr(b); // raises Lua's concatenation error
};
/** 5.1: __eq fires only when BOTH are tables (or both userdata) and share the SAME __eq */
const $eq = (a, b) => {
  if (a === b) return true;
  const obj = x => isTable(x) || (x !== null && typeof x === 'object' && META.has(x)); // tables, and userdata (a TSNode)
  if (!obj(a) || !obj(b)) return false;
  const ha = meta(a, '__eq');
  if (ha === undefined || ha !== meta(b, '__eq')) return false;
  return $t($1($call(ha, a, b)));
};
/** 5.1: __lt / __le fire only when both operands are the same non-number, non-string type with the same handler */
const cmpmeta = (event, a, b) => {
  if ($type(a) !== $type(b)) return undefined;
  const h = meta(a, event);
  return h !== undefined && h === meta(b, event) ? h : undefined;
};
const $lt = (a, b) => {
  if (typeof a === typeof b && (typeof a === 'number' || typeof a === 'string')) return a < b;
  const h = cmpmeta('__lt', a, b);
  if (h !== undefined) return $t($1($call(h, a, b)));
  cmpok(a, b); return a < b;
};
const $le = (a, b) => {
  if (typeof a === typeof b && (typeof a === 'number' || typeof a === 'string')) return a <= b;
  const h = cmpmeta('__le', a, b);
  if (h !== undefined) return $t($1($call(h, a, b)));
  const hl = cmpmeta('__lt', a, b); // 5.1: a <= b is not (b < a) when only __lt exists
  if (hl !== undefined) return !$t($1($call(hl, b, a)));
  cmpok(a, b); return a <= b;
};
// a > b and a >= b keep Lua's LEFT-TO-RIGHT evaluation (rewriting them as b < a would evaluate b first)
const $gt = (a, b) => { const x = a, y = b; return $lt(y, x); };
const $ge = (a, b) => { const x = a, y = b; return $le(y, x); };
const cmpok = (a, b) => { if (!((typeof a === 'number' && typeof b === 'number') || (typeof a === 'string' && typeof b === 'string'))) { const ta = $type(a), tb = $type(b); throw new LuaError(ta === tb ? 'attempt to compare two ' + ta + ' values' : 'attempt to compare ' + ta + ' with ' + tb); } }; // LuaJIT lj_err_comp: BADCMPV when the type names match, else BADCMPT

// ── the base library ─────────────────────────────────────────────────────────────────────────────────────────────
const ids = new WeakMap(); let nextId = 1;
const addr = o => { if (!ids.has(o)) ids.set(o, nextId++); return '0x' + ids.get(o).toString(16).padStart(8, '0'); };
function $type(v) {
  if (v === undefined || v === null) return 'nil';
  if (typeof v === 'boolean') return 'boolean';
  if (typeof v === 'number') return 'number';
  if (typeof v === 'string') return 'string';
  if (typeof v === 'function') return 'function';
  if (isTable(v)) return 'table';
  return 'userdata';
}
function $tostring(v) {
  const t = $type(v);
  if (t === 'nil') return 'nil';
  if (t === 'boolean') return v ? 'true' : 'false';
  if (t === 'number') return $numstr(v);
  if (t === 'string') return v;
  const h = meta(v, '__tostring');
  if (h !== undefined) { const s = $1($call(h, v)); if (typeof s !== 'string') throw new LuaError("'__tostring' must return a string"); return s; }
  return t + ': ' + addr(v);
}
/** a numeric for's control values, checked AFTER all three are evaluated (the JS call evaluates its arguments first),
 *  in LuaJIT's order: initial value, limit, step — each a number or a string Lua reads as one (lj_meta_for:
 *  lj_strscan_numberobj; measured: `for i = "0x2", "3"` runs 2 3, `for i = 1, nil` is "'for' limit must be a number") */
function $forprep(a, b, s) {
  const n = (v, what) => {
    if (typeof v === 'number') return v;
    const x = typeof v === 'string' ? $tonumber(v) : undefined;
    if (x === undefined) throw new LuaError("'for' " + what + ' must be a number');
    return x;
  };
  const v = [n(a, 'initial value'), n(b, 'limit'), n(s, 'step')];
  // the DIRECTION is the step's SIGN BIT, as LuaJIT's: a step of 0 counts UP (`for i = 1, 2, 0` loops, `2, 1, 0` does
  // not), -0 counts DOWN — measured; a `s > 0` test had both backwards
  v.push(v[2] > 0 || Object.is(v[2], 0));
  return v;
}
const SCAN = require('./$strscan.js');
function $tonumber(v, base) {
  if (base !== undefined && base !== 10) {
    if (typeof v !== 'string' && typeof v !== 'number') return undefined;
    const s = String(v).trim().toLowerCase();
    if (!/^-?[0-9a-z]+$/.test(s)) return undefined;
    const n = parseInt(s, base);
    const digits = s.replace(/^-/, '');
    for (const ch of digits) if (parseInt(ch, 36) >= base) return undefined;
    return Number.isNaN(n) ? undefined : n;
  }
  if (typeof v === 'number') return v;
  if (typeof v !== 'string') return undefined;
  // a STRING is read by LuaJIT's OWN scanner, transliterated from C (lj_strscan.c at the oracle's revision —
  // $strscan.js, tools/cjs.lua strscan): hex floats, inf/nan, every C whitespace byte, correctly rounded decimals. The
  // hand-written regexes it replaces differed from LuaJIT on 17,886 of 200,000 generated strings; it on 0 (CART-1211)
  return SCAN.tonum(v);
}
const pairs_iter = t => {
  if (t instanceof Map) { const it = t.entries(); return () => { for (;;) { const r = it.next(); if (r.done) return undefined; const [k, v] = r.value; if (t.has(k) && t.get(k) !== undefined) return $mv(k, v); } }; }
  const side_iter = m => { if (m === undefined) return () => undefined; const it = m.entries(); return () => { for (;;) { const r = it.next(); if (r.done) return undefined; const [k, v] = r.value; if (m.has(k) && m.get(k) !== undefined) return $mv(k, v); } }; };
  if (Array.isArray(t)) { let i = 0, rest; return () => { while (++i < t.length) if (t[i] !== undefined) return $mv(i, t[i]); rest = rest || side_iter(side(t)); return rest(); }; }
  if (isRec(t)) { const ks = Object.keys(t); let i = 0, rest; return () => { while (i < ks.length) { const k = ks[i++]; if (t[k] !== undefined) return $mv(k, t[k]); } rest = rest || side_iter(side(t)); return rest(); }; }
  throw new LuaError("bad argument #1 to 'pairs' (table expected, got " + $type(t) + ')');
};
const G = Object.create(null);
G.pairs = t => $mv(pairs_iter(t), t, undefined);
// 5.1: ipairs, unpack and the table library read and write RAW (lua_rawgeti) — metamethods do not fire
G.ipairs = t => { if (!isTable(t) && typeof t !== 'string') throw new LuaError("bad argument #1 to 'ipairs' (table expected, got " + $type(t) + ')'); return $mv((s, i) => { i = i + 1; const v = rawget(s, i); return v === undefined ? undefined : $mv(i, v); }, t, 0); };
// next(t, k): the entry AFTER k in the same traversal order pairs uses (arrays by index, records by key order, maps
// by insertion); a nil value is skipped as a missing key. ⚠ O(n) per step (it finds k first) — faithful, not fast.
G.next = (t, k) => {
  if (k === undefined) { const r = pairs_iter(t)(); return r === undefined ? undefined : r; }
  if (t instanceof Map) {
    let seen = false;
    for (const [kk, v] of t) { if (seen) { if (v !== undefined) return $mv(kk, v); } else if (kk === k) seen = true; }
    if (!seen) throw new LuaError("invalid key to 'next'");
    return undefined;
  }
  if (Array.isArray(t) || isRec(t)) {
    // the same order pairs walks — the shaped part, then the side Map — found by walking it
    const it = pairs_iter(t);
    for (let r = it(); r !== undefined; r = it()) {
      if ($all(r)[0] === k) { const n = it(); return n === undefined ? undefined : n; }
    }
    throw new LuaError("invalid key to 'next'");
  }
  throw new LuaError("bad argument #1 to 'next' (table expected, got " + $type(t) + ')');
};
G.type = v => $type(v);
G.tostring = v => $tostring(v);
G.tonumber = (v, b) => $tonumber(v, b);
G.select = (n, ...a) => (n === '#' ? a.length : $mv(...a.slice(n < 0 ? a.length + n : n - 1)));
G.unpack = (t, i, j) => { i = i === undefined ? 1 : i; j = j === undefined ? $len(t) : j; const o = []; for (let k = i; k <= j; k++) o.push(rawget(t, k)); return $mv(...o); };
G.error = (v, level) => { throw new LuaError(v); };
G.assert = (v, msg, ...rest) => { if (!$t(v)) throw new LuaError(msg === undefined ? 'assertion failed!' : msg); return $mv(v, msg, ...rest); };
// a LuaBreak is NOT a Lua error — it is a construct with no faithful form, reached: pcall must not swallow it (a break
// inside pcall would otherwise turn into a quiet `false, <object>`)
G.pcall = (f, ...a) => { try { return $mv(true, ...$all($call(f, ...a))); } catch (e) { if (e instanceof LuaBreak) throw e; return $mv(false, e instanceof LuaError ? e.value : String(e && e.message || e)); } };G.rawequal = (a, b) => a === b;
G.rawget = (t, k) => rawget(t, k);
G.rawset = (t, k, v) => { if (!isTable(t)) throw new LuaError("bad argument #1 to 'rawset' (table expected, got " + $type(t) + ')'); rawset(t, k, v); return t; };
G.setmetatable = (t, mt) => {
  if (!isTable(t)) throw new LuaError("bad argument #1 to 'setmetatable' (table expected, got " + $type(t) + ')');
  if (mt !== undefined && !isTable(mt)) throw new LuaError("bad argument #2 to 'setmetatable' (nil or table expected)");
  const old = META.get(t);
  if (old !== undefined && rawget(old, '__metatable') !== undefined) throw new LuaError('cannot change a protected metatable');
  if (mt === undefined) META.delete(t); else META.set(t, mt);
  return t;
};
G.getmetatable = v => { const mt = mt_of(v); if (mt === undefined) return undefined; const p = rawget(mt, '__metatable'); return p !== undefined ? p : mt; };
G.print = (...a) => { fs.writeSync(1, Buffer.from(a.map($tostring).join('\t') + '\n', 'latin1')); };
G.require = name => $require(name);
G.package = $rec('loaded', $rec(), 'path', '', 'cpath', '');
G._G = G;
// evaluating Lua SOURCE at run time has no faithful form here (the emitter runs in nvim, not in this pack)
G.load = () => $abort('load (evaluating Lua source at run time)');
G.loadstring = () => $abort('loadstring (evaluating Lua source at run time)');
G.dofile = () => $abort('dofile (evaluating Lua source at run time)');
G.loadfile = () => $abort('loadfile (evaluating Lua source at run time)');
G._VERSION = 'Lua 5.1';
G.table = $rec(
  'insert', (t, a, b) => { if (b === undefined) rawset(t, $len(t) + 1, a); else { const n = $len(t); for (let k = n; k >= a; k--) rawset(t, k + 1, rawget(t, k)); rawset(t, a, b); } },
  'remove', (t, pos) => { const n = $len(t); if (pos === undefined) pos = n; if (n === 0) return undefined; const v = rawget(t, pos); for (let k = pos; k < n; k++) rawset(t, k, rawget(t, k + 1)); rawset(t, n, undefined); return v; },
  'concat', (t, sep, i, j) => { sep = sep === undefined ? '' : sep; i = i === undefined ? 1 : i; j = j === undefined ? $len(t) : j; const o = []; for (let k = i; k <= j; k++) { const v = rawget(t, k); if (typeof v !== 'string' && typeof v !== 'number') throw new LuaError("invalid value (at index " + k + ") in table for 'concat'"); o.push(cstr(v)); } return o.join(cstr(sep)); },
  'sort', (t, cmp) => { const n = $len(t); const a = []; for (let k = 1; k <= n; k++) a.push(rawget(t, k)); a.sort((x, y) => (cmp ? ($t($1($call(cmp, x, y))) ? -1 : ($t($1($call(cmp, y, x))) ? 1 : 0)) : ($lt(x, y) ? -1 : ($lt(y, x) ? 1 : 0)))); for (let k = 1; k <= n; k++) rawset(t, k, a[k - 1]); },
  'unpack', (...a) => G.unpack(...a));
G.math = $rec('floor', Math.floor, 'ceil', Math.ceil, 'abs', Math.abs, 'sqrt', Math.sqrt, 'pow', (a, b) => LIBM.pow(num(a), num(b)), 'max', (...a) => Math.max(...a.map(x => num(x))), 'min', (...a) => Math.min(...a.map(x => num(x))),
  'huge', Infinity, 'pi', Math.PI, 'exp', Math.exp, 'log', (x, b) => (b === undefined ? Math.log(x) : Math.log(x) / Math.log(b)), 'fmod', (a, b) => a % b, 'modf', x => $mv(Math.trunc(x), x - Math.trunc(x)),
  'random', () => $abort('math.random (a different generator)'), 'randomseed', () => $abort('math.randomseed'));
const STRING = Object.create(null);
const bpos = (s, i) => (i < 0 ? Math.max(s.length + i + 1, 1) : (i === 0 ? 1 : i));
STRING.len = s => cstr(s).length;
STRING.sub = (s, i, j) => { s = cstr(s); const n = s.length; i = i === undefined ? 1 : i; j = j === undefined ? -1 : j; if (i < 0) i = Math.max(n + i + 1, 1); else if (i === 0) i = 1; if (j < 0) j = n + j + 1; else if (j > n) j = n; return i > j ? '' : s.slice(i - 1, j); };
STRING.byte = (s, i, j) => { s = cstr(s); i = i === undefined ? 1 : bpos(s, i); j = j === undefined ? i : (j < 0 ? s.length + j + 1 : j); const o = []; for (let k = i; k <= Math.min(j, s.length); k++) o.push(s.charCodeAt(k - 1)); return $mv(...o); };
STRING.char = (...c) => String.fromCharCode(...c);
STRING.rep = (s, n, sep) => { s = cstr(s); if (n <= 0) return ''; return sep === undefined ? s.repeat(n) : Array(n).fill(s).join(cstr(sep)); };
STRING.lower = s => cstr(s).replace(/[A-Z]/g, c => c.toLowerCase());
STRING.upper = s => cstr(s).replace(/[a-z]/g, c => c.toUpperCase());
STRING.reverse = s => cstr(s).split('').reverse().join('');
// ── Lua patterns: LuaJIT's OWN matcher, TRANSLITERATED from src/lib_string.c by cartograph.cjs ($lstrmatch.js,
// generated — its header names the source and the commit). What follows is only the ADAPTER at the Lua C-API seam,
// written line for line from str_find_aux / lj_cf_string_gmatch_aux / lj_cf_string_gsub / add_s / add_value: the
// matcher sees one byte HEAP (its tables, then the subject + NUL, then the pattern + NUL), a pointer is an offset.
const LM = require('./$lstrmatch.js');
const IMG = LM.image();
const MAXCAP = LM.STRUCTS.MatchState.capture;
let HEAP = null;
const use = h => { HEAP = h; LM.setheap(h); };
const hstr = (h, at, n) => frombytes(Buffer.from(h.buffer, h.byteOffset + at, n));
LM.bind({
  $cerr: msg => { throw new LuaError(msg); },
  $memcmp: (a, b, n) => { for (let i = 0; i < n; i++) { const d = HEAP[a + i] - HEAP[b + i]; if (d) return d; } return 0; },
  $push: (L, v) => { L.push(v); },
  $str: (at, n) => hstr(HEAP, at, n),
});
function prepare(s, p) {
  const s0 = LM.IMAGE_END, p0 = s0 + s.length + 1;
  const h = new Uint8Array(p0 + p.length + 1);
  h.set(IMG, 0);
  for (let i = 0; i < s.length; i++) h[s0 + i] = s.charCodeAt(i);
  for (let i = 0; i < p.length; i++) h[p0 + i] = p.charCodeAt(i);
  return { h, s0, p0 };
}
const mstate = (s0, n) => ({ src_init: s0, src_end: s0 + n, L: [], level: 0, depth: 0,
  capture: Array.from({ length: MAXCAP }, () => ({ init: 0, len: 0 })) });
// lj_str_haspattern: any of ^$*+?.([%- (lj_char_ispunct excludes the NUL strchr would also find)
const haspattern = p => /[\^$*+?.(\[%-]/.test(p);
const optint = (v, d) => (v === undefined ? d : Math.trunc(num(v)));
function find_aux(find, s, p, init, plain) {
  s = cstr(s); p = cstr(p);
  let start = optint(init, 1);
  if (start < 0) start += s.length; else start--;
  if (start < 0) start = 0;
  let st = start;
  if (st > s.length) st = s.length; // !LJ_52
  if (find && ($t(plain) || !haspattern(p))) { // search for a fixed string
    const q = s.indexOf(p, st);
    return q < 0 ? undefined : $mv(q + 1, q + p.length);
  }
  const { h, s0, p0 } = prepare(s, p);
  let pstr = p0, sstr = s0 + st, anchor = 0;
  if (h[pstr] === 94) { pstr++; anchor = 1; }
  const ms = mstate(s0, s.length);
  do {
    ms.level = ms.depth = 0;
    use(h);
    const q = LM.match(ms, sstr, pstr);
    if (q !== null) {
      ms.L = [];
      if (find) { const a = sstr - (s0 - 1), b = q - s0; LM.push_captures(ms, null, null); return $mv(a, b, ...ms.L); }
      LM.push_captures(ms, sstr, q);
      return $mv(...ms.L);
    }
  } while (sstr++ < ms.src_end && !anchor);
  return undefined;
}
STRING.find = (s, p, init, plain) => find_aux(true, s, p, init, plain);
STRING.match = (s, p, init) => find_aux(false, s, p, init);
STRING.gmatch = (s, p) => {
  s = cstr(s); p = cstr(p);
  const { h, s0, p0 } = prepare(s, p);
  const ms = mstate(s0, s.length);
  let pos = 0;
  return () => {
    for (let src = s0 + pos; src <= ms.src_end; src++) {
      ms.level = ms.depth = 0;
      use(h);
      const e = LM.match(ms, src, p0);
      if (e !== null) {
        let np = e - s0;
        if (e === src) np++; // ensure progress for an empty match
        pos = np;
        ms.L = [];
        LM.push_captures(ms, src, e);
        return $mv(...ms.L);
      }
    }
    return undefined;
  };
};
function add_s(ms, h, b, s, e, news) {
  for (let i = 0; i < news.length; i++) {
    if (news.charCodeAt(i) !== 37) { b.push(news[i]); continue; }
    i++; // skip ESC
    const d = i < news.length ? news.charCodeAt(i) : 0; // C reads the terminating NUL
    if (!(d >= 48 && d <= 57)) b.push(String.fromCharCode(d));
    else if (d === 48) b.push(hstr(h, s, e - s));
    else { ms.L = []; use(h); LM.push_onecapture(ms, d - 49, s, e); b.push(cstr(ms.L[0])); }
  }
}
function add_value(ms, h, b, s, e, repl, tr) {
  if (tr === 'number' || tr === 'string') { add_s(ms, h, b, s, e, cstr(repl)); return; }
  let v;
  ms.L = []; use(h);
  if (tr === 'function') { LM.push_captures(ms, s, e); v = $1($call(repl, ...ms.L)); }
  else { LM.push_onecapture(ms, 0, s, e); v = $idx(repl, ms.L[0]); }
  if (!$t(v)) b.push(hstr(h, s, e - s)); // nil or false: keep the original text
  else if (typeof v === 'string' || typeof v === 'number') b.push(cstr(v));
  else throw new LuaError('invalid replacement value (a ' + $type(v) + ')');
}
STRING.gsub = (s, p, repl, max_s) => {
  s = cstr(s); p = cstr(p);
  const tr = $type(repl);
  if (!(tr === 'number' || tr === 'string' || tr === 'function' || tr === 'table')) throw new LuaError("bad argument #3 to 'gsub' (string/function/table expected)");
  const max = optint(max_s, s.length + 1);
  const { h, s0, p0 } = prepare(s, p);
  let pp = p0, anchor = 0;
  if (h[pp] === 94) { pp++; anchor = 1; }
  const ms = mstate(s0, s.length);
  let src = s0, n = 0;
  const b = [];
  while (n < max) {
    ms.level = ms.depth = 0;
    use(h);
    const e = LM.match(ms, src, pp);
    if (e !== null) { n++; add_value(ms, h, b, src, e, repl, tr); }
    if (e !== null && e > src) src = e; // a non-empty match: skip it
    else if (src < ms.src_end) b.push(String.fromCharCode(h[src++]));
    else break;
    if (anchor) break;
  }
  b.push(hstr(h, src, ms.src_end - src));
  return $mv(b.join(''), n);
};
STRING.format = (fmt, ...args) => {
  let i = 0;
  return cstr(fmt).replace(/%([-+ #0]*)(\d*)(?:\.(\d+))?([sdiqfgxXcoeE%])/g, (all, flags, width, prec, conv) => {
    if (conv === '%') return '%';
    const v = args[i++];
    let out;
    switch (conv) {
      case 's': out = $tostring(v); if (prec !== undefined) out = out.slice(0, +prec); break;
      case 'd': case 'i': out = String(Math.trunc(num(v))); break;
      case 'f': out = num(v).toFixed(prec === undefined ? 6 : +prec); break;
      case 'x': out = Math.trunc(num(v)).toString(16); break;
      case 'X': out = Math.trunc(num(v)).toString(16).toUpperCase(); break;
      case 'c': out = String.fromCharCode(num(v)); break;
      case 'g': if (prec === undefined) { out = $numstr(num(v)); if (Number.isInteger(num(v)) && Math.abs(num(v)) >= 1e6) $abort('%g of a large integer'); } else $abort('%.Ng'); break;
      default: $abort('string.format %' + conv);
    }
    const w = width === '' ? 0 : +width;
    if (out.length < w) out = flags.includes('-') ? out.padEnd(w) : (flags.includes('0') && conv !== 's' ? out.padStart(w, '0') : out.padStart(w));
    return out;
  });
};
G.string = Object.assign(Object.create(null), STRING);
// getmetatable('') is { __index = string }, as in Lua
const STRING_MT = $rec('__index', G.string);

// ── HOST: the operating system, as LuaJIT's io / os / debug libraries see it ─────────────────────────────────────
// A byte string crosses to the OS as the same BYTES (Buffer.from(s, 'latin1')); what the OS hands back (a file, an
// environment value) comes in as bytes. Errors are Lua's triple: nil, "<path>: <strerror>", errno.
const bytes = s => Buffer.from(cstr(s), 'latin1');
const frombytes = b => b.toString('latin1');
const utf8bytes = s => Buffer.from(String(s), 'utf8').toString('latin1'); // a JS (UTF-16) host string -> a byte string
const STRERROR = $rec('ENOENT', 'No such file or directory', 'EACCES', 'Permission denied', 'EISDIR', 'Is a directory',
  'ENOTDIR', 'Not a directory', 'EEXIST', 'File exists', 'ENOTEMPTY', 'Directory not empty', 'EBADF', 'Bad file descriptor',
  'EPERM', 'Operation not permitted', 'EXDEV', 'Invalid cross-device link');
const errno = e => (e && e.code && nodeos.constants.errno[e.code]) || 0;
const oserr = (e, p) => {
  const msg = STRERROR[e && e.code] || (e && e.code) || String(e);
  return $mv(undefined, p === undefined ? msg : cstr(p) + ': ' + msg, errno(e));
};

// file handles: USERDATA with a metatable, as in Lua (type() is 'userdata', io.type() is 'file')
class LuaFile { constructor(fd, name) { this.fd = fd; this.name = name; this.pos = 0; this.closed = false; this.std = false; } }
const FILE = Object.create(null);
const FILE_MT = $rec('__index', FILE, '__tostring', f => (f.closed ? 'file (closed)' : 'file (' + addr(f) + ')'));
const mkfile = (fd, name) => { const f = new LuaFile(fd, name); META.set(f, FILE_MT); return f; };
const openfile = f => { if (!(f instanceof LuaFile)) throw new LuaError('bad argument #1 (FILE* expected, got ' + $type(f) + ')'); if (f.closed) throw new LuaError('attempt to use a closed file'); return f; };
function readn(f, n) {
  const buf = Buffer.alloc(n);
  let got;
  try { got = fs.readSync(f.fd, buf, 0, n, f.std ? null : f.pos); } catch (e) { return { err: e }; }
  if (!f.std) f.pos += got;
  return { s: frombytes(buf.subarray(0, got)), n: got };
}
function readall(f) {
  const parts = [];
  for (;;) { const r = readn(f, 65536); if (r.err) return r; if (r.n === 0) break; parts.push(r.s); }
  return { s: parts.join('') };
}
function readline(f, keep) {
  const parts = [];
  for (;;) {
    const r = readn(f, 1);
    if (r.err) return r;
    if (r.n === 0) return parts.length ? { s: parts.join('') } : { s: undefined };
    if (r.s === '\n') { if (keep) parts.push('\n'); return { s: parts.join('') }; }
    parts.push(r.s);
  }
}
function read1(f, fmt) {
  if (typeof fmt === 'number') { if (fmt === 0) { const r = readn(f, 1); if (r.err) return r; if (r.n === 0) return { s: undefined }; f.pos -= 1; return { s: '' }; } const r = readn(f, fmt); return r.err ? r : { s: r.n === 0 ? undefined : r.s }; }
  const k = String(fmt).replace(/^\*/, '')[0];
  if (k === 'a') return readall(f);
  if (k === 'l') return readline(f, false);
  if (k === 'L') return readline(f, true);
  if (k === 'n') { const r = readall(f); if (r.err) return r; const m = /^\s*([+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?|[+-]?0[xX][0-9a-fA-F]+)/.exec(r.s); if (!m) { f.pos -= r.s.length; return { s: undefined }; } f.pos -= r.s.length - m[0].length; return { s: $tonumber(m[1]) }; }
  $abort("file:read format '" + String(fmt) + "'");
}
FILE.read = (f, ...fmts) => {
  openfile(f);
  if (fmts.length === 0) fmts = ['l'];
  const out = [];
  for (const fmt of fmts) {
    const r = read1(f, fmt);
    if (r.err) return oserr(r.err);
    out.push(r.s);
    if (r.s === undefined) break;
  }
  return $mv(...out);
};
FILE.lines = (f, fmt) => { openfile(f); return () => $1(FILE.read(f, fmt === undefined ? 'l' : fmt)); };
FILE.write = (f, ...a) => {
  openfile(f);
  for (const x of a) {
    const b = bytes(x);
    try { const n = fs.writeSync(f.fd, b, 0, b.length, f.std || f.append ? null : f.pos); if (!f.std) f.pos += n; } catch (e) { return oserr(e); }
  }
  return f;
};
FILE.seek = (f, whence, offset) => {
  openfile(f);
  whence = whence === undefined ? 'cur' : whence; offset = offset === undefined ? 0 : offset;
  let base = 0;
  if (whence === 'cur') base = f.pos;
  else if (whence === 'end') { try { base = fs.fstatSync(f.fd).size; } catch (e) { return oserr(e); } }
  else if (whence !== 'set') throw new LuaError("bad argument #1 to 'seek' (invalid option '" + whence + "')");
  f.pos = base + offset;
  return f.pos;
};
FILE.flush = f => { openfile(f); return f; };
FILE.close = f => { openfile(f); if (f.std) return $mv(undefined, 'cannot close standard file'); try { fs.closeSync(f.fd); } catch (e) { return oserr(e); } f.closed = true; return true; };
FILE.setvbuf = f => true;
const MODES = $rec('r', 'r', 'w', 'w', 'a', 'a', 'r+', 'r+', 'w+', 'w+', 'a+', 'a+');
const stdio = (fd, name) => { const f = mkfile(fd, name); f.std = true; return f; };
const STDIN = stdio(0, 'stdin'), STDOUT = stdio(1, 'stdout'), STDERR = stdio(2, 'stderr');
G.io = $rec(
  'open', (p, mode) => {
    mode = mode === undefined ? 'r' : cstr(mode);
    const m = MODES[mode.replace('b', '')];
    if (m === undefined) throw new LuaError("bad argument #2 to 'open' (invalid mode '" + mode + "')");
    let fd;
    try { fd = fs.openSync(bytes(p), m); } catch (e) { return oserr(e, p); }
    const f = mkfile(fd, p);
    f.append = m[0] === 'a';
    return f;
  },
  'write', (...a) => FILE.write(STDOUT, ...a),
  'close', f => (f === undefined ? FILE.close(STDOUT) : FILE.close(f)),
  'read', (...fmts) => FILE.read(STDIN, ...fmts),
  'lines', (p, fmt) => {
    if (p === undefined) return FILE.lines(STDIN, fmt);
    const f = $1(G.io.open(p, 'r'));
    if (f === undefined) throw new LuaError(cstr(p) + ': No such file or directory');
    return () => { const v = $1(FILE.read(f, fmt === undefined ? 'l' : fmt)); if (v === undefined) FILE.close(f); return v; };
  },
  'type', f => (f instanceof LuaFile ? (f.closed ? 'closed file' : 'file') : undefined),
  'popen', () => $abort('io.popen (a subprocess with a Lua file interface)'),
  'tmpfile', () => $abort('io.tmpfile'),
  'stdin', STDIN, 'stdout', STDOUT, 'stderr', STDERR);

// strftime, the C locale (the codes LuaJIT's os.date passes to the C library; an unknown one aborts by name)
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const p2 = n => String(n).padStart(2, '0');
function parts(d, utc) {
  const g = k => d[(utc ? 'getUTC' : 'get') + k]();
  const year = g('FullYear'), month = g('Month'), day = g('Date');
  const start = utc ? Date.UTC(year, 0, 1) : new Date(year, 0, 1).getTime();
  const now = utc ? Date.UTC(year, month, day) : new Date(year, month, day).getTime();
  return { year, month, day, hour: g('Hours'), min: g('Minutes'), sec: g('Seconds'), wday: g('Day'), yday: Math.round((now - start) / 864e5) + 1 };
}
function strftime(fmt, d, utc) {
  const t = parts(d, utc);
  return fmt.replace(/%(.)/g, (all, c) => {
    switch (c) {
      case 'Y': return String(t.year);
      case 'y': return p2(t.year % 100);
      case 'm': return p2(t.month + 1);
      case 'd': return p2(t.day);
      case 'e': return String(t.day).padStart(2, ' ');
      case 'H': return p2(t.hour);
      case 'I': return p2(((t.hour + 11) % 12) + 1);
      case 'M': return p2(t.min);
      case 'S': return p2(t.sec);
      case 'p': return t.hour < 12 ? 'AM' : 'PM';
      case 'a': return DAYS[t.wday].slice(0, 3);
      case 'A': return DAYS[t.wday];
      case 'b': case 'h': return MONTHS[t.month].slice(0, 3);
      case 'B': return MONTHS[t.month];
      case 'j': return String(t.yday).padStart(3, '0');
      case 'w': return String(t.wday);
      case 'x': return p2(t.month + 1) + '/' + p2(t.day) + '/' + p2(t.year % 100);
      case 'X': return p2(t.hour) + ':' + p2(t.min) + ':' + p2(t.sec);
      case 'c': return DAYS[t.wday].slice(0, 3) + ' ' + MONTHS[t.month].slice(0, 3) + ' ' + String(t.day).padStart(2, ' ') + ' ' + p2(t.hour) + ':' + p2(t.min) + ':' + p2(t.sec) + ' ' + t.year;
      case 'F': return t.year + '-' + p2(t.month + 1) + '-' + p2(t.day);
      case 'T': return p2(t.hour) + ':' + p2(t.min) + ':' + p2(t.sec);
      case 's': return String(Math.floor(d.getTime() / 1000));
      case 'z': { if (utc) return '+0000'; const o = -d.getTimezoneOffset(); return (o < 0 ? '-' : '+') + p2(Math.floor(Math.abs(o) / 60)) + p2(Math.abs(o) % 60); }
      case '%': return '%';
      default: $abort('os.date %' + c);
    }
  });
}
G.os = $rec(
  'time', t => {
    if (t === undefined) return Math.floor(Date.now() / 1000);
    const f = k => { const v = $idx(t, k); return v === undefined ? undefined : num(v); };
    const year = f('year'), month = f('month'), day = f('day');
    if (year === undefined || month === undefined || day === undefined) throw new LuaError("field 'day' missing in date table");
    const hour = f('hour'), min = f('min'), sec = f('sec');
    return Math.floor(new Date(year, month - 1, day, hour === undefined ? 12 : hour, min || 0, sec || 0).getTime() / 1000);
  },
  'date', (fmt, t) => {
    fmt = fmt === undefined ? '%c' : cstr(fmt);
    const d = new Date((t === undefined ? Math.floor(Date.now() / 1000) : num(t)) * 1000);
    let utc = false;
    if (fmt[0] === '!') { utc = true; fmt = fmt.slice(1); }
    if (fmt.startsWith('*t')) {
      const x = parts(d, utc);
      return $rec('year', x.year, 'month', x.month + 1, 'day', x.day, 'hour', x.hour, 'min', x.min, 'sec', x.sec, 'wday', x.wday + 1, 'yday', x.yday, 'isdst', false);
    }
    return strftime(fmt, d, utc);
  },
  'clock', () => { const u = process.cpuUsage(); return (u.user + u.system) / 1e6; },
  'getenv', k => { const v = process.env[frombytes(bytes(k))]; return v === undefined ? undefined : utf8bytes(v); },
  'exit', code => process.exit(code === undefined || code === true ? 0 : (code === false ? 1 : num(code))),
  'remove', p => {
    try { const st = fs.lstatSync(bytes(p)); if (st.isDirectory()) fs.rmdirSync(bytes(p)); else fs.unlinkSync(bytes(p)); return true; } catch (e) { return oserr(e, p); }
  },
  'rename', (a, b) => { try { fs.renameSync(bytes(a), bytes(b)); return true; } catch (e) { return oserr(e, a); } },
  'tmpname', () => utf8bytes(path.join(nodeos.tmpdir(), 'lua_' + process.pid + '_' + (nextId++).toString(36))),
  'execute', cmd => {
    if (cmd === undefined) return 1;
    const r = child.spawnSync('/bin/sh', ['-c', frombytes(bytes(cmd))], { stdio: 'inherit' });
    return r.status === null ? 1 : r.status * 256; // 5.1: the raw wait status, as C system() returns it
  });

// debug: the SOURCE of the running Lua module (`debug.getinfo(1, 'S')`, the idiom cartograph uses to find its own
// files) — the emitted module's JS path mapped back to the Lua file it was transliterated from (LUAJS_SRC_ROOT); a
// deeper level, another field set, or a function argument has no faithful form here and aborts by name
const chunkid = src => (src.length <= 59 ? src : '...' + src.slice(src.length - 56));
function source_of_caller() {
  const files = [];
  for (const l of String(new Error().stack).split('\n').slice(1)) {
    const m = /\(?((?:\/|[A-Za-z]:\\)[^():]+\.js):\d+:\d+\)?\s*$/.exec(l);
    if (m && m[1] !== __filename) files.push(m[1]);
  }
  const js = files[0];
  if (js === undefined) return undefined;
  const root = process.env.LUAJS_ROOT || __dirname;
  const rel = path.relative(root, js).replace(/\.js$/, '.lua');
  const src = process.env.LUAJS_SRC_ROOT ? path.join(process.env.LUAJS_SRC_ROOT, rel) : js.replace(/\.js$/, '.lua');
  return utf8bytes(src);
}
G.debug = $rec(
  'getinfo', (what_level, what) => {
    if (what_level !== 1) $abort('debug.getinfo at level/function ' + $tostring(what_level) + ' (only level 1 has a faithful form)');
    what = what === undefined ? 'flnSu' : cstr(what);
    if (/[^S]/.test(what)) $abort("debug.getinfo field set '" + what + "' (only 'S')");
    const file = source_of_caller();
    if (file === undefined) $abort('debug.getinfo: no caller frame');
    return $rec('source', '@' + file, 'short_src', chunkid(file), 'what', 'Lua', 'linedefined', -1, 'lastlinedefined', -1);
  },
  'traceback', (msg) => (msg === undefined ? 'stack traceback:\n\t[transliterated: no Lua traceback]' : $tostring(msg) + '\nstack traceback:\n\t[transliterated: no Lua traceback]'),
  'sethook', () => $abort('debug.sethook'),
  'getupvalue', () => $abort('debug.getupvalue'),
  'getlocal', () => $abort('debug.getlocal'));

// ── HOST: vim — nvim's API, as far as it has a meaning outside the editor ────────────────────────────────────────
// THREE KINDS OF MEMBER, and the kind decides the form:
//   PURE LUA in nvim's own runtime (vim.split / tbl_* / list_extend / deepcopy / inspect / uri_* / fs): TRANSLITERATED
//     from $VIMRUNTIME/lua by the same emitter (tools/luajs.lua emits them beside the modules) and loaded LAZILY on the
//     first miss, as nvim itself defers them — never re-authored here.
//   C / libuv-BACKED (vim.uv, vim.fn, vim.json, vim.system, vim.env, vim.NIL, vim.log, vim.notify): a declared template
//     per member, matched to nvim's behaviour PROBED first; a member not declared ABORTS BY NAME.
//   THE EDITOR (vim.api, keymap, bo, wo, cmd, opt, lsp, diagnostic, treesitter, schedule, …): no meaning outside nvim —
//     an access aborts by name, at the read.
const refuse_table = (name, why) => { const t = $rec(); META.set(t, $rec('__index', (_, k) => $abort(name + '.' + $tostring(k) + ' (' + why + ')'))); return t; };
const with_refusal = (t, name, why) => { META.set(t, $rec('__index', (_, k) => $abort(name + '.' + $tostring(k) + ' (' + why + ')'))); return t; };
const NIL = new (class LuaNIL {})();
META.set(NIL, $rec('__tostring', () => 'vim.NIL'));
const EMPTY_DICT_MT = $rec();
const vim = $rec();
G.vim = vim;
rawset(vim, 'NIL', NIL);
rawset(vim, 'empty_dict', () => { const t = $map(); META.set(t, EMPTY_DICT_MT); return t; });
// nvim defines this in C; shared.lua's vim.empty_dict / tbl_isempty / json read it
rawset(vim, '_empty_dict_mt', EMPTY_DICT_MT);
rawset(vim, 'log', $rec('levels', $rec('TRACE', 0, 'DEBUG', 1, 'INFO', 2, 'WARN', 3, 'ERROR', 4, 'OFF', 5)));
rawset(vim, 'notify', (msg) => { fs.writeSync(2, bytes(cstr(msg === undefined ? 'nil' : $tostring(msg)) + '\n')); });
// vim.env: the process environment, read and written by name
const ENV = $rec();
META.set(ENV, $rec('__index', (_, k) => { const v = process.env[frombytes(bytes(k))]; return v === undefined ? undefined : utf8bytes(v); },
  '__newindex', (_, k, v) => { if (v === undefined) delete process.env[frombytes(bytes(k))]; else process.env[frombytes(bytes(k))] = Buffer.from(cstr(v), 'latin1').toString('utf8'); }));
rawset(vim, 'env', ENV);

// vim.json — decode: objects are MAPs (the general table), arrays 1-based ARRAYs, null vim.NIL, strings UTF-8 bytes;
// encode: an empty table is `[]` (vim.empty_dict() is `{}`), a 1..n table an array, '/' unescaped, bytes raw, numbers
// %.14g. ⚠ An object's KEY ORDER follows the table's iteration order — unspecified in Lua, and LuaJIT's hash order is
// not reproducible here: compare decoded values, not encoded text, across the two.
const from_json = v => {
  if (v === null) return NIL;
  if (Array.isArray(v)) return $arr(...v.map(from_json));
  if (typeof v === 'object') { const m = $map(); for (const k of Object.keys(v)) rawset(m, utf8bytes(k), from_json(v[k])); return m; }
  if (typeof v === 'string') return utf8bytes(v);
  return v;
};
const json_str = s => {
  let o = '"';
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c === 34) o += '\\"'; else if (c === 92) o += '\\\\';
    else if (c === 8) o += '\\b'; else if (c === 12) o += '\\f'; else if (c === 10) o += '\\n'; else if (c === 13) o += '\\r'; else if (c === 9) o += '\\t';
    else if (c < 32 || c === 127) o += '\\u' + c.toString(16).padStart(4, '0');
    else o += s[i];
  }
  return o + '"';
};
function to_json(v, depth) {
  if (depth > 1000) throw new LuaError('Cannot serialise, excessive nesting (1001)');
  if (v === undefined || v === NIL) return 'null';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') { if (!Number.isFinite(v)) throw new LuaError('Cannot serialise number: must not be NaN or Inf'); return $numstr(v); }
  if (typeof v === 'string') return json_str(v);
  if (isTable(v)) {
    const keys = [];
    const it = pairs_iter(v);
    for (let r = it(); r !== undefined; r = it()) keys.push($all(r)[0]);
    if (keys.length === 0) return META.get(v) === EMPTY_DICT_MT ? '{}' : '[]';
    const ints = keys.every(k => typeof k === 'number' && Number.isInteger(k) && k >= 1);
    if (ints) {
      const max = Math.max(...keys);
      if (max > keys.length * 2 && max > 10) throw new LuaError('Cannot serialise table: excessively sparse array');
      const o = [];
      for (let k = 1; k <= max; k++) o.push(to_json(rawget(v, k), depth + 1));
      return '[' + o.join(',') + ']';
    }
    return '{' + keys.map(k => {
      if (typeof k !== 'string' && typeof k !== 'number') throw new LuaError('Cannot serialise ' + $type(k) + ': table key must be a number or string');
      return json_str(cstr(k)) + ':' + to_json(rawget(v, k), depth + 1);
    }).join(',') + '}';
  }
  throw new LuaError('Cannot serialise ' + $type(v) + ': type not supported');
}
rawset(vim, 'json', $rec(
  'decode', (s, opts) => {
    let v;
    try { v = JSON.parse(Buffer.from(cstr(s), 'latin1').toString('utf8')); } catch (e) { throw new LuaError('Expected value but found invalid token at character 1'); }
    if (opts !== undefined) $abort('vim.json.decode with options');
    return from_json(v);
  },
  'encode', (v, opts) => { if (opts !== undefined) $abort('vim.json.encode with options'); return to_json(v, 0); }));

// vim.uv — the libuv calls that have a synchronous meaning; errors are libuv's triple: nil, "<CODE>: <msg>: <path>", CODE
const uverr = (e, p) => $mv(undefined, (e.code || 'EIO') + ': ' + (STRERROR[e.code] || e.message || '').toLowerCase() + (p === undefined ? '' : ': ' + cstr(p)), e.code || 'EIO');
const tstamp = ms => $rec('sec', Math.floor(ms / 1000), 'nsec', Math.round((ms % 1000) * 1e6));
const kind_of = st => (st.isFile() ? 'file' : st.isDirectory() ? 'directory' : st.isSymbolicLink() ? 'link' : st.isFIFO() ? 'fifo' : st.isSocket() ? 'socket' : st.isCharacterDevice() ? 'char' : st.isBlockDevice() ? 'block' : 'unknown');
const stat_rec = st => $rec('type', kind_of(st), 'size', st.size, 'mode', st.mode, 'ino', st.ino, 'dev', st.dev, 'nlink', st.nlink,
  'uid', st.uid, 'gid', st.gid, 'mtime', tstamp(st.mtimeMs), 'atime', tstamp(st.atimeMs), 'ctime', tstamp(st.ctimeMs), 'birthtime', tstamp(st.birthtimeMs), 'blksize', st.blksize, 'blocks', st.blocks);
const sync_only = (name, cb) => { if (cb !== undefined) $abort('vim.uv.' + name + ' with a callback (the event loop)'); };
class ScanDir { constructor(names, types) { this.names = names; this.types = types; this.i = 0; } }
const t0 = process.hrtime.bigint();
const uv = with_refusal($rec(
  'hrtime', () => Number(process.hrtime.bigint()),
  'now', () => Math.floor(Number(process.hrtime.bigint() - t0) / 1e6),
  'cwd', () => utf8bytes(process.cwd()),
  'available_parallelism', () => (nodeos.availableParallelism ? nodeos.availableParallelism() : nodeos.cpus().length),
  'gettimeofday', () => { const ms = Date.now(); return $mv(Math.floor(ms / 1000), (ms % 1000) * 1000); },
  'os_homedir', () => utf8bytes(nodeos.homedir()),
  'os_getenv', k => { const v = process.env[frombytes(bytes(k))]; return v === undefined ? undefined : utf8bytes(v); },
  'os_uname', () => $rec('sysname', utf8bytes(nodeos.type()), 'release', utf8bytes(nodeos.release()), 'version', utf8bytes(nodeos.version ? nodeos.version() : ''), 'machine', utf8bytes(nodeos.machine ? nodeos.machine() : process.arch)),
  'fs_stat', (p, cb) => { sync_only('fs_stat', cb); try { return stat_rec(fs.statSync(bytes(p))); } catch (e) { return uverr(e, p); } },
  'fs_lstat', (p, cb) => { sync_only('fs_lstat', cb); try { return stat_rec(fs.lstatSync(bytes(p))); } catch (e) { return uverr(e, p); } },
  'fs_realpath', (p, cb) => { sync_only('fs_realpath', cb); try { return frombytes(fs.realpathSync(bytes(p), { encoding: 'buffer' })); } catch (e) { return uverr(e, p); } },
  'fs_rename', (a, b, cb) => { sync_only('fs_rename', cb); try { fs.renameSync(bytes(a), bytes(b)); return true; } catch (e) { return uverr(e, a); } },
  'fs_unlink', (p, cb) => { sync_only('fs_unlink', cb); try { fs.unlinkSync(bytes(p)); return true; } catch (e) { return uverr(e, p); } },
  'fs_mkdir', (p, mode, cb) => { sync_only('fs_mkdir', cb); try { fs.mkdirSync(bytes(p), { mode }); return true; } catch (e) { return uverr(e, p); } },
  'fs_rmdir', (p, cb) => { sync_only('fs_rmdir', cb); try { fs.rmdirSync(bytes(p)); return true; } catch (e) { return uverr(e, p); } },
  // libuv's scandir SORTS (scandir(3) with its own comparator: byte order)
  'fs_scandir', (p, cb) => {
    sync_only('fs_scandir', cb);
    let ents;
    try { ents = fs.readdirSync(bytes(p), { withFileTypes: true, encoding: 'buffer' }); } catch (e) { return uverr(e, p); }
    const rows = ents.map(d => ({ n: frombytes(d.name), t: d.isFile() ? 'file' : d.isDirectory() ? 'directory' : d.isSymbolicLink() ? 'link' : d.isFIFO() ? 'fifo' : d.isSocket() ? 'socket' : d.isCharacterDevice() ? 'char' : d.isBlockDevice() ? 'block' : 'unknown' }));
    rows.sort((a, b) => (a.n < b.n ? -1 : a.n > b.n ? 1 : 0));
    const h = new ScanDir(rows.map(r => r.n), rows.map(r => r.t));
    META.set(h, $rec('__tostring', () => 'uv_fs_t: ' + addr(h)));
    return h;
  },
  'fs_scandir_next', h => { if (!(h instanceof ScanDir)) throw new LuaError("bad argument #1 to 'fs_scandir_next' (uv_fs_t expected)"); if (h.i >= h.names.length) return undefined; const i = h.i++; return $mv(h.names[i], h.types[i]); }),
  'vim.uv', 'no synchronous form outside the editor');
rawset(vim, 'uv', uv);
rawset(vim, 'loop', uv);

// vim.system — run to completion at the call (the editor runs it concurrently; the RESULT is the same, the ordering of
// side effects against later code is not); :wait() returns { code, signal, stdout, stderr }
class SysObj { constructor(r) { this.r = r; } }
const SYS_MT = $rec('__index', $rec(
  'wait', self => self.r,
  'kill', () => undefined,
  'is_closing', () => true));
rawset(vim, 'system', (cmd, opts, on_exit) => {
  if (on_exit !== undefined) $abort('vim.system with an on_exit callback (the event loop)');
  const argv = [];
  for (let i = 1; rawget(cmd, i) !== undefined; i++) argv.push(frombytes(bytes(rawget(cmd, i))));
  const o = opts === undefined ? $rec() : opts;
  const env = Object.assign({}, $t(rawget(o, 'clear_env')) ? {} : process.env);
  const e = rawget(o, 'env');
  if (e !== undefined) { const it = pairs_iter(e); for (let r = it(); r !== undefined; r = it()) { const [k, v] = $all(r); env[Buffer.from(cstr(k), 'latin1').toString('utf8')] = Buffer.from(cstr(v), 'latin1').toString('utf8'); } }
  const stdin = rawget(o, 'stdin');
  const timeout = rawget(o, 'timeout');
  const cwd = rawget(o, 'cwd');
  const r = child.spawnSync(argv[0], argv.slice(1), { env, cwd: cwd === undefined ? undefined : Buffer.from(cstr(cwd), 'latin1').toString('utf8'),
    input: typeof stdin === 'string' ? bytes(stdin) : undefined, timeout: timeout === undefined ? undefined : num(timeout), maxBuffer: 1 << 30 });
  if (r.error && r.error.code === 'ENOENT') throw new LuaError('ENOENT: no such file or directory');
  const out = r.stdout ? frombytes(r.stdout) : undefined, err = r.stderr ? frombytes(r.stderr) : undefined;
  const timedout = r.error && r.error.code === 'ETIMEDOUT';
  const res = $rec('code', timedout ? 124 : (r.status === null ? 1 : r.status), 'signal', r.signal ? (nodeos.constants.signals[r.signal] || 0) : 0,
    'stdout', out === undefined ? undefined : out, 'stderr', err === undefined ? undefined : err);
  const so = new SysObj(res);
  so.pid = r.pid;
  META.set(so, SYS_MT);
  return so;
});

// vim.fn — Vimscript functions, the ones with a meaning outside the editor
const fn_bool = b => (b ? 1 : 0);
const isdir = p => { try { return fs.statSync(bytes(p)).isDirectory(); } catch (e) { return false; } };
function fnamemodify(f, mods) {
  f = cstr(f); mods = cstr(mods);
  const home = utf8bytes(nodeos.homedir());
  const cwd = utf8bytes(process.cwd());
  const tail = x => x.slice(x.lastIndexOf('/') + 1);
  const head = x => { const i = x.lastIndexOf('/'); if (i < 0) return '.'; if (i === 0) return '/'; return x.slice(0, i); };
  let i = 0;
  while (i < mods.length) {
    if (mods[i] !== ':') $abort("vim.fn.fnamemodify modifier '" + mods.slice(i) + "'");
    const m = mods[i + 1];
    if (m === 'p') { if (f[0] === '~') f = home + f.slice(1); if (f[0] !== '/') f = cwd + '/' + f; f = path.posix.normalize(f); if (isdir(f) && !f.endsWith('/')) f += '/'; }
    else if (m === 'h') { f = f.endsWith('/') && f.length > 1 ? f.slice(0, -1) : head(f); }
    else if (m === 't') f = tail(f);
    else if (m === 'r') { const t = tail(f); const d = t.lastIndexOf('.'); if (d > 0) f = f.slice(0, f.length - t.length + d); }
    else if (m === 'e') { const t = tail(f); const d = t.lastIndexOf('.'); f = d > 0 ? t.slice(d + 1) : ''; }
    else if (m === '~') { if (f === home || f.startsWith(home + '/')) f = '~' + f.slice(home.length); }
    else if (m === '.') { if (f.startsWith(cwd + '/')) f = f.slice(cwd.length + 1); }
    else $abort("vim.fn.fnamemodify modifier ':" + m + "'");
    i += 2;
  }
  return f;
}
function expand(s) {
  s = cstr(s);
  if (/[*?[\]{}]/.test(s) || /^[%#<]/.test(s)) $abort("vim.fn.expand of '" + s + "' (wildcards / editor names)");
  if (s[0] === '~') s = utf8bytes(nodeos.homedir()) + s.slice(1);
  return s.replace(/\$([A-Za-z_][A-Za-z0-9_]*)/g, (all, k) => (process.env[k] === undefined ? all : utf8bytes(process.env[k])));
}
// Vim's glob over the filesystem (probed): `*` `?` `[…]` inside one component, `**` across ZERO or more directories;
// results SORTED; a pattern with no magic returns the path when it exists
const glob_re = pat => new RegExp('^' + pat.replace(/[.+^${}()|\\]/g, '\\$&').replace(/\*/g, '[^/]*').replace(/\?/g, '[^/]') + '$');
function vglob(pattern) {
  const p = expand_plain(cstr(pattern));
  const parts = p.split('/');
  let paths = [parts[0] === '' ? '/' : '.'];
  const start = parts[0] === '' ? 1 : 0;
  const has_magic = s => /[*?[]/.test(s);
  const join = (a, b) => (a === '/' ? '/' + b : a === '.' ? b : a + '/' + b);
  for (let i = start; i < parts.length; i++) {
    const comp = parts[i];
    const next = [];
    if (comp === '**') {
      const walk = d => { next.push(d); let ents; try { ents = fs.readdirSync(Buffer.from(d, 'latin1'), { withFileTypes: true, encoding: 'buffer' }); } catch (e) { return; } for (const e of ents) if (e.isDirectory()) walk(join(d, frombytes(e.name))); };
      for (const d of paths) walk(d);
    } else if (!has_magic(comp)) {
      for (const d of paths) { const q = join(d, comp); try { fs.lstatSync(Buffer.from(q, 'latin1')); next.push(q); } catch (e) {} }
    } else {
      const re = glob_re(comp);
      for (const d of paths) {
        let ents;
        try { ents = fs.readdirSync(Buffer.from(d, 'latin1'), { encoding: 'buffer' }).map(frombytes); } catch (e) { continue; }
        for (const e of ents) if ((e[0] !== '.' || comp[0] === '.') && re.test(e)) next.push(join(d, e));
      }
    }
    paths = [...new Set(next)];
  }
  return paths.filter(x => x !== '.' && x !== '/').sort();
}
const expand_plain = s => { if (s[0] === '~') s = utf8bytes(nodeos.homedir()) + s.slice(1); return s.replace(/\$([A-Za-z_][A-Za-z0-9_]*)/g, (all, k) => (process.env[k] === undefined ? all : utf8bytes(process.env[k]))); };
let tmpdir, tmpn = 0;
const utf8_units = s => Buffer.from(cstr(s), 'latin1').toString('utf8');
const fnt = with_refusal($rec(
  'fnamemodify', fnamemodify,
  'expand', expand,
  'getcwd', () => utf8bytes(process.cwd()),
  'isdirectory', p => fn_bool(isdir(p)),
  'filereadable', p => { try { fs.accessSync(bytes(p), fs.constants.R_OK); return fn_bool(!isdir(p)); } catch (e) { return 0; } },
  'executable', name => {
    name = frombytes(bytes(name));
    const ok = p => { try { fs.accessSync(p, fs.constants.X_OK); return fs.statSync(p).isFile(); } catch (e) { return false; } };
    if (name.includes('/')) return fn_bool(ok(name));
    return fn_bool((process.env.PATH || '').split(':').some(d => d !== '' && ok(path.join(d, name))));
  },
  'mkdir', (d, flags) => { try { fs.mkdirSync(bytes(d), { recursive: $t(flags) && cstr(flags).includes('p') }); return 1; } catch (e) { if (e.code === 'EEXIST' && $t(flags) && cstr(flags).includes('p')) return 1; return 0; } },
  'delete', (p, flags) => {
    const f = flags === undefined ? '' : cstr(flags);
    try { if (f.includes('rf')) fs.rmSync(bytes(p), { recursive: true, force: true }); else if (f.includes('d')) fs.rmdirSync(bytes(p)); else fs.unlinkSync(bytes(p)); return 0; } catch (e) { return -1; }
  },
  'sha256', s => require('crypto').createHash('sha256').update(bytes(s)).digest('hex'),
  'tempname', () => {
    if (!tmpdir) tmpdir = fs.mkdtempSync(path.join(nodeos.tmpdir(), 'nvim.luajs.'));
    return utf8bytes(path.join(tmpdir, String(tmpn++)));
  },
  'stdpath', what => {
    const w = cstr(what);
    const env = (k, d) => (process.env[k] ? process.env[k] : path.join(nodeos.homedir(), d));
    const m = { config: env('XDG_CONFIG_HOME', '.config'), data: env('XDG_DATA_HOME', '.local/share'), state: env('XDG_STATE_HOME', '.local/state'), cache: env('XDG_CACHE_HOME', '.cache') }[w];
    if (m === undefined) $abort("vim.fn.stdpath('" + w + "')");
    return utf8bytes(path.join(m, 'nvim'));
  },
  'readfile', (p, flags, max) => {
    let t;
    try { t = frombytes(fs.readFileSync(bytes(p))); } catch (e) { throw new LuaError("Vim:E484: Can't open file " + cstr(p)); }
    const binary = flags !== undefined && cstr(flags).includes('b');
    let lines = t.split('\n');
    if (lines[lines.length - 1] === '' && !binary) lines.pop(); // the final newline ends the last line
    if (max !== undefined) { const n = num(max); lines = n >= 0 ? lines.slice(0, n) : lines.slice(n); }
    return $arr(...lines);
  },
  'writefile', (list, p, flags) => {
    const f = flags === undefined ? '' : cstr(flags);
    const lines = [];
    if (typeof list === 'string') lines.push(list); else for (let i = 1; rawget(list, i) !== undefined; i++) lines.push(cstr(rawget(list, i)));
    const body = f.includes('b') ? lines.join('\n') : lines.map(l => l + '\n').join('');
    try { (f.includes('a') ? fs.appendFileSync : fs.writeFileSync)(bytes(p), bytes(body)); return 0; } catch (e) { return -1; }
  },
  'glob', (pat, nosuf, list) => { const r = vglob(pat); return $t(list) ? $arr(...r) : r.join('\n'); },
  'globpath', (dirs, pat, nosuf, list) => { const r = []; for (const d of cstr(dirs).split(',')) if (d !== '') r.push(...vglob(d + '/' + cstr(pat))); return $t(list) ? $arr(...r) : r.join('\n'); },
  'readdir', p => { let ns; try { ns = fs.readdirSync(bytes(p), { encoding: 'buffer' }).map(frombytes); } catch (e) { return $arr(); } ns.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)); return $arr(...ns); },
  'has', feat => { const f = cstr(feat); return fn_bool({ nvim: 1, unix: process.platform !== 'win32', linux: process.platform === 'linux', mac: process.platform === 'darwin', macunix: process.platform === 'darwin', win32: process.platform === 'win32', win64: process.platform === 'win32', wsl: !!process.env.WSL_DISTRO_NAME }[f]); },
  'strchars', s => [...utf8_units(s)].length,
  'strcharpart', (s, start, len) => { const cs = [...utf8_units(s)]; const st = Math.max(0, num(start)); const e = len === undefined ? cs.length : Math.max(0, num(start) + num(len)); return utf8bytes(cs.slice(st, e).join('')); },
  'strdisplaywidth', s => { s = cstr(s); if (/[^\x20-\x7e]/.test(s)) $abort('vim.fn.strdisplaywidth of a non-ASCII or control string (the editor\'s cell widths)'); return s.length; },
  'fnameescape', s => cstr(s).replace(/[ \t\n*?[{`$\\%#'"|!<]/g, c => '\\' + c).replace(/^[+>-]/, c => '\\' + c),
  'system', cmd => {
    const r = child.spawnSync('/bin/sh', ['-c', frombytes(typeof cmd === 'string' ? bytes(cmd) : bytes(cstr(cmd)))], { maxBuffer: 1 << 30 });
    VVARS.shell_error = r.status === null ? -1 : r.status;
    return frombytes(Buffer.concat([r.stdout || Buffer.alloc(0), r.stderr || Buffer.alloc(0)]));
  },
  'systemlist', cmd => { const out = fnt_system(cmd); const ls = out.split('\n'); if (ls[ls.length - 1] === '') ls.pop(); return $arr(...ls); }),
  'vim.fn', 'an editor function');
const fnt_system = cmd => $idx(fnt, 'system')(cmd);
rawset(vim, 'fn', fnt);
const VVARS = { shell_error: 0 };
rawset(vim, 'v', (() => { const t = $rec(); META.set(t, $rec('__index', (_, k) => { if (k === 'shell_error') return VVARS.shell_error; return $abort('vim.v.' + $tostring(k) + ' (an editor variable)'); })); return t; })());
// vim.mpack — MessagePack, as nvim maps it (probed): nil decodes to vim.NIL, arrays and maps to tables (ARRAY / MAP),
// str and bin to byte strings; encode: {} is an empty ARRAY, a 1..n table an array, a float as float32 when lossless
// (else float64), integers in the smallest form (negative fixint, uint8…uint64, int8…int64); errors are nvim's own two
function mp_decode(s) {
  const b = bytes(s);
  let i = 0;
  const need = n => { if (i + n > b.length) throw new LuaError('incomplete msgpack string'); };
  const str = n => { need(n); const v = frombytes(b.subarray(i, i + n)); i += n; return v; };
  const arr = n => { const items = []; for (let k = 0; k < n; k++) items.push(one()); return $arr(...items); };
  const map = n => { const m = $map(); for (let k = 0; k < n; k++) { const key = one(); const v = one(); if (key !== NIL) rawset(m, key, v); } return m; };
  function one() {
    need(1);
    const c = b[i++];
    if (c <= 0x7f) return c;
    if (c >= 0xe0) return c - 256;
    if ((c & 0xf0) === 0x80) return map(c & 0x0f);
    if ((c & 0xf0) === 0x90) return arr(c & 0x0f);
    if ((c & 0xe0) === 0xa0) return str(c & 0x1f);
    switch (c) {
      case 0xc0: return NIL;
      case 0xc2: return false;
      case 0xc3: return true;
      case 0xc4: need(1); return str(b[i++]);
      case 0xc5: need(2); { const n = b.readUInt16BE(i); i += 2; return str(n); }
      case 0xc6: need(4); { const n = b.readUInt32BE(i); i += 4; return str(n); }
      case 0xca: need(4); { const v = b.readFloatBE(i); i += 4; return v; }
      case 0xcb: need(8); { const v = b.readDoubleBE(i); i += 8; return v; }
      case 0xcc: need(1); return b[i++];
      case 0xcd: need(2); { const v = b.readUInt16BE(i); i += 2; return v; }
      case 0xce: need(4); { const v = b.readUInt32BE(i); i += 4; return v; }
      case 0xcf: need(8); { const v = Number(b.readBigUInt64BE(i)); i += 8; return v; }
      case 0xd0: need(1); { const v = b.readInt8(i); i += 1; return v; }
      case 0xd1: need(2); { const v = b.readInt16BE(i); i += 2; return v; }
      case 0xd2: need(4); { const v = b.readInt32BE(i); i += 4; return v; }
      case 0xd3: need(8); { const v = Number(b.readBigInt64BE(i)); i += 8; return v; }
      case 0xd9: need(1); return str(b[i++]);
      case 0xda: need(2); { const n = b.readUInt16BE(i); i += 2; return str(n); }
      case 0xdb: need(4); { const n = b.readUInt32BE(i); i += 4; return str(n); }
      case 0xdc: need(2); { const n = b.readUInt16BE(i); i += 2; return arr(n); }
      case 0xdd: need(4); { const n = b.readUInt32BE(i); i += 4; return arr(n); }
      case 0xde: need(2); { const n = b.readUInt16BE(i); i += 2; return map(n); }
      case 0xdf: need(4); { const n = b.readUInt32BE(i); i += 4; return map(n); }
      default: $abort('vim.mpack.decode of type byte 0x' + c.toString(16) + ' (ext / reserved)');
    }
  }
  if (b.length === 0) throw new LuaError('incomplete msgpack string');
  const v = one();
  return v;
}
function mp_encode(v) {
  const out = [];
  const u8 = (...x) => out.push(Buffer.from(x));
  const put = (tag, n, w) => { const buf = Buffer.alloc(1 + w); buf[0] = tag; if (w === 1) buf.writeUInt8(n, 1); else if (w === 2) buf.writeUInt16BE(n, 1); else if (w === 4) buf.writeUInt32BE(n, 1); out.push(buf); };
  const len = (fix, fixmax, t16, t32, n, t8) => { if (n <= fixmax) u8(fix | n); else if (t8 !== undefined && n <= 0xff) put(t8, n, 1); else if (n <= 0xffff) put(t16, n, 2); else put(t32, n, 4); };
  function one(x) {
    if (x === undefined || x === NIL) return u8(0xc0);
    if (x === false) return u8(0xc2);
    if (x === true) return u8(0xc3);
    if (typeof x === 'number') {
      if (Number.isInteger(x) && Math.abs(x) <= Number.MAX_SAFE_INTEGER) {
        if (x >= 0) { if (x <= 0x7f) return u8(x); if (x <= 0xff) return put(0xcc, x, 1); if (x <= 0xffff) return put(0xcd, x, 2); if (x <= 0xffffffff) return put(0xce, x, 4); const b8 = Buffer.alloc(9); b8[0] = 0xcf; b8.writeBigUInt64BE(BigInt(x), 1); return out.push(b8); }
        if (x >= -32) return u8(x + 256);
        if (x >= -128) { const b2 = Buffer.alloc(2); b2[0] = 0xd0; b2.writeInt8(x, 1); return out.push(b2); }
        if (x >= -32768) { const b3 = Buffer.alloc(3); b3[0] = 0xd1; b3.writeInt16BE(x, 1); return out.push(b3); }
        if (x >= -2147483648) { const b5 = Buffer.alloc(5); b5[0] = 0xd2; b5.writeInt32BE(x, 1); return out.push(b5); }
        const b9 = Buffer.alloc(9); b9[0] = 0xd3; b9.writeBigInt64BE(BigInt(x), 1); return out.push(b9);
      }
      if (Math.fround(x) === x || Number.isNaN(x)) { const b5 = Buffer.alloc(5); b5[0] = 0xca; b5.writeFloatBE(x, 1); return out.push(b5); }
      const b9 = Buffer.alloc(9); b9[0] = 0xcb; b9.writeDoubleBE(x, 1); return out.push(b9);
    }
    if (typeof x === 'string') { len(0xa0, 31, 0xda, 0xdb, x.length, 0xd9); return out.push(bytes(x)); }
    if (isTable(x)) {
      const keys = [];
      const it = pairs_iter(x);
      for (let r = it(); r !== undefined; r = it()) keys.push($all(r)[0]);
      const seq = keys.every(k => typeof k === 'number' && Number.isInteger(k) && k >= 1) && keys.length === Math.max(0, ...keys);
      if (seq) { len(0x90, 15, 0xdc, 0xdd, keys.length); for (let k = 1; k <= keys.length; k++) one(rawget(x, k)); return; }
      len(0x80, 15, 0xde, 0xdf, keys.length);
      for (const k of keys) { one(k); one(rawget(x, k)); }
      return;
    }
    throw new LuaError('can not serialize object of type ' + $type(x));
  }
  one(v);
  return frombytes(Buffer.concat(out));
}
rawset(vim, 'mpack', $rec('decode', mp_decode, 'encode', mp_encode));
// vim.g: the global variables — with no editor it is simply an empty, writable namespace (reads nil, writes store)
rawset(vim, 'g', $map());
for (const ed of ['keymap', 'bo', 'wo', 'o', 'go', 'b', 'w', 't', 'opt', 'opt_local', 'opt_global', 'lsp', 'diagnostic', 'health', 'ui', 'filetype', 'snippet', 'hl', 'highlight', 'keycode'])
  rawset(vim, ed, refuse_table('vim.' + ed, 'the editor'));

// ── vim.treesitter's C BINDING (nvim's treesitter.c surface: _meta/tsnode.lua, tstree.lua, tsquery.lua, misc.lua) ──
// over TSBRIDGE (lua/cartograph/luajs/tsbridge.c): the SAME grammar .so nvim loads, the tree-sitter runtime built from
// its own source. NAVIGATION runs on the serialized tree here (a node's identity = its PREORDER index — tree-sitter is
// deterministic, so the bridge re-parsing the same source numbers the same nodes); QUERIES, sexpr and
// descendant_for_range run IN the bridge (libtree-sitter itself). The cursor's match LIMIT is honoured — nvim's default
// 256 drops matches on large files, and a faithful binding reproduces the cap rather than fixing it.
// nvim's pure-Lua vim.treesitter.* (query predicates, LanguageTree, language.add) is TRANSLITERATED beside the modules.
// ★ A PERSISTENT BRIDGE: the server keeps languages,
// compiled queries and parsed trees by id. Node has no synchronous child stdio, so the transport is two FIFOs opened
// read-write (so no open blocks) — fs.writeSync / fs.readSync on them ARE synchronous. Responses are framed
// `<length>\n<body>`. The server reads EOF and exits when this process does.
let TS = null;
function ts_open() {
  if (TS) return TS;
  const bridge = process.env.LUAJS_TS_BRIDGE;
  if (!bridge) $abort('vim.treesitter: no tree-sitter bridge (LUAJS_TS_BRIDGE is unset)');
  const dir = fs.mkdtempSync(path.join(nodeos.tmpdir(), 'tsbridge.'));
  const fin = path.join(dir, 'req'), fout = path.join(dir, 'res');
  child.execFileSync('mkfifo', [fin, fout]);
  const wfd = fs.openSync(fin, 'r+'), rfd = fs.openSync(fout, 'r+');
  const proc = child.spawn(bridge, ['serve', fin, fout], { stdio: ['ignore', 'ignore', 'inherit'] });
  proc.unref();
  TS = { wfd, rfd, dir, buf: Buffer.alloc(0), chunk: Buffer.alloc(1 << 16) };
  process.on('exit', () => { try { fs.closeSync(wfd); fs.closeSync(rfd); fs.rmSync(dir, { recursive: true, force: true }); } catch (e) {} });
  return TS;
}
function ts_fill(T) { const n = fs.readSync(T.rfd, T.chunk, 0, T.chunk.length, null); if (n === 0) throw new LuaError('the tree-sitter bridge closed'); T.buf = Buffer.concat([T.buf, T.chunk.subarray(0, n)]); }
function tsrun(header, ...payloads) {
  const T = ts_open();
  const req = Buffer.concat([Buffer.from(header + '\n', 'latin1'), ...payloads.map(bytes)]);
  let off = 0;
  while (off < req.length) off += fs.writeSync(T.wfd, req, off, req.length - off, null);
  let nl;
  while ((nl = T.buf.indexOf(10)) < 0) ts_fill(T);
  const n = +T.buf.subarray(0, nl).toString('latin1');
  T.buf = T.buf.subarray(nl + 1);
  while (T.buf.length < n) ts_fill(T);
  const body = frombytes(T.buf.subarray(0, n));
  T.buf = T.buf.subarray(n);
  if (body.startsWith('ERR ')) throw new LuaError(body.slice(4).trim());
  return body;
}
const TSLANG = Object.create(null);
const U32 = 4294967295;
function tslang(lang) { const l = TSLANG[lang]; if (!l) throw new LuaError('no such language: ' + cstr(lang)); return l; }
function tsinfo(lang) {
  const l = tslang(lang);
  if (l.info) return l;
  const out = tsrun('inspect ' + l.id);
  l.syms = []; l.symtype = []; l.fields = [undefined]; l.supers = [];
  for (const line of out.split('\n')) {
    let m;
    if ((m = /^S (\d+) (\d+) (\d+):/.exec(line))) { l.syms[+m[1]] = line.slice(m[0].length, m[0].length + +m[3]); l.symtype[+m[1]] = +m[2]; }
    else if ((m = /^F (\d+) (\d+):/.exec(line))) l.fields[+m[1]] = line.slice(m[0].length, m[0].length + +m[2]);
    else if (line.startsWith('ABI ')) l.abi = +line.slice(4);
    else if (line.startsWith('STATES ')) l.states = +line.slice(7);
    else if (line.startsWith('META ')) l.meta = line.slice(5).split(' ').map(Number);
    else if (line.startsWith('SUPER ')) { const v = line.slice(6).split(' ').map(Number); l.supers.push([v[0], v.slice(2)]); }
  }
  l.info = true;
  return l;
}
rawset(vim, '_ts_get_language_version', () => 15);
rawset(vim, '_ts_get_minimum_language_version', () => 13);
rawset(vim, '_ts_has_language', lang => TSLANG[cstr(lang)] !== undefined);
rawset(vim, '_ts_add_language_from_object', (p, lang, symbol) => {
  lang = cstr(lang);
  const l = { so: frombytes(bytes(p)), sym: symbol === undefined ? lang : cstr(symbol) };
  try {
    const out = tsrun('lang ' + l.so + ' ' + l.sym);
    l.id = +/^L (\d+)/.exec(out)[1];
    TSLANG[lang] = l;
    tsinfo(lang);
  } catch (e) { delete TSLANG[lang]; throw new LuaError('Failed to load parser for language \'' + lang + '\': ' + (e.value || e.message)); }
  return true;
});
rawset(vim, '_ts_inspect_language', lang => {
  const l = tsinfo(cstr(lang));
  const symbols = $map();
  l.syms.forEach((name, i) => { const ty = l.symtype[i]; if (ty === 3) return; const nm = ty !== 1; rawset(symbols, nm ? name : '"' + name + '"', nm); });
  const supertypes = $map();
  for (const [st, subs] of l.supers) rawset(supertypes, l.syms[st], $arr(...subs.map(x => l.syms[x])));
  const info = $rec('abi_version', l.abi, 'state_count', l.states, 'fields', $arr(...l.fields.slice(1)), 'symbols', symbols, 'supertypes', supertypes, '_wasm', false);
  if (l.meta) rawset(info, 'metadata', $rec('major_version', l.meta[0], 'minor_version', l.meta[1], 'patch_version', l.meta[2]));
  return info;
});

// the TREE: flat arrays by preorder id
let tsTreeSeq = 0;
class TSTreeObj {}
class TSNodeObj {}
const TSTREE_MT = $rec(), TSNODE_MT = $rec();
function mktree(lang, src) {
  const l = tslang(lang);
  const out = tsrun('parse ' + l.id + ' ' + src.length, src);
  const t = new TSTreeObj();
  t.lang = lang; t.src = src; t.seq = ++tsTreeSeq; t.nodes = [];
  t.tid = +/^T (\d+)/.exec(out)[1];
  const rows = [];
  for (const line of out.split('\n')) if (line.charCodeAt(0) === 78) rows.push(line); // 'N'
  const n = rows.length;
  t.n = n;
  t.parent = new Int32Array(n); t.field = new Uint16Array(n); t.sym = new Uint16Array(n); t.flags = new Uint8Array(n);
  t.sb = new Uint32Array(n); t.eb = new Uint32Array(n); t.sr = new Uint32Array(n); t.sc = new Uint32Array(n); t.er = new Uint32Array(n); t.ec = new Uint32Array(n);
  t.kids = Array.from({ length: n }, () => []);
  for (const line of rows) {
    const v = line.split(' ');
    const i = +v[1];
    t.parent[i] = +v[2]; t.field[i] = +v[3]; t.sym[i] = +v[4];
    t.flags[i] = (+v[5]) | (+v[6] << 1) | (+v[7] << 2) | (+v[8] << 3); // named, missing, extra, has_error
    t.sb[i] = +v[9]; t.eb[i] = +v[10]; t.sr[i] = +v[11]; t.sc[i] = +v[12]; t.er[i] = +v[13]; t.ec[i] = +v[14];
    if (t.parent[i] >= 0) t.kids[t.parent[i]].push(i);
  }
  META.set(t, TSTREE_MT);
  return t;
}
function node(t, i) {
  if (i === undefined || i < 0 || i >= t.n) return undefined;
  let x = t.nodes[i];
  if (!x) { x = new TSNodeObj(); x.t = t; x.i = i; META.set(x, TSNODE_MT); t.nodes[i] = x; }
  return x;
}
const isnode = x => x instanceof TSNodeObj;
// a request about a tree the bridge holds by id; an evicted tree (MISS) is re-parsed — the same source numbers the same
// nodes, so every node object this side holds stays valid — and the request retried
function ts_tree(t, req) {
  let out = tsrun(req(t.tid));
  if (out.startsWith('MISS')) {
    const r = tsrun('parse ' + tslang(t.lang).id + ' ' + t.src.length, t.src);
    t.tid = +/^T (\d+)/.exec(r)[1];
    out = tsrun(req(t.tid));
  }
  return out;
}
const N = x => { if (!isnode(x)) throw new LuaError('TSNode expected, got ' + $type(x)); return x; };
const named = (t, i) => (t.flags[i] & 1) !== 0;
const sibling = (x, step, want_named) => {
  const t = x.t, p = t.parent[x.i];
  if (p < 0) return undefined;
  const ks = t.kids[p];
  for (let k = ks.indexOf(x.i) + step; k >= 0 && k < ks.length; k += step) if (!want_named || named(t, ks[k])) return node(t, ks[k]);
  return undefined;
};
const NODE = Object.create(null);
// tree-sitter's BUILTIN error symbols lie outside the language's symbol table (ts_builtin_sym_error = 65535)
const BUILTIN_SYM = { 65535: 'ERROR', 65534: '_ERROR' };
NODE.type = x => { N(x); const s = x.t.sym[x.i]; return BUILTIN_SYM[s] !== undefined ? BUILTIN_SYM[s] : tsinfo(x.t.lang).syms[s]; };
NODE.symbol = x => N(x).t.sym[x.i];
NODE.range = (x, bytes_too) => { const t = N(x).t, i = x.i; return $t(bytes_too) ? $mv(t.sr[i], t.sc[i], t.sb[i], t.er[i], t.ec[i], t.eb[i]) : $mv(t.sr[i], t.sc[i], t.er[i], t.ec[i]); };
NODE.start = x => { const t = N(x).t, i = x.i; return $mv(t.sr[i], t.sc[i], t.sb[i]); };
NODE.end_ = x => { const t = N(x).t, i = x.i; return $mv(t.er[i], t.ec[i], t.eb[i]); };
NODE.byte_length = x => { const t = N(x).t; return t.eb[x.i] - t.sb[x.i]; };
NODE.child_count = x => N(x).t.kids[x.i].length;
NODE.child = (x, k) => { const ks = N(x).t.kids[x.i]; return node(x.t, ks[num(k)]); };
NODE.named_child_count = x => { const t = N(x).t; return t.kids[x.i].filter(k => named(t, k)).length; };
NODE.named_child = (x, k) => { const t = N(x).t; return node(t, t.kids[x.i].filter(c => named(t, c))[num(k)]); };
NODE.named_children = x => { const t = N(x).t; return $arr(...t.kids[x.i].filter(c => named(t, c)).map(c => node(t, c))); };
NODE.iter_children = x => { const t = N(x).t, ks = t.kids[x.i]; let k = 0; return () => { if (k >= ks.length) return undefined; const c = ks[k++]; const f = t.field[c]; return $mv(node(t, c), f ? tsinfo(t.lang).fields[f] : undefined); }; };
NODE.field = (x, name) => { const t = N(x).t, fs = tsinfo(t.lang).fields; name = cstr(name); return $arr(...t.kids[x.i].filter(c => t.field[c] && fs[t.field[c]] === name).map(c => node(t, c))); };
NODE.parent = x => { const t = N(x).t; return node(t, t.parent[x.i]); };
NODE.next_sibling = x => sibling(N(x), 1, false);
NODE.prev_sibling = x => sibling(N(x), -1, false);
NODE.next_named_sibling = x => sibling(N(x), 1, true);
NODE.prev_named_sibling = x => sibling(N(x), -1, true);
NODE.named = x => named(N(x).t, x.i);
NODE.missing = x => (N(x).t.flags[x.i] & 2) !== 0;
NODE.extra = x => (N(x).t.flags[x.i] & 4) !== 0;
NODE.has_error = x => (N(x).t.flags[x.i] & 8) !== 0;
NODE.has_changes = x => { N(x); return false; };
NODE.id = x => N(x).t.seq + ':' + x.i;
NODE.equal = (x, y) => isnode(y) && N(x).t === y.t && x.i === y.i;
NODE.tree = x => N(x).t;
NODE.child_with_descendant = (x, d) => { N(x); N(d); let c = d.i; while (c >= 0 && x.t.parent[c] !== x.i) c = x.t.parent[c]; return c >= 0 && d.t === x.t ? node(x.t, c) : undefined; };
NODE.__has_ancestor = (x, types) => { const t = N(x).t, want = new Set(); for (let k = 1; rawget(types, k) !== undefined; k++) want.add(rawget(types, k)); for (let p = t.parent[x.i]; p >= 0; p = t.parent[p]) if (want.has(tsinfo(t.lang).syms[t.sym[p]])) return true; return false; };
NODE.sexpr = x => { const t = N(x).t; return ts_tree(t, tid => 'sexpr ' + tid + ' ' + x.i).slice(2); };
const desc = named_only => (x, sr, sc, er, ec) => {
  const t = N(x).t;
  const out = ts_tree(t, tid => ['desc', tid, x.i, num(sr), num(sc), num(er), num(ec), named_only ? 1 : 0].join(' '));
  const m = /^D (\d+)/.exec(out);
  return m ? node(t, +m[1]) : undefined;
};
NODE.descendant_for_range = desc(false);
NODE.named_descendant_for_range = desc(true);
TSNODE_MT.__index = NODE;
TSNODE_MT.__tostring = x => '<node ' + NODE.type(x) + '>';
TSNODE_MT.__eq = (x, y) => NODE.equal(x, y);
const TREE = Object.create(null);
TREE.root = t => node(t, 0);
TREE.copy = t => t;
TREE.edit = () => $abort('TSTree:edit (incremental re-parsing)');
TREE.included_ranges = (t, bytes_too) => ($t(bytes_too) ? $arr($arr(0, 0, 0, U32, U32, U32)) : $arr($arr(0, 0, U32, U32)));
TSTREE_MT.__index = TREE;
TSTREE_MT.__tostring = () => '<tree>';

// the PARSER
class TSParserObj {}
const PARSER_MT = $rec();
const PARSER = Object.create(null);
PARSER.parse = (p, old, source, bytes_too) => {
  if (typeof source !== 'string') $abort('TSParser:parse of a buffer (the editor)');
  if (p.ranges !== undefined) $abort('TSParser:parse with included ranges (injections)');
  const t = mktree(p.lang, source);
  return $mv(t, $arr($t(bytes_too) ? $arr(0, 0, 0, U32, U32, U32) : $arr(0, 0, U32, U32)));
};
PARSER.reset = () => undefined;
PARSER.included_ranges = (p, bytes_too) => ($t(bytes_too) ? $arr($arr(0, 0, 0, U32, U32, U32)) : $arr($arr(0, 0, U32, U32)));
PARSER.set_included_ranges = (p, ranges) => { p.ranges = ranges !== undefined && rawget(ranges, 1) !== undefined ? ranges : undefined; };
PARSER._set_logger = () => undefined;
PARSER._logger = () => undefined;
PARSER_MT.__index = PARSER;
PARSER_MT.__tostring = () => '<parser>';
rawset(vim, '_create_ts_parser', lang => { lang = cstr(lang); tslang(lang); const p = new TSParserObj(); p.lang = lang; META.set(p, PARSER_MT); return p; });

// the QUERY
class TSQueryObj {}
const QUERY_MT = $rec();
const QERR = [null, 'Invalid syntax:\n', 'Invalid node type ', 'Invalid field name ', 'Invalid capture name ', 'Impossible pattern:\n', 'Invalid language:\n'];
function query_err(src, off, ty) {
  // nvim's query_err_string: the row/column of the offset, the kind, the name for the kinds that report one, the line
  let line_start = 0, row = 0, line = null;
  for (;;) {
    const nl = src.indexOf('\n', line_start);
    const end = nl < 0 ? src.length : nl;
    if (end > off) { line = src.slice(line_start, end); break; }
    if (nl < 0) break;
    line_start = nl + 1; row++;
  }
  const col = off - line_start;
  let msg = 'Query error at ' + (row + 1) + ':' + (col + 1) + '. ' + (QERR[ty] || 'Unknown error ');
  if (ty === 2 || ty === 3 || ty === 4) {
    const anon = ty === 2 && src[off - 1] === '"';
    let k = off;
    if (anon) { let bs = 0; while (k < src.length && (src[k] !== '"' || bs % 2 !== 0)) { bs = src[k] === '\\' ? bs + 1 : 0; k++; } }
    else while (k < src.length && /[A-Za-z0-9_.\-]/.test(src[k])) k++;
    msg += '"' + src.slice(off, k) + '":\n';
  }
  if (line === null) return msg + 'Unexpected EOF\n';
  return msg + line + '\n' + ' '.repeat(col) + '^\n';
}
rawset(vim, '_ts_parse_query', (lang, q) => {
  lang = cstr(lang); q = cstr(q);
  const l = tslang(lang);
  const out = tsrun('qcompile ' + l.id + ' ' + q.length, q);
  if (out.startsWith('QERR ')) { const [, off, ty] = out.trim().split(' ').map(Number); throw new LuaError(query_err(q, off, ty)); }
  const query = new TSQueryObj();
  query.lang = lang; query.src = q; query.captures = []; query.patterns = [];
  query.qid = +/^Q (\d+)/.exec(out)[1];
  for (const line of out.split('\n')) {
    let m;
    if ((m = /^C (\d+) (\d+):/.exec(line))) query.captures[+m[1]] = line.slice(m[0].length, m[0].length + +m[2]);
    else if ((m = /^P (\d+) (\d+)/.exec(line))) {
      // steps: cN (a capture), sLEN:text (a string), . (done) — split into predicates, capture ids 1-based
      const preds = [];
      let cur = [], rest = line.slice(m[0].length);
      while (rest.length) {
        rest = rest.replace(/^ /, '');
        if (rest[0] === 'c') { const mm = /^c(\d+)/.exec(rest); cur.push(+mm[1] + 1); rest = rest.slice(mm[0].length); }
        else if (rest[0] === 's') { const mm = /^s(\d+):/.exec(rest); cur.push(rest.slice(mm[0].length, mm[0].length + +mm[1])); rest = rest.slice(mm[0].length + +mm[1]); }
        else if (rest[0] === '.') { preds.push(cur); cur = []; rest = rest.slice(1); }
        else break;
      }
      query.patterns[+m[1]] = preds;
    }
  }
  META.set(query, QUERY_MT);
  return query;
});
const QUERY = Object.create(null);
QUERY.inspect = q => {
  const patterns = $map();
  q.patterns.forEach((preds, i) => { if (preds.length) rawset(patterns, i + 1, $arr(...preds.map(pr => $arr(...pr)))); });
  return $rec('captures', $arr(...q.captures), 'patterns', patterns);
};
QUERY.disable_capture = () => $abort('TSQuery:disable_capture');
QUERY.disable_pattern = () => $abort('TSQuery:disable_pattern');
QUERY_MT.__index = QUERY;
QUERY_MT.__tostring = () => '<query>';

// the CURSOR: one bridge run yields both streams; next_capture / next_match consume them; remove_match filters
class TSMatchObj {}
const MATCH_MT = $rec('__index', $rec(
  'info', m => $mv(m.id, m.pattern + 1),
  'captures', m => { const out = $map(); for (const [ci, ni] of m.caps) { const k = ci + 1; let l = rawget(out, k); if (l === undefined) { l = $arr(); rawset(out, k, l); } rawset(l, $len(l) + 1, node(m.t, ni)); } return out; }));
const mkmatch = (t, id, pattern, caps) => { const m = new TSMatchObj(); m.t = t; m.id = id; m.pattern = pattern; m.caps = caps; META.set(m, MATCH_MT); return m; };
class TSCursorObj {}
const CURSOR_MT = $rec('__index', $rec(
  'next_capture', c => {
    while (c.ki < c.K.length) {
      const k = c.K[c.ki++];
      if (c.removed.has(k.id)) continue;
      return $mv(k.cap + 1, node(c.t, k.node), mkmatch(c.t, k.id, k.pattern, k.caps));
    }
    return undefined;
  },
  'next_match', c => {
    while (c.mi < c.M.length) { const m = c.M[c.mi++]; if (!c.removed.has(m.id)) return mkmatch(c.t, m.id, m.pattern, m.caps); }
    return undefined;
  },
  'remove_match', (c, id) => { c.removed.add(num(id)); }));
rawset(vim, '_create_ts_querycursor', (nd, q, opts) => {
  N(nd);
  const t = nd.t;
  const o = opts === undefined ? $rec() : opts;
  const g = (k, d) => { const v = rawget(o, k); return v === undefined ? d : num(v); };
  const sr = g('start_row', 0), sc = g('start_col', 0), er = g('end_row', U32), ec = g('end_col', 0);
  const depth = g('max_start_depth', U32), limit = g('match_limit', U32);
  const out = ts_tree(t, tid => ['query', tid, q.qid, nd.i, sr, sc, er, er === U32 ? U32 : ec, depth, limit].join(' '));
  const c = new TSCursorObj();
  c.t = t; c.K = []; c.M = []; c.ki = 0; c.mi = 0; c.removed = new Set();
  for (const line of out.split('\n')) {
    const v = line.split(' ');
    if (v[0] === 'K') {
      const caps = [];
      for (let k = 6; k + 1 < v.length; k += 2) caps.push([+v[k], +v[k + 1]]);
      c.K.push({ id: +v[1], pattern: +v[2], cap: +v[3], node: +v[4], caps });
    } else if (v[0] === 'M') {
      const caps = [];
      for (let k = 4; k + 1 < v.length; k += 2) caps.push([+v[k], +v[k + 1]]);
      c.M.push({ id: +v[1], pattern: +v[2], caps });
    }
  }
  META.set(c, CURSOR_MT);
  return c;
});
// the runtime path search language.add uses to find a parser (LUAJS_RTP: the runtime directories, ':'-separated)
const rtp_glob = (name, all) => {
  const out = [];
  const dirs = (process.env.LUAJS_RTP || '').split(':').filter(Boolean);
  const i = name.lastIndexOf('/');
  const dirpart = i < 0 ? '' : name.slice(0, i), pat = i < 0 ? name : name.slice(i + 1);
  const re = new RegExp('^' + pat.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.') + '$');
  for (const d of dirs) {
    let ents;
    try { ents = fs.readdirSync(path.join(d, dirpart)).sort(); } catch (e) { continue; }
    for (const e of ents) if (re.test(e)) { out.push(utf8bytes(path.join(d, dirpart, e))); if (!all) return out; }
  }
  return out;
};
// vim.api: the editor — except the runtime-path search, which has a meaning given a runtime path
const API = refuse_table('vim.api', 'the editor');
rawset(API, 'nvim_get_runtime_file', (name, all) => $arr(...rtp_glob(cstr(name), $t(all))));
// autocmds: a registration is faithful — outside the editor no event ever fires, so the callback correctly never runs
let AUTOCMD = 0;
rawset(API, 'nvim_create_autocmd', () => ++AUTOCMD);
rawset(API, 'nvim_create_augroup', () => ++AUTOCMD);
rawset(API, 'nvim_del_autocmd', () => undefined);
rawset(API, 'nvim_clear_autocmds', () => undefined);
rawset(vim, 'api', API);

// the PURE-LUA half, loaded on the first miss exactly as nvim defers it (shared first; then the lazy modules)
let shared_loaded = false;
let SUBMODS;
const LAZY = $rec('inspect', () => $require('vim.inspect'), 'fs', () => $require('vim.fs'), 'treesitter', () => $require('vim.treesitter'),
  'uri_from_fname', () => $idx($require('vim.uri'), 'uri_from_fname'), 'uri_to_fname', () => $idx($require('vim.uri'), 'uri_to_fname'),
  'uri_from_bufnr', () => $idx($require('vim.uri'), 'uri_from_bufnr'), 'uri_to_bufnr', () => $idx($require('vim.uri'), 'uri_to_bufnr'));
META.set(vim, $rec('__index', (t, k) => {
  if (!shared_loaded) { shared_loaded = true; $require('vim._core.shared'); const v = rawget(t, k); if (v !== undefined) return v; }
  const lz = typeof k === 'string' ? LAZY[k] : undefined;
  if (lz !== undefined) { const v = lz(); rawset(t, k, v); return v; }
  // nvim's own LAZY SUBMODULE list, as transliterated beside the modules (vim/$submodules.json, derived at emit time)
  if (typeof k === 'string') {
    if (SUBMODS === undefined) { try { SUBMODS = new Set(JSON.parse(fs.readFileSync(path.join(process.env.LUAJS_ROOT || __dirname, 'vim', '$submodules.json'), 'utf8'))); } catch (e) { SUBMODS = new Set(); } }
    if (SUBMODS.has(k)) { const v = $require('vim.' + k); rawset(t, k, v); return v; }
  }
  // FEATURE PROBES that read nil in nvim too (a build without wasm): nil, not an abort
  if (k === '_ts_add_language_from_wasm') return undefined;
  return $abort('vim.' + $tostring(k) + ' (not in the host pack)');
}));

// ── modules ──────────────────────────────────────────────────────────────────────────────────────────────────────
// `require 'a.b'` loads <root>/a/b.js (or <root>/a/b/init.js), root = LUAJS_ROOT or this pack's directory; a module
// that is not there is a HOST gap, and says so
const loaded = Object.create(null);
const tobit = x => num(x) | 0;
const BUILTIN = $rec('bit', () => $rec('tobit', tobit, 'bnot', x => ~tobit(x), 'band', (...a) => a.reduce((x, y) => tobit(x) & tobit(y)),
  'bor', (...a) => a.reduce((x, y) => tobit(x) | tobit(y)), 'bxor', (...a) => a.reduce((x, y) => tobit(x) ^ tobit(y)),
  'lshift', (x, n) => tobit(x) << (tobit(n) & 31), 'rshift', (x, n) => tobit(x) >>> (tobit(n) & 31) | 0, 'arshift', (x, n) => tobit(x) >> (tobit(n) & 31),
  'rol', (x, n) => { x = tobit(x); n = tobit(n) & 31; return (x << n | x >>> (32 - n)) | 0; }, 'ror', (x, n) => { x = tobit(x); n = tobit(n) & 31; return (x >>> n | x << (32 - n)) | 0; },
  'bswap', x => { x = tobit(x); return ((x & 0xff) << 24 | (x & 0xff00) << 8 | (x >>> 8) & 0xff00 | x >>> 24) | 0; },
  'tohex', (x, n) => { x = tobit(x); n = n === undefined ? 8 : tobit(n); const up = n < 0; n = Math.min(Math.abs(n), 8); let h = (x >>> 0).toString(16).padStart(8, '0').slice(8 - n); return up ? h.toUpperCase() : h; }));
function $require(name) {
  if (name in loaded) return loaded[name];
  if (typeof name === 'string' && BUILTIN[name] !== undefined) { loaded[name] = BUILTIN[name](); return loaded[name]; }
  const root = process.env.LUAJS_ROOT || __dirname;
  const base = path.join(root, ...String(name).split('.'));
  const file = fs.existsSync(base + '.js') ? base + '.js' : (fs.existsSync(path.join(base, 'init.js')) ? path.join(base, 'init.js') : null);
  if (!file) throw new LuaError("module '" + name + "' not found (no transliteration of it)");
  loaded[name] = true; // a require cycle sees `true`, as Lua's does
  const m = require(file);
  const v = m && typeof m.$chunk === 'function' ? $1(m.$chunk(name)) : m; // the chunk runs with the module name as `...`
  loaded[name] = v === undefined ? true : v;
  return loaded[name];
}

module.exports = { $mappos, $forprep, $t, $and, $or, $mv, $1, $all, $adj, $arr, $rec, $map, $idx, $set, $len, $m, $call, $add, $sub, $mul, $div, $mod,
  $pow, $neg, $cat, $eq, $lt, $le, $gt, $ge, $type, $tostring, $tonumber, $abort, $require, $G: G, MV, LuaError, LuaBreak, $numstr };
