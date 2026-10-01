-- cartograph.cinterp — the engine itself, on C text alone (no facts runner, no compiler): what one construct evaluates to.
local CI = require 'cartograph.cinterp'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'c') end

local function engine(src)
    local u = CI.units({ { name = 'x.c', text = src } })
    u.layout = { fields = {} }; u.reps = { tag = {} }; u.noret = {}; u.frame = {}; u.sentinels = {}; u.builtins = {}
    local A = CI.analyzer(u)
    return u, function (f, args)
        local s = A.run(u.defs[f], args, {}, 1, { ['X@0'] = true }, false)
        local l = {}
        for _, r in ipairs(s.returns) do l[#l + 1] = CI.key_of(CI.at(r.v, 'X@0')) end
        table.sort(l)
        return table.concat(l, ' | ')
    end
end

test('cinterp: an AGGREGATE by value — a compound literal, nested and designated, its field read back, a join that keeps the fields both sides agree on', function ()
    if not ready() then skip 'no C parser' end
    local u, ret = engine([[
typedef union JSValueUnion { int int32; double float64; void *ptr; } JSValueUnion;
typedef struct JSValue { JSValueUnion u; long tag; } JSValue;
JSValue mk(int t, int v) { return (JSValue){ (JSValueUnion){ .int32 = v }, t }; }
JSValue pick(int c, int v) { if (c) return mk(6, 0); return mk(0, v); }
int tagof(int c, int v) { JSValue x = pick(c, v); return (int)x.tag; }
JSValue retag(int v) { JSValue x = mk(1, v); x.tag = 7; return x; }
JSValue br(int c, int v) { JSValue x; if (c) x = mk(6, 0); else x = mk(6, v); return x; }
]])
    eq({ 'u', 'tag' }, vim.tbl_map(function (x) return x.name end, u.aggregates.JSValue.fields), 'the members in declaration order')
    eq('gJSValue{tag=i6LL:32s;u.int32=i0LL:32s}', ret('mk', { CI._int(6), CI._int(0), n = 2 }), 'positional, then a nested designated member flattened to its path')
    eq('gJSValue{tag=i0LL:32s} | gJSValue{tag=i6LL:32s;u.int32=i0LL:32s}', ret('pick', { nil, nil, n = 2 }), 'an unknown member is left out, the known ones survive')
    eq({ 'i6LL:32s', 'i0LL:32s' }, { ret('tagof', { CI._int(1), CI._int(5), n = 2 }), ret('tagof', { CI._int(0), nil, n = 2 }) }, 'a field read of a local aggregate')
    eq('gJSValue{tag=i7LL:32s;u.int32=i3LL:32s}', ret('retag', { CI._int(3), n = 1 }), 'a field write is a functional update')
    eq('gJSValue{tag=i6LL:32s}', ret('br', { nil, nil, n = 2 }), 'two paths JOINED: the member they agree on kept, the other dropped')
end)
