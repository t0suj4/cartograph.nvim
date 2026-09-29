// GENERATED — do not edit. LuaJIT's number formatter, TRANSLITERATED from C by cartograph.cjs (exact heap mode,
// CART-1211 leaf 3):
//   source   src/lj_strfmt_num.c (lj_strfmt_wfnum …) + src/lj_strfmt.c (lj_strfmt_wint), LuaJIT fbb36bb6 — the ORACLE's revision
//   root     cjs_numstr = lj_strfmt_num's body, its GCstr result replaced by the byte count
//   flags    gcc -E -P -D__attribute__(x)= -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -U_FORTIFY_SOURCE -DLUAJIT_UNWIND_EXTERNAL (the build's own, from its make)
//   layout   TValue 8 bytes: u64@0:u64 n@0:f64 it64@0:i64 i@0:i32 it@4:u32 ftsz@0:i64 u32.lo@0:u32 u32.hi@4:u32 (the compiler's: offsetof/sizeof/classify)
//   command  nvim --headless -u NONE -l tools/cjs.lua strfmt <BUILT luajit src dir> lua/cartograph/luajs/strfmt.js
// LuaJIT: Copyright (C) 2005-2026 Mike Pall. MIT license (its COPYRIGHT file).
'use strict';
// C truthiness: nonzero and non-NULL (offset 0 is never a valid pointer)
const $T = x => x !== 0 && x !== null && x !== undefined;
const $crefuse = what => { throw new Error("[cjs] no faithful form: " + what); };
let H = null; // the byte heap, installed by the caller (setheap)
// the heap image: every static array the code reads, at its fixed offset (offset 0 reserved)
const IMAGE = [
  // four_ulp_m_e[256] at 1
  [1, [34, (-21), 68, (-21), 14, (-20), 28, (-20), 55, (-20), 2, (-19), 3, (-19), 5, (-19), 9, (-19), (-82), (-18), 35, (-18), 7, (-17), (-117), (-17), 28, (-17), 56, (-17), 112, (-16), (-33), (-16), 45, (-16), 89, (-16), (-78), (-15), 36, (-15), 72, (-15), (-113), (-14), 29, (-14), 57, (-14), 114, (-13), (-28), (-13), 46, (-13), 91, (-12), (-74), (-12), 37, (-12), 73, (-12), 15, (-11), 3, (-11), 59, (-11), 2, (-10), 3, (-10), 5, (-10), 1, (-9), (-69), (-9), 38, (-9), 75, (-9), 15, (-7), 3, (-7), 6, (-7), 12, (-6), (-17), (-7), 48, (-7), 96, (-7), (-65), (-6), 39, (-6), 77, (-6), (-103), (-5), 31, (-5), 62, (-5), 123, (-4), (-11), (-4), 49, (-4), 98, (-4), (-60), (-3), 4, (-2), 79, (-3), 16, (-2), 32, (-2), 63, (-2), 2, (-1), 25, 0, 5, 1, 1, 2, 2, 2, 4, 2, 8, 2, 16, 2, 32, 2, 64, 2, (-128), 2, 26, 2, 52, 2, 103, 3, (-51), 3, 41, 4, 82, 4, (-92), 4, 33, 4, 66, 4, (-124), 5, 27, 5, 53, 5, 105, 6, 21, 6, 42, 6, 84, 6, 17, 7, 34, 7, 68, 7, 2, 8, 3, 8, 6, 8, 108, 9, (-41), 9, 43, 10, 86, 9, (-84), 10, 35, 10, 69, 10, (-118), 11, 28, 11, 55, 12, 11, 13, 22, 13, 44, 13, 88, 13, (-80), 13, 36, 13, 71, 13, (-115), 14, 29, 14, 57, 14, 113, 15, (-30), 15, 46, 15, 91, 15, 19, 16, 37, 16, 73, 16, 2, 17, 3, 17, 6, 17]],
  // ndigits_dec_threshold[11] at 264
  [264, [((0) >>> 0), 9, 99, 999, 9999, 99999, 999999, 9999999, 99999999, 999999999, 0xffffffff], "setUint32"],
  // rescale_e[32] at 312
  [312, [(-(308)), (-(289)), (-(270)), (-(250)), (-(231)), (-(212)), (-(193)), (-(173)), (-(154)), (-(135)), (-(115)), (-(96)), (-(77)), (-(58)), (-(38)), (-(0)), (-(0)), (-(0)), (39), (58), (77), (96), (116), (135), (154), (174), (193), (212), (231), (251), (270), (289)], "setInt16"],
  // rescale_n[32] at 376
  [376, [1e+308, 1.0000000000000001e+289, 1e+270, 9.9999999999999992e+249, 1.0000000000000001e+231, 9.9999999999999991e+211, 1.0000000000000001e+193, 1e+173, 1e+154, 9.9999999999999996e+134, 1e+115, 1e+96, 9.9999999999999998e+76, 9.9999999999999994e+57, 9.9999999999999998e+37, 1, 1, 1, 9.9999999999999993e-40, 1e-58, 9.9999999999999993e-78, 9.9999999999999991e-97, 9.9999999999999999e-117, 1e-135, 9.9999999999999997e-155, 1e-174, 1e-193, 9.9999999999999995e-213, 9.9999999999999999e-232, 1e-251, 1e-270, 1e-289], "setFloat64"],
];
const IMAGE_END = 632;
function image() { const h = new Uint8Array(IMAGE_END), dv = new DataView(h.buffer);
  const W = { setFloat64: 8, setBigUint64: 8, setBigInt64: 8, setUint32: 4, setInt32: 4, setUint16: 2, setInt16: 2 };
  for (const [at, vals, set] of IMAGE) { if (!set) h.set(vals, at); else vals.forEach((v, i) => dv[set](at + i * W[set], v, true)); }
  return h; }
const $STACK = 65536;
H = new Uint8Array(IMAGE_END + $STACK); H.set(image());
const DV = new DataView(H.buffer);
let SP = H.length;
const $alloca = n => { SP = (SP - n) & ~7; if (SP < IMAGE_END) throw new Error("[cjs] heap stack overflow"); return SP; };
const $memcmp = (a, b, n) => { for (let i = 0; i < n; i++) { const d = H[a + i] - H[b + i]; if (d) return d; } return 0; };
function ndigits_dec(x) {
let t = ((((((Math.imul((((((Math.clz32(((x | ((1) >>> 0)) >>> 0)) ^ 31))) >>> 0)), ((77) >>> 0)) >>> 0)) >>> 8)) + ((1) >>> 0)) >>> 0);
return ((t + (((+(x > DV.getUint32((264 + (t) * 4), true)))) >>> 0)) >>> 0);
}

