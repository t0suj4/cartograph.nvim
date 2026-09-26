-- tsdump — a tree-sitter parse with FIELD NAMES and ANONYMOUS TOKENS, or the diff between two builds of a grammar.
--
--   nvim --headless -u NONE -l tools/tsdump.lua <lang> <file|-> [--named] [--view] [--parser <so>] [--vs <so>]
--
--   <file|->        a source file, or `-` for stdin (a snippet: `printf 'x = global.f\n' | ... lua -`)
--   --named         named nodes only (default also prints anonymous tokens, quoted)
--   --view          parse cartograph's parse VIEW (lua: `global` masked for a pre-5.5 dialect, luadialect.lua)
--   --parser <so>   use this parser build instead of the one the runtimepath loads
--   --vs <so>       print a unified diff: runtimepath (or --parser) build vs this build. The previous nvim's bundled
--                   parsers live under bob, e.g. ~/.local/share/bob/v0.11.5/lib/nvim/parser/lua.so
--
-- The library is lua/cartograph/tsdump.lua (and why this exists is written there).
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local here = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tools/') or '.'
package.path = here .. '/lua/?.lua;' .. here .. '/lua/?/init.lua;' .. package.path
local tsdump = require 'cartograph.tsdump'

local lang, file = arg[1], arg[2]
if not (lang and file) then
    io.stderr:write('usage: tsdump.lua <lang> <file|-> [--named] [--view] [--parser <so>] [--vs <so>]\n')
    os.exit(2)
end
local opts, vs = {}, nil
local i = 3
while arg[i] do
    local a = arg[i]
    if a == '--named' then opts.anon = false
    elseif a == '--view' then opts.view = true
    elseif a == '--parser' then i = i + 1; opts.parser = vim.fn.expand(arg[i])
    elseif a == '--vs' then i = i + 1; vs = vim.fn.expand(arg[i])
    else io.stderr:write('unknown option ' .. a .. '\n'); os.exit(2) end
    i = i + 1
end
local src
if file == '-' then src = io.read('a') else
    local fd = assert(io.open(file, 'rb')); src = fd:read('a'); fd:close()
end
if vs then
    local d = tsdump.diff(src, lang, opts.parser, vs, opts)
    io.write(d == '' and '(identical trees)\n' or d)
else
    io.write(table.concat(tsdump.lines(src, lang, opts), '\n'), '\n')
end
