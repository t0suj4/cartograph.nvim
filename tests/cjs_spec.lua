-- cartograph.cjs EXACT mode (CART-1211) under a C ORACLE: one C function over C's own arithmetic — uint32 wraparound,
-- uint64 overflow, arithmetic shifts, truncating casts, typed literals, hex floats, the usual conversions, a ternary's
-- common type, compound assignment, an out-parameter box, a struct global with designated and positional initializers
-- — compiled by the host gcc and run, then transliterated and run under node: every result must be identical.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local C = require 'cartograph.cjs'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'c') and vim.fn.executable('gcc') == 1 and vim.fn.executable('node') == 1 end

local SRC = [[
#include <stdint.h>
#include <stdio.h>
struct tab { double k; uint64_t bits[3]; struct { int a, b; } pair[2]; };
static const struct tab T = { .k = 0x1.8p1, .bits = { 0xffffffffffffffff, 1ULL << 63, 42 }, .pair = { {1, 2}, {3, -4} } };
static void out(uint64_t *o, uint64_t v) { *o = v * 3; }
uint64_t f(uint64_t x, uint32_t y, int32_t z, double d)
{
  uint32_t w = y - 7u;
  uint64_t m = x * 0x9E3779B97F4A7C15ull;
  int64_t s = (int64_t)m >> 3;
  int32_t t = (int32_t)m;
  uint64_t u = (uint64_t)d;
  uint32_t big = 0x80000000;
  double h = 0x1p-3 * z + T.k;
  uint64_t r;
  out(&r, x);
  r ^= (uint64_t)w << 32 | (uint32_t)t;
  r += (s < 0 ? 1 : 2) + (m ? 10 : 20) + (uint64_t)(h * 8) + T.bits[(int)(x & 1)] + (uint64_t)T.pair[1].b + big;
  if (x)
    r -= u;
  w *= 0x10001u;
  r += w + (uint32_t)(-z) + ((y >> 3) ^ (y << 29));
  return r;
}
#ifdef MAIN
int main(void)
{
  uint64_t xs[] = { 0, 1, 7, 0xffffffffffffffffULL, 12345678901234567ULL };
  uint32_t ys[] = { 0, 6, 7, 0xffffffffu };
  int32_t zs[] = { 0, -5, 2147483647 };
  double ds[] = { 0.0, 3.99, 1e18 };
  for (int a = 0; a < 5; a++) for (int b = 0; b < 4; b++) for (int c = 0; c < 3; c++) for (int e = 0; e < 3; e++)
    printf("%llu\n", (unsigned long long)f(xs[a], ys[b], zs[c], ds[e]));
  return 0;
}
#endif
]]

test('cjs EXACT mode: C\'s own arithmetic (uint32 wrap, uint64 overflow, shifts, casts, typed literals, hex floats, conversions, an out-parameter, a struct global) — every result identical to the host gcc\'s', function ()
    if not ready() then skip 'no C parser / gcc / node' end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(dir .. '/t.c', 'w')); fd:write(SRC); fd:close()
    eq(0, vim.system({ 'gcc', '-O0', '-DMAIN', 't.c', '-o', 't' }, { cwd = dir }):wait().code)
    local want = vim.system({ './t' }, { cwd = dir, text = true }):wait().stdout
    local pp = vim.system({ 'gcc', '-E', '-P', 't.c' }, { cwd = dir, text = true }):wait().stdout
    local js, refusals = C.emit({ { text = pp, name = 't.c' } }, { exact = true, roots = { 'f' } })
    eq({}, refusals)
    fd = assert(io.open(dir .. '/t.js', 'w'))
    fd:write(js .. [[

const xs = [0n, 1n, 7n, 0xffffffffffffffffn, 12345678901234567n], ys = [0, 6, 7, 0xffffffff], zs = [0, -5, 2147483647], ds = [0, 3.99, 1e18];
const $res = [];
for (const x of xs) for (const y of ys) for (const z of zs) for (const d of ds) $res.push(String(f(x, y, z, d)));
process.stdout.write($res.join('\n') + '\n');
]])
    fd:close()
    local r = vim.system({ 'node', 't.js' }, { cwd = dir, text = true }):wait()
    eq(0, r.code, r.stderr)
    ok(#vim.split(vim.trim(want), '\n') == 180, 'the premise: 180 C results')
    eq(want, r.stdout)
end)

