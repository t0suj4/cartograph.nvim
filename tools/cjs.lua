-- cjs — TRANSLITERATE A CLOSED C REGION TO JAVASCRIPT (cartograph.cjs, CART-1197). One RECIPE today:
--
--   nvim --headless -u NONE -l tools/cjs.lua lstrmatch <luajit src dir> <out.js>
--
-- lstrmatch: LuaJIT's Lua-pattern matcher (src/lib_string.c: classend … match, push_captures) with the class table it
-- reads (src/lj_char.c: lj_char_bits). The HOST COMPILER preprocesses both (`gcc -E -P -I<src>`), so every macro is
-- expanded by the compiler that builds LuaJIT, never re-typed. The Lua C-API calls the region makes are the declared
-- TEMPLATES below (the only hand-written mapping, one line each); anything else the region needs is refused by name.
-- The output's header names the source, its git commit and this command. Refusals print and fail the run.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local recipe, src, out = arg[1], arg[2], arg[3]
if recipe ~= 'lstrmatch' or not (src and out) then
    io.stderr:write('usage: cjs.lua lstrmatch <luajit src dir> <out.js>\n'); os.exit(2)
end
src = vim.fn.fnamemodify(src, ':p'):gsub('/$', '')
local function cpp(file)
    local r = vim.system({ 'gcc', '-E', '-P', '-I' .. src, src .. '/' .. file }, { text = true }):wait()
    if r.code ~= 0 then io.stderr:write('gcc -E ', file, ' failed: ', r.stderr or '', '\n'); os.exit(1) end
    return r.stdout
end
local commit = vim.trim(vim.system({ 'git', '-C', src, 'rev-parse', 'HEAD' }, { text = true }):wait().stdout or '?')
local C = require 'cartograph.cjs'
local js, refusals, info = C.emit({ { text = cpp('lib_string.c'), name = 'lib_string.c' }, { text = cpp('lj_char.c'), name = 'lj_char.c' } }, {
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
for _, r in ipairs(refusals) do io.stderr:write('REFUSED ', r.kind, ': ', r.why, ' (preprocessed line ', r.line, ')\n') end
if #refusals > 0 then os.exit(1) end
js = js:gsub('module%.exports = { ', 'module.exports = { bind, ', 1)
local f = assert(io.open(out, 'w')); f:write(js); f:close()
io.write(('%s: %d function(s) (%s), %d table(s) in the heap image, %d LuaJIT message(s), 0 refusals\n')
    :format(out, #info.functions, table.concat(info.functions, ' '), #info.globals, vim.tbl_count(info.messages)))
