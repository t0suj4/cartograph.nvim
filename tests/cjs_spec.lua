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

test('cjs: a LEGACY recipe (exact mode off) is unchanged, and regeneration is DETERMINISTIC — the module text of two emits is identical', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'c') then skip 'no C parser' end
    local src = 'typedef struct { int a[3]; int b[2]; } S; static int g(int x) { return x + 1; } int h(int y) { return g(y) * 2; }'
    local a = C.emit({ { text = src, name = 's.c' } }, { roots = { 'h' } })
    local b = C.emit({ { text = src, name = 's.c' } }, { roots = { 'h' } })
    eq(a, b)
    ok(a:find('STRUCTS: {"S":{"a":3,"b":2}}', 1, true), a:match('STRUCTS: [^}]*}}') or a)
    ok(a:find('function g(x)', 1, true) and a:find('function h(y)', 1, true), 'both reachable functions, in call order')
end)