local HEAP_SRC = [[
#include <stdint.h>
#include <stdio.h>
typedef union Cell { uint64_t u64; double n; struct { int32_t i; uint32_t it; }; struct { uint32_t lo, hi; } w; } Cell;
typedef enum { K_A, K_B, K_C = 7, K_D } Kind;
static void fill(Cell *o, double d) { o->n = d; }
static int kindof(int x)
{
  int r = 0;
  switch (x) {
  case 1: r = 10; goto tail;
  case 2: r = 20;
  default:
  tail:
    if (r > 15) break;
    r += 1;
    r *= 3;
  }
  return r;
}
uint64_t f(uint64_t bits, double d, int32_t k)
{
  Cell c, *p = &c;
  uint8_t buf[16], *bp = buf;
  uint64_t acc = 0;
  int32_t j;
  p->u64 = bits;                       /* write the bits, read the double: a union's punning */
  acc ^= (uint64_t)(int64_t)(p->n * 4.0);
  fill(&c, d);                          /* a local union written through its address */
  acc = acc * 31 + c.u64 + (uint64_t)(uint32_t)c.i + c.it;
  for (j = 0; j < 16; j++) *bp++ = (uint8_t)(j * k + 250);   /* bytes, wrapped mod 256 */
  for (j = 0; j < 16; j++) acc += buf[j], acc <<= 1;           /* a comma expression */
  bp = buf; *bp = bits >> 49; acc += buf[0];                   /* a 64-bit value stored as a byte: C truncates it */
  acc += K_A + K_B * 2 + K_C * 3 + K_D * 5 + (sizeof(long) == 8 ? 100 : 200);
  acc += kindof(k & 3);
  return acc;
}
#ifdef MAIN
int main(void)
{
  uint64_t bs[] = { 0x3ff0000000000000ULL, 0x4010000000000000ULL, 0xc000000000000000ULL, 0 };
  double ds[] = { 1.5, -0.0, 1e300, 3.0 };
  int32_t ks[] = { 0, 1, 2, 3, 7, -5 };
  for (int a = 0; a < 4; a++) for (int b = 0; b < 4; b++) for (int c = 0; c < 6; c++)
    printf("%llu\n", (unsigned long long)f(bs[a], ds[b], ks[c]));
  return 0;
}
#endif
]]

test('cjs EXACT HEAP mode: a union\'s punning, a local union by address, a local byte array through *p++, enums, sizeof(long), a comma expression, a goto into `default:` with trailing statements — every result identical to gcc\'s, the layout the compiler\'s', function ()
    if not ready() then skip 'no C parser / gcc / node' end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(dir .. '/h.c', 'w')); fd:write(HEAP_SRC); fd:close()
    eq(0, vim.system({ 'gcc', '-O0', '-DMAIN', 'h.c', '-o', 'h' }, { cwd = dir }):wait().code)
    local want = vim.system({ './h' }, { cwd = dir, text = true }):wait().stdout
    local pp = vim.system({ 'gcc', '-E', '-P', 'h.c' }, { cwd = dir, text = true }):wait().stdout
    -- the layout and the sizes, from the compiler (the header is the source itself, without its main)
    local hdr = dir .. '/cell.h'
    fd = assert(io.open(hdr, 'w')); fd:write((HEAP_SRC:gsub('#ifdef MAIN.*', ''))); fd:close()
    local copts = { src = pp, header = 'cell.h', include = dir }
    local layout, desc = C.compiler_layout(vim.tbl_extend('force', copts, { type = 'Cell' }))
    ok(layout, tostring(desc))
    eq(8, layout.size)
    eq({ 0, 'f64' }, { layout.fields.n.off, layout.fields.n.cls })
    eq({ 4, 'u32' }, { layout.fields.it.off, layout.fields.it.cls }, 'an anonymous struct member is the union\'s own')
    eq(nil, layout.fields.lo, 'a NAMED struct\'s member is not')
    local sizes = assert(C.compiler_sizes(copts))
    eq(8, sizes.long)
    local js, refusals = C.emit({ { text = pp, name = 'h.c' } }, { exact = true, roots = { 'f' }, heap = { types = { Cell = layout } }, sizes = sizes })
    eq({}, refusals)
    fd = assert(io.open(dir .. '/h.js', 'w'))
    fd:write(js .. [[

const bs = [0x3ff0000000000000n, 0x4010000000000000n, 0xc000000000000000n, 0n], ds = [1.5, -0, 1e300, 3.0], ks = [0, 1, 2, 3, 7, -5];
const $res = [];
for (const b of bs) for (const d of ds) for (const k of ks) $res.push(String(f(b, d, k)));
process.stdout.write($res.join('\n') + '\n');
]])
    fd:close()
    local r = vim.system({ 'node', 'h.js' }, { cwd = dir, text = true }):wait(120000)
    eq(0, r.code, r.stderr)
    ok(#vim.split(vim.trim(want), '\n') == 96, 'the premise: 96 C results')
    eq(want, r.stdout)
end)

