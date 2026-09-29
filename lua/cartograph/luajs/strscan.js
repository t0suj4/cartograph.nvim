// GENERATED — do not edit. LuaJIT's string -> number scanner, TRANSLITERATED from C by cartograph.cjs (exact
// heap mode, CART-1211 leaf 3):
//   source   src/lj_strscan.c (lj_strscan_scan …) + src/lj_char.c (lj_char_bits), LuaJIT fbb36bb6 — the ORACLE's revision
//   root     cjs_tonum = lj_strscan_num's body with its GCstr accessor replaced by (p, len)
//   flags    gcc -E -P -D__attribute__(x)= -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -U_FORTIFY_SOURCE -DLUAJIT_UNWIND_EXTERNAL (the build's own, from its make)
//   layout   TValue 8 bytes: u64@0:u64 n@0:f64 it64@0:i64 i@0:i32 it@4:u32 ftsz@0:i64 u32.lo@0:u32 u32.hi@4:u32 (the compiler's: offsetof/sizeof/classify)
//   command  nvim --headless -u NONE -l tools/cjs.lua strscan <BUILT luajit src dir> lua/cartograph/luajs/strscan.js
// LuaJIT: Copyright (C) 2005-2026 Mike Pall. MIT license (its COPYRIGHT file).
'use strict';
// C truthiness: nonzero and non-NULL (offset 0 is never a valid pointer)
const $T = x => x !== 0 && x !== null && x !== undefined;
const $crefuse = what => { throw new Error("[cjs] no faithful form: " + what); };
let H = null; // the byte heap, installed by the caller (setheap)
// the heap image: every static array the code reads, at its fixed offset (offset 0 reserved)
const IMAGE = [
  // lj_char_bits[257] at 1
  [1, [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 3, 3, 3, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 152, 152, 152, 152, 152, 152, 152, 152, 152, 152, 4, 4, 4, 4, 4, 4, 4, 176, 176, 176, 176, 176, 176, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 4, 4, 4, 4, 132, 4, 208, 208, 208, 208, 208, 208, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 4, 4, 4, 4, 1, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128]],
];
const IMAGE_END = 258;
function image() { const h = new Uint8Array(IMAGE_END); for (const [at, vals] of IMAGE) h.set(vals, at); return h; }
const $STACK = 65536;
H = new Uint8Array(IMAGE_END + $STACK); H.set(image());
const DV = new DataView(H.buffer);
let SP = H.length;
const $alloca = n => { SP = (SP - n) & ~7; if (SP < IMAGE_END) throw new Error("[cjs] heap stack overflow"); return SP; };
const { $ldexp, $clz64, $num2int_check } = require('./$fpu.js');
function strscan_oct(p, o, fmt, neg, dig) {
let x = BigInt.asUintN(64, BigInt(0));
if ($T((+($T(+(dig > ((22) >>> 0))) || $T((+($T(+(dig === ((22) >>> 0))) && $T(+(H[p] > 49))))))))) return 0;
while ($T((+(dig-- > ((0) >>> 0))))) {
if ($T((+!$T((+($T(+(H[p] >= 48)) && $T(+(H[p] <= 55)))))))) return 0;
x = BigInt.asUintN(64, (BigInt.asUintN(64, x << BigInt(3))) + BigInt.asUintN(64, BigInt(((H[p++] & 7)))));
}
$sw1: switch ((fmt)) {
case 3:
if ($T((+(x >= BigInt.asUintN(64, BigInt(((0x80000000 + ((neg) >>> 0)) >>> 0))))))) fmt = 4;
case 4:
if (((((x >> BigInt(32)))) !== 0n)) return 0;
DV.setInt32((o + 0), ($T(neg) ? (((((((~Number(BigInt.asUintN(32, x))) >>> 0) + 1) >>> 0))) | 0) : Number(BigInt.asIntN(32, x))), true);
break;
default:

case 5:

case 6:
DV.setBigUint64((o + 0), ($T(neg) ? BigInt.asUintN(64, BigInt.asUintN(64, ~x) + BigInt.asUintN(64, BigInt(1))) : x), true);
break;
}
return fmt;
}

