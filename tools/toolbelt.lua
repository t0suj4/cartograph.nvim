-- toolbelt — list, run and check the named tactics in lua/cartograph/tactics/ (CART-1152 follow-on).
--
--   nvim --headless -u NONE -l tools/toolbelt.lua list
--   nvim --headless -u NONE -l tools/toolbelt.lua run <name> <dir> [key=value ...]   (a discovery re-measures <dir>;
--                                                                                   a write tactic PREVIEWS, add apply=1)
--   nvim --headless -u NONE -l tools/toolbelt.lua examples [name]                    (run the examples: usage AND test)
--   a tactic FROM AN EXAMPLE is itself a tactic — learn into a project, then promote:
--     run learn-from-example <project> name=<n> before=@<file> after=@<file> apply=1
--     run promote-tactic <cartograph-repo> name=<n> from=<project> apply=1   (stops on the `promote` decision)
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local tb = require 'cartograph.toolbelt'
local cmd = arg[1] or 'list'
if cmd == 'list' then
    local entries, broken = tb.list(nil, arg[2] and vim.fn.fnamemodify(arg[2], ':p'):gsub('/$', '') or nil)
    for _, e in ipairs(entries) do
        io.write(('%-26s %-9s %-8s %s%s\n'):format(e.name, e.kind, e.scope, e.summary, e.measures and (' [' .. e.measures .. ']') or ''))
        for _, ex in ipairs(e.examples) do io.write(('  e.g. %s\n'):format(ex.name)) end
    end
    for k, v in pairs(broken) do io.write(('BROKEN %s: %s\n'):format(k, v)) end
elseif cmd == 'examples' then
    -- examples [name] [--dir <d>]: --dir confines the toolbelt to one directory (a new entry is validated this way)
    local only, d
    local i = 2
    while arg[i] do
        if arg[i] == '--dir' then d = arg[i + 1]; i = i + 2 else only = arg[i]; i = i + 1 end
    end
    local bad, seen = 0, 0
    local list, broken = tb.list(d)
    for name, why in pairs(broken) do
        if not only or only == name then bad = bad + 1; io.write(('%-26s FAIL  does not load: %s\n'):format(name, why)) end
    end
    for _, e in ipairs(list) do
        if not only or only == e.name then
            seen = seen + 1
            for _, ex in ipairs(e.examples) do
                local ok, why = tb.example(e, ex)
                if not ok then bad = bad + 1 end
                io.write(('%-26s %s  %s%s\n'):format(e.name, ok and 'ok  ' or 'FAIL', ex.name, ok and '' or ('\n      ' .. tostring(why))))
            end
        end
    end
    if only and seen == 0 and bad == 0 then io.write('no entry ', only, '\n'); os.exit(1) end
    os.exit(bad == 0 and 0 or 1)
elseif cmd == 'run' then
    local name, dir = arg[2], arg[3]
    if not (name and dir) then io.stderr:write('usage: run <name> <dir> [key=value ...]\n'); os.exit(2) end
    local params, apply = {}, false
    for i = 4, #arg do
        local k, v = arg[i]:match('^([%w_]+)=(.*)$')
        if k == 'apply' then apply = v == '1' elseif k then params[k] = v end
    end
    local store = require 'cartograph.store'
    store.ingest(require('cartograph.providers.treesitter').extract((vim.fn.fnamemodify(dir, ':p'):gsub('/$', ''))))
    local res, why = tb.run(store, name, params, { apply = apply })
    if not res then io.write('refused: ', tostring(why), '\n'); os.exit(1) end
    io.write(vim.inspect(res.value and { holds = res.holds, why = res.why, value = res.value }
        or { status = res.status, class = res.class, why = res.why, applied = res.applied, residue = res.residue }), '\n')
else
    io.stderr:write('toolbelt: unknown command ' .. cmd .. '\n'); os.exit(2)
end
