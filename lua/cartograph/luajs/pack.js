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
//              A key a shape cannot hold (a string on an ARRAY, a number on a RECORD) ABORTS by name.
//   function   a JS function; multiple returns are an MV (`$mv`), unwrapped by `$1` / spread by `$all`
//   metatable  held in a WeakMap keyed by the table's identity (META), so a table's own representation is untouched.
//              Honoured as Lua 5.1 / LuaJIT does: __index / __newindex on a RAW miss, __call, __tostring, __concat,
//              arithmetic (__add … __unm), __eq (only when BOTH operands are tables sharing the same __eq), __lt / __le,
//              __metatable. __len does NOT fire on a table (5.1 — measured in-tree under LuaJIT), so it is ignored.
//              __mode is held STRONGLY: GC-driven removal is not deterministically observable, so never removing is a
//              faithful subset of what Lua may do.
'use strict';

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
const trim = a => { while (a.length > 1 && a[a.length - 1] === undefined) a.length--; return a; };
const $arr = (...items) => trim([undefined, ...items]);
const $rec = (...pairs) => { const o = Object.create(null); for (let i = 0; i < pairs.length; i += 2) if (pairs[i + 1] !== undefined) o[pairs[i]] = pairs[i + 1]; return o; };
const $map = (...pairs) => { const m = new Map(); for (let i = 0; i < pairs.length; i += 2) if (pairs[i + 1] !== undefined) m.set(key(pairs[i]), pairs[i + 1]); return m; };
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
  if (Array.isArray(t)) return typeof k === 'number' && Number.isInteger(k) && k >= 1 ? t[k] : undefined;
  if (isRec(t)) return typeof k === 'string' ? t[k] : undefined;
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
  return idx_raw(t, k);
}
function idx_raw(t, k) {
  if (t instanceof Map) return t.get(k);
  if (Array.isArray(t)) {
    if (typeof k === 'number') return Number.isInteger(k) && k >= 1 ? t[k] : undefined;
    if (typeof k === 'string') return undefined; // an array holds no string keys: a read is nil (a WRITE aborts)
    return undefined;
  }
  if (isRec(t)) return typeof k === 'string' ? t[k] : undefined;
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
  if (t instanceof Map) { if (v === undefined) t.delete(k); else t.set(k, v); return; }
  if (Array.isArray(t)) {
    if (typeof k === 'number' && Number.isInteger(k) && k >= 1) { t[k] = v; if (v === undefined) trim(t); return; }
    $abort('a ' + typeof k + ' key on an ARRAY-shaped table (' + String(k) + ')');
  }
  if (isRec(t)) {
    if (typeof k === 'string') { if (v === undefined) delete t[k]; else t[k] = v; return; }
    $abort('a ' + typeof k + ' key on a RECORD-shaped table (' + String(k) + ')');
  }
  throw new LuaError('attempt to index a ' + $type(t) + ' value');
}
function $len(x) {
  if (typeof x === 'string') return x.length;
  if (Array.isArray(x)) return x.length - 1;
  if (x instanceof Map) { let n = 0; while (x.get(n + 1) !== undefined) n++; return n; }
  if (isRec(x)) return 0;
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
const $pow = arith('__pow', (a, b) => Math.pow(a, b));
const $neg = a => { if (numish(a)) return -num(a); const h = meta(a, '__unm'); if (h !== undefined) return $1($call(h, a, a)); return -num(a); };
function $numstr(n) {
  if (Number.isInteger(n) && Math.abs(n) < 1e15) return String(n);
  if (n === Infinity) return 'inf';
  if (n === -Infinity) return '-inf';
  if (Number.isNaN(n)) return 'nan';
  // %.14g
  let s = n.toPrecision(14);
  if (s.includes('e')) {
    let [m, e] = s.split('e');
    if (m.includes('.')) m = m.replace(/0+$/, '').replace(/\.$/, '');
    const sign = e[0] === '-' ? '-' : '+';
    e = e.replace(/^[+-]/, '');
    return m + 'e' + sign + (e.length < 2 ? '0' + e : e);
  }
  if (s.includes('.')) s = s.replace(/0+$/, '').replace(/\.$/, '');
  return s;
}
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
  if (!isTable(a) || !isTable(b)) return false;
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
const cmpok = (a, b) => { if (!((typeof a === 'number' && typeof b === 'number') || (typeof a === 'string' && typeof b === 'string'))) throw new LuaError('attempt to compare ' + $type(a) + ' with ' + $type(b)); };

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
  const s = v.trim();
  if (/^-?0[xX][0-9a-fA-F]+$/.test(s)) return (s[0] === '-' ? -1 : 1) * parseInt(s.replace(/^-/, ''), 16);
  if (/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(s)) return Number(s);
  if (/^[+-]?(inf|nan)/i.test(s)) return undefined;
  return undefined;
}
const pairs_iter = t => {
  if (t instanceof Map) { const it = t.entries(); return () => { for (;;) { const r = it.next(); if (r.done) return undefined; const [k, v] = r.value; if (t.has(k) && t.get(k) !== undefined) return $mv(k, v); } }; }
  if (Array.isArray(t)) { let i = 0; return () => { while (++i < t.length) if (t[i] !== undefined) return $mv(i, t[i]); return undefined; }; }
  if (isRec(t)) { const ks = Object.keys(t); let i = 0; return () => { while (i < ks.length) { const k = ks[i++]; if (t[k] !== undefined) return $mv(k, t[k]); } return undefined; }; }
  throw new LuaError("bad argument #1 to 'pairs' (table expected, got " + $type(t) + ')');
};
const G = Object.create(null);
G.pairs = t => $mv(pairs_iter(t), t, undefined);
// 5.1: ipairs, unpack and the table library read and write RAW (lua_rawgeti) — metamethods do not fire
G.ipairs = t => { if (!isTable(t) && typeof t !== 'string') throw new LuaError("bad argument #1 to 'ipairs' (table expected, got " + $type(t) + ')'); return $mv((s, i) => { i = i + 1; const v = rawget(s, i); return v === undefined ? undefined : $mv(i, v); }, t, 0); };
G.next = (t, k) => {
  if (k !== undefined) $abort('next(t, k) with a control key');
  const r = pairs_iter(t)();
  return r === undefined ? undefined : r;
};
G.type = v => $type(v);
G.tostring = v => $tostring(v);
G.tonumber = (v, b) => $tonumber(v, b);
G.select = (n, ...a) => (n === '#' ? a.length : $mv(...a.slice(n < 0 ? a.length + n : n - 1)));
G.unpack = (t, i, j) => { i = i === undefined ? 1 : i; j = j === undefined ? $len(t) : j; const o = []; for (let k = i; k <= j; k++) o.push(rawget(t, k)); return $mv(...o); };
G.error = (v, level) => { throw new LuaError(v); };
G.assert = (v, msg, ...rest) => { if (!$t(v)) throw new LuaError(msg === undefined ? 'assertion failed!' : msg); return $mv(v, msg, ...rest); };
G.pcall = (f, ...a) => { try { return $mv(true, ...$all($call(f, ...a))); } catch (e) { return $mv(false, e instanceof LuaError ? e.value : (e instanceof LuaBreak ? e : String(e && e.message || e))); } };
G.rawequal = (a, b) => a === b;
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
G.print = (...a) => { process.stdout.write(Buffer.from(a.map($tostring).join('\t') + '\n', 'latin1')); };
G.require = name => $require(name);
G.table = $rec(
  'insert', (t, a, b) => { if (b === undefined) rawset(t, $len(t) + 1, a); else { const n = $len(t); for (let k = n; k >= a; k--) rawset(t, k + 1, rawget(t, k)); rawset(t, a, b); } },
  'remove', (t, pos) => { const n = $len(t); if (pos === undefined) pos = n; if (n === 0) return undefined; const v = rawget(t, pos); for (let k = pos; k < n; k++) rawset(t, k, rawget(t, k + 1)); rawset(t, n, undefined); return v; },
  'concat', (t, sep, i, j) => { sep = sep === undefined ? '' : sep; i = i === undefined ? 1 : i; j = j === undefined ? $len(t) : j; const o = []; for (let k = i; k <= j; k++) { const v = rawget(t, k); if (typeof v !== 'string' && typeof v !== 'number') throw new LuaError("invalid value (at index " + k + ") in table for 'concat'"); o.push(cstr(v)); } return o.join(cstr(sep)); },
  'sort', (t, cmp) => { const n = $len(t); const a = []; for (let k = 1; k <= n; k++) a.push(rawget(t, k)); a.sort((x, y) => (cmp ? ($t(cmp(x, y)) ? -1 : ($t(cmp(y, x)) ? 1 : 0)) : ($lt(x, y) ? -1 : ($lt(y, x) ? 1 : 0)))); for (let k = 1; k <= n; k++) rawset(t, k, a[k - 1]); },
  'unpack', (...a) => G.unpack(...a));
