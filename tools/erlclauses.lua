-- erlclauses — WHICH CLAUSE EACH CALL REACHES, and the clauses no call reaches (CART-1110; the client/server merge
-- one altitude down: a call site is its callee's peer, CART-1138). Library: lua/cartograph/erlclauses.lua.
--
--   nvim --headless -u NONE -l tools/erlclauses.lua [<root>] [--rows]
--
-- <root> defaults to ~/work/brotardcast/ejabberd (its src/, include/; the xmpp dependency at ~/git/xmpp). Printed:
-- call sites to multi-clause functions split exact / possible / none (a none is a function_clause crash waiting, or
-- a gap in reading the arguments), and the clauses no call reaches in functions whose callers are all in their module
-- (not exported, not a fun value, one definition).
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local here = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tools/') or '.'
package.path = here .. '/lua/?.lua;' .. here .. '/lua/?/init.lua;' .. package.path
vim.opt.rtp:prepend(here)
local root, want_rows = nil, false
for _, a in ipairs(arg) do if a == '--rows' then want_rows = true else root = a end end
root = vim.fn.expand(root or '~/work/brotardcast/ejabberd')
local function print(line) io.write(line, '\n') end
local EC = require 'cartograph.erlclauses'
local ER = require 'cartograph.erlrecords'
local E = ER.new { include_dirs = { root .. '/include' }, apps = { xmpp = vim.fn.expand('~/git/xmpp') } }
local t0 = vim.uv.hrtime()
local rows, st, un = EC.census(root .. '/src', { E = E })
print(('erlclauses  %s  (%.0f ms)'):format(root, (vim.uv.hrtime() - t0) / 1e6))
print(('  call sites to multi-clause functions %d: exact %d, possible %d, NONE %d'):format(st.sites, st.exact, st.possible, st.none))
print(('  multi-clause functions %d (%d clauses): exported %d, taken as a fun value %d, preprocessor variants %d — '
    .. 'the rest have every caller in their module'):format(st.functions, st.clauses, st.exported_skipped,
    st.fun_values or 0, st.variants or 0))
print(('  clauses no call reaches: %d'):format(st.unreached))
for _, u in ipairs(un) do print(('    %s:%d  %s clause #%d'):format(u.file, u.line, u.callee, u.clause)) end
if want_rows then
    for _, r in ipairs(rows) do
        if r.kind == 'none' then print(('  NONE %s:%d %s -> %s'):format(r.file, r.line, tostring(r.caller), r.callee)) end
    end
end
