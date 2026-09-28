-- decisions — the user's REMEMBERED DECISIONS (cartograph.decisions, CART-1160 step 6): answer a tactic's question once.
--
--   nvim --headless -u NONE -l tools/decisions.lua list
--   nvim --headless -u NONE -l tools/decisions.lua remember kind=<kind> key=<key> [why=...]      this exact question
--   nvim --headless -u NONE -l tools/decisions.lua remember kind=<kind> dir=<dir> [why=...]      every <kind> under a dir
--   nvim --headless -u NONE -l tools/decisions.lua remember kind=<kind> file=<file> [why=...]    every <kind> about a file
--   nvim --headless -u NONE -l tools/decisions.lua forget <id>
-- A stopped run prints its options with each question's `key` (tools/toolbelt.lua run ...). The record is yours: it
-- lives in the state directory, and no MCP verb writes it.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path
local D = require 'cartograph.decisions'
local cmd = arg[1] or 'list'
if cmd == 'list' then
    local list = D.list()
    if #list == 0 then io.write('no remembered decisions (', D.path, ')\n') end
    for _, e in ipairs(list) do
        local where = e.scope.exact and ('exact ' .. e.scope.exact) or ('under ' .. tostring(e.scope.dir or e.scope.file))
        io.write(('%s  %-18s %s  %s%s\n'):format(e.id, e.kind, e.at, where, e.why and ('  — ' .. e.why) or ''))
    end
elseif cmd == 'remember' then
    local what = {}
    for i = 2, #arg do
        local k, v = arg[i]:match('^([%w_]+)=(.*)$')
        if k then what[k] = v end
    end
    local e, why = D.remember(what)
    if not e then io.write('refused: ', tostring(why), '\n'); os.exit(1) end
    io.write('remembered ', e.id, '\n')
elseif cmd == 'forget' then
    local ok, why = D.forget(arg[2])
    if not ok then io.write('refused: ', tostring(why), '\n'); os.exit(1) end
    io.write('forgot ', arg[2], '\n')
else
    io.stderr:write('decisions: unknown command ' .. cmd .. '\n'); os.exit(2)
end
