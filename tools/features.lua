-- features — FUNCTIONALITY THE TREE CONTAINS BUT COMPILES OUT BY DEFAULT, and how to turn it on (erlang + rebar +
-- autoconf; the library is lua/cartograph/erlfeatures.lua). Answer this BEFORE implementing something or searching
-- for it elsewhere: it may already be here, behind a configure flag.
--
--   nvim --headless -u NONE -l tools/features.lua <root> [--all]
--
-- Per gated macro: the configure switch and its DEFAULT (read from the maintainers' own help string), the rebar
-- variable, the dependencies the switch pulls in, and every -ifdef/-ifndef branch that needs it ON, with the line
-- range and the functions defined there. --all also lists features that are ON by default.
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local here = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tools/') or '.'
package.path = here .. '/lua/?.lua;' .. here .. '/lua/?/init.lua;' .. package.path
local F = require 'cartograph.erlfeatures'

local root, all = nil, false
for _, a in ipairs(arg) do
    if a == '--all' then all = true
    elseif not root then root = vim.fn.fnamemodify(vim.fn.expand(a), ':p'):gsub('/+$', '')
    else io.stderr:write('unknown argument ' .. a .. '\n'); os.exit(2) end
end
if not root then io.stderr:write('usage: features.lua <root> [--all]\n'); os.exit(2) end
local function w(s) io.write(s, '\n') end
local function rel(p) return (p:gsub('^' .. vim.pesc(root) .. '/', '')) end

local feats = F.features(root)
local off, lines = 0, 0
for _, f in ipairs(feats) do
    if f.defined_by_default == false and #f.regions > 0 then
        off = off + 1
        for _, r in ipairs(f.regions) do lines = lines + r.lines end
    end
end
w(('features  %s   gated macros %d; OFF by default with code behind them %d (%d lines compiled out)'):format(root, #feats, off, lines))
for _, f in ipairs(feats) do
    local cf = f.configure
    local show = all or (f.defined_by_default == false and #f.regions > 0)
    if show then
        w('')
        w(('  %s  %s'):format(f.macro, f.defined_by_default == false and 'OFF by default'
            or (f.defined_by_default and 'on by default' or 'default unknown')))
        if cf then w(('    enable: ./configure %s   (%s)  %s:%d'):format(cf.flag or '?', cf.desc or '', rel(cf.file), cf.line)) end
        w(('    rebar variable %s -> macro %s  %s:%d'):format(f.var, f.macro, rel(f.gate.file), f.gate.line))
        for _, d in ipairs(f.deps) do w(('    pulls in dependency %s  %s:%d'):format(d.name, rel(d.file), d.line)) end
        for _, r in ipairs(f.regions) do
            w(('    %s %s:%d-%d (%d lines)%s'):format(r.compiled_by_default and 'compiled' or 'COMPILED OUT', rel(r.file),
                r.first, r.last, r.lines, #r.functions > 0 and ('  ' .. table.concat(r.functions, ', ')) or ''))
        end
    end
end