function lj_strfmt_wint(p, k) {
let u, v, w, d, d$2, d$3, d$4, d$5, d$6, d$7;
let $L = 0;
$d: for (;;) switch ($L) {
case 0:
u = ((k) >>> 0);
if (!$T((+(k < 0)))) { $L = 7; continue $d; }
u = ((((~u) >>> 0) + 1) >>> 0);
H[p++] = 45;
case 7:
case 8:
if (!$T((+(u < ((10000) >>> 0))))) { $L = 9; continue $d; }
if (!$T((+(u < ((10) >>> 0))))) { $L = 11; continue $d; }
{ $L = 6; continue $d; }
case 11:
case 12:
if (!$T((+(u < ((100) >>> 0))))) { $L = 13; continue $d; }
{ $L = 5; continue $d; }
case 13:
case 14:
if (!$T((+(u < ((1000) >>> 0))))) { $L = 15; continue $d; }
{ $L = 4; continue $d; }
case 15:
case 16:
{ $L = 10; continue $d; }
case 9:
v = Math.trunc(u / ((10000) >>> 0));
u = ((u - (Math.imul(v, ((10000) >>> 0)) >>> 0)) >>> 0);
if (!$T((+(v < ((10000) >>> 0))))) { $L = 17; continue $d; }
if (!$T((+(v < ((10) >>> 0))))) { $L = 19; continue $d; }
{ $L = 3; continue $d; }
case 19:
case 20:
if (!$T((+(v < ((100) >>> 0))))) { $L = 21; continue $d; }
{ $L = 2; continue $d; }
case 21:
case 22:
if (!$T((+(v < ((1000) >>> 0))))) { $L = 23; continue $d; }
{ $L = 1; continue $d; }
case 23:
case 24:
{ $L = 18; continue $d; }
case 17:
w = Math.trunc(v / ((10000) >>> 0));
v = ((v - (Math.imul(w, ((10000) >>> 0)) >>> 0)) >>> 0);
if (!$T((+(w >= ((10) >>> 0))))) { $L = 25; continue $d; }
d = (((Math.imul(w, (((Math.trunc((((((1 << 10)) + 10) - 1)) / 10))) >>> 0)) >>> 0)) >>> 10);
w = ((w - (Math.imul(d, ((10) >>> 0)) >>> 0)) >>> 0);
H[p++] = (((((((48) >>> 0) + d) >>> 0))) << 24 >> 24);
case 25:
case 26:
H[p++] = (((((((48) >>> 0) + w) >>> 0))) << 24 >> 24);
case 18:
d$2 = (((Math.imul(v, (((Math.trunc((((((1 << 23)) + 1000) - 1)) / 1000))) >>> 0)) >>> 0)) >>> 23);
v = ((v - (Math.imul(d$2, ((1000) >>> 0)) >>> 0)) >>> 0);
H[p++] = (((((((48) >>> 0) + d$2) >>> 0))) << 24 >> 24);
case 1:
d$3 = (((Math.imul(v, (((Math.trunc((((((1 << 12)) + 100) - 1)) / 100))) >>> 0)) >>> 0)) >>> 12);
v = ((v - (Math.imul(d$3, ((100) >>> 0)) >>> 0)) >>> 0);
H[p++] = (((((((48) >>> 0) + d$3) >>> 0))) << 24 >> 24);
case 2:
d$4 = (((Math.imul(v, (((Math.trunc((((((1 << 10)) + 10) - 1)) / 10))) >>> 0)) >>> 0)) >>> 10);
v = ((v - (Math.imul(d$4, ((10) >>> 0)) >>> 0)) >>> 0);
H[p++] = (((((((48) >>> 0) + d$4) >>> 0))) << 24 >> 24);
case 3:
H[p++] = (((((((48) >>> 0) + v) >>> 0))) << 24 >> 24);
case 10:
d$5 = (((Math.imul(u, (((Math.trunc((((((1 << 23)) + 1000) - 1)) / 1000))) >>> 0)) >>> 0)) >>> 23);
u = ((u - (Math.imul(d$5, ((1000) >>> 0)) >>> 0)) >>> 0);
H[p++] = (((((((48) >>> 0) + d$5) >>> 0))) << 24 >> 24);
case 4:
d$6 = (((Math.imul(u, (((Math.trunc((((((1 << 12)) + 100) - 1)) / 100))) >>> 0)) >>> 0)) >>> 12);
u = ((u - (Math.imul(d$6, ((100) >>> 0)) >>> 0)) >>> 0);
H[p++] = (((((((48) >>> 0) + d$6) >>> 0))) << 24 >> 24);
case 5:
d$7 = (((Math.imul(u, (((Math.trunc((((((1 << 10)) + 10) - 1)) / 10))) >>> 0)) >>> 0)) >>> 10);
u = ((u - (Math.imul(d$7, ((10) >>> 0)) >>> 0)) >>> 0);
H[p++] = (((((((48) >>> 0) + d$7) >>> 0))) << 24 >> 24);
case 6:
H[p++] = (((((((48) >>> 0) + u) >>> 0))) << 24 >> 24);
return p;
return;
}
}

function nd_mul2k(nd, ndhi, k, carry_in, sf) {
let i, ndlo = ((0) >>> 0), start = ((1) >>> 0);
if ($T((+($T(+(k > (((29 * 2)) >>> 0))) && $T(+(((((((sf) >>> 4)) & ((3) >>> 0)) >>> 0)) !== (((((((0x0020) >> 4)) & 3))) >>> 0))))))) {
start = ((ndhi - Math.trunc(((((((((((((sf) >>> 24)) & 255) >>> 0)) - 1) >>> 0)) + ((17) >>> 0)) >>> 0)) / ((8) >>> 0))) >>> 0);
}
while ($T((+(k >= ((29) >>> 0))))) {
for (i = ndlo; $T(+(i <= ndhi)); i++) {
let val = BigInt.asUintN(64, (BigInt.asUintN(64, BigInt.asUintN(64, BigInt(DV.getUint32((nd + (i) * 4), true))) << BigInt(29))) | BigInt.asUintN(64, BigInt(carry_in)));
carry_in = (Number(BigInt.asUintN(32, (((val) / BigInt.asUintN(64, BigInt(1000000000)))))));
DV.setUint32((nd + (i) * 4), ((Number(BigInt.asUintN(32, val)) - (Math.imul(carry_in, ((1000000000) >>> 0)) >>> 0)) >>> 0), true);
}
if ($T((carry_in))) {
DV.setUint32((nd + (++ndhi) * 4), carry_in, true);
carry_in = ((0) >>> 0);
if ($T((+(start++ === ndlo)))) ++ndlo;
}
k = ((k - ((29) >>> 0)) >>> 0);
}
if ($T((k))) {
for (i = ndlo; $T(+(i <= ndhi)); i++) {
let val = BigInt.asUintN(64, (BigInt.asUintN(64, BigInt.asUintN(64, BigInt(DV.getUint32((nd + (i) * 4), true))) << BigInt(k))) | BigInt.asUintN(64, BigInt(carry_in)));
carry_in = (Number(BigInt.asUintN(32, (((val) / BigInt.asUintN(64, BigInt(1000000000)))))));
DV.setUint32((nd + (i) * 4), ((Number(BigInt.asUintN(32, val)) - (Math.imul(carry_in, ((1000000000) >>> 0)) >>> 0)) >>> 0), true);
}
if ($T((carry_in))) DV.setUint32((nd + (++ndhi) * 4), carry_in, true);
}
return ndhi;
}

