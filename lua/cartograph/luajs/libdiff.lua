-- cartograph.luajs.libdiff — a LIBRARY FUNCTION's bulk differential: the ORACLE (this process's LuaJIT — nvim's, the
-- differential's reference) against the luajs pack's function of the same name under node, over GENERATED inputs,
-- compared value by value — numbers by their BITS (ffi), NaN as "both NaN" (CART-1211 leaf 3, CART-1220's shape).
--
-- ★ A POSITIVE CONTROL FIRST: an input family that never separates the pack from the oracle cannot accept a change to
-- the pack; run it against the pack as it is before swapping anything in, and expect differences where the pack is
-- known to be hand-written.
--
-- M.FAMILIES[fn] = function (rng, n) -> list of argument lists (Lua strings are bytes) — the measurement's own choice
-- of inputs, weighted toward the boundaries of the thing measured.
local M = {}

local ffi = require 'ffi'
local u64 = ffi.typeof('uint64_t[1]')
local f64 = ffi.typeof('double[1]')

--- a deterministic xorshift64* generator -> { int(lo, hi), pick(list), chance(p) }
function M.rng(seed)
    local s = ffi.new('uint64_t[1]', seed or 0x9E3779B97F4A7C15ULL)
    local r = {}
    function r.next()
        local x = s[0]
        x = bit.bxor(x, bit.rshift(x, 12)); x = bit.bxor(x, bit.lshift(x, 25)); x = bit.bxor(x, bit.rshift(x, 27))
        s[0] = x
        return tonumber(bit.rshift(x * 0x2545F4914F6CDD1DULL, 11)) / 2 ^ 53
    end
    function r.int(lo, hi) return lo + math.floor(r.next() * (hi - lo + 1)) end
    function r.pick(l) return l[r.int(1, #l)] end
    function r.chance(p) return r.next() < p end
    return r
end

--- a value as a comparable string: numbers by their bits (every NaN one class), strings by bytes
function M.encode(v)
    local t = type(v)
    if t == 'number' then
        if v ~= v then return 'n:nan' end
        local d = f64(v)
        local b = ffi.cast('uint64_t*', d)[0]
        return 'n:' .. bit.tohex(b, 16)
    elseif t == 'string' then
        return 's:' .. (v:gsub('.', function (c) return ('%02x'):format(c:byte()) end))
    end
    return tostring(v)
end

local function hex(s) return (s:gsub('.', function (c) return ('%02x'):format(c:byte()) end)) end
-- an ARGUMENT's wire form: a number by its bits (`n` + 16 hex digits — tostring() would round it), a string by bytes
local function bits_of(d) local b = f64(d); return ffi.cast('uint64_t*', b)[0] end
local function arg_enc(v)
    if type(v) == 'number' then return 'n' .. bit.tohex(bits_of(v), 16) end
    return hex(v)
end
--- a double from its bits (a Lua number or a uint64 cdata). ★ A NaN comes back CANONICAL (0/0): LuaJIT NaN-tags its
--- values and does NOT canonicalize an ffi load (lj_cconv.c: "Numbers are NOT canonicalized here! Beware of
--- uninitialized data.") — a payload NaN in 0xfff8… IS a tagged GC reference, and the collector follows it (MEASURED: a
--- segfault in plain Lua code, JIT off, at ~100,000 inputs). A Lua program can only make the two NaNs 0/0 and -(0/0)
--- have, so no input is lost that the oracle could see.
local function from_bits(u)
    local b = u64(u)
    if bit.band(b[0], 0x7ff0000000000000ULL) == 0x7ff0000000000000ULL and bit.band(b[0], 0x000fffffffffffffULL) ~= 0ULL then
        return bit.band(b[0], 0x8000000000000000ULL) ~= 0ULL and 0 / 0 or -(0 / 0)
    end
    return ffi.cast('double*', b)[0]
end

M.FAMILIES = {}

--- tonumber(s): strings at the scanner's boundaries — decimal and hex (with `p` exponents), long digit runs (beyond 19
--- digits: the bignum path), exponents near the double's limits (±308, ±324, the ±1075 subnormal band), every C
--- whitespace byte around it, signs, inf/infinity/nan in mixed case, the empty and malformed ones, an embedded NUL
function M.FAMILIES.tonumber(r, n)
    local out = {}
    local WS = { ' ', '\t', '\n', '\v', '\f', '\r' }
    local function ws() local s = '' for _ = 1, r.int(0, 2) do s = s .. r.pick(WS) end return s end
    local function digits(k, alpha) local s = '' for _ = 1, k do local j = r.int(1, #alpha); s = s .. alpha:sub(j, j) end return s end
    local function mixcase(s) return (s:gsub('%a', function (c) return r.chance(0.5) and c:upper() or c end)) end
    local DEC, HEX = '0123456789', '0123456789abcdefABCDEF'
    local JUNK = '0123456789abcdefxXpPeE.+- \t\n\v\f\r\0infytINFYTaAnN'
    for i = 1, n do
        local kind = i % 8
        local s
        if kind == 0 then
            s = ''
            for _ = 1, r.int(0, 24) do local k = r.int(1, #JUNK); s = s .. JUNK:sub(k, k) end
        elseif kind == 1 or kind == 2 then
            -- a decimal: digits, fraction, exponent (long runs; exponents at the limits)
            local lead = digits(r.pick { 1, 1, 2, 5, 17, 19, 20, 25, 40 }, DEC)
            local frac = r.chance(0.5) and ('.' .. digits(r.int(0, 30), DEC)) or ''
            local ex = ''
            if r.chance(0.6) then
                ex = r.pick { 'e', 'E' } .. r.pick { '', '+', '-' } .. tostring(r.pick { r.int(0, 30), r.int(290, 330), r.int(300, 400), r.int(0, 1100) })
            end
            s = ws() .. r.pick { '', '', '-', '+' } .. lead .. frac .. ex .. ws()
        elseif kind == 3 or kind == 4 then
            -- a hex integer or hex float with a binary exponent
            local lead = digits(r.pick { 0, 1, 2, 8, 13, 16, 17, 20 }, HEX)
            local frac = r.chance(0.5) and ('.' .. digits(r.int(0, 16), HEX)) or ''
            local ex = r.chance(0.6) and (r.pick { 'p', 'P' } .. r.pick { '', '+', '-' } .. tostring(r.pick { r.int(0, 60), r.int(1000, 1100), r.int(1070, 1080) })) or ''
            s = ws() .. r.pick { '', '-', '+' } .. r.pick { '0x', '0X' } .. lead .. frac .. ex .. ws()
        elseif kind == 5 then
            s = ws() .. r.pick { '', '-', '+' } .. mixcase(r.pick { 'inf', 'infinity', 'nan', 'infin', 'na', 'infinityx' }) .. ws()
        elseif kind == 6 then
            s = r.pick { '', ' ', '0x', '0x.', '.', '1e', '1e+', '0x1p', '0x1p-', '-', '+', '..1', '1..', '0x.p1', '1e1.5',
                '00', '0b101', '1\0', '\0' .. '1', '  12  \0', '1 2', '+-1', '0x-1', '1f', '1L', '1.e5', '.e5', '0e0' }
        else
            -- a decimal at a representability boundary: 2^53 neighbours, the smallest normal/subnormal, huge
            s = r.pick { '9007199254740993', '9007199254740992.5', '2.2250738585072011e-308', '2.2250738585072014e-308',
                '4.9406564584124654e-324', '2.4703282292062327e-324', '2.4703282292062328e-324', '1.7976931348623157e308',
                '1.7976931348623159e308', '179769313486231580793728971405301e276', '0.1', '1e23', '8.589973e9',
                '123456789012345678901234567890e-10' } .. r.pick { '', '0', '1', '5' }
        end
        out[#out + 1] = { s }
    end
    return out
end

--- tostring(x) of a NUMBER (C's %.14g, lj_strfmt_num): doubles at the formatter's boundaries — any bits (NaN payloads,
--- infinities, subnormals), EXACT decimal ties at the 15th significant digit (integers of 15 digits ending in 5, and
--- their exact power-of-two multiples), the %e/%f switch points (exponent -5/-4 and 13/14) a few ulps either side,
--- integers around 1e14..1e15 and 2^53, every power of ten +- a few ulps, -0, and ordinary values of every magnitude
function M.FAMILIES.tostring(r, n)
    local out = {}
    local function near(d, k) return from_bits(bits_of(d) + k) end -- k ulps away (k may be negative: wraps as uint64)
    local function rbits() return bit.bor(bit.lshift(ffi.new('uint64_t', r.int(0, 2 ^ 32 - 1)), 32), ffi.new('uint64_t', r.int(0, 2 ^ 32 - 1))) end
    for i = 1, n do
        local kind = i % 8
        local d
        if kind == 0 then
            d = from_bits(rbits())
        elseif kind == 1 then
            -- an exact tie: a 15-digit integer ending in 5 (< 2^53, so exact), scaled by an exact power of two
            d = (r.int(10000000000000, 99999999999999) * 10 + 5) * 2 ^ r.pick { 0, 0, 1, -1, 3, -7, 20, -30 }
        elseif kind == 2 then
            d = near(r.pick { 1e-5, 1e-4, 1e13, 1e14, 1e15, 9.99999999999995e-5, 9.99999999999995e13, 99999999999999.5,
                0.000099999999999999995, 1e-4 * (1 - 2 ^ -53) }, r.int(-3, 3))
        elseif kind == 3 then
            d = r.pick { 1e14, 1e15, 2 ^ 53, 2 ^ 52, 2 ^ 63, 123456789012345 } + r.int(-20, 20)
        elseif kind == 4 then
            d = near(10 ^ r.int(-323, 308), r.int(-2, 2))
        elseif kind == 5 then
            d = r.pick { 0, -0, 1 / 0, -1 / 0, 0 / 0, 5e-324, -5e-324, 2.2250738585072014e-308, 1.7976931348623157e308,
                from_bits(bit.band(rbits(), 0x800fffffffffffffULL)) } -- the last: a random subnormal
        elseif kind == 6 then
            d = (r.chance(0.5) and -1 or 1) * r.next() * 10 ^ r.int(-30, 30)
        else
            d = r.pick { r.int(-1000, 1000), r.int(-1000, 1000) / 2 ^ r.int(1, 10), 0.1, 1 / 3, 2 / 3, 0.5, 1e21, 1e22 }
        end
        out[#out + 1] = { d }
    end
    return out
end

--- the differential. opts: { fn, n, seed, dir (install_pack'd), js_fn (the pack side: a JS expression over P and G
--- evaluated to the function; default the library function of the same name), limit (examples kept) }
--- -> { n, differ, examples = { {args, lua, js} }, family }
function M.run(opts)
    local fam = M.FAMILIES[opts.fn]
    if not fam then
        local names = vim.tbl_keys(M.FAMILIES)
        table.sort(names)
        return nil, 'no input family for `' .. tostring(opts.fn) .. '` (families: ' .. table.concat(names, ', ') .. ')'
    end
    local r = M.rng(opts.seed)
    local inputs = fam(r, opts.n or 100000)
    local path = opts.fn:gmatch('[^.]+')
    local f = _G
    for part in path do f = f[part] end
    local lines = {}
    for _, args in ipairs(inputs) do
        local res = { pcall(f, unpack(args)) }
        local enc
        if res[1] then
            local vals = {}
            for i = 2, math.max(2, #res) do vals[#vals + 1] = M.encode(res[i]) end
            enc = table.concat(vals, ',')
        else enc = 'error' end
        local a = {}
        for i, v in ipairs(args) do a[i] = arg_enc(v) end
        lines[#lines + 1] = table.concat(a, ',') .. '\t' .. enc
    end
    local data = opts.dir .. '/$libdiff.tsv'
    local fd = assert(io.open(data, 'w')); fd:write(table.concat(lines, '\n'), '\n'); fd:close()
    local js = [[
const P = require(process.argv[2] + '/$pack.js');
const fs = require('fs');
const F = new Float64Array(1), U = new BigUint64Array(F.buffer);
const enc = v => { if (typeof v === 'number') { if (Number.isNaN(v)) return 'n:nan'; F[0] = v; return 'n:' + U[0].toString(16).padStart(16, '0'); }
  if (typeof v === 'string') { let h = ''; for (let i = 0; i < v.length; i++) h += v.charCodeAt(i).toString(16).padStart(2, '0'); return 's:' + h; }
  if (v === undefined) return 'nil'; return String(v); };
const unhex = h => { if (h[0] === 'n') { U[0] = BigInt('0x' + h.slice(1)); return F[0]; }
  let s = ''; for (let i = 0; i < h.length; i += 2) s += String.fromCharCode(parseInt(h.substr(i, 2), 16)); return s; };
const G = P.$G; const f = ]] .. (opts.js_fn or ('G.' .. opts.fn)) .. [[;
let n = 0, differ = 0; const ex = [];
for (const line of fs.readFileSync(process.argv[3], 'latin1').split('\n')) {
  if (!line) continue; n++;
  const [a, want] = line.split('\t');
  const args = a === '' ? [''] : a.split(',').map(unhex);
  let got;
  try { const r = P.$all(f(...args)); got = (r.length ? r : [undefined]).map(enc).join(','); } catch (e) { got = 'error'; }
  if (got !== want) { differ++; ex.push([args, want, got]); }
}
ex.sort((x, y) => x[0].join('').length - y[0].join('').length);
process.stdout.write(JSON.stringify({ n, differ, examples: ex.slice(0, ]] .. (opts.limit or 12) .. [[) }));
]]
    local jf = opts.dir .. '/$libdiff.js'
    fd = assert(io.open(jf, 'w')); fd:write(js); fd:close()
    local res = vim.system({ 'node', jf, opts.dir, data }, { text = true }):wait(600000)
    if res.code ~= 0 then return nil, 'node: ' .. (res.stderr or '') end
    local out = vim.json.decode(res.stdout)
    out.family = opts.fn
    return out
end

return M