-- REPS of OBJECT POINTERS from the RUNNING runtime (CPython: the slot is `PyObject *`): a probe LINKED against the
-- tree's own static library (`lib<name>.a` in the build directory, the Makefile's LIBS / LIBM) initializes the
-- interpreter — an isolated config, its search path the tree's Lib/ and build/lib.* — and hands every value it can
-- make with no input: one instance of each builtin TYPE whose zero-argument call succeeds (int() 0, str() '', list()
-- [] …; exception classes but BaseException left out), every builtin value that is not callable (None, Ellipsis,
-- NotImplemented), a builtin function, a type, a module. A representative IS its object's ADDRESS, named by its
-- type's tp_name; the MEMORY the interpreter reads through it is the process's own words: a window at the object and
-- at every readable word it points to, two levels deep (its type object, the type's slot tables) — `Py_TYPE(o)->
-- tp_flags` is read, not modelled. And `symaddr`: the address of every extern data object the headers declare
-- (`extern PyTypeObject PyLong_Type;`), so `Py_IS_TYPE(o, &PyLong_Type)` compares two real addresses.
local function hex16(h) return (('%016s'):format(h):gsub(' ', '0')) end

return {
    fact = 'reps',
    needs = { 'layout', 'compdb', 'sources' },
    summary = 'object pointers made by a probe linked against the tree\'s library, with the memory they reach',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        local ffi = require 'ffi'
        local L = got.layout
        if not (L.layout.scalar and L.pointer) then return nil, 'the slot is not a pointer word' end
        local dir = got.compdb.dir
        local lib = vim.fn.glob(dir .. '/lib*.a', false, true)[1]
        if not lib then return nil, 'no static library lib*.a in the build directory' end
        local mk = F.readfile(dir .. '/Makefile') or ''
        local libs = {}
        for _, var in ipairs({ 'LIBS', 'LIBM', 'LIBC' }) do
            for w in (mk:match('\n' .. var .. '=%s*([^\n]*)') or ''):gmatch('%S+') do if w:match('^%-l') then libs[#libs + 1] = w end end
        end
        vim.list_extend(libs, { '-lpthread', '-lutil' })
        local unit
        for _, u in ipairs(got.compdb.units) do if (F.readfile(u.file) or ''):find('#include%s+"Python.h"') then unit = u; break end end
        if not unit then return nil, 'no unit includes "Python.h"' end
        -- (an EMBEDDING probe: only the unit's include directories, not its core-build defines)
        local pu = { file = unit.file, cwd = unit.cwd, flags = vim.tbl_filter(function (f) return f:match('^%-I') ~= nil end, unit.flags) }
        local paths = { dir .. '/Lib' }
        vim.list_extend(paths, vim.fn.glob(dir .. '/build/lib.*', false, true))
        -- (every extern DATA object the headers declare, with its type: the symbols a unit may take the address of)
        local syms, seen = {}, {}
        for _, s in ipairs(got.sources.units) do
            for ty, name in s.text:gmatch('extern%s+([%w_]+)%s+([%w_]+)%s*;') do
                if not seen[name] and ty ~= 'int' and ty ~= 'char' and ty ~= 'const' then seen[name] = true; syms[#syms + 1] = { name, ty } end
            end
        end
        table.sort(syms, function (a, b) return a[1] < b[1] end)
        local function program(list)
            local P = { '#define PY_SSIZE_T_CLEAN', '#include <Python.h>', '#include <stdio.h>',
                'static unsigned long R[8192][2]; static int NR;',
                'static void maps(void) { FILE *f = fopen("/proc/self/maps", "r"); char l[1024]; while (f && fgets(l, sizeof l, f)) { unsigned long a, b; char p[8]; if (sscanf(l, "%lx-%lx %7s", &a, &b, p) == 3 && p[0] == \'r\' && NR < 8192) { R[NR][0] = a; R[NR][1] = b; NR++; } } if (f) fclose(f); }',
                'static int okr(unsigned long p, unsigned long n) { int i; for (i = 0; i < NR; i++) if (p >= R[i][0] && p + n <= R[i][1]) return 1; return 0; }',
                -- (a window is visited again when reached DEEPER than before: a type object first met as another's
                -- tp_base must still have its own pointers followed when it is an object's type)
                'static unsigned long V[65536]; static int D[65536]; static int NV;',
                'static int seen(unsigned long p, int depth) { int i; for (i = 0; i < NV; i++) if (V[i] == p) { if (D[i] >= depth) return 1; D[i] = depth; return 0; } if (NV < 65536) { V[NV] = p; D[NV++] = depth; } return 0; }',
                'static void win(unsigned long p, int n, int depth) { int i; p &= ~7UL; if (seen(p, depth)) return; while (n > 0 && !okr(p, (unsigned long)n * 8)) n--;',
                '  for (i = 0; i < n; i++) printf("MEM %lx %lx\\n", p + 8 * i, ((unsigned long *)p)[i]);',
                '  if (depth > 0) for (i = 0; i < n; i++) { unsigned long w = ((unsigned long *)p)[i]; if (w && !(w & 7) && okr(w, 8)) win(w, 64, depth - 1); } }',
                'static void rep(PyObject *o) { printf("REP %s %lx\\n", Py_TYPE(o)->tp_name, (unsigned long)o); win((unsigned long)o, 64, 2); }',
                'int main(void) {',
                '  PyConfig c; PyConfig_InitIsolatedConfig(&c); c.module_search_paths_set = 1;' }
            for _, p in ipairs(paths) do P[#P + 1] = ('  PyWideStringList_Append(&c.module_search_paths, L"%s");'):format(p) end
            vim.list_extend(P, {
                '  PyStatus s = Py_InitializeFromConfig(&c); if (PyStatus_Exception(s)) { fprintf(stderr, "init: %s\\n", s.err_msg ? s.err_msg : "?"); return 3; }',
                '  maps();',
                '  PyObject *b = PyEval_GetBuiltins(), *k, *v; Py_ssize_t pos = 0;',
                '  while (PyDict_Next(b, &pos, &k, &v)) {',
                '    if (PyType_Check(v)) {',
                '      if (PyType_IsSubtype((PyTypeObject *)v, (PyTypeObject *)PyExc_BaseException) && v != PyExc_BaseException) continue;',
                '      PyObject *o = PyObject_CallNoArgs(v); if (!o) { PyErr_Clear(); continue; } rep(o);',
                '    } else if (!PyCallable_Check(v)) rep(v);',
                '  }',
                '  rep(PyDict_GetItemString(b, "len")); rep((PyObject *)&PyLong_Type); rep(PyImport_AddModule("builtins"));',
            })
            for _, sy in ipairs(list) do P[#P + 1] = ('  printf("SYM %s %s %%lx\\n", (unsigned long)&%s);'):format(sy[1], sy[2], sy[1]) end
            P[#P + 1] = '  return 0; }'
            return table.concat(P, '\n') .. '\n'
        end
        local list = syms
        local out, why
        for _ = 1, 6 do
            local stderr
            out, why, stderr = F.run_c(program(list), pu, { link = vim.list_extend({ lib }, libs), timeout = 120000 })
            if out then break end
            -- (a symbol the compiler or the linker refuses — declared, never defined here — is dropped)
            local bad = {}
            -- (both quotings: the C locale's `x' / 'x', a UTF-8 locale's ‘x’)
            for nm in (stderr or ''):gmatch("undefined reference to [`'\226\128\152]+([%w_]+)") do bad[nm] = true end
            for nm in (stderr or ''):gmatch("([%w_]+)[\226\128\153']+ undeclared") do bad[nm] = true end
            if not next(bad) then break end
            list = vim.tbl_filter(function (sy) return not bad[sy[1]] end, list)
        end
        if not out then return nil, why end
        local R = { order = {}, tag = {}, kind = 'objects', memory = {}, symaddr = {} }
        local function i64(h) h = hex16(h); return ffi.cast('int64_t', ffi.new('uint64_t', tonumber(h:sub(1, 8), 16)) * 2 ^ 32 + tonumber(h:sub(9), 16)) end
        for line in out:gmatch('[^\n]+') do
            local a, w = line:match('^MEM (%x+) (%x+)$')
            if a then R.memory[tostring(i64(a))] = hex16(w)
            else
                local nm, addr = line:match('^REP (%S+) (%x+)$')
                if nm and not R.tag[nm] then R.order[#R.order + 1] = nm; R.tag[nm] = { u64 = hex16(addr) } end
                local sn, sty, sa = line:match('^SYM (%S+) (%S+) (%x+)$')
                if sn then R.symaddr[sn] = { v = i64(sa), type = sty } end
            end
        end
        if #R.order == 0 then return nil, 'the probe made no object' end
        return R
    end,
}