function nd_div2k(nd, ndhi, k, sf) {
let ndlo = ((0) >>> 0), stop1 = (((~0)) >>> 0), stop2 = (((~0)) >>> 0);
if ($T((+!$T(ndhi)))) {
if ($T((+!$T(DV.getUint32((nd + (0) * 4), true))))) {
return ((0) >>> 0);
} else {
let s = ((((31 - Math.clz32((DV.getUint32((nd + (0) * 4), true)) & -(DV.getUint32((nd + (0) * 4), true))))) >>> 0));
if ($T((+(s >= k)))) {
DV.setUint32((nd + (0) * 4), (DV.getUint32((nd + (0) * 4), true) >>> k), true);
return ((0) >>> 0);
}
DV.setUint32((nd + (0) * 4), (DV.getUint32((nd + (0) * 4), true) >>> s), true);
k = ((k - s) >>> 0);
}
}
if ($T((+(k > ((18) >>> 0))))) {
if ($T((+(((((((sf) >>> 4)) & ((3) >>> 0)) >>> 0)) === (((((((0x0020) >> 4)) & 3))) >>> 0))))) {

} else {
let floorlog2 = (((((((Math.imul(ndhi, ((29) >>> 0)) >>> 0) + (((((Math.clz32(DV.getUint32((nd + (ndhi) * 4), true)) ^ 31))) >>> 0))) >>> 0) - k) >>> 0)) | 0);
let floorlog10 = (Math.trunc(((floorlog2 * 0.30102999566398114))) | 0);
stop1 = (((62 + Math.trunc(((floorlog10 - (((((((((((sf) >>> 24)) & 255) >>> 0)) - 1) >>> 0))) | 0))) / 9))) >>> 0);
stop2 = ((((((61) >>> 0) + ndhi) >>> 0) - ((Math.trunc((((((((((((sf) >>> 24)) & 255) >>> 0)) - 1) >>> 0))) | 0) / 8)) >>> 0)) >>> 0);
}
}
while ($T((+(k >= ((9) >>> 0))))) {
let i = ndhi, carry = ((0) >>> 0);
for (; ; ) {
let val = DV.getUint32((nd + (i) * 4), true);
DV.setUint32((nd + (i) * 4), ((((val >>> 9)) + carry) >>> 0), true);
carry = (Math.imul((((val & ((0x1ff) >>> 0)) >>> 0)), ((1953125) >>> 0)) >>> 0);
if ($T((+(i === ndlo)))) break;
i = (((((i - ((1) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0);
}
if ($T((+($T(+(ndlo !== stop1)) && $T(+(ndlo !== stop2)))))) {
if ($T((carry))) {
ndlo = (((((ndlo - ((1) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0);
DV.setUint32((nd + (ndlo) * 4), carry, true);
}
if ($T((+!$T(DV.getUint32((nd + (ndhi) * 4), true))))) {
ndhi = (((((ndhi - ((1) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0);
stop2--;
}
} else if ($T((+!$T(DV.getUint32((nd + (ndhi) * 4), true))))) {
if ($T((+(ndhi !== ndlo)))) {
ndhi = (((((ndhi - ((1) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0);
stop2--;
} else return ndlo;
}
k = ((k - ((9) >>> 0)) >>> 0);
}
if ($T((k))) {
let mask = (((((1 << k) >>> 0)) - ((1) >>> 0)) >>> 0), mul = (((1000000000 >> k)) >>> 0), i = ndhi, carry = ((0) >>> 0);
for (; ; ) {
let val = DV.getUint32((nd + (i) * 4), true);
DV.setUint32((nd + (i) * 4), ((((val >>> k)) + carry) >>> 0), true);
carry = (Math.imul((((val & mask) >>> 0)), mul) >>> 0);
if ($T((+(i === ndlo)))) break;
i = (((((i - ((1) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0);
}
if ($T((carry))) {
ndlo = (((((ndlo - ((1) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0);
DV.setUint32((nd + (ndlo) * 4), carry, true);
}
}
return ndlo;
}

function nd_add_m10e(nd, ndhi, m, e) {
let i, carry;
if ($T((+(e >= 0)))) {
i = Math.trunc(((e) >>> 0) / ((9) >>> 0));
carry = (Math.imul(((m) >>> 0), (((DV.getUint32((264 + ((e - (((i) | 0) * 9))) * 4), true) + ((1) >>> 0)) >>> 0))) >>> 0);
} else {
let f = Math.trunc(((e - 8)) / 9);
i = ((((64 + f))) >>> 0);
carry = (Math.imul(((m) >>> 0), (((DV.getUint32((264 + ((e - (f * 9))) * 4), true) + ((1) >>> 0)) >>> 0))) >>> 0);
}
for (; ; ) {
let val = ((DV.getUint32((nd + (i) * 4), true) + carry) >>> 0);
if ($T((+!$T(+!$T((+(val >= ((1000000000) >>> 0)))))))) {
val = ((val - ((1000000000) >>> 0)) >>> 0);
DV.setUint32((nd + (i) * 4), val, true);
if ($T((+!$T(+!$T((+(i === ndhi))))))) {
ndhi = (((((ndhi + ((1) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0);
DV.setUint32((nd + (ndhi) * 4), ((1) >>> 0), true);
break;
}
carry = ((1) >>> 0);
i = (((((i + ((1) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0);
} else {
DV.setUint32((nd + (i) * 4), val, true);
break;
}
}
return ndhi;
}

function lj_strfmt_wuint9(p, u) {
let v = Math.trunc(u / ((10000) >>> 0)), w;
u = ((u - (Math.imul(v, ((10000) >>> 0)) >>> 0)) >>> 0);
w = Math.trunc(v / ((10000) >>> 0));
v = ((v - (Math.imul(w, ((10000) >>> 0)) >>> 0)) >>> 0);
H[p++] = (((((((48) >>> 0) + w) >>> 0))) << 24 >> 24);
{
let d = (((Math.imul(v, (((Math.trunc((((((1 << 23)) + 1000) - 1)) / 1000))) >>> 0)) >>> 0)) >>> 23);
v = ((v - (Math.imul(d, ((1000) >>> 0)) >>> 0)) >>> 0);
H[p++] = (((((((48) >>> 0) + d) >>> 0))) << 24 >> 24);
}
{
let d = (((Math.imul(v, (((Math.trunc((((((1 << 12)) + 100) - 1)) / 100))) >>> 0)) >>> 0)) >>> 12);
v = ((v - (Math.imul(d, ((100) >>> 0)) >>> 0)) >>> 0);
H[p++] = (((((((48) >>> 0) + d) >>> 0))) << 24 >> 24);
}
{
let d = (((Math.imul(v, (((Math.trunc((((((1 << 10)) + 10) - 1)) / 10))) >>> 0)) >>> 0)) >>> 10);
v = ((v - (Math.imul(d, ((10) >>> 0)) >>> 0)) >>> 0);
H[p++] = (((((((48) >>> 0) + d) >>> 0))) << 24 >> 24);
}
H[p++] = (((((((48) >>> 0) + v) >>> 0))) << 24 >> 24);
{
let d = (((Math.imul(u, (((Math.trunc((((((1 << 23)) + 1000) - 1)) / 1000))) >>> 0)) >>> 0)) >>> 23);
u = ((u - (Math.imul(d, ((1000) >>> 0)) >>> 0)) >>> 0);
H[p++] = (((((((48) >>> 0) + d) >>> 0))) << 24 >> 24);
}
{
let d = (((Math.imul(u, (((Math.trunc((((((1 << 12)) + 100) - 1)) / 100))) >>> 0)) >>> 0)) >>> 12);
u = ((u - (Math.imul(d, ((100) >>> 0)) >>> 0)) >>> 0);
H[p++] = (((((((48) >>> 0) + d) >>> 0))) << 24 >> 24);
}
{
let d = (((Math.imul(u, (((Math.trunc((((((1 << 10)) + 10) - 1)) / 10))) >>> 0)) >>> 0)) >>> 10);
u = ((u - (Math.imul(d, ((10) >>> 0)) >>> 0)) >>> 0);
H[p++] = (((((((48) >>> 0) + d) >>> 0))) << 24 >> 24);
}
H[p++] = (((((((48) >>> 0) + u) >>> 0))) << 24 >> 24);
return p;
}

function nd_similar(nd, ndhi, ref, hilen, prec) {
const $sp = SP;
try {
let nd9 = $alloca((Math.trunc(9) * 1)), ref9 = $alloca((Math.trunc(9) * 1));
if ($T((+(hilen <= prec)))) {
if ($T((+!$T(+!$T((+(DV.getUint32((nd + (ndhi) * 4), true) !== DV.getUint32((ref), true)))))))) return 0;
prec = ((prec - hilen) >>> 0);
((ref -= 4) + 4);
ndhi = (((((ndhi - ((1) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0);
if ($T((+(prec >= ((9) >>> 0))))) {
if ($T((+!$T(+!$T((+(DV.getUint32((nd + (ndhi) * 4), true) !== DV.getUint32((ref), true)))))))) return 0;
prec = ((prec - ((9) >>> 0)) >>> 0);
((ref -= 4) + 4);
ndhi = (((((ndhi - ((1) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0);
}
} else {
prec = ((prec - ((hilen - ((9) >>> 0)) >>> 0)) >>> 0);
}
(void (0));
lj_strfmt_wuint9(nd9, DV.getUint32((nd + (ndhi) * 4), true));
lj_strfmt_wuint9(ref9, DV.getUint32((ref), true));
return +($T(+!$T($memcmp(nd9, ref9, BigInt.asUintN(64, BigInt(prec))))) && $T(+((+((H[nd9 + prec] << 24 >> 24) < 53)) === (+((H[ref9 + prec] << 24 >> 24) < 53)))));
} finally { SP = $sp; }
}

function nd_round(nd, ndlo, ndhi, e) {
const $sp = SP;
try {
let i, d, buf, f;
buf = $alloca((Math.trunc(9) * 1));
let $L = 0;
$d: for (;;) switch ($L) {
case 0:
if (!$T((+(e >= 0)))) { $L = 2; continue $d; }
i = Math.trunc(((e) >>> 0) / ((9) >>> 0));
d = ((8 - e) + (((i) | 0) * 9));
{ $L = 3; continue $d; }
case 2:
f = Math.trunc(((e - 8)) / 9);
i = ((((64 + f))) >>> 0);
d = ((8 - e) + (f * 9));
case 3:
lj_strfmt_wuint9(buf, DV.getUint32((nd + (i) * 4), true));
if (!$T((+((H[buf + d] << 24 >> 24) < 53)))) { $L = 4; continue $d; }
return ndhi;
{ $L = 5; continue $d; }
case 4:
if (!$T((+((H[buf + d] << 24 >> 24) === 53)))) { $L = 6; continue $d; }
if (!$T((($T(d) ? (((((H[buf + (d - 1)] << 24 >> 24) & 1))) >>> 0) : (((DV.getUint32((nd + ((((((i + ((1) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0)) * 4), true) & ((1) >>> 0)) >>> 0)))))) { $L = 8; continue $d; }
{ $L = 1; continue $d; }
case 8:
case 9:
case 10:
if (!$T((+(++d < 9)))) { $L = 11; continue $d; }
if (!$T((+((H[buf + d] << 24 >> 24) !== 48)))) { $L = 12; continue $d; }
{ $L = 1; continue $d; }
case 12:
case 13:
{ $L = 10; continue $d; }
case 11:
case 14:
if (!$T((+(i !== ndlo)))) { $L = 15; continue $d; }
if (!$T((DV.getUint32((nd + (i) * 4), true)))) { $L = 16; continue $d; }
{ $L = 1; continue $d; }
case 16:
case 17:
i = (((((i - ((1) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0);
{ $L = 14; continue $d; }
case 15:
return ndhi;
case 6:
case 7:
case 5:
case 1:
return nd_add_m10e(nd, ndhi, 5, e);
return;
}
} finally { SP = $sp; }
}

function lj_strfmt_wfnum(sb, sf, n, p) {
const $sp = SP;
try {
let width, prec, len, t, prefix, ch, hexdig, e, prefix$2, eprefix, shift, q, nd, ndhi, ndlo, i, e$2, ndebias, prefix$3, q$2, eprefix$2, nde, hilen, eidx, m_e, tail, maxprec, tail$2, maxprec$2;
t = $alloca(8);
nd = $alloca((Math.trunc(64) * 4));
tail = $alloca((Math.trunc(9) * 1));
tail$2 = $alloca((Math.trunc(9) * 1));
let $L = 0;
$d: for (;;) switch ($L) {
case 0:
width = ((((((sf) >>> 16)) & 255) >>> 0)); prec = (((((((((sf) >>> 24)) & 255) >>> 0)) - 1) >>> 0));
DV.setFloat64((t + 0), n, true);
if (!$T((+!$T(+!$T((+((((DV.getUint32((t + 4), true) << 1) >>> 0)) >= 0xffe00000))))))) { $L = 4; continue $d; }
prefix = 0; ch = ($T((((sf & ((0x2000) >>> 0)) >>> 0))) ? 0x202020 : 0);
if (!$T((+(((((((DV.getUint32((t + 4), true) & ((0x000fffff) >>> 0)) >>> 0)) | DV.getUint32((t + 0), true)) >>> 0)) !== ((0) >>> 0))))) { $L = 6; continue $d; }
ch = (ch ^ ((((110 << 16)) | ((97 << 8))) | 110));
if (!$T(((((sf & ((0x0800) >>> 0)) >>> 0))))) { $L = 8; continue $d; }
prefix = 32;
case 8:
case 9:
{ $L = 7; continue $d; }
case 6:
ch = (ch ^ ((((105 << 16)) | ((110 << 8))) | 102));
if (!$T(((((DV.getUint32((t + 4), true) & 0x80000000) >>> 0))))) { $L = 10; continue $d; }
prefix = 45;
{ $L = 11; continue $d; }
case 10:
if (!$T(((((sf & ((0x0200) >>> 0)) >>> 0))))) { $L = 12; continue $d; }
prefix = 43;
{ $L = 13; continue $d; }
case 12:
if (!$T(((((sf & ((0x0800) >>> 0)) >>> 0))))) { $L = 14; continue $d; }
prefix = 32;
case 14:
case 15:
case 13:
case 11:
case 7:
len = (((3 + (+(prefix !== 0)))) >>> 0);
if (!$T((+!$T(p)))) { $L = 16; continue $d; }
p = $crefuse("lj_buf_more: the adapter always passes a buffer");
case 16:
case 17:
if (!$T((+!$T((((sf & ((0x0100) >>> 0)) >>> 0)))))) { $L = 18; continue $d; }
case 20:
if (!$T((+(width-- > len)))) { $L = 21; continue $d; }
H[p++] = 32;
{ $L = 20; continue $d; }
case 21:
case 18:
case 19:
if (!$T((prefix))) { $L = 22; continue $d; }
H[p++] = prefix;
case 22:
case 23:
H[p++] = ((((ch >> 16))) << 24 >> 24);
H[p++] = ((((ch >> 8))) << 24 >> 24);
H[p++] = ((ch) << 24 >> 24);
{ $L = 5; continue $d; }
case 4:
if (!$T((+(((((((sf) >>> 4)) & ((3) >>> 0)) >>> 0)) === (((((((0x0000) >> 4)) & 3))) >>> 0))))) { $L = 24; continue $d; }
hexdig = ($T((((sf & ((0x2000) >>> 0)) >>> 0))) ? "0123456789ABCDEFPX" : "0123456789abcdefpx");
e = ((((((DV.getUint32((t + 4), true) >>> 20)) & ((0x7ff) >>> 0)) >>> 0)) | 0);
prefix$2 = 0; eprefix = 43;
if (!$T((((DV.getUint32((t + 4), true) & 0x80000000) >>> 0)))) { $L = 26; continue $d; }
prefix$2 = 45;
{ $L = 27; continue $d; }
case 26:
if (!$T(((((sf & ((0x0200) >>> 0)) >>> 0))))) { $L = 28; continue $d; }
prefix$2 = 43;
{ $L = 29; continue $d; }
case 28:
if (!$T(((((sf & ((0x0800) >>> 0)) >>> 0))))) { $L = 30; continue $d; }
prefix$2 = 32;
case 30:
case 31:
case 29:
case 27:
DV.setUint32((t + 4), ((DV.getUint32((t + 4), true) & ((0xfffff) >>> 0)) >>> 0), true);
if (!$T((e))) { $L = 32; continue $d; }
DV.setUint32((t + 4), ((DV.getUint32((t + 4), true) | ((0x100000) >>> 0)) >>> 0), true);
e = (e - 1023);
{ $L = 33; continue $d; }
case 32:
if (!$T((((DV.getUint32((t + 0), true) | DV.getUint32((t + 4), true)) >>> 0)))) { $L = 34; continue $d; }
shift = ($T(DV.getUint32((t + 4), true)) ? ((((20) >>> 0) - (((((Math.clz32(DV.getUint32((t + 4), true)) ^ 31))) >>> 0))) >>> 0) : ((((52) >>> 0) - (((((Math.clz32(DV.getUint32((t + 0), true)) ^ 31))) >>> 0))) >>> 0));
e = (((((((-1022)) >>> 0) - shift) >>> 0)) | 0);
DV.setBigUint64((t + 0), BigInt.asUintN(64, DV.getBigUint64((t + 0), true) << BigInt(shift)), true);
case 34:
case 35:
case 33:
if (!$T((+(((prec) | 0) < 0)))) { $L = 36; continue $d; }
prec = ($T(DV.getUint32((t + 0), true)) ? ((((13) >>> 0) - Math.trunc(((((31 - Math.clz32((DV.getUint32((t + 0), true)) & -(DV.getUint32((t + 0), true))))) >>> 0)) / ((4) >>> 0))) >>> 0) : ((((5) >>> 0) - Math.trunc(((((31 - Math.clz32((((DV.getUint32((t + 4), true) | ((0x100000) >>> 0)) >>> 0)) & -(((DV.getUint32((t + 4), true) | ((0x100000) >>> 0)) >>> 0))))) >>> 0)) / ((4) >>> 0))) >>> 0));
{ $L = 37; continue $d; }
case 36:
if (!$T((+(prec < ((13) >>> 0))))) { $L = 38; continue $d; }
DV.setBigUint64((t + 0), BigInt.asUintN(64, DV.getBigUint64((t + 0), true) + (BigInt.asUintN(64, (BigInt.asUintN(64, BigInt(1))) << BigInt((((((51) >>> 0) - (Math.imul(prec, ((4) >>> 0)) >>> 0)) >>> 0)))))), true);
case 38:
case 39:
case 37:
if (!$T((+(e < 0)))) { $L = 40; continue $d; }
eprefix = 45;
e = (-e);
case 40:
case 41:
len = ((((((((((5) >>> 0) + ndigits_dec(((e) >>> 0))) >>> 0) + prec) >>> 0) + (((+(prefix$2 !== 0))) >>> 0)) >>> 0) + (((+((((prec | (((sf & ((0x1000) >>> 0)) >>> 0))) >>> 0)) !== ((0) >>> 0)))) >>> 0)) >>> 0);
if (!$T((+!$T(p)))) { $L = 42; continue $d; }
p = $crefuse("lj_buf_more: the adapter always passes a buffer");
case 42:
case 43:
if (!$T((+!$T((((sf & ((((0x0100 | 0x0400))) >>> 0)) >>> 0)))))) { $L = 44; continue $d; }
case 46:
if (!$T((+(width-- > len)))) { $L = 47; continue $d; }
H[p++] = 32;
{ $L = 46; continue $d; }
case 47:
case 44:
case 45:
if (!$T((prefix$2))) { $L = 48; continue $d; }
H[p++] = prefix$2;
case 48:
case 49:
H[p++] = 48;
H[p++] = (H[hexdig + 17] << 24 >> 24);
if (!$T((+((((sf & ((((0x0100 | 0x0400))) >>> 0)) >>> 0)) === ((0x0400) >>> 0))))) { $L = 50; continue $d; }
case 52:
if (!$T((+(width-- > len)))) { $L = 53; continue $d; }
H[p++] = 48;
{ $L = 52; continue $d; }
case 53:
case 50:
case 51:
H[p++] = ((((((48) >>> 0) + ((DV.getUint32((t + 4), true) >>> 20))) >>> 0)) | 0);
if (!$T(((((prec | (((sf & ((0x1000) >>> 0)) >>> 0))) >>> 0))))) { $L = 54; continue $d; }
q = ((p + 1) + prec);
H[p] = 46;
if (!$T((+(prec < ((13) >>> 0))))) { $L = 56; continue $d; }
DV.setBigUint64((t + 0), (DV.getBigUint64((t + 0), true) >> BigInt((((((52) >>> 0) - (Math.imul(prec, ((4) >>> 0)) >>> 0)) >>> 0)))), true);
{ $L = 57; continue $d; }
case 56:
case 58:
if (!$T((+(prec > ((13) >>> 0))))) { $L = 59; continue $d; }
H[p + prec--] = 48;
{ $L = 58; continue $d; }
case 59:
case 57:
case 60:
if (!$T((prec))) { $L = 61; continue $d; }
H[p + prec--] = (H[hexdig + BigInt.asUintN(64, DV.getBigUint64((t + 0), true) & BigInt.asUintN(64, BigInt(15)))] << 24 >> 24);
DV.setBigUint64((t + 0), (DV.getBigUint64((t + 0), true) >> BigInt(4)), true);
{ $L = 60; continue $d; }
case 61:
p = q;
case 54:
case 55:
H[p++] = (H[hexdig + 16] << 24 >> 24);
H[p++] = eprefix;
p = lj_strfmt_wint(p, e);
{ $L = 25; continue $d; }
case 24:
ndhi = ((0) >>> 0);
e$2 = ((((((DV.getUint32((t + 4), true) >>> 20)) & ((0x7ff) >>> 0)) >>> 0)) | 0); ndebias = 0;
prefix$3 = 0;
if (!$T((((DV.getUint32((t + 4), true) & 0x80000000) >>> 0)))) { $L = 62; continue $d; }
prefix$3 = 45;
{ $L = 63; continue $d; }
case 62:
if (!$T(((((sf & ((0x0200) >>> 0)) >>> 0))))) { $L = 64; continue $d; }
prefix$3 = 43;
{ $L = 65; continue $d; }
case 64:
if (!$T(((((sf & ((0x0800) >>> 0)) >>> 0))))) { $L = 66; continue $d; }
prefix$3 = 32;
case 66:
case 67:
case 65:
case 63:
prec = ((prec + (((((((prec) | 0) >> 31)) & 7)) >>> 0)) >>> 0);
if (!$T((+(((((((sf) >>> 4)) & ((3) >>> 0)) >>> 0)) === (((((((0x0030) >> 4)) & 3))) >>> 0))))) { $L = 68; continue $d; }
prec--;
prec = ((prec ^ ((((((prec) | 0) >> 31))) >>> 0)) >>> 0);
case 68:
case 69:
if (!$T((+($T(+($T((((sf & ((0x0010) >>> 0)) >>> 0))) && $T(+(prec < ((14) >>> 0))))) && $T(+(n !== 0)))))) { $L = 70; continue $d; }
if (!$T(((ndebias = DV.getInt16((312 + ((e$2 >> 6)) * 2), true))))) { $L = 72; continue $d; }
DV.setFloat64((t + 0), (n * DV.getFloat64((376 + ((e$2 >> 6)) * 8), true)), true);
if (!$T((+!$T(+!$T((+!$T(e$2))))))) { $L = 74; continue $d; }
(DV.setFloat64((t + 0), (DV.getFloat64((t + 0), true) * 10000000000), true), ndebias = (ndebias - 10));
case 74:
case 75:
DV.setBigUint64((t + 0), BigInt.asUintN(64, DV.getBigUint64((t + 0), true) - BigInt.asUintN(64, BigInt(2))), true);
DV.setUint32((nd + (0) * 4), ((((0x100000) >>> 0) | (((DV.getUint32((t + 4), true) & ((0xfffff) >>> 0)) >>> 0))) >>> 0), true);
e$2 = (((((((((((DV.getUint32((t + 4), true) >>> 20)) & ((0x7ff) >>> 0)) >>> 0)) - ((1075) >>> 0)) >>> 0) - (((+(29 < 29))) >>> 0)) >>> 0)) | 0);
{ $L = 2; continue $d; }
case 1:
DV.setFloat64((t + 0), n, true);
e$2 = ((((((DV.getUint32((t + 4), true) >>> 20)) & ((0x7ff) >>> 0)) >>> 0)) | 0);
ndebias = ((ndhi = ((0) >>> 0)) | 0);
case 72:
case 73:
case 70:
case 71:
DV.setUint32((nd + (0) * 4), ((DV.getUint32((t + 4), true) & ((0xfffff) >>> 0)) >>> 0), true);
if (!$T((+(e$2 === 0)))) { $L = 76; continue $d; }
e$2++;
{ $L = 77; continue $d; }
case 76:
DV.setUint32((nd + (0) * 4), ((DV.getUint32((nd + (0) * 4), true) | ((0x100000) >>> 0)) >>> 0), true);
case 77:
e$2 = (e$2 - 1043);
if (!$T((DV.getUint32((t + 0), true)))) { $L = 78; continue $d; }
e$2 = (e$2 - (32 + (+(29 < 29))));
case 2:
DV.setUint32((nd + (0) * 4), (((((DV.getUint32((nd + (0) * 4), true) << 3) >>> 0)) | ((DV.getUint32((t + 0), true) >>> 29))) >>> 0), true);
ndhi = nd_mul2k(nd, ndhi, ((29) >>> 0), ((DV.getUint32((t + 0), true) & ((0x1fffffff) >>> 0)) >>> 0), sf);
case 78:
case 79:
if (!$T((+(e$2 >= 0)))) { $L = 80; continue $d; }
ndhi = nd_mul2k(nd, ndhi, ((e$2) >>> 0), ((0) >>> 0), sf);
ndlo = ((0) >>> 0);
{ $L = 81; continue $d; }
case 80:
ndlo = nd_div2k(nd, ndhi, (((-e$2)) >>> 0), sf);
if (!$T((+($T(ndhi) && $T(+!$T(DV.getUint32((nd + (ndhi) * 4), true))))))) { $L = 82; continue $d; }
ndhi--;
case 82:
case 83:
case 81:
if (!$T(((((sf & ((0x0010) >>> 0)) >>> 0))))) { $L = 84; continue $d; }
eprefix$2 = 43;
nde = (-1);
if (!$T((+($T(ndlo) && $T(+!$T(DV.getUint32((nd + (ndhi) * 4), true))))))) { $L = 86; continue $d; }
ndhi = ((64) >>> 0);
case 88:
case 89:
if ($T((+!$T(DV.getUint32((nd + (--ndhi) * 4), true))))) { $L = 88; continue $d; }
case 90:
nde = (nde - (64 * 9));
case 86:
case 87:
hilen = ndigits_dec(DV.getUint32((nd + (ndhi) * 4), true));
nde = ((((((nde) >>> 0) + (((Math.imul(ndhi, ((9) >>> 0)) >>> 0) + hilen) >>> 0)) >>> 0)) | 0);
if (!$T((ndebias))) { $L = 91; continue $d; }
eidx = (((e$2 + 70) + (+(29 < 29))) + (+($T(+(DV.getUint32((t + 0), true) >= 0xfffffffe)) && $T(+!$T((((((~DV.getUint32((t + 4), true)) >>> 0) << 12) >>> 0)))))));
m_e = (1 + (eidx * 2));
(void (0));
DV.setUint32((nd + (33) * 4), DV.getUint32((nd + (ndhi) * 4), true), true);
DV.setUint32((nd + (32) * 4), DV.getUint32((nd + ((((((ndhi - ((1) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0)) * 4), true), true);
DV.setUint32((nd + (31) * 4), DV.getUint32((nd + ((((((ndhi - ((2) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0)) * 4), true), true);
nd_add_m10e(nd, ndhi, (((H[m_e] << 24 >> 24)) & 255), (H[m_e + 1] << 24 >> 24));
if (!$T((+!$T(+!$T((+!$T(nd_similar(nd, ndhi, (nd + (33) * 4), hilen, ((prec + ((1) >>> 0)) >>> 0))))))))) { $L = 93; continue $d; }
{ $L = 1; continue $d; }
case 93:
case 94:
case 91:
case 92:
if (!$T((+((((((prec - ((nde) >>> 0)) >>> 0))) | 0) < (((0x3f & (-((ndlo) | 0)))) * 9))))) { $L = 95; continue $d; }
ndhi = nd_round(nd, ndlo, ndhi, ((((((((nde) >>> 0) - prec) >>> 0) - ((1) >>> 0)) >>> 0)) | 0));
nde = (nde + (+(hilen !== ndigits_dec(DV.getUint32((nd + (ndhi) * 4), true)))));
case 95:
case 96:
nde = (nde + ndebias);
if (!$T(((((sf & ((0x0020) >>> 0)) >>> 0))))) { $L = 97; continue $d; }
if (!$T((+($T(+(((prec) | 0) >= nde)) && $T(+(nde >= (-4))))))) { $L = 99; continue $d; }
if (!$T((+(nde < 0)))) { $L = 101; continue $d; }
ndhi = ((0) >>> 0);
case 101:
case 102:
prec = ((prec - ((nde) >>> 0)) >>> 0);
{ $L = 3; continue $d; }
{ $L = 100; continue $d; }
case 99:
if (!$T((+($T(+($T(+!$T((((sf & ((0x1000) >>> 0)) >>> 0)))) && $T(prec))) && $T(+(width > ((5) >>> 0))))))) { $L = 103; continue $d; }
maxprec = ((((hilen - ((1) >>> 0)) >>> 0) + (Math.imul(((((((ndhi - ndlo) >>> 0)) & ((0x3f) >>> 0)) >>> 0)), ((9) >>> 0)) >>> 0)) >>> 0);
if (!$T((+(prec >= maxprec)))) { $L = 105; continue $d; }
prec = maxprec;
{ $L = 106; continue $d; }
case 105:
ndlo = (((((ndhi - (((Math.trunc((((((((prec - hilen) >>> 0))) | 0) + 9)) / 9))) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0);
case 106:
i = ((((((prec - hilen) >>> 0) - ((Math.imul(((((((ndhi - ndlo) >>> 0)) & ((0x3f) >>> 0)) >>> 0)), ((9) >>> 0)) >>> 0))) >>> 0) + ((10) >>> 0)) >>> 0);
lj_strfmt_wuint9(tail, DV.getUint32((nd + (ndlo) * 4), true));
case 107:
if (!$T((+($T(prec) && $T(+((H[tail + --i] << 24 >> 24) === 48)))))) { $L = 108; continue $d; }
prec--;
if (!$T((+!$T(i)))) { $L = 109; continue $d; }
if (!$T((+(ndlo === ndhi)))) { $L = 111; continue $d; }
prec = ((0) >>> 0);
{ $L = 108; continue $d; }
case 111:
case 112:
ndlo = (((((ndlo + ((1) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0);
lj_strfmt_wuint9(tail, DV.getUint32((nd + (ndlo) * 4), true));
i = ((9) >>> 0);
case 109:
case 110:
{ $L = 107; continue $d; }
case 108:
case 103:
case 104:
case 100:
case 97:
case 98:
if (!$T((+(nde < 0)))) { $L = 113; continue $d; }
eprefix$2 = 45;
nde = (-nde);
case 113:
case 114:
len = ((((((((((((3) >>> 0) + prec) >>> 0) + (((+(prefix$3 !== 0))) >>> 0)) >>> 0) + ndigits_dec(((nde) >>> 0))) >>> 0) + (((+(nde < 10))) >>> 0)) >>> 0) + (((+((((prec | (((sf & ((0x1000) >>> 0)) >>> 0))) >>> 0)) !== ((0) >>> 0)))) >>> 0)) >>> 0);
if (!$T((+!$T(p)))) { $L = 115; continue $d; }
p = $crefuse("lj_buf_more: the adapter always passes a buffer");
case 115:
case 116:
if (!$T((+!$T((((sf & ((((0x0100 | 0x0400))) >>> 0)) >>> 0)))))) { $L = 117; continue $d; }
case 119:
if (!$T((+(width-- > len)))) { $L = 120; continue $d; }
H[p++] = 32;
{ $L = 119; continue $d; }
case 120:
case 117:
case 118:
if (!$T((prefix$3))) { $L = 121; continue $d; }
H[p++] = prefix$3;
case 121:
case 122:
if (!$T((+((((sf & ((((0x0100 | 0x0400))) >>> 0)) >>> 0)) === ((0x0400) >>> 0))))) { $L = 123; continue $d; }
case 125:
if (!$T((+(width-- > len)))) { $L = 126; continue $d; }
H[p++] = 48;
{ $L = 125; continue $d; }
case 126:
case 123:
case 124:
q$2 = lj_strfmt_wint((p + 1), ((DV.getUint32((nd + (ndhi) * 4), true)) | 0));
H[p + 0] = (H[p + 1] << 24 >> 24);
if (!$T(((((prec | (((sf & ((0x1000) >>> 0)) >>> 0))) >>> 0))))) { $L = 127; continue $d; }
H[p + 1] = 46;
p = (p + 2);
prec = ((prec - (((q$2 - p)) >>> 0)) >>> 0);
p = q$2;
i = ndhi;
case 129:
if (!$T(+($T(+(((prec) | 0) > 0)) && $T(+(i !== ndlo))))) { $L = 131; continue $d; }
i = (((((i - ((1) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0);
p = lj_strfmt_wuint9(p, DV.getUint32((nd + (i) * 4), true));
case 130:
prec = ((prec - ((9) >>> 0)) >>> 0);
{ $L = 129; continue $d; }
case 131:
if (!$T((+($T((((sf & ((0x0020) >>> 0)) >>> 0))) && $T(+!$T((((sf & ((0x1000) >>> 0)) >>> 0)))))))) { $L = 132; continue $d; }
p = (p + (((prec) | 0) & ((((prec) | 0) >> 31))));
case 134:
if (!$T((+((H[p + (-1)] << 24 >> 24) === 48)))) { $L = 135; continue $d; }
p--;
{ $L = 134; continue $d; }
case 135:
if (!$T((+((H[p + (-1)] << 24 >> 24) === 46)))) { $L = 136; continue $d; }
p--;
case 136:
case 137:
{ $L = 133; continue $d; }
case 132:
case 138:
if (!$T((+(((prec) | 0) > 0)))) { $L = 139; continue $d; }
H[p++] = 48;
prec--;
{ $L = 138; continue $d; }
case 139:
p = (p + ((prec) | 0));
case 133:
{ $L = 128; continue $d; }
case 127:
p++;
case 128:
H[p++] = ($T((((sf & ((0x2000) >>> 0)) >>> 0))) ? 69 : 101);
H[p++] = eprefix$2;
if (!$T((+(nde < 10)))) { $L = 140; continue $d; }
H[p++] = 48;
case 140:
case 141:
p = lj_strfmt_wint(p, nde);
{ $L = 85; continue $d; }
case 84:
if (!$T((+(prec < (Math.imul((((0x3f & (-((ndlo) | 0)))) >>> 0), ((9) >>> 0)) >>> 0))))) { $L = 142; continue $d; }
ndhi = nd_round(nd, ndlo, ndhi, ((((((((0) >>> 0) - prec) >>> 0) - ((1) >>> 0)) >>> 0)) | 0));
case 142:
case 143:
case 3:
if (!$T((+($T(+($T(+($T((((sf & ((0x0010) >>> 0)) >>> 0))) && $T(+!$T((((sf & ((0x1000) >>> 0)) >>> 0)))))) && $T(prec))) && $T(width))))) { $L = 144; continue $d; }
if (!$T((ndlo))) { $L = 146; continue $d; }
maxprec$2 = (Math.imul((((((64) >>> 0) - ndlo) >>> 0)), ((9) >>> 0)) >>> 0);
if (!$T((+(prec >= maxprec$2)))) { $L = 148; continue $d; }
prec = maxprec$2;
{ $L = 149; continue $d; }
case 148:
ndlo = ((((64) >>> 0) - Math.trunc((((prec + ((8) >>> 0)) >>> 0)) / ((9) >>> 0))) >>> 0);
case 149:
i = ((prec - ((Math.imul((((((63) >>> 0) - ndlo) >>> 0)), ((9) >>> 0)) >>> 0))) >>> 0);
lj_strfmt_wuint9(tail$2, DV.getUint32((nd + (ndlo) * 4), true));
case 150:
if (!$T((+($T(prec) && $T(+((H[tail$2 + --i] << 24 >> 24) === 48)))))) { $L = 151; continue $d; }
prec--;
if (!$T((+!$T(i)))) { $L = 152; continue $d; }
if (!$T((+(ndlo === ((63) >>> 0))))) { $L = 154; continue $d; }
prec = ((0) >>> 0);
{ $L = 151; continue $d; }
case 154:
case 155:
lj_strfmt_wuint9(tail$2, DV.getUint32((nd + (++ndlo) * 4), true));
i = ((9) >>> 0);
case 152:
case 153:
{ $L = 150; continue $d; }
case 151:
{ $L = 147; continue $d; }
case 146:
prec = ((0) >>> 0);
case 147:
case 144:
case 145:
len = (((((((((Math.imul(ndhi, ((9) >>> 0)) >>> 0) + ndigits_dec(DV.getUint32((nd + (ndhi) * 4), true))) >>> 0) + prec) >>> 0) + (((+(prefix$3 !== 0))) >>> 0)) >>> 0) + (((+((((prec | (((sf & ((0x1000) >>> 0)) >>> 0))) >>> 0)) !== ((0) >>> 0)))) >>> 0)) >>> 0);
if (!$T((+!$T(p)))) { $L = 156; continue $d; }
p = $crefuse("lj_buf_more: the adapter always passes a buffer");
case 156:
case 157:
if (!$T((+!$T((((sf & ((((0x0100 | 0x0400))) >>> 0)) >>> 0)))))) { $L = 158; continue $d; }
case 160:
if (!$T((+(width-- > len)))) { $L = 161; continue $d; }
H[p++] = 32;
{ $L = 160; continue $d; }
case 161:
case 158:
case 159:
if (!$T((prefix$3))) { $L = 162; continue $d; }
H[p++] = prefix$3;
case 162:
case 163:
if (!$T((+((((sf & ((((0x0100 | 0x0400))) >>> 0)) >>> 0)) === ((0x0400) >>> 0))))) { $L = 164; continue $d; }
case 166:
if (!$T((+(width-- > len)))) { $L = 167; continue $d; }
H[p++] = 48;
{ $L = 166; continue $d; }
case 167:
case 164:
case 165:
p = lj_strfmt_wint(p, ((DV.getUint32((nd + (ndhi) * 4), true)) | 0));
i = ndhi;
case 168:
if (!$T((i))) { $L = 169; continue $d; }
p = lj_strfmt_wuint9(p, DV.getUint32((nd + (--i) * 4), true));
{ $L = 168; continue $d; }
case 169:
if (!$T(((((prec | (((sf & ((0x1000) >>> 0)) >>> 0))) >>> 0))))) { $L = 170; continue $d; }
H[p++] = 46;
case 172:
if (!$T((+($T(+(((prec) | 0) > 0)) && $T(+(i !== ndlo)))))) { $L = 173; continue $d; }
i = (((((i - ((1) >>> 0)) >>> 0)) & ((0x3f) >>> 0)) >>> 0);
p = lj_strfmt_wuint9(p, DV.getUint32((nd + (i) * 4), true));
prec = ((prec - ((9) >>> 0)) >>> 0);
{ $L = 172; continue $d; }
case 173:
if (!$T((+($T((((sf & ((0x0010) >>> 0)) >>> 0))) && $T(+!$T((((sf & ((0x1000) >>> 0)) >>> 0)))))))) { $L = 174; continue $d; }
p = (p + (((prec) | 0) & ((((prec) | 0) >> 31))));
case 176:
if (!$T((+((H[p + (-1)] << 24 >> 24) === 48)))) { $L = 177; continue $d; }
p--;
{ $L = 176; continue $d; }
case 177:
if (!$T((+((H[p + (-1)] << 24 >> 24) === 46)))) { $L = 178; continue $d; }
p--;
case 178:
case 179:
{ $L = 175; continue $d; }
case 174:
case 180:
if (!$T((+(((prec) | 0) > 0)))) { $L = 181; continue $d; }
H[p++] = 48;
prec--;
{ $L = 180; continue $d; }
case 181:
p = (p + ((prec) | 0));
case 175:
case 170:
case 171:
case 85:
case 25:
case 5:
if (!$T(((((sf & ((0x0100) >>> 0)) >>> 0))))) { $L = 182; continue $d; }
case 184:
if (!$T((+(width-- > len)))) { $L = 185; continue $d; }
H[p++] = 32;
{ $L = 184; continue $d; }
case 185:
case 182:
case 183:
return p;
return;
}
} finally { SP = $sp; }
}

function cjs_numstr(n, p) {
return (((lj_strfmt_wfnum((null), ((((((5 | 0x0030)) | ((((14 + 1)) << 24))))) >>> 0), n, p) - p)) >>> 0);
}

/** a number -> its Lua string (tostring / concatenation): LuaJIT's %.14g, into a 32-byte heap buffer
 *  (STRFMT_MAXBUF_NUM, as lj_strfmt_num gives it), read back as a JS string of bytes */
function numstr(x) {
  const $sp = SP;
  try {
    const p = $alloca(32);
    const len = cjs_numstr(x, p);
    let s = '';
    for (let i = 0; i < len; i++) s += String.fromCharCode(H[p + i]);
    return s;
  } finally { SP = $sp; }
}
module.exports = { setheap: h => { H = h; }, image, IMAGE_END, STRUCTS: {"*__locale_t":[],"CCallback":{"fpr":8,"gpr":8},"CTState":{"hash":128},"CType":[],"FILE":[],"FPRCBArg":{"f":2},"FormatState":[],"FrameLink":[],"GCRef":[],"GCState":[],"GCcdata":[],"GCcdataVar":[],"GCfunc":[],"GCfuncC":{"upvalue":1},"GCfuncL":{"uvptr":1},"GChead":[],"GCobj":[],"GCproto":[],"GCstr":[],"GCtab":[],"GCudata":[],"GCupval":[],"MRef":[],"Node":[],"PRNGState":{"u":4},"SBuf":[],"SBufExt":[],"StrInternState":[],"TValue":[],"Unaligned16":{"b":2},"Unaligned32":{"b":4},"__FILE":[],"__atomic_wide_counter":[],"__fpos64_t":[],"__fpos_t":[],"__fsid_t":{"__val":2},"__mbstate_t":[],"__once_flag":[],"__pthread_list_t":[],"__pthread_slist_t":[],"__sigset_t":[],"cookie_io_functions_t":[],"div_t":[],"fd_set":[],"global_State":[],"ldiv_t":[],"lldiv_t":[],"lua_Debug":[],"lua_State":[],"max_align_t":[],"pthread_attr_t":[],"pthread_barrier_t":{"__size":32},"pthread_barrierattr_t":{"__size":4},"pthread_cond_t":{"__size":48},"pthread_condattr_t":{"__size":4},"pthread_mutex_t":{"__size":40},"pthread_mutexattr_t":{"__size":4},"pthread_rwlock_t":{"__size":56},"pthread_rwlockattr_t":{"__size":8}}, ndigits_dec, lj_strfmt_wint, nd_mul2k, nd_div2k, nd_add_m10e, lj_strfmt_wuint9, nd_similar, nd_round, lj_strfmt_wfnum, cjs_numstr, numstr };