function strscan_double(x, o, ex2, neg) {
let n;
if ($T((+!$T(+!$T((+($T(+(ex2 <= (-1075))) && $T(+(x !== BigInt.asUintN(64, BigInt(0))))))))))) {
let b = (($clz64(x) ^ 63));
if ($T((+($T(+((b + ex2) <= (-1023))) && $T(+((b + ex2) >= (-1075))))))) {
let rb = BigInt.asUintN(64, BigInt.asUintN(64, BigInt(1)) << BigInt((((-1075) - ex2))));
if ($T((+(((BigInt.asUintN(64, x & rb)) !== 0n) && (((BigInt.asUintN(64, x & (BigInt.asUintN(64, BigInt.asUintN(64, BigInt.asUintN(64, rb + rb) + rb) - BigInt.asUintN(64, BigInt(1))))))) !== 0n))))) x = BigInt.asUintN(64, x + BigInt.asUintN(64, rb + rb));
x = (BigInt.asUintN(64, x & BigInt.asUintN(64, ~(BigInt.asUintN(64, BigInt.asUintN(64, rb + rb) - BigInt.asUintN(64, BigInt(1)))))));
}
}
(void (0));
n = Number(BigInt.asIntN(64, x));
if ($T((neg))) n = (-n);
if ($T((ex2))) n = $ldexp(n, ex2);
DV.setFloat64((o + 0), n, true);
}

function strscan_hex(p, o, fmt, opt, ex2, neg, dig) {
let x = BigInt.asUintN(64, BigInt(0));
let i;
for (i = ($T(+(dig > ((16) >>> 0))) ? ((16) >>> 0) : dig); $T(i); (i--, p++)) {
let d = (((($T(+(H[p] !== 46)) ? H[p] : H[++p]))) >>> 0);
if ($T((+(d > ((57) >>> 0))))) d = ((d + ((9) >>> 0)) >>> 0);
x = BigInt.asUintN(64, (BigInt.asUintN(64, x << BigInt(4))) + BigInt.asUintN(64, BigInt((((d & ((15) >>> 0)) >>> 0)))));
}
for (i = ((16) >>> 0); $T(+(i < dig)); (i++, p++)) (x = BigInt.asUintN(64, x | BigInt.asUintN(64, BigInt((+((($T(+(H[p] !== 46)) ? H[p] : H[++p])) !== 48))))), ex2 = (ex2 + 4));
$sw2: switch ((fmt)) {
case 3:
if ($T((+($T(+($T(+!$T((((opt & ((0x02) >>> 0)) >>> 0)))) && $T(+(x < BigInt.asUintN(64, BigInt(((0x80000000 + ((neg) >>> 0)) >>> 0))))))) && $T(+!$T((+($T(+(x === BigInt.asUintN(64, BigInt(0)))) && $T(neg))))))))) {
DV.setInt32((o + 0), ($T(neg) ? Number(BigInt.asIntN(32, (BigInt.asUintN(64, BigInt.asUintN(64, ~x) + BigInt.asUintN(64, BigInt(1)))))) : Number(BigInt.asIntN(32, x))), true);
return 3;
}
if ($T((+!$T((((opt & ((0x10) >>> 0)) >>> 0)))))) {
fmt = 1;
break;
}
case 4:
if ($T((+(dig > ((8) >>> 0))))) return 0;
DV.setInt32((o + 0), ($T(neg) ? Number(BigInt.asIntN(32, (BigInt.asUintN(64, BigInt.asUintN(64, ~x) + BigInt.asUintN(64, BigInt(1)))))) : Number(BigInt.asIntN(32, x))), true);
return 4;
case 5:

case 6:
if ($T((+(dig > ((16) >>> 0))))) return 0;
DV.setBigUint64((o + 0), ($T(neg) ? BigInt.asUintN(64, BigInt.asUintN(64, ~x) + BigInt.asUintN(64, BigInt(1))) : x), true);
return fmt;
default:
break;
}
if ((((BigInt.asUintN(64, x & (BigInt.asUintN(64, (BigInt.asUintN(64, BigInt.asUintN(64, BigInt(0xc0000000)) << BigInt(32))) + BigInt.asUintN(64, BigInt(0x0000000))))))) !== 0n)) {
x = BigInt.asUintN(64, ((x >> BigInt(2))) | (BigInt.asUintN(64, x & BigInt.asUintN(64, BigInt(3)))));
ex2 = (ex2 + 2);
}
strscan_double(x, o, ex2, neg);
return fmt;
}

