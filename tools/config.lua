-- config — the EFFECTIVE configuration for a subject, with the entry that decided each value (CART-1120).
--
--   nvim --headless -u NONE -l tools/config.lua at <path> [key]
-- Reads the user's setup{} the way a session does only if it is loaded; run it from a session (:lua) for the live
-- scoped table, or pass `--setup <file.lua>` returning the options table to apply first.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path
local config = require 'cartograph.config'
local args, i = {}, 1
while arg[i] do
    if arg[i] == '--setup' then config.apply(dofile(arg[i + 1])); i = i + 2 else args[#args + 1] = arg[i]; i = i + 1 end
end
if args[1] ~= 'at' or not args[2] then io.stderr:write('usage: at <path> [key] [--setup <file.lua>]\n'); os.exit(2) end
local subject = vim.fn.fnamemodify(args[2], ':p')
local rows = args[3] and { [args[3]] = { config.at(subject, args[3]) } } or {}
if not args[3] then for k, r in pairs(config.explain(subject)) do rows[k] = { r.value, r.provenance } end end
local keys = vim.tbl_keys(rows); table.sort(keys)
if #keys == 0 then io.write('no scoped setting covers ', subject, '\n') end
for _, k in ipairs(keys) do
    local v, prov = rows[k][1], rows[k][2] or {}
    local from = prov.source == 'scoped' and ('scoped:' .. tostring(prov.scope)) or prov.source
    if prov.source == 'ambiguous' then
        local e = {}
        for _, r in ipairs(prov.entries) do e[#e + 1] = ('%s = %s'):format(r.scope, vim.inspect(r.value)) end
        from = 'AMBIGUOUS: ' .. table.concat(e, ' | ')
    end
    io.write(('%-22s %-30s %s\n'):format(k, vim.inspect(v), from))
end
