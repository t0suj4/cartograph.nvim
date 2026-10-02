-- cjs — TRANSLITERATE A CLOSED C REGION TO JAVASCRIPT (cartograph.cjs, CART-1197, CART-1211). The RECIPES:
--
--   nvim --headless -u NONE -l tools/cjs.lua lstrmatch <luajit src dir> <out.js>
--   nvim --headless -u NONE -l tools/cjs.lua libmpow <AOR math dir> <out.js>
--   nvim --headless -u NONE -l tools/cjs.lua strscan <BUILT luajit src dir> <out.js>   (tonumber's scanner)
--   nvim --headless -u NONE -l tools/cjs.lua strfmt <BUILT luajit src dir> <out.js>    (tostring's formatter)
--
-- strscan / strfmt: EXACT HEAP mode over a tree tools/packmap.lua builds at the oracle's revision (see luajit_build).
--
-- libmpow: pow() as LuaJIT gets it from glibc — Arm optimized-routines pow (AOR_v20.02/math: pow.c + its tables +
-- math_err.c), preprocessed with -mfma, in cjs's EXACT mode (64-bit and unsigned C arithmetic). See the recipe below.
--
-- lstrmatch: LuaJIT's Lua-pattern matcher (src/lib_string.c: classend … match, push_captures) with the class table it
-- reads (src/lj_char.c: lj_char_bits). The HOST COMPILER preprocesses both (`gcc -E -P -I<src>`), so every macro is
-- expanded by the compiler that builds LuaJIT, never re-typed. The Lua C-API calls the region makes are the declared
-- TEMPLATES below (the only hand-written mapping, one line each); anything else the region needs is refused by name.
-- The output's header names the source, its git commit and this command. Refusals print and fail the run.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local USAGE = 'usage: cjs.lua lstrmatch <luajit src dir> <out.js>  |  cjs.lua libmpow <AOR math dir> <out.js>'
    .. '  |  cjs.lua strscan <BUILT luajit src dir> <out.js>  |  cjs.lua strfmt <BUILT luajit src dir> <out.js>\n'
local recipe, src, out = arg[1], arg[2], arg[3]
if not (recipe == 'lstrmatch' or recipe == 'libmpow' or recipe == 'strscan' or recipe == 'strfmt') or not (src and out) then io.stderr:write(USAGE); os.exit(2) end
src = vim.fn.fnamemodify(src, ':p'):gsub('/$', '')
local function cpp(file, flags)
    local cmd = { 'gcc', '-E', '-P' }
    for _, f in ipairs(flags or {}) do cmd[#cmd + 1] = f end
    vim.list_extend(cmd, { '-I' .. src, src .. '/' .. file })
    local r = vim.system(cmd, { text = true }):wait()
    if r.code ~= 0 then io.stderr:write('gcc -E ', file, ' failed: ', r.stderr or '', '\n'); os.exit(1) end
    return r.stdout
end
local C = require 'cartograph.cjs'
local js, refusals, info
--- the shared setup of a recipe over a BUILT LuaJIT tree (strscan, strfmt): the build's own compile flags (its make,
--- asked for one object's command line), a C ADAPTER written beside the tree, the preprocessor with those flags
--- (`__attribute__` defined away: tree-sitter's C grammar cannot parse one before `=`), TValue's LAYOUT and every
--- sizeof from the COMPILER (cartograph.cjs.compiler_layout / _sizes — cjs never re-derives C layout rules) read over
--- `root_c` (else the adapter), and the tree's revision (git, else the REV file tools/packmap.lua writes beside it)
local function luajit_build(dir, adapter_name, adapter_text, root_c)
    local B = { cflags = {} }
    for line in (vim.system({ 'make', '-n', 'lj_err.o' }, { cwd = dir, text = true }):wait().stdout or ''):gmatch('[^\n]+') do
        if line:match('%-c %-o lj_err%.o lj_err%.c') then
            for flag in line:gmatch('%S+') do if flag:match('^%-[DU]') then B.cflags[#B.cflags + 1] = flag end end
        end
    end
    B.tmp = vim.fn.tempname()
    vim.fn.mkdir(B.tmp, 'p')
    B.adapter = B.tmp .. '/' .. adapter_name
    local fd = assert(io.open(B.adapter, 'w')); fd:write(adapter_text); fd:close()
    function B.pp(path)
        local cmd = { 'gcc', '-E', '-P', '-D__attribute__(x)=' }
        vim.list_extend(cmd, B.cflags)
        vim.list_extend(cmd, { '-I' .. dir, path })
        local r = vim.system(cmd, { text = true }):wait()
        if r.code ~= 0 then io.stderr:write('gcc -E ', path, ': ', r.stderr or '', '\n'); os.exit(1) end
        return r.stdout
    end
    B.ppadapter = B.pp(B.adapter)
    B.ppsrc = root_c and B.pp(root_c) or B.ppadapter
    local copts = { src = B.ppsrc, header = 'lj_obj.h', include = dir, cflags = B.cflags }
    local desc
    B.layout, desc = C.compiler_layout(vim.tbl_extend('force', copts, { type = 'TValue' }))
    if not B.layout then io.stderr:write(tostring(desc), '\n'); os.exit(1) end
    B.desc = desc
    local swhy
    B.sizes, swhy = C.compiler_sizes(copts)
    if not B.sizes then io.stderr:write(tostring(swhy), '\n'); os.exit(1) end
    B.commit = vim.trim(vim.system({ 'git', '-C', dir, 'rev-parse', '--short', 'HEAD' }, { text = true }):wait().stdout or '')
    if B.commit == '' then
        local rf = io.open(dir .. '/../REV')
        if rf then B.commit = vim.trim(rf:read('a')); rf:close() end
    end
    if B.commit == '' then B.commit = '(no git)' end
    return B
end
if recipe == 'lstrmatch' then
    local commit = vim.trim(vim.system({ 'git', '-C', src, 'rev-parse', 'HEAD' }, { text = true }):wait().stdout or '?')
    js, refusals, info = C.emit({ { text = cpp('lib_string.c'), name = 'lib_string.c' }, { text = cpp('lj_char.c'), name = 'lj_char.c' } }, {
        roots = { 'match', 'push_captures' },
        templates = {
            lj_err_caller = '$cerr($2)',          -- raise the Lua error with LuaJIT's own message (derived from the enum)
            memcmp = '$memcmp($1, $2, $3)',       -- over the heap
            lua_pushlstring = '$push($1, $str($2, $3))',
            lua_pushinteger = '$push($1, $2)',
            luaL_checkstack = 'void 0',           -- a JS array stack cannot overflow
        },
        prelude = 'let $cerr, $memcmp, $push, $str;\nfunction bind(env) { ({ $cerr, $memcmp, $push, $str } = env); }',
        header = table.concat({
            '// GENERATED — do not edit. LuaJIT\'s Lua-pattern matcher, TRANSLITERATED from C by cartograph.cjs (CART-1197):',
            '//   source   src/lib_string.c + src/lj_char.c (lj_char_bits), LuaJIT git ' .. commit,
            '//   command  nvim --headless -u NONE -l tools/cjs.lua lstrmatch <luajit src dir> lua/cartograph/luajs/lstrmatch.js',
        }, '\n'),
    })
elseif recipe == 'strfmt' then
    -- strfmt: LuaJIT's number -> string formatter (lj_strfmt_num.c: lj_strfmt_wfnum, the %a/%e/%f/%g engine), under
    -- tostring(n), concatenation and every number printed. x64 LuaJIT has no integer fast path (no DUALNUM): every
    -- number is `lj_strfmt_wfnum(NULL, STRFMT_G14, n, buf)` (lj_strfmt_num). <src> as strscan's.
    -- THE ROOT: lj_strfmt_num's own body with its GCstr result replaced by the byte count (wfnum is static: the
    -- adapter INCLUDES its file)
    local B = luajit_build(src, 'cjs_strfmt.c', table.concat({
        '#include "lj_strfmt_num.c"',
        'MSize cjs_numstr(lua_Number n, char *p)',
        '{',
        '  return (MSize)(lj_strfmt_wfnum(NULL, STRFMT_G14, n, p) - p);',
        '}',
        -- (string.format's %e / %f / %g: the same engine under any SFormat — type, width, precision, flags — as
        -- lj_strfmt_putfnum runs it)
        'MSize cjs_fmtnum(SFormat sf, lua_Number n, char *p)',
        '{',
        '  return (MSize)(lj_strfmt_wfnum(NULL, sf, n, p) - p);',
        '}', '' }, '\n'), nil)
    -- the buffer lj_strfmt_num gives it: STRFMT_MAXBUF_NUM, from the preprocessor
    local probe = B.tmp .. '/maxbuf.c'
    local fd = assert(io.open(probe, 'w')); fd:write('#include "lj_strfmt.h"\ncjs_maxbuf STRFMT_MAXBUF_NUM\n'); fd:close()
    local maxbuf = tonumber(B.pp(probe):match('cjs_maxbuf%s+(%d+)'))
    if not maxbuf then io.stderr:write('STRFMT_MAXBUF_NUM did not preprocess to a number\n'); os.exit(1) end
    js, refusals, info = C.emit({ { text = B.ppadapter, name = 'cjs_strfmt.c' }, { text = B.pp(src .. '/lj_strfmt.c'), name = 'lj_strfmt.c' } }, {
        exact = true,
        roots = { 'cjs_numstr', 'cjs_fmtnum' },
        heap = { types = { TValue = B.layout }, stack = 65536 },
        sizes = B.sizes,
        -- the shared compiler builtins (cartograph.cjs.BUILTINS; memcmp over the heap, below), and this recipe's SEAM:
        -- the adapter always passes a buffer, so wfnum's "grow the SBuf" branch is unreachable, and breaks by name
        templates = vim.tbl_extend('force', {}, C.BUILTINS, {
            lj_buf_more = { js = '$crefuse("lj_buf_more: the adapter always passes a buffer")', ret = 'u32' },
        }),
        prelude = 'const $memcmp = (a, b, n) => { for (let i = 0; i < n; i++) { const d = H[a + i] - H[b + i]; if (d) return d; } return 0; };',
        epilogue = table.concat({
            '/** a number -> its Lua string (tostring / concatenation): LuaJIT\'s %.14g, into a ' .. maxbuf .. '-byte heap buffer',
            ' *  (STRFMT_MAXBUF_NUM, as lj_strfmt_num gives it), read back as a JS string of bytes */',
            'function numstr(x) {',
            '  const $sp = SP;',
            '  try {',
            '    const p = $alloca(' .. maxbuf .. ');',
            '    const len = cjs_numstr(x, p);',
            '    let s = \'\';',
            '    for (let i = 0; i < len; i++) s += String.fromCharCode(H[p + i]);',
            '    return s;',
            '  } finally { SP = $sp; }',
            '}',
            '/** a number under a string.format SFormat (%e / %f / %g with their width, precision and flags) -> its bytes as a',
            ' *  JS string. The buffer: format\'s width and precision are at most 99, and %f of the largest double is 309',
            ' *  integer digits — sign + 309 + point + 99 < 512 */',
            'function fmtnum(sf, x) {',
            '  const $sp = SP;',
            '  try {',
            '    const p = $alloca(512);',
            '    const len = cjs_fmtnum(sf >>> 0, x, p);',
            '    let s = \'\';',
            '    for (let i = 0; i < len; i++) s += String.fromCharCode(H[p + i]);',
            '    return s;',
            '  } finally { SP = $sp; }',
            '}',
        }, '\n'),
        exports = { 'numstr', 'fmtnum' },
        header = table.concat({
            '// GENERATED — do not edit. LuaJIT\'s number formatter, TRANSLITERATED from C by cartograph.cjs (exact heap mode,',
            '// CART-1211 leaf 3):',
            '//   source   src/lj_strfmt_num.c (lj_strfmt_wfnum …) + src/lj_strfmt.c (lj_strfmt_wint), LuaJIT ' .. B.commit .. ' — the ORACLE\'s revision',
            '//   root     cjs_numstr = lj_strfmt_num\'s body, its GCstr result replaced by the byte count; cjs_fmtnum = the same',
            '//            engine under any SFormat (string.format\'s %e / %f / %g)',
            '//   flags    gcc -E -P -D__attribute__(x)= ' .. table.concat(B.cflags, ' ') .. ' (the build\'s own, from its make)',
            '//   layout   TValue ' .. tostring(B.layout.size) .. ' bytes: ' .. table.concat(B.desc, ' ') .. ' (the compiler\'s: offsetof/sizeof/classify)',
            '//   command  nvim --headless -u NONE -l tools/cjs.lua strfmt <BUILT luajit src dir> lua/cartograph/luajs/strfmt.js',
            '// LuaJIT: Copyright (C) 2005-2026 Mike Pall. MIT license (its COPYRIGHT file).',
        }, '\n'),
    })
    vim.fn.delete(B.tmp, 'rf')
elseif recipe == 'strscan' then
    -- strscan: LuaJIT's string -> number scanner (lj_strscan.c), under tonumber(s) and every string->number arithmetic
    -- coercion. <src> is a BUILT LuaJIT src dir at the ORACLE's revision (tools/packmap.lua leaves one under
    -- ~/.cache/nvim/cartograph/packmap/<rev>/src: git archive + LuaJIT's make for its generated headers).
    -- THE ROOT: lj_strscan_num's own body (lj_strscan.c) with its GCstr accessor (strdata(str), str->len) replaced by
    -- (p, len) — the one hand-written line; the preprocessor resolves STRSCAN_OPT_TONUM / STRSCAN_ERROR as LuaJIT's
    local B = luajit_build(src, 'cjs_strscan.c', table.concat({
        '#include "lj_strscan.h"',
        'int cjs_tonum(const uint8_t *p, MSize len, TValue *o)',
        '{',
        '  return lj_strscan_scan(p, len, o, STRSCAN_OPT_TONUM) != STRSCAN_ERROR;',
        '}', '' }, '\n'), src .. '/lj_strscan.c')
    local cflags, pp, tmp, adapter, ppsrc, layout, desc, sizes, commit = B.cflags, B.pp, B.tmp, B.adapter, B.ppsrc, B.layout, B.desc, B.sizes, B.commit

    js, refusals, info = C.emit({ { text = pp(adapter), name = 'cjs_strscan.c' }, { text = ppsrc, name = 'lj_strscan.c' },
        { text = pp(src .. '/lj_char.c'), name = 'lj_char.c' } }, {
        exact = true,
        roots = { 'cjs_tonum' },
        heap = { types = { TValue = layout }, stack = 65536 },
        sizes = sizes,
        -- the shared compiler builtins (cartograph.cjs.BUILTINS: ldexp and clzll from fpu.js), and the VM ASSEMBLY
        -- this scanner calls, read from vm_x64.dasc (fpu.js)
        templates = vim.tbl_extend('force', {}, C.BUILTINS, { lj_vm_num2int_check = '$num2int_check($1)' }),
        prelude = "const { $ldexp, $clz64, $num2int_check } = require('./$fpu.js');",
        epilogue = table.concat({
            '/** a Lua string (a JS string of bytes) -> its number, or undefined when LuaJIT reads none: the bytes and a',
            ' *  NUL (the scanner reads its terminator, as a GCstr has one) and an 8-byte TValue on the heap stack */',
            'function tonum(s) {',
            '  const $sp = SP;',
            '  try {',
            '    const p = $alloca(s.length + 1);',
            '    for (let i = 0; i < s.length; i++) H[p + i] = s.charCodeAt(i);',
            '    H[p + s.length] = 0;',
            '    const o = $alloca(' .. layout.size .. ');',
            '    return cjs_tonum(p, s.length, o) ? DV.getFloat64(o + ' .. layout.fields.n.off .. ', true) : undefined;',
            '  } finally { SP = $sp; }',
            '}',
        }, '\n'),
        exports = { 'tonum' },
        header = table.concat({
            '// GENERATED — do not edit. LuaJIT\'s string -> number scanner, TRANSLITERATED from C by cartograph.cjs (exact',
            '// heap mode, CART-1211 leaf 3):',
            '//   source   src/lj_strscan.c (lj_strscan_scan …) + src/lj_char.c (lj_char_bits), LuaJIT ' .. (commit ~= '' and commit or '(no git)') .. ' — the ORACLE\'s revision',
            '//   root     cjs_tonum = lj_strscan_num\'s body with its GCstr accessor replaced by (p, len)',
            '//   flags    gcc -E -P -D__attribute__(x)= ' .. table.concat(cflags, ' ') .. ' (the build\'s own, from its make)',
            '//   layout   TValue ' .. tostring(layout.size) .. ' bytes: ' .. table.concat(desc, ' ') .. ' (the compiler\'s: offsetof/sizeof/classify)',
            '//   command  nvim --headless -u NONE -l tools/cjs.lua strscan <BUILT luajit src dir> lua/cartograph/luajs/strscan.js',
            '// LuaJIT: Copyright (C) 2005-2026 Mike Pall. MIT license (its COPYRIGHT file).',
        }, '\n'),
    })
    vim.fn.delete(tmp, 'rf')
else
    -- libmpow: the pow() LuaJIT calls — glibc's, which is Arm's optimized-routines pow (AOR) in its FMA build on this
    -- CPU (MEASURED: glibc 2.39 pow == AOR v20.02 pow compiled -mfma on 5,998,564 of 5,998,564 inputs; the non-FMA build
    -- differs on 2,482). The HOST COMPILER preprocesses with -mfma so the FMA path is the one it selects; `exact` gives
    -- C's 64-bit and unsigned arithmetic; the TEMPLATES are the hardware (fma, bit casts) and compiler builtins.
    -- `__attribute__` is defined AWAY: tree-sitter's C grammar cannot parse one between a declarator and its `=`
    -- (math_config.h: `volatile double y __attribute__ ((unused)) = x;` — an ERROR node, the function lost), and no
    -- attribute here (visibility, noinline, unused) has a meaning a transliteration keeps
    local FLAGS = { '-mfma', '-D__attribute__(x)=', '-I' .. src .. '/include' }
    local srcs = {}
    for _, f in ipairs { 'pow.c', 'pow_log_data.c', 'exp_data.c', 'math_err.c' } do srcs[#srcs + 1] = { text = cpp(f, FLAGS), name = f } end
    -- ★ CONTRACTION, FROM THE COMPILER: gcc -mfma also FUSES plain `a*b + c` into FMA instructions (-ffp-contract=fast,
    -- GNU C's default), and glibc's pow is that build — MEASURED: AOR -mfma matches glibc on 5,998,564 of 5,998,564
    -- inputs, AOR -mfma -ffp-contract=off on 5,996,100. Which additions it fuses is the compiler's decision (inlining,
    -- basic blocks, single-use products), so it is READ from its own GIMPLE dump of the SAME preprocessed text: every
    -- .FMA/.FMS/.FNMA/.FNMS statement's [file:line:col] names the fused addition (an explicit fma() call included)
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    local fd = assert(io.open(tmp .. '/pow_pp.c', 'w')); fd:write(srcs[1].text); fd:close()
    local r = vim.system({ 'gcc', '-O2', '-mfma', '-c', 'pow_pp.c', '-o', 'pow_pp.o', '-fdump-tree-widening_mul-lineno' }, { cwd = tmp, text = true }):wait()
    if r.code ~= 0 then io.stderr:write('gcc (the contraction dump) failed: ', r.stderr or '', '\n'); os.exit(1) end
    local dump = vim.fn.glob(tmp .. '/*.widening_mul', false, true)[1]
    local sites, nsites = {}, 0
    -- (ONE value: assert returns its message too, and io.lines reads a second argument as a FORMAT — measured: 'n…'
    -- read numbers, and every line came back nil)
    for line in io.lines((assert(dump, 'no widening_mul dump'))) do
        local l, c = line:match('%[pow_pp%.c:(%d+):(%d+)[^%]]*%]%s+[%w_]+%s*=%s*%.FN?M[AS]%s*%(')
        if l then sites[l .. ':' .. c] = true; nsites = nsites + 1 end
    end
    vim.fn.delete(tmp, 'rf')
    if nsites == 0 then io.stderr:write('the contraction dump names no FMA site — the premise (an FMA build) failed\n'); os.exit(1) end
    -- ⚠ SITES ARE KEYED BY SOURCE POSITION, which is sound because each helper (log_inline, exp_inline, specialcase) is
    -- inlined ONCE into pow: a helper inlined twice with different fusions would be read as one. A second libm function
    -- sharing helpers needs per-instance sites (the dump's statements carry the inlined instance)
    -- the facts that DECIDE the output: which gcc made the contraction decisions, which glibc they were matched against
    local gcc_v = vim.trim((vim.system({ 'gcc', '--version' }, { text = true }):wait().stdout or '?'):match('[^\n]*'))
    local libc_v = vim.trim((vim.system({ 'ldd', '--version' }, { text = true }):wait().stdout or '?'):match('[^\n]*'))
    js, refusals, info = C.emit(srcs, {
        exact = true,
        contract = { ['pow.c'] = sites },
        roots = { 'pow' },
        templates = {
            asuint64 = '$asu64($1)', asdouble = '$asd($1)', -- C's union bit casts (their bodies are unions)
            fma = '$fma($1, $2, $3)',                        -- the FMA instruction, exact (lua/cartograph/luajs/fpu.js)
            fabs = 'Math.abs($1)',
            __builtin_fabs = 'Math.abs($1)',
            __builtin_expect = { js = '$1', ret = 'arg1' },
            __builtin_inff = { js = 'Infinity', ret = 'double' },
            __builtin_inf = { js = 'Infinity', ret = 'double' },
            __builtin_isnan = { js = '+Number.isNaN($1)', ret = 'i32' },
            __builtin_isinf_sign = { js = '(($1) === Infinity ? 1 : ($1) === -Infinity ? -1 : 0)', ret = 'i32' },
        },
        prelude = "const { $fma, $asu64, $asd } = require('./$fpu.js');",
        header = table.concat({
            '// GENERATED — do not edit. pow() as glibc runs it: Arm optimized-routines pow, TRANSLITERATED from C by',
            '// cartograph.cjs in exact mode (CART-1211):',
            '//   source   ' .. vim.fn.fnamemodify(src, ':~') .. ' (pow.c, pow_log_data.c, exp_data.c, math_err.c), preprocessed',
            '//            gcc -E -P -mfma -D__attribute__(x)= -I<dir> -I<dir>/include — the FMA build glibc selects on an FMA CPU',
            '//            + the multiply-adds gcc -O2 -mfma FUSES (-ffp-contract=fast), read from its widening_mul dump',
            '//   decided by  ' .. gcc_v .. ' (the contraction sites are its decisions)',
            '//   matched to  ' .. libc_v .. ' — its pow on an FMA CPU (the FMA ifunc path): 5,998,564 of 5,998,564 inputs',
            '//   command  nvim --headless -u NONE -l tools/cjs.lua libmpow <AOR math dir> lua/cartograph/luajs/libmpow.js',
            '// The C source: Copyright (c) 2018, Arm Limited. SPDX-License-Identifier: MIT (as its files state).',
        }, '\n'),
    })
end
for _, r in ipairs(refusals) do io.stderr:write('REFUSED ', r.kind, ': ', r.why, ' (preprocessed line ', r.line, ')\n') end
if #refusals > 0 then os.exit(1) end
if #(info.unresolved_sites or {}) > 0 then
    -- a compiler FMA site that named no addition in an emitted function: its contraction would be LOST, silently
    io.stderr:write('UNRESOLVED contraction sites: ', table.concat(info.unresolved_sites, ' '), '\n')
    os.exit(1)
end
if recipe == 'lstrmatch' then js = js:gsub('module%.exports = { ', 'module.exports = { bind, ', 1) end
local f = assert(io.open(out, 'w')); f:write(js); f:close()
io.write(('%s: %d function(s) (%s), %d table(s) in the heap image, %d message(s), 0 refusals\n')
    :format(out, #info.functions, table.concat(info.functions, ' '), #info.globals, vim.tbl_count(info.messages)))