function strscan_bin(p, o, fmt, opt, ex2, neg, dig) {
let x = BigInt.asUintN(64, BigInt(0));
let i;
if ($T((+($T(ex2) || $T(+(dig > ((64) >>> 0))))))) return 0;
for (i = dig; $T(i); (i--, p++)) {
if ($T((+(((H[p] & (~1))) !== 48)))) return 0;
x = BigInt.asUintN(64, (BigInt.asUintN(64, x << BigInt(1))) | BigInt.asUintN(64, BigInt(((H[p] & 1)))));
}
$sw3: switch ((fmt)) {
case 3:
if ($T((+($T(+!$T((((opt & ((0x02) >>> 0)) >>> 0)))) && $T(+(x < BigInt.asUintN(64, BigInt(((0x80000000 + ((neg) >>> 0)) >>> 0))))))))) {
DV.setInt32((o + 0), ($T(neg) ? Number(BigInt.asIntN(32, (BigInt.asUintN(64, BigInt.asUintN(64, ~x) + BigInt.asUintN(64, BigInt(1)))))) : Number(BigInt.asIntN(32, x))), true);
return 3;
}
if ($T((+!$T((((opt & ((0x10) >>> 0)) >>> 0)))))) {
fmt = 1;
break;
}
case 4:
if ($T((+(dig > ((32) >>> 0))))) return 0;
DV.setInt32((o + 0), ($T(neg) ? Number(BigInt.asIntN(32, (BigInt.asUintN(64, BigInt.asUintN(64, ~x) + BigInt.asUintN(64, BigInt(1)))))) : Number(BigInt.asIntN(32, x))), true);
return 4;
case 5:

case 6:
DV.setBigUint64((o + 0), ($T(neg) ? BigInt.asUintN(64, BigInt.asUintN(64, ~x) + BigInt.asUintN(64, BigInt(1))) : x), true);
return fmt;
default:
break;
}
if ((((BigInt.asUintN(64, x & (BigInt.asUintN(64, (BigInt.asUintN(64, BigInt.asUintN(64, BigInt(0xc0000000)) << BigInt(32))) + BigInt.asUintN(64, BigInt(0x0000000))))))) !== 0n)) {
x = BigInt.asUintN(64, ((x >> BigInt(2))) | (BigInt.asUintN(64, x & BigInt.asUintN(64, BigInt(3)))));
ex2 = (ex2 + 2);
}
strscan_double(x, o, ex2, neg);
return fmt;
}