local FLOW_SRC = [[
#include <stdint.h>
#include <stdio.h>
typedef unsigned int MyU;
typedef union Num { double n; uint64_t u64; struct { uint32_t lo, hi; } u32; } Num;
static const int16_t tab16[] = { -300, 7, 32767, -32768, 12 };
static const double tabd[] = { 0.5, 1e10, -2.25 };
static const int8_t tab8[] = { -1, 5, -128, 127 };
static const uint64_t tab64[] = { 1, 0xffffffffffffffffULL, 12345678901234ULL };
static uint32_t sum_words(uint32_t *w, uint32_t n) { uint32_t s = 0, *e = w + n; while (w < e) s += *w++; return s; }
static int32_t span(uint32_t *a, uint32_t *b) { return (int32_t)(b - a); }
/* a FORWARD goto into a sibling block, a BACKWARD goto into an earlier block, gotos out of an if-chain to a shared
   tail, a loop with continue and break, a switch with a fallthrough, sibling blocks declaring the same name */
static int32_t flow(int32_t x)
{
  int32_t r = 0, tries = 0;
  if (x > 100) {
    r = 1;
    goto mid;
  } else {
    r = 2;
  again:
    r += 10;
  }
  if (x & 1) {
    int32_t d = x * 3;
    r += d;
  mid:
    r += 100;
  } else {
    int32_t d = x - 1;
    r -= d;
  }
  if (tries++ < 2 && x % 3 == 0) goto again;
  for (int32_t i = 0; i < 10; i++) {
    if (i == 2) continue;
    if (i * x > 50) break;
    r += i;
  }
  switch (x & 3) {
  case 0: r ^= 5; break;
  case 1: if (r > 200) goto tail; r ^= 9;
  default: r += 1;
  }
  {
    int32_t r = 5;                  /* an inner block SHADOWS r: the outer one is back after it */
    r *= 3;
    if (r > 14) goto shadow_done;
    r = 0;
  }
shadow_done:
  r += 1;
  while (r < 60 + x) {              /* a while whose BREAK fires before its condition fails */
    r += 7;
    if (r % 5 == 0) break;
  }
  if (r > 1000) goto tail;
  if (r < -1000) goto tail;
  return r;
tail:
  return -r;
}
/* a goto INTO a loop body that holds continue and break */
static int32_t intoloop(int32_t n)
{
  int32_t i = 0, acc = 0;
  if (n > 5) goto inside;
  for (i = 0; i < n; i++) {
    acc += 2;
  inside:
    if (i == 7) continue;
    if (acc > 40) break;
    acc += i;
  }
  return acc * 100 + i;
}
uint64_t f(int32_t x, double d)
{
  uint32_t w[8], *p = w;
  int16_t h = (int16_t)(x * 1000);
  uint16_t uh = (uint16_t)(x * -77);
  Num v;
  uint64_t acc = 0;
  int32_t i;
  for (i = 0; i < 8; i++) w[i] = (uint32_t)x * 2654435761u + (uint32_t)i;
  p += 3; *p = 17; p[1] += 5;
  acc += sum_words(w, 8) + (uint64_t)span(w, p) * 1000;
  acc += (uint64_t)(int64_t)tab16[(uint32_t)x % 5] + (uint64_t)(int64_t)(tabd[(uint32_t)x % 3] * 4) + (uint64_t)(int64_t)tab8[(uint32_t)x % 4];
  v.n = d; acc ^= (uint64_t)v.u32.hi << 7; v.u32.lo = 12345; acc += v.u64 >> 3;
  acc += (MyU)(x - 3);
  {
    uint16_t hw[4];                 /* 16-bit storage read back through a BYTE pointer: the width decides the bytes */
    uint8_t *hb = (uint8_t *)hw;
    for (i = 0; i < 4; i++) hw[i] = (uint16_t)(x * 40503 + i);
    acc += hb[2] + hb[5] * 3u + tab64[(uint32_t)x % 3];
  }
  acc += (uint64_t)(int64_t)h + uh;
  acc += (uint64_t)(int64_t)flow(x) * 7 + (uint64_t)(int64_t)intoloop(x);
  return acc;
}
#ifdef MAIN
int main(void)
{
  int32_t xs[] = { -7, -3, -1, 0, 1, 2, 3, 5, 6, 7, 9, 12, 33, 99, 101, 150, 301, 40000 };
  double ds[] = { 1.5, -0.0, 1e300, 3.0 };
  for (int a = 0; a < 18; a++) for (int b = 0; b < 4; b++) printf("%llu\n", (unsigned long long)f(xs[a], ds[b]));
  return 0;
}
#endif
]]

