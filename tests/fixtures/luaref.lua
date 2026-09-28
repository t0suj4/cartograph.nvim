-- tests/fixtures/luaref.lua — run a Lua FILE with the STANDARD print (tab-joined tostring, to stdout), not nvim's:
-- the reference side of the luajs differential tests that need a real file (debug.getinfo's source is its path)
local out = {}
local env = setmetatable({ print = function (...)
    local t = {}
    for i = 1, select('#', ...) do t[i] = tostring((select(i, ...))) end
    io.stdout:write(table.concat(t, '\t'), '\n')
end }, { __index = _G })
local f = assert(loadfile(arg[1]))
setfenv(f, env)
local ok, err = pcall(f)
if not ok then io.stdout:write('ERROR ', tostring(err), '\n') end