function strscan_dec(p, o, fmt, opt, ex10, neg, dig) {
const $sp = SP;
try {
let xi = $alloca((Math.trunc((Math.trunc(1024 / 2))) * 1)), xip = xi;
if ($T((dig))) {
let i = dig;
if ($T((+(i > ((800) >>> 0))))) {
ex10 = (ex10 + (((((i - ((800) >>> 0)) >>> 0))) | 0));
i = ((800) >>> 0);
}
if ($T((((((((((ex10) >>> 0) ^ i) >>> 0)) & ((1) >>> 0)) >>> 0))))) (H[xip++] = (((($T(+(H[p] !== 46)) ? H[p] : H[++p])) & 15)), (i--, p++));
for (; $T(+(i > ((1) >>> 0))); i = ((i - ((2) >>> 0)) >>> 0)) {
let d = (((10 * (((($T(+(H[p] !== 46)) ? H[p] : H[++p])) & 15)))) >>> 0);
p++;
H[xip++] = ((((d + (((((($T(+(H[p] !== 46)) ? H[p] : H[++p])) & 15))) >>> 0)) >>> 0)) | 0);
p++;
}
if ($T((i))) (H[xip++] = (10 * (((($T(+(H[p] !== 46)) ? H[p] : H[++p])) & 15))), (ex10--, (dig++, p++)));
if ($T((+(dig > ((800) >>> 0))))) {
do {
if ($T((+((($T(+(H[p] !== 46)) ? H[p] : H[++p])) !== 48)))) {
H[xip + (-1)] = (H[xip + (-1)] | 1);
break;
}
p++;
} while ($T((+(--dig > ((800) >>> 0)))));
dig = ((800) >>> 0);
} else {
while ($T((+($T(+(ex10 > 0)) && $T(+(dig <= ((18) >>> 0))))))) (H[xip++] = 0, (ex10 = (ex10 - 2), dig = ((dig + ((2) >>> 0)) >>> 0)));
}
} else {
ex10 = 0;
H[xi + 0] = 0;
}
if ($T((+($T(+(dig <= ((20) >>> 0))) && $T(+(ex10 === 0)))))) {
let xis;
let x = BigInt.asUintN(64, BigInt(H[xi + 0]));
let n;
for (xis = (xi + 1); $T(+(xis < xip)); xis++) x = BigInt.asUintN(64, BigInt.asUintN(64, x * BigInt.asUintN(64, BigInt(100))) + BigInt.asUintN(64, BigInt(H[xis])));
if ($T((+!$T((+($T(+(dig === ((20) >>> 0))) && $T((+($T(+(H[xi + 0] > 18)) || $T(+(BigInt.asIntN(64, x) >= BigInt(0)))))))))))) {
{ let $go4 = false;
$sw4: switch ((fmt)) {
case 3:
if ($T((+($T(+!$T((((opt & ((0x02) >>> 0)) >>> 0)))) && $T(+(x < BigInt.asUintN(64, BigInt(((0x80000000 + ((neg) >>> 0)) >>> 0))))))))) {
DV.setInt32((o + 0), ($T(neg) ? Number(BigInt.asIntN(32, (BigInt.asUintN(64, BigInt.asUintN(64, ~x) + BigInt.asUintN(64, BigInt(1)))))) : Number(BigInt.asIntN(32, x))), true);
return 3;
}
if ($T((+!$T((((opt & ((0x10) >>> 0)) >>> 0)))))) {
fmt = 1;
{ $go4 = true; break $sw4; }
}
case 4:
if ($T((+(((x >> BigInt(32))) !== BigInt.asUintN(64, BigInt(0)))))) return 0;
DV.setInt32((o + 0), ($T(neg) ? Number(BigInt.asIntN(32, (BigInt.asUintN(64, BigInt.asUintN(64, ~x) + BigInt.asUintN(64, BigInt(1)))))) : Number(BigInt.asIntN(32, x))), true);
return 4;
case 5:

case 6:
DV.setBigUint64((o + 0), ($T(neg) ? BigInt.asUintN(64, BigInt.asUintN(64, ~x) + BigInt.asUintN(64, BigInt(1))) : x), true);
return fmt;
default:
$go4 = true;
}
if ($go4) $blk4: {
if ($T((+(BigInt.asIntN(64, x) < BigInt(0))))) break $blk4;
n = Number(BigInt.asIntN(64, x));
if ($T((neg))) n = (-n);
DV.setFloat64((o + 0), n, true);
return fmt;
} }
}
}
if ($T((+(fmt === 3)))) {
if ($T(((((opt & ((0x10) >>> 0)) >>> 0))))) return 0;
fmt = 1;
} else if ($T((+(fmt > 3)))) {
return 0;
}
{
let hi = ((0) >>> 0), lo = ((((xip - xi))) >>> 0);
let ex2 = 0, idig = (((lo) | 0) + ((ex10 >> 1)));
(void (0));
if ($T((+(idig > Math.trunc(310 / 2))))) {
if ($T((neg))) (DV.setBigUint64(((o) + 0), (BigInt.asUintN(64, (BigInt.asUintN(64, BigInt.asUintN(64, BigInt(0xfff00000)) << BigInt(32))) + BigInt.asUintN(64, BigInt(0x00000000)))), true)); else (DV.setBigUint64(((o) + 0), (BigInt.asUintN(64, (BigInt.asUintN(64, BigInt.asUintN(64, BigInt(0x7ff00000)) << BigInt(32))) + BigInt.asUintN(64, BigInt(0x00000000)))), true));
return fmt;
} else if ($T((+(idig < Math.trunc((-326) / 2))))) {
DV.setFloat64((o + 0), ($T(neg) ? -0 : 0), true);
return fmt;
}
while ($T((+($T(+(idig < 9)) && $T(+(idig < ((((((((((lo) - (hi)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0))) | 0)))))))) {
let i, cy = ((0) >>> 0);
ex2 = (ex2 - 6);
for (i = (((((((lo) - ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0)); ; i = (((((((i) - ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0))) {
let d = ((((((H[xi + i] << 6))) >>> 0) + cy) >>> 0);
cy = ((((Math.imul(((d >>> 2)), ((5243) >>> 0)) >>> 0)) >>> 17));
d = ((d - (Math.imul(cy, ((100) >>> 0)) >>> 0)) >>> 0);
H[xi + i] = ((d) & 255);
if ($T((+(i === hi)))) break;
if ($T((+($T(+(d === ((0) >>> 0))) && $T(+(i === (((((((lo) - ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0)))))))) lo = i;
}
if ($T((cy))) {
hi = (((((((hi) - ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0));
if ($T((+(H[xi + (((((((lo) - ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0))] === 0)))) lo = (((((((lo) - ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0)); else if ($T((+(hi === lo)))) {
lo = (((((((lo) - ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0));
H[xi + (((((((lo) - ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0))] = (H[xi + (((((((lo) - ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0))] | H[xi + lo]);
}
H[xi + hi] = ((cy) & 255);
idig++;
}
}
while ($T((+(idig > 9)))) {
let i = hi, cy = ((0) >>> 0);
ex2 = (ex2 + 6);
do {
cy = ((cy + ((H[xi + i]) >>> 0)) >>> 0);
H[xi + i] = ((((cy >>> 6))) | 0);
cy = (Math.imul(((100) >>> 0), (((cy & ((0x3f) >>> 0)) >>> 0))) >>> 0);
if ($T((+($T(+(H[xi + i] === 0)) && $T(+(i === hi)))))) (hi = (((((((hi) + ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0)), idig--);
i = (((((((i) + ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0));
} while ($T((+(i !== lo))));
while ($T((cy))) {
if ($T((+(hi === lo)))) {
H[xi + (((((((lo) - ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0))] = (H[xi + (((((((lo) - ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0))] | 1);
break;
}
H[xi + lo] = ((((cy >>> 6))) | 0);
lo = (((((((lo) + ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0));
cy = (Math.imul(((100) >>> 0), (((cy & ((0x3f) >>> 0)) >>> 0))) >>> 0);
}
}
{
let x = BigInt.asUintN(64, BigInt(H[xi + hi]));
let i;
for (i = (((((((hi) + ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0)); $T(+($T(+(--idig > 0)) && $T(+(i !== lo)))); i = (((((((i) + ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0))) x = BigInt.asUintN(64, BigInt.asUintN(64, x * BigInt.asUintN(64, BigInt(100))) + BigInt.asUintN(64, BigInt(H[xi + i])));
if ($T((+(i === lo)))) {
while ($T((+(--idig >= 0)))) x = BigInt.asUintN(64, x * BigInt.asUintN(64, BigInt(100)));
} else {
x = BigInt.asUintN(64, x << BigInt(1));
ex2--;
do {
if ($T((H[xi + i]))) {
x = BigInt.asUintN(64, x | BigInt.asUintN(64, BigInt(1)));
break;
}
i = (((((((i) + ((1) >>> 0)) >>> 0)) & (((((Math.trunc(1024 / 2)) - 1))) >>> 0)) >>> 0));
} while ($T((+(i !== lo))));
}
strscan_double(x, o, ex2, neg);
}
}
return fmt;
} finally { SP = $sp; }
}

function lj_strscan_scan(p, len, o, opt) {
const $sp = SP;
try {
let neg = 0;
let pe = (p + len);
if ($T((+!$T(+!$T((+!$T(((H[((1 + 1)) + ((H[p]))] & 0x08))))))))) {
while ($T((((H[((1 + 1)) + ((H[p]))] & 0x02))))) p++;
if ($T((+($T(+(H[p] === 43)) || $T(+(H[p] === 45)))))) neg = (+(H[p++] === 45));
if ($T((+!$T(+!$T((+(H[p] >= 65))))))) {
let tmp = $alloca(8);
(DV.setBigUint64(((tmp) + 0), (BigInt.asUintN(64, (BigInt.asUintN(64, BigInt.asUintN(64, BigInt(0xfff80000)) << BigInt(32))) + BigInt.asUintN(64, BigInt(0x00000000)))), true));
if ($T((+($T(+($T((+((((H[p + 0]) | 0x20)) === 105))) && $T((+((((H[p + 1]) | 0x20)) === 110))))) && $T((+((((H[p + 2]) | 0x20)) === 102))))))) {
if ($T((neg))) (DV.setBigUint64(((tmp) + 0), (BigInt.asUintN(64, (BigInt.asUintN(64, BigInt.asUintN(64, BigInt(0xfff00000)) << BigInt(32))) + BigInt.asUintN(64, BigInt(0x00000000)))), true)); else (DV.setBigUint64(((tmp) + 0), (BigInt.asUintN(64, (BigInt.asUintN(64, BigInt.asUintN(64, BigInt(0x7ff00000)) << BigInt(32))) + BigInt.asUintN(64, BigInt(0x00000000)))), true));
p = (p + 3);
if ($T((+($T(+($T(+($T(+($T((+((((H[p + 0]) | 0x20)) === 105))) && $T((+((((H[p + 1]) | 0x20)) === 110))))) && $T((+((((H[p + 2]) | 0x20)) === 105))))) && $T((+((((H[p + 3]) | 0x20)) === 116))))) && $T((+((((H[p + 4]) | 0x20)) === 121))))))) p = (p + 5);
} else if ($T((+($T(+($T((+((((H[p + 0]) | 0x20)) === 110))) && $T((+((((H[p + 1]) | 0x20)) === 97))))) && $T((+((((H[p + 2]) | 0x20)) === 110))))))) {
p = (p + 3);
}
while ($T((((H[((1 + 1)) + ((H[p]))] & 0x02))))) p++;
if ($T((+($T(H[p]) || $T(+(p < pe)))))) return 0;
DV.setBigUint64((o + 0), DV.getBigUint64((tmp + 0), true), true);
return 1;
}
}
{
let fmt = 3;
let cmask = 0x08;
let base = ($T(+($T((((opt & ((0x10) >>> 0)) >>> 0))) && $T(+(H[p] === 48)))) ? 0 : 10);
let sp, dp = (null);
let dig = ((0) >>> 0), hasdig = ((0) >>> 0), x = ((0) >>> 0);
let ex = 0;
if ($T((+!$T(+!$T((+(H[p] <= 48))))))) {
if ($T((+(H[p] === 48)))) {
if ($T(((+((((H[p + 1]) | 0x20)) === 120))))) (base = 16, (cmask = 0x10, p = (p + 2))); else if ($T(((+((((H[p + 1]) | 0x20)) === 98))))) (base = 2, (cmask = 0x08, p = (p + 2)));
}
for (; ; p++) {
if ($T((+(H[p] === 48)))) {
hasdig = ((1) >>> 0);
} else if ($T((+(H[p] === 46)))) {
if ($T((dp))) return 0;
dp = p;
} else {
break;
}
}
}
for (sp = p; ; p++) {
if ($T((+!$T(+!$T((((H[((1 + 1)) + (H[p])] & cmask)))))))) {
x = (((Math.imul(x, ((10) >>> 0)) >>> 0) + ((((H[p] & 15))) >>> 0)) >>> 0);
dig++;
} else if ($T((+(H[p] === 46)))) {
if ($T((dp))) return 0;
dp = p;
} else {
break;
}
}
if ($T((+!$T((((hasdig | dig) >>> 0)))))) return 0;
if ($T((dp))) {
if ($T((+(base === 2)))) return 0;
fmt = 1;
if ($T((dig))) {
ex = ((dp - ((p - 1))));
dp = (p - 1);
while ($T((+($T(+(ex < 0)) && $T(+(H[dp--] === 48)))))) (ex++, dig--);
if ($T((+(ex <= (-((1 << 20))))))) return 0;
if ($T((+(base === 16)))) ex = (ex * 4);
}
}
if ($T((+($T(+(base >= 10)) && $T((+((((((H[p]) | 0x20))) >>> 0) === (((($T(+(base === 16)) ? 112 : 101))) >>> 0)))))))) {
let xx;
let negx = 0;
fmt = 1;
p++;
if ($T((+($T(+(H[p] === 43)) || $T(+(H[p] === 45)))))) negx = (+(H[p++] === 45));
if ($T((+!$T(((H[((1 + 1)) + ((H[p]))] & 0x08)))))) return 0;
xx = ((((H[p++] & 15))) >>> 0);
while ($T((((H[((1 + 1)) + ((H[p]))] & 0x08))))) {
xx = (((Math.imul(xx, ((10) >>> 0)) >>> 0) + ((((H[p] & 15))) >>> 0)) >>> 0);
if ($T((+(xx >= ((((1 << 20))) >>> 0))))) return 0;
p++;
}
ex = (ex + ($T(negx) ? (((((((~xx) >>> 0) + 1) >>> 0))) | 0) : ((xx) | 0)));
}
if ($T((H[p]))) {
if ($T(((+((((H[p]) | 0x20)) === 105))))) {
if ($T((+!$T((((opt & ((0x04) >>> 0)) >>> 0)))))) return 0;
p++;
fmt = 2;
} else if ($T((+(fmt === 3)))) {
if ($T(((+((((H[p]) | 0x20)) === 117))))) (p++, fmt = 4);
if ($T(((+((((H[p]) | 0x20)) === 108))))) {
p++;
if ($T(((+((((H[p]) | 0x20)) === 108))))) (p++, fmt = (fmt + (5 - 3))); else if ($T((+!$T((((opt & ((0x10) >>> 0)) >>> 0)))))) return 0; else if ($T((+(8n === BigInt.asUintN(64, BigInt(8)))))) fmt = (fmt + (5 - 3));
}
if ($T((+($T((+((((H[p]) | 0x20)) === 117))) && $T((+($T(+(fmt === 3)) || $T(+(fmt === 5))))))))) (p++, fmt = (fmt + (4 - 3)));
if ($T((+($T((+($T(+(fmt === 4)) && $T(+!$T((((opt & ((0x10) >>> 0)) >>> 0))))))) || $T((+($T(+(fmt >= 5)) && $T(+!$T((((opt & ((0x08) >>> 0)) >>> 0))))))))))) return 0;
}
while ($T((((H[((1 + 1)) + ((H[p]))] & 0x02))))) p++;
if ($T((H[p]))) return 0;
}
if ($T((+(p < pe)))) return 0;
if ($T((+($T(+($T(+(fmt === 3)) && $T(+(base === 10)))) && $T((+($T(+(dig < ((10) >>> 0))) || $T((+($T(+($T(+(dig === ((10) >>> 0))) && $T(+(H[sp] <= 50)))) && $T(+(x < ((0x80000000 + ((neg) >>> 0)) >>> 0))))))))))))) {
if ($T(((((opt & ((0x02) >>> 0)) >>> 0))))) {
DV.setFloat64((o + 0), ($T(neg) ? (-x) : x), true);
return 1;
} else if ($T((+($T(+(x === ((0) >>> 0))) && $T(neg))))) {
DV.setFloat64((o + 0), -0, true);
return 1;
} else {
DV.setInt32((o + 0), ($T(neg) ? (((((((~x) >>> 0) + 1) >>> 0))) | 0) : ((x) | 0)), true);
return 3;
}
}
if ($T((+($T(+(base === 0)) && $T(+!$T((+($T(+(fmt === 1)) || $T(+(fmt === 2)))))))))) return strscan_oct(sp, o, fmt, neg, dig);
if ($T((+(base === 16)))) fmt = strscan_hex(sp, o, fmt, opt, ex, neg, dig); else if ($T((+(base === 2)))) fmt = strscan_bin(sp, o, fmt, opt, ex, neg, dig); else fmt = strscan_dec(sp, o, fmt, opt, ex, neg, dig);
if ($T((+($T(+(fmt === 1)) && $T((((opt & ((0x01) >>> 0)) >>> 0))))))) {
let tmp = [0];
if ($T((+($T(((tmp[0] = $num2int_check(((DV.getFloat64((o + 0), true)))), ($T(+(tmp[0] >= BigInt(0))) ? ((DV.setInt32((o + 0), Number(BigInt.asIntN(32, tmp[0])), true), 1)) : 0)))) && $T(+!$T((+(DV.getBigUint64(((o) + 0), true) === (BigInt.asUintN(64, (BigInt.asUintN(64, BigInt.asUintN(64, BigInt(0x80000000)) << BigInt(32))) + BigInt.asUintN(64, BigInt(0x00000000)))))))))))) return 3;
}
return fmt;
}
} finally { SP = $sp; }
}

function cjs_tonum(p, len, o) {
return +(lj_strscan_scan(p, len, o, ((0x02) >>> 0)) !== 0);
}

/** a Lua string (a JS string of bytes) -> its number, or undefined when LuaJIT reads none: the bytes and a
 *  NUL (the scanner reads its terminator, as a GCstr has one) and an 8-byte TValue on the heap stack */
function tonum(s) {
  const $sp = SP;
  try {
    const p = $alloca(s.length + 1);
    for (let i = 0; i < s.length; i++) H[p + i] = s.charCodeAt(i);
    H[p + s.length] = 0;
    const o = $alloca(8);
    return cjs_tonum(p, s.length, o) ? DV.getFloat64(o + 0, true) : undefined;
  } finally { SP = $sp; }
}
module.exports = { setheap: h => { H = h; }, image, IMAGE_END, STRUCTS: {"*__locale_t":[],"FrameLink":[],"GCRef":[],"GCState":[],"GCcdata":[],"GCcdataVar":[],"GCfunc":[],"GCfuncC":{"upvalue":1},"GCfuncL":{"uvptr":1},"GChead":[],"GCobj":[],"GCproto":[],"GCstr":[],"GCtab":[],"GCudata":[],"GCupval":[],"MRef":[],"Node":[],"PRNGState":{"u":4},"SBuf":[],"StrInternState":[],"TValue":[],"Unaligned16":{"b":2},"Unaligned32":{"b":4},"__atomic_wide_counter":[],"__fsid_t":{"__val":2},"__once_flag":[],"__pthread_list_t":[],"__pthread_slist_t":[],"__sigset_t":[],"div_t":[],"fd_set":[],"global_State":[],"ldiv_t":[],"lldiv_t":[],"lua_Debug":[],"lua_State":[],"max_align_t":[],"pthread_attr_t":[],"pthread_barrier_t":{"__size":32},"pthread_barrierattr_t":{"__size":4},"pthread_cond_t":{"__size":48},"pthread_condattr_t":{"__size":4},"pthread_mutex_t":{"__size":40},"pthread_mutexattr_t":{"__size":4},"pthread_rwlock_t":{"__size":56},"pthread_rwlockattr_t":{"__size":8}}, strscan_oct, strscan_double, strscan_hex, strscan_bin, strscan_dec, lj_strscan_scan, cjs_tonum, tonum };