test('cjs EXACT HEAP mode, CONTROL: gotos the structured forms cannot express take the LABEL-DISPATCH form (into a sibling block, backward into an earlier one, out of an if-chain, into a loop body with continue/break), sibling blocks keep their own locals; WIDE heap data: uint32 arrays through pointers (*p++, p[i] +=, p - q), int16/double/int8 static tables, a named nested union member, (T)(x) with a typedef T, 16-bit wraps — every result gcc\'s', function ()
    if not ready() then skip 'no C parser / gcc / node' end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(dir .. '/g.c', 'w')); fd:write(FLOW_SRC); fd:close()
    eq(0, vim.system({ 'gcc', '-O0', '-DMAIN', 'g.c', '-o', 'g' }, { cwd = dir }):wait().code)
    local want = vim.system({ './g' }, { cwd = dir, text = true }):wait().stdout
    local pp = vim.system({ 'gcc', '-E', '-P', 'g.c' }, { cwd = dir, text = true }):wait().stdout
    fd = assert(io.open(dir .. '/num.h', 'w')); fd:write((FLOW_SRC:gsub('#ifdef MAIN.*', ''))); fd:close()
    local copts = { src = pp, header = 'num.h', include = dir }
    local layout = assert(C.compiler_layout(vim.tbl_extend('force', copts, { type = 'Num' })))
    eq({ 4, 'u32' }, { layout.fields['u32.hi'].off, layout.fields['u32.hi'].cls }, 'a named member\'s member is a PATH, its offset the outer type\'s')
    local js, refusals = C.emit({ { text = pp, name = 'g.c' } }, { exact = true, roots = { 'f' }, heap = { types = { Num = layout } }, sizes = assert(C.compiler_sizes(copts)) })
    eq({}, refusals)
    ok(js:find('function flow(x) {\nlet ', 1, true) and js:find('$d: for (;;) switch ($L)', 1, true), 'flow takes the dispatch form')
    ok(not js:match('function sum_words[^\n]*\n[^\n]*%$d:'), 'a function the structured forms express keeps them')
    fd = assert(io.open(dir .. '/g.js', 'w'))
    fd:write(js .. [[

const xs = [-7, -3, -1, 0, 1, 2, 3, 5, 6, 7, 9, 12, 33, 99, 101, 150, 301, 40000], ds = [1.5, -0, 1e300, 3.0];
const $res = [];
for (const x of xs) for (const d of ds) $res.push(String(f(x, d)));
process.stdout.write($res.join('\n') + '\n');
]])
    fd:close()
    local r = vim.system({ 'node', 'g.js' }, { cwd = dir, text = true }):wait(120000) -- (a lowering that loops forever FAILS, bounded)
    eq(0, r.code, r.stderr)
    ok(#vim.split(vim.trim(want), '\n') == 72, 'the premise: 72 C results')
    eq(want, r.stdout)
end)

test('cjs: a LEGACY recipe (exact mode off) is unchangedd, and regeneration is DETERMINISTIC — the module text of two emits is identical', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'c') then skip 'no C parser' end
    local src = 'typedef struct { int a[3]; int b[2]; } S; static int g(int x) { return x + 1; } int h(int y) { return g(y) * 2; }'
    local a = C.emit({ { text = src, name = 's.c' } }, { roots = { 'h' } })
    local b = C.emit({ { text = src, name = 's.c' } }, { roots = { 'h' } })
    eq(a, b)
    ok(a:find('STRUCTS: {"S":{"a":3,"b":2}}', 1, true), a:match('STRUCTS: [^}]*}}') or a)
    ok(a:find('function g(x)', 1, true) and a:find('function h(y)', 1, true), 'both reachable functions, in call order')
end)
