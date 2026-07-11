-- Shape-consumer roster over a Lua tree. The Encapsulate Field checklist:
-- every deref path with sites, every escape as a frontier row.
--
--   nvim --headless -u NONE -l tools/consumers.lua <root> \
--       [--call name[=list|elem]]... [--field name[=list|elem|any]]... \
--       [--bless fn,fn,...] [--full]
--
-- e.g. the at display seam, with the at.lua accessors blessed:
--   nvim --headless -u NONE -l tools/consumers.lua . \
--       --call occurrences --field at --bless sl,sc,el,ec,oneline

vim.opt.rtp:prepend('.')
local consumers = require 'cartograph.consumers'

local root, spec, full = nil, { calls = {}, fields = {}, bless = {} }, false
local i = 1
while i <= #_G.arg do
    local a = _G.arg[i]
    if a == '--call' or a == '--field' then
        i = i + 1
        local name, kind = _G.arg[i]:match('^([%w_]+)=?(%a*)$')
        if a == '--call' then spec.calls[name] = kind ~= '' and kind or 'list'
        else spec.fields[name] = kind ~= '' and kind or 'any' end
    elseif a == '--bless' then
        i = i + 1
        for fn in _G.arg[i]:gmatch('[%w_]+') do spec.bless[fn] = true end
    elseif a == '--full' then full = true
    else root = a end
    i = i + 1
end
if not root or (not next(spec.calls) and not next(spec.fields)) then
    print('usage: ... <root> [--call name[=kind]] [--field name[=kind]] [--full]')
    vim.cmd('cquit 1')
end

local files = {}
for _, f in ipairs(vim.fn.glob(root .. '/lua/**/*.lua', false, true)) do
    files[#files + 1] = f:sub(#root + 2)
end
local r = consumers.roster(root, files, spec)

local out = {}
local function emit(fmt, ...) out[#out + 1] = fmt:format(...) end

emit('\n%d files, %d producer expressions seen', #files, r.seeds)

emit('\nDEREF PATHS (the accessor surface this shape needs):')
local paths = {}
for p in pairs(r.by_path) do paths[#paths + 1] = p end
table.sort(paths, function (a, b)
    return r.by_path[a] > r.by_path[b] or (r.by_path[a] == r.by_path[b] and a < b)
end)
for _, p in ipairs(paths) do
    emit('  %4d  %s', r.by_path[p], p)
end

if full then
    emit('\nSITES:')
    for _, s in ipairs(r.sites) do
        emit('  %s:%d:%d  %-16s %s', s.file, s.line, s.col, s.path, s.via)
    end
end

if next(spec.bless) then
    emit('\nSEAMED (%d sites already read through a blessed accessor):', #r.seamed)
    for _, e in ipairs(r.seamed) do
        emit('  %s:%d:%d  %-12s %s', e.file, e.line, e.col, e.via, e.detail or '')
    end
end

emit('\nFRONTIER (%d rows — coverage STOPS here; each needs a human eye):',
    #r.frontier)
for _, e in ipairs(r.frontier) do
    emit('  %s:%d:%d  %-7s %-12s %s', e.file, e.line, e.col,
        e.kind, e.via, e.detail or '')
end
io.write(table.concat(out, '\n'), '\n')
vim.cmd('qall!')
