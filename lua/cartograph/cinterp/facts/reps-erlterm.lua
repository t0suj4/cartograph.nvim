-- REPS of TAGGED WORDS (erts' Eterm), each built by the COMPILER with the tree's own constructors: make_small at
-- several values, NIL, every atom of the generated atom table (`am_<c>`), one atom past it; HEAP terms built with the
-- tree's own heap constructors where it has them — a proper list [1] and an improper [1|2] (make_list over static
-- cells), a tuple {1, []} (TUPLE2), a float 1.5 (PUT_DOUBLE / make_float) — whose heap words are the MEMORY the
-- interpreter reads through (`*boxed_val(x)` is the tuple's header); and two whose memory is UNKNOWN, standing for
-- every term not built: CONS (any other list) and BOXED (any other boxed kind) — sound, a check on them reads as
-- content. And the TAG FAMILIES, whatever the tree names: a minimal object of every header kind (`_TAG_HEADER_<X>`:
-- `_make_header(0, tag)` then zero words — {} an empty tuple, a zero bignum, an empty binary / map, a fun…) and a word
-- of every immediate kind (`_TAG_IMMED1_<X>` / `_TAG_IMMED2_<X>` with payload 1 — a pid, a port…). Their TYPES are the
-- guard BIFs' own answer (typenames-guardbifs), which also drops those no guard calls a value (a match state, a catch).
return {
    fact = 'reps',
    needs = { 'layout', 'frame', 'registrations', 'compdb' },
    summary = 'tagged-word representatives from make_small / NIL / am_* / make_list',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        if not got.layout.layout.scalar then return nil, 'the slot is not a scalar word' end
        if got.frame.kind ~= 'array' then return nil, 'the frame is not an argument array' end
        local unit
        for _, u in ipairs(got.compdb.units) do if (F.readfile(u.file) or ''):find(got.frame.argmacro .. '1', 1, true) then unit = u; break end end
        if not unit then return nil, 'no unit uses ' .. got.frame.argmacro .. '1' end
        local src = F.readfile(unit.file) or ''
        if not (src:find('make_small') or F.find(F.files(got, 'h'), 'define%s+make_small')) then return nil, 'no make_small constructor' end
        local atoms = vim.tbl_keys(got.registrations.atoms); table.sort(atoms)
        local inc = {}
        for l in src:gmatch('[^\n]+') do if l:match('^%s*#%s*include%s') then inc[#inc + 1] = l end end
        local L = { '#include <stdio.h>' }
        vim.list_extend(L, inc)
        L[#L + 1] = 'static Eterm cell[2], l1[2], li[2], tup[3], flt[3];'
        L[#L + 1] = 'static void mem(const Eterm *p, int n) { int i; for (i = 0; i < n; i++) printf("MEM %llx %llx\\n", (unsigned long long)(size_t)(p + i), (unsigned long long)p[i]); }'
        L[#L + 1] = 'static void row(const char *n, Eterm v) {'
        L[#L + 1] = '  printf("%s %llx\\n", n, (unsigned long long)v); }'
        L[#L + 1] = 'int main(void) {'
        for i, v in ipairs({ 0, 1, -1, 10, 256 }) do L[#L + 1] = ('  row("SMALL#%d", make_small(%d));'):format(i, v) end
        L[#L + 1] = '  row("NIL", NIL);'
        for _, c in ipairs(atoms) do L[#L + 1] = ('  row("ATOM:%s", am_%s);'):format(c, c) end
        L[#L + 1] = ('  row("ATOM", make_atom(%d));'):format(got.registrations.natoms)
        L[#L + 1] = '  row("CONS", make_list(cell));'
        L[#L + 1] = '  l1[0] = make_small(1); l1[1] = NIL; row("LIST1", make_list(l1)); mem(l1, 2);'
        L[#L + 1] = '  li[0] = make_small(1); li[1] = make_small(2); row("IMPROPER", make_list(li)); mem(li, 2);'
        L[#L + 1] = '#ifdef TUPLE2\n  row("TUPLE", TUPLE2(tup, make_small(1), NIL)); mem(tup, 3);\n#endif'
        L[#L + 1] = '#ifdef PUT_DOUBLE\n  { FloatDef f; f.fd = 1.5; PUT_DOUBLE(f, flt); row("FLOAT", make_float(flt)); mem(flt, 3); }\n#endif'
        -- (the tag families, read from the build's headers — no kind named here)
        local fam = { HEADER = {}, IMMED1 = {}, IMMED2 = {} }
        for _, p in ipairs(F.files(got, 'h')) do
            for kind, nm in (F.readfile(p) or ''):gmatch('#%s*define%s+_TAG_(%u+%d?)_([%u%d_]+)%s') do
                if fam[kind] and nm ~= 'MASK' and nm ~= 'SIZE' then fam[kind][nm] = true end
            end
        end
        for _, nm in ipairs(vim.fn.sort(vim.tbl_keys(fam.HEADER))) do
            L[#L + 1] = ('#if defined(_make_header) && defined(make_boxed)\n  { static Eterm h[4]; h[0] = _make_header(0, _TAG_HEADER_%s); row("HDR:%s", make_boxed(h)); mem(h, 4); }\n#endif'):format(nm, nm)
        end
        -- (and the tree's OWN headers — `#define HEADER_<X> _make_header(…, _TAG_HEADER_<X>)`, the exact word an
        -- `is_fun_header(x) == HEADER_FUN` compares — each followed by as many zero words as its arity says)
        local heads = {}
        for _, p in ipairs(F.files(got, 'h')) do
            for nm in (F.readfile(p) or ''):gmatch('#%s*define%s+(HEADER_[%w_]+)%s+_make_header%s*%(') do heads[nm] = true end
        end
        for _, nm in ipairs(vim.fn.sort(vim.tbl_keys(heads))) do
            L[#L + 1] = ('#if defined(%s) && defined(make_boxed) && defined(_HEADER_ARITY_OFFS)\n  { static Eterm h[18]; int n = (int)(((Uint)(%s)) >> _HEADER_ARITY_OFFS) + 1; if (n > 18) n = 18; h[0] = %s; row("HEAD:%s", make_boxed(h)); mem(h, n); }\n#endif'):format(nm, nm, nm, nm)
            -- (and the same header with its payload UNKNOWN — a stand-in for every object of that kind: a sub-binary of
            -- any bitsize, not only the zero-filled one)
            L[#L + 1] = ('#if defined(%s) && defined(make_boxed)\n  { static Eterm h[1]; h[0] = %s; row("HEAD?:%s", make_boxed(h)); mem(h, 1); }\n#endif'):format(nm, nm, nm)
        end
        for _, lvl in ipairs({ 'IMMED1', 'IMMED2' }) do
            for _, nm in ipairs(vim.fn.sort(vim.tbl_keys(fam[lvl]))) do
                L[#L + 1] = ('#ifdef _TAG_%s_SIZE\n  row("%s:%s", (Eterm)(((Uint)1 << _TAG_%s_SIZE) | _TAG_%s_%s));\n#endif'):format(lvl, lvl, nm, lvl, lvl, nm)
            end
        end
        L[#L + 1] = '  return 0; }'
        local out, why = F.run_c(table.concat(L, '\n') .. '\n', unit)
        if not out then return nil, why end
        local R = { order = {}, tag = {}, kind = 'erlterm', atoms = {}, memory = {}, ondemand = {} }
        local ffi = require 'ffi'
        local function i64(h)
            h = ('%016s'):format(h):gsub(' ', '0')
            return ffi.cast('int64_t', ffi.new('uint64_t', tonumber(h:sub(1, 8), 16)) * 2 ^ 32 + tonumber(h:sub(9), 16))
        end
        for line in out:gmatch('[^\n]+') do
            local f = vim.split(line, ' ', { plain = true })
            if f[1] == 'MEM' then R.memory[tostring(i64(f[2]))] = ('%016s'):format(f[3]):gsub(' ', '0'); goto next end
            local hex = ('%016s'):format(f[2]):gsub(' ', '0')
            R.order[#R.order + 1] = f[1]
            R.tag[f[1]] = { u64 = hex }
            do
                -- (the atoms are an ON-DEMAND family: an element only where a comparison on the paths names its word)
                local c = f[1]:match('^ATOM:(.+)$')
                if c then R.atoms[c] = f[1]; R.ondemand[f[1]] = true end
            end
            ::next::
        end
        R.order[#R.order + 1] = 'BOXED'
        R.tag.BOXED = {}
        return R
    end,
}