G.math = $rec('floor', Math.floor, 'ceil', Math.ceil, 'abs', Math.abs, 'sqrt', Math.sqrt, 'max', (...a) => Math.max(...a.map(x => num(x))), 'min', (...a) => Math.min(...a.map(x => num(x))),
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
const MAGIC = /[\^$*+?.()[\]%-]/;
STRING.find = (s, p, init, plain) => {
  s = cstr(s); p = cstr(p); init = init === undefined ? 1 : bpos(s, init);
  if (!$t(plain) && MAGIC.test(p)) $abort('string.find with a Lua pattern');
  const at = s.indexOf(p, init - 1);
  return at < 0 ? undefined : $mv(at + 1, at + p.length);
};
for (const name of ['match', 'gmatch', 'gsub']) STRING[name] = () => $abort('string.' + name + ' (Lua patterns)');
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

// ── modules ──────────────────────────────────────────────────────────────────────────────────────────────────────
// `require 'a.b'` loads <root>/a/b.js (or <root>/a/b/init.js), root = LUAJS_ROOT or this pack's directory; a module
// that is not there is a HOST gap, and says so
const path = require('path');
const fs = require('fs');
const loaded = Object.create(null);
function $require(name) {
  if (name in loaded) return loaded[name];
  const root = process.env.LUAJS_ROOT || __dirname;
  const base = path.join(root, ...String(name).split('.'));
  const file = fs.existsSync(base + '.js') ? base + '.js' : (fs.existsSync(path.join(base, 'init.js')) ? path.join(base, 'init.js') : null);
  if (!file) throw new LuaError("module '" + name + "' not found (no transliteration of it)");
  loaded[name] = true; // a require cycle sees `true`, as Lua's does
  const v = require(file);
  loaded[name] = v === undefined ? true : v;
  return loaded[name];
}

module.exports = { $t, $and, $or, $mv, $1, $all, $adj, $arr, $rec, $map, $idx, $set, $len, $m, $call, $add, $sub, $mul, $div, $mod,
  $pow, $neg, $cat, $eq, $lt, $le, $gt, $ge, $type, $tostring, $tonumber, $abort, $require, $G: G, MV, LuaError, LuaBreak, $numstr };
