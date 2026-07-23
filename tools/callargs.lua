-- callargs — is c.args derivable from c.argv? ([[cartograph-thin-index]] lossless narrowing).
-- args[i] is the OLD flat string value; argv[i] = { k, name, v, ... }. argv.str reads the
-- folded v-column OR (args[i] or ''), so the canonical flat value SHOULD be recoverable from
-- argv[i].v. If args[i] == (argv[i].v or '') for EVERY arg of EVERY call, args is redundant
-- with argv and can be dropped (derived on read via argv). args is 100%-present and an ARRAY,
-- so dropping it could be the biggest lossless win. Reports the match rate + args entry volume.
--
--   nvim --headless -u NONE -l tools/callargs.lua [corpus]   (default: libs)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'

local name = arg[1] or 'libs'
local data = bench.extract_parallel(name)
local calls = data.calls or {}
if data._callstore then calls = require('cartograph.rescols').materialize(data._callstore) end

local with_args, entries, entry_ok = 0, 0, 0
local calls_all_ok, len_mismatch = 0, 0
local first = {}
for _, c in ipairs(calls) do
    local a = c.args
    if a then
        with_args = with_args + 1
        local av = c.argv or {}
        if #a ~= #av then len_mismatch = len_mismatch + 1 end
        local all = true
        for i = 1, #a do
            entries = entries + 1
            local flat = a[i] or ''
            local vv = (av[i] and av[i].v) or ''
            if flat == vv then entry_ok = entry_ok + 1
            else
                all = false
                if #first < 6 then first[#first + 1] = ('%s[%d]: args=%q argv.v=%q'):format(
                    c.callee or c.full or '?', i, tostring(a[i]), tostring(av[i] and av[i].v)) end
            end
        end
        if all then calls_all_ok = calls_all_ok + 1 end
    end
end

print(('callargs %s — %d calls, %d with args'):format(name, #calls, with_args))
print(('  args entries: %d  ·  args[i] == (argv[i].v or "") : %d  (%.2f%%)')
    :format(entries, entry_ok, entries > 0 and 100 * entry_ok / entries or 0))
print(('  calls whose args are FULLY derivable from argv: %d / %d  (%.2f%%)  ·  length mismatches: %d')
    :format(calls_all_ok, with_args, with_args > 0 and 100 * calls_all_ok / with_args or 0, len_mismatch))
for _, s in ipairs(first) do print('    mismatch: ' .. s) end
if entry_ok == entries and len_mismatch == 0 then
    print('  ✓ args is REDUNDANT with argv — droppable (derive args[i] = argv.str(c,i))')
else
    print('  ✗ args carries values argv.v does not — NOT purely derivable')
end
vim.cmd('qall!')
