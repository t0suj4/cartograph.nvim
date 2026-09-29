'use strict';
// THE HOST FLOATING-POINT PRIMITIVES a transliterated libm needs (CART-1211) — the hardware's semantics, which have no C
// source to transliterate, so they are written here once and checked against the C library's own (tests/luajs_spec.lua):
//   $fma(a, b, c)   a*b + c rounded ONCE (the x86 FMA instruction: glibc's pow runs its FMA build on this CPU —
//                   measured, 5,998,564 of 5,998,564 inputs bit-identical to AOR pow compiled with -mfma, 2,482 of
//                   them differing from the non-FMA build)
//   $asu64(d)       a double's bits as a BigInt;   $asd(u)   a BigInt's low 64 bits as a double
const F = new Float64Array(1);
const U = new BigUint64Array(F.buffer);
const $asu64 = d => { F[0] = d; return U[0]; };
const $asd = u => { U[0] = BigInt.asUintN(64, u); return F[0]; };

// a finite nonzero double as m * 2^e, m a BigInt integer (signed), e an integer
function decompose(d) {
  const bits = $asu64(d);
  const neg = bits >> 63n;
  const ex = Number((bits >> 52n) & 0x7ffn);
  let m = bits & 0xfffffffffffffn;
  let e;
  if (ex === 0) e = -1074; // subnormal
  else { m |= 1n << 52n; e = ex - 1075; }
  return [neg ? -m : m, e];
}
function bitlen(n) { return n === 0n ? 0 : n.toString(2).length; }
// an integer x < 2^54 times 2^n, exactly (the caller guarantees the result is representable or overflows)
function ldexp(x, n) {
  let r = x;
  while (n > 1000) { r *= 2 ** 1000; n -= 1000; }
  while (n < -1000) { r *= 2 ** -1000; n += 1000; }
  return r * 2 ** n;
}

/** exact a*b + c, rounded to nearest-even once */
function $fma(a, b, c) {
  // non-finite operands and zero products: IEEE's own a*b + c is already exact-then-rounded (a zero product is exact,
  // and a non-finite result has no rounding to get wrong)
  if (!Number.isFinite(a) || !Number.isFinite(b) || !Number.isFinite(c) || a === 0 || b === 0) return a * b + c;
  if (c === 0) return a * b; // one rounding of the exact product; the sign of a zero c cannot matter for a nonzero product
  const [ma, ea] = decompose(a), [mb, eb] = decompose(b), [mc, ec] = decompose(c);
  const ep = ea + eb;
  const E = Math.min(ep, ec);
  const S = ma * mb * (1n << BigInt(ep - E)) + mc * (1n << BigInt(ec - E));
  if (S === 0n) return 0; // an exact zero sum of nonzero terms is +0 in round-to-nearest
  return round(S, E);
}

/** the EXACT value S * 2^E (S a BigInt integer) rounded to nearest-even ONCE — the one rounding both $fma and $ldexp
 *  need (53 significant bits, fewer where the result is subnormal: its grid is 2^-1074) */
function round(S, E) {
  const neg = S < 0n;
  let M = neg ? -S : S;
  const L = bitlen(M);
  let shift = Math.max(L - 53, -1074 - E);
  let e = E;
  if (shift > 0) {
    const sh = BigInt(shift);
    let q = M >> sh;
    const rem = M - (q << sh);
    const half = 1n << (sh - 1n);
    if (rem > half || (rem === half && (q & 1n) === 1n)) q += 1n;
    M = q;
    e += shift;
  }
  // M < 2^54 now: Number(M) is exact; the scaling by 2^e is exact or overflows to infinity, as the rounding says
  const r = ldexp(Number(M), e);
  return neg ? -r : r;
}

/** C's ldexp(x, n): x * 2^n rounded ONCE (a subnormal result rounds at 2^-1074 — scaling in steps would round twice) */
function $ldexp(x, n) {
  if (!Number.isFinite(x) || x === 0) return x;
  const [m, e] = decompose(x);
  return round(m, e + n);
}

/** __builtin_clzll(x): leading zero bits of a 64-bit value (undefined for 0 in C; 64 here) */
const $clz64 = x => { x = BigInt.asUintN(64, x); return x === 0n ? 64 : 64 - x.toString(2).length; };

/** lj_vm_num2int_check(x) — VM ASSEMBLY (vm_x64.dasc ->vm_num2int_check), read, not transliterated: cvttsd2si eax,
 *  back with cvtsi2sd, ucomisd; equal and ordered -> rax = the 32-bit result ZERO-extended (so >= 0 even for a negative
 *  int), else 0x8000000080000000 (negative). -0 converts to 0 and compares equal (the caller checks -0 itself). */
const $num2int_check = x => {
  const t = Math.trunc(x);
  if (Number.isNaN(x) || t < -2147483648 || t > 2147483647 || t !== x) return BigInt.asIntN(64, 0x8000000080000000n);
  return BigInt(t >>> 0);
};

module.exports = { $fma, $ldexp, $clz64, $num2int_check, $asu64, $asd };
