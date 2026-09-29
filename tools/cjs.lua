-- cjs — TRANSLITERATE A CLOSED C REGION TO JAVASCRIPT (cartograph.cjs, CART-1197, CART-1211). Two RECIPES:
--
--   nvim --headless -u NONE -l tools/cjs.lua lstrmatch <luajit src dir> <out.js>
--   nvim --headless -u NONE -l tools/cjs.lua libmpow <AOR math dir> <out.js>
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
local USAGE = 'usage: cjs.lua lstrmatch <luajit src dir> <out.js>  |  cjs.lua libmpow <AOR math dir> <out.js>\n'
local recipe, src, out = arg[1], arg[2], arg[3]
if not (recipe == 'lstrmatch' or recipe == 'libmpow') or not (src and out) then io.stderr:write(USAGE); os.exit(2) end
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

