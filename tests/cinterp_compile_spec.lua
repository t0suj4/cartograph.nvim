-- cartograph.cinterp.compile (CART-1317): the CLOSURE COMPILER is eval / exec run once per node — held to eval itself,
-- function by function: the same returns per tag, the same rejections, the same STEPS (the budget and A.self read them).
local CI = require 'cartograph.cinterp'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'c') end

local FIXTURE = [[
typedef struct P { int a; long b; } P;
typedef long ssz;
enum { K1 = 3, K2 = 9 };
static int helper(int x) { return x * 2 + K1; }
int lits(int x) { char c = 'a'; const char *s = "str"; return c + (x ? 1 : 0) + K2 + (int)sizeof(int) + (s != 0); }
int ops(int x, int y) { int r = (x + y) * (x - y) / (y | 1) % 7; r ^= x << 2; r |= y >> 1; r = ~r + -x + !y; return r; }
int logic(int x, int y) { if ((x > 0 && y < 10) || x == y) return 1; return x != y ? 2 : 3; }
int incdec(int x) { int a = (x++, x + 1); int b = ++x; int c = x--; return a + b + c + --x; }
int arr(int x) { int v[3] = { x, x + 1, x + 2 }; v[1] += 5; v[x & 1] = 7; return v[0] + v[1] + v[2]; }
P mkp(int x) { return (P){ .a = x, .b = 2 }; }
int agg(int x) { P p = mkp(x); p.a = p.a + 1; return p.a + (int)p.b; }
static int setp(int *p, int v) { *p = v; return 0; }
int outp(int x) { int r = 0; setp(&r, x + 4); return r; }
int ptrs(int x) { int y = x; int *p = &y; *p = *p + 1; return y; }
int loop(int n) { int s = 0; for (int i = 0; i < n; i++) { s += i; if (s > 20) break; } while (s > 5) s -= 3; do { s++; } while (s < 2); return s; }
int sw(int x) { switch (x) { case 1: return 10; case 2: case 3: return 20; default: break; } return 0; }
int calls(int x) { int (*fp)(int) = helper; return helper(x) + fp(x); }
long tcast(int n) { return (ssz)(n) + 1; }
int unk(int x) { return undefined_fn(x) + (int)(x > 2 ? 1u : 2u); }
int cond(int x) { unsigned char a = x; return x > 1 ? a : -1; }
]]

-- one function's run as text: every return per tag, the rejected tags, over, and the steps it took
local function run(A, d, args)
    local s0 = A.steps
    local s = A.run(d, args, {}, 1, { ['X@0'] = true }, false)
    local l = {}
    for _, r in ipairs(s.returns) do l[#l + 1] = CI.key_of(CI.at(r.v, 'X@0')) end
    table.sort(l)
    local rej = vim.tbl_keys(s.rej or {})
    table.sort(rej)
    return ('%s | rej %s | over %s | steps %d'):format(table.concat(l, ' '), table.concat(rej, ','), tostring(s.over), A.steps - s0)
end

local function ctx_of(src)
    local u = CI.units({ { name = 'x.c', text = src } })
    u.layout = { fields = {} }; u.reps = { tag = {} }; u.noret = {}; u.frame = {}; u.sentinels = {}; u.builtins = {}
    return u
end
local function analyzers(u)
    u.interp = 'eval'
    local E = CI.analyzer(u)
    u.interp = nil
    return E, CI.analyzer(u)
end

test('compile: every arm of eval / exec, compiled, answers as eval does — returns, rejections, over AND the steps, function by function, argument by argument', function ()
    if not ready() then skip 'no C parser' end
    local u = ctx_of(FIXTURE)
    local E, C = analyzers(u)
    local names = vim.tbl_keys(u.defs)
    table.sort(names)
    local n, rows = 0, {}
    for _, f in ipairs(names) do
        local d = u.defs[f]
        local np = #d.params
        local vectors = { { n = np } }
        for _, c in ipairs({ 0, 1, 2, 5 }) do
            local a = { n = np }
            for j = 1, np do a[j] = CI._int(c) end
            vectors[#vectors + 1] = a
        end
        for _, a in ipairs(vectors) do
            local want, got = run(E, d, a), run(C, d, a)
            eq(want, got, f .. ' ' .. vim.inspect(a, { newline = ' ', indent = '' }))
            rows[#rows + 1] = got
            n = n + 1
        end
    end
    eq(17 * 5, n, 'every fixture function, five argument vectors')
    -- (the differential is only worth what the fixture REACHES: pin that the runs are not all unknown)
    local known = 0
    for _, r in ipairs(rows) do if r:find('^i') then known = known + 1 end end
    ok(known >= 50, ('%d of %d runs return a known integer (55 when written: the all-unknown vector is mostly unknown)'):format(known, n))
    ok(run(C, u.defs.outp, { CI._int(4), n = 1 }):find('^i8LL:32s |'), 'an out-parameter written by the callee, compiled')
end)

test('compile: the DEFAULT arm is eval\'s own — an expression cinterp does not model is unknown, COUNTED by type, never handed back to eval', function ()
    if not ready() then skip 'no C parser' end
    local u = ctx_of('struct S { int a; int b; };\nint off(int x) { return offsetof(struct S, b) + x; }\nint gen(int x) { return _Generic(x, int: 1, default: 2); }\n')
    local E, C = analyzers(u)
    for _, f in ipairs({ 'off', 'gen' }) do
        eq(run(E, u.defs[f], { CI._int(1), n = 1 }), run(C, u.defs[f], { CI._int(1), n = 1 }), f)
    end
    eq({ generic_expression = 1, offsetof_expression = 1 }, C.unmodeled)
    eq(nil, E.unmodeled, 'eval keeps no census: it is the reference')
end)

test('compile: the compiled code is PER ANALYZER — two contexts over one definition each read their own facts', function ()
    if not ready() then skip 'no C parser' end
    local u = ctx_of('typedef struct T { char c[3]; } T;\nint sz(int x) { return (int)sizeof(T) + x; }\n')
    local A1 = CI.analyzer(u)
    local u2 = setmetatable({ sizes = { ['x.c'] = { T = 40 } } }, { __index = u })
    local A2 = CI.analyzer(u2)
    local d = u.defs.sz
    local function ret(A) return (run(A, d, { CI._int(1), n = 1 }):match('^(%S+)')) end
    local first = ret(A1) -- (the first analyzer compiles sz)
    eq('i41LL:32s', ret(A2), 'the second context\'s compiler size, not the first analyzer\'s closures')
    eq(first, ret(A1), 'and the first is unchanged')
end)
