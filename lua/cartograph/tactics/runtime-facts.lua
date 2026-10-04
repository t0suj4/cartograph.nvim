-- RUNTIME-FACTS (discovery): what does an interpreter ADAPTER need from this runtime's C tree, and which of it does
-- the tree give? Every derivation of cartograph.cinterp.facts runs over `src` and the WHOLE table comes back — never
-- stopping at the first gap, so each gap gets its own targeted derivation: ADAPTER (nothing derives it yet — write a
-- derivation), ENGINE (derived, in a shape cartograph.cinterp cannot run — a ticket), BLOCKED (a fact it needs is a
-- gap), ERROR (a derivation raised). MEASURED 2026-09-30 (CART-1248): LuaJIT fbb36bb6 16 of 16; OTP 25.3.2.8 erts 4
-- of 16 (compdb with ERL_TOP derived, sources, units, builtins).
-- CLAIM: every fact derives.
local function cready()
    if vim.fn.executable('gcc') ~= 1 then return false, 'no gcc' end
    if not pcall(vim.treesitter.get_string_parser, '', 'c') then return false, 'no C parser' end
    return true
end

local LJ = {
    ['lua.h'] = '#define LUA_TNONE (-1)\n#define LUA_TNIL 0\n#define LUA_TBOOLEAN 1\n#define LUA_TNUMBER 3\n',
    ['lj_def.h'] = '#define LJ_NORET __attribute__((noreturn))\n',
    ['lj_lib.h'] = '#define FFH_RETRY 0\n#define FFH_RES(n) ((n)+1)\n',
    ['lj_obj.h'] = table.concat({
        '#include <stdint.h>', '#include "lj_def.h"', '#include "lua.h"',
        'typedef union TValue { uint64_t u64; double n; int64_t it64; struct { uint32_t lo; uint32_t it; }; } TValue;',
        'typedef struct MRef { uint64_t ptr64; } MRef;',
        'typedef struct lua_State { TValue *base, *top; MRef stack; } lua_State;',
        '#define LJ_TNIL (~0u)', '#define LJ_TFALSE (~1u)', '#define LJ_TTRUE (~2u)', '#define LJ_TNUMX (~13u)',
        '#define LJ_TISNUM LJ_TNUMX', '#define LJ_TISPRI LJ_TTRUE',
        '#define itype(o) ((uint32_t)((o)->it64 >> 47))',
        '#define setpriV(o, x) ((o)->it64 = (int64_t)~((uint64_t)~(x)<<47))',
        '#define setnumV(o, x) ((o)->n = (x))',
        'static inline void setgcVraw(TValue *o, void *v, uint32_t it) { o->u64 = ((uint64_t)(uintptr_t)v & (((uint64_t)1 << 47) - 1)) | ((uint64_t)it << 47); }',
        'typedef void GCobj;',
        '#define tvisnil(o) ((o)->it64 == -1)', '#define tvisnumber(o) (itype(o) <= LJ_TISNUM)',
        'LJ_NORET void lj_err_argt(lua_State *L, int narg, int tt);',
    }, '\n') .. '\n',
    ['lj_obj.c'] = '#include "lj_obj.h"\nconst char *const lj_obj_itypename[] = { "nil", "boolean", "boolean", "userdata", "string", "upval", "thread", "proto", "function", "trace", "cdata", "table", "userdata", "number" };\n',
    ['lib_x.c'] = table.concat({
        '#include "lj_obj.h"',
        'int lua_gettop(lua_State *L) { return (int)(L->top - L->base); }',
        'int lua_type(lua_State *L, int idx) { TValue *o = L->base + idx - 1; if (o >= L->top) return LUA_TNONE; if (tvisnil(o)) return LUA_TNIL; return LUA_TBOOLEAN; }',
        'void *x_realloc(void *p);',
        'static void x_grow(lua_State *L) { TValue *st, *oldst = ((TValue *)(void *)(L->stack).ptr64); long delta; st = (TValue *)x_realloc(oldst);',
        '  (L->stack).ptr64 = (uint64_t)(void *)st; delta = (char *)st - (char *)oldst; L->top = (TValue *)((char *)L->top + delta); }',
    }, '\n') .. '\n',
}

return {
    name = 'runtime-facts',
    kind = 'discovery',
    tags = { 'find', 'code' },
    summary = 'the facts an interpreter adapter needs, derived from a runtime\'s C tree (src = the dir; omitted = the graph\'s root): each DERIVED, or a gap by kind',
    params = { src = 'string?' },
    measure = function (store, p)
        local T = require('cartograph.cinterp.facts').derive({ src = p.src or store.data.root })
        local v = { derived = T.derived, total = T.total, rows = {}, gaps = {}, broken = T.broken }
        for _, f in ipairs(T.order) do
            local r = T.rows[f]
            if r.value ~= nil then v.rows[f] = { by = r.by }
            else v.rows[f] = { kind = r.kind, gap = r.gap }; v.gaps[#v.gaps + 1] = ('%s %s: %s'):format(r.kind, f, r.gap) end
        end
        return v
    end,
    claim = function (v)
        local by = {}
        for _, r in pairs(v.rows) do if r.kind then by[r.kind] = (by[r.kind] or 0) + 1 end end
        local l = {}
        for k, n in pairs(by) do l[#l + 1] = n .. ' ' .. k end
        table.sort(l)
        return v.derived == v.total and #v.broken == 0, ('%d of %d facts derived%s'):format(v.derived, v.total, #l > 0 and (' — gaps: ' .. table.concat(l, ', ')) or '')
    end,
    examples = {
        {
            name = 'a LuaJIT-shaped tree with no build description: the interpreter\'s facts derive, the library\'s markers are named gaps',
            requires = cready,
            files = LJ,
            params = function (store) return { src = store.data.root } end,
            expect = { holds = false, check = function (v)
                local r = v.rows
                if not (r.compdb and r.compdb.by == 'compdb-plain') then return false, 'compdb: ' .. vim.inspect(r.compdb) end
                for _, f in ipairs({ 'units', 'noret', 'frame', 'slot', 'layout', 'reps', 'numbers', 'firstclass', 'typenames', 'result' }) do
                    if not (r[f] and r[f].by) then return false, f .. ' did not derive: ' .. vim.inspect(r[f]) end
                end
                if not (r.registrations and r.registrations.kind == 'adapter' and r.registrations.gap:find('LJLIB_CF', 1, true)) then return false, 'registrations: ' .. vim.inspect(r.registrations) end
                return true
            end },
        },
        {
            name = 'a tree with no C at all: compdb is an ADAPTER gap and every fact behind it is BLOCKED, named',
            files = { ['README'] = 'not a C tree\n' },
            params = function (store) return { src = store.data.root } end,
            expect = { holds = false, check = function (v)
                local r = v.rows
                if not (r.compdb and r.compdb.kind == 'adapter') then return false, 'compdb: ' .. vim.inspect(r.compdb) end
                if not (r.frame and r.frame.kind == 'blocked' and r.units.kind == 'blocked') then return false, 'frame/units: ' .. vim.inspect({ r.frame, r.units }) end
                if not (r.builtins and r.builtins.by) then return false, 'builtins need no tree' end
                return true
            end },
        },
    },
}
