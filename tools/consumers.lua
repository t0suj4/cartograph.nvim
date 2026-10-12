-- Shape-consumer roster over a Lua tree. The Encapsulate Field checklist:
-- every deref path with sites, every escape as a frontier row — and the
-- SEAM REWRITER: mechanically reroute coordinate derefs through an accessor.
--
--   nvim --headless -u NONE -l tools/consumers.lua <root> \
--       [--call name[=list|elem]]... [--field name[=list|elem|any]]... \
--       [--bless fn,fn,...] [--full] \
--       [--rw suffix=acc,...] [--rwmod module:binding] [--apply]
--
-- A DOTTED --field is a ROOTED producer (`--field data.calls`): the taint is
-- scoped to that exact base, so a same-named field on an unrelated record
-- (`counter.calls`) is NOT tainted — the fix for name-match over-approximation.
--
-- e.g. the at display seam (2-segment sub-path accessors — stem is the range):
--   nvim --headless -u NONE -l tools/consumers.lua . \
--       --call occurrences --field at --bless sl,sc,el,ec,oneline \
--       --rw start.line=sl,start.char=sc,end.line=el,end.char=ec \
--       --rwmod cartograph.at:atr
--
-- e.g. the CALL-RECORD read seam (1-segment record-field accessors — stem is
-- the record; record-fold arc step 2, [[cartograph-record-fold-arc]]):
--   nvim --headless -u NONE -l tools/consumers.lua . \
--       --field data.calls=list --field store.data.calls=list \
--       --bless file,callee,full,method,line \
--       --rw file=file,callee=callee,full=full,method=method,line=line \
--       --rwmod cartograph.callrec:callrec --apply
--
-- The rewrite is deliberately narrow: a deref whose path ENDS in a mapped
-- suffix (1- OR 2-segment), physical chain (no prefix-taint partials), single-
-- line, in a file that doesn't OWN the representation (providers/, store, fold,
-- csr, argv, detail, cache, refresh, parallel, validate, refused, and the
-- accessor module are skipped). INTERPROCEDURAL escapes (the record passed into
-- a helper, `x.c.file`) are honest FRONTIER rows, not rewritten — hand residue.

vim.opt.rtp:prepend('.')
local consumers = require 'cartograph.consumers'

local root, spec, full = nil, { calls = {}, fields = {}, rooted = {}, bless = {} }, false
local rwmap, rwmod, rwbind, apply = nil, nil, nil, false
local RWSKIP = consumers.OWNERS -- representation owners (single source: the
                                -- module, shared with the seam guard)
local i = 1
while i <= #_G.arg do
    local a = _G.arg[i]
    if a == '--call' or a == '--field' then
        i = i + 1
        -- a dotted name (`data.calls`) = a ROOTED field producer: scope the
        -- taint to that exact base, not any `.calls` (kills over-approximation)
        local name, kind = _G.arg[i]:match('^([%w_.]+)=?(%a*)$')
        if a == '--call' then spec.calls[name] = kind ~= '' and kind or 'list'
        elseif name:find('.', 1, true) then spec.rooted[name] = kind ~= '' and kind or 'list'
        else spec.fields[name] = kind ~= '' and kind or 'any' end
    elseif a == '--bless' then
        i = i + 1
        for fn in _G.arg[i]:gmatch('[%w_]+') do spec.bless[fn] = true end
    elseif a == '--rw' then
        i = i + 1
        rwmap = {}
        for suf, acc in _G.arg[i]:gmatch('([%w_.%[%]]+)=([%w_]+)') do rwmap[suf] = acc end
    elseif a == '--rwmod' then
        i = i + 1
        rwmod, rwbind = _G.arg[i]:match('^([%w_.%-]+):([%w_]+)$')
    elseif a == '--accessors' then
        -- `module:binding` (cartograph.callrec:callrec): count reads THROUGH that module's plain field accessors,
        -- derived by parsing its exports (CART-1165) — without it a seamed field reads as barely used
        i = i + 1
        local mod, bind = _G.arg[i]:match('^([%w_.%-]+):([%w_]+)$')
        -- through the RUNTIMEPATH, where require finds it (package.path does not hold ./lua)
        local path = mod and vim.api.nvim_get_runtime_file('lua/' .. mod:gsub('%.', '/') .. '.lua', false)[1]
        local fd = path and io.open(path)
        if not fd then io.stderr:write('consumers: cannot find accessor module ' .. tostring(_G.arg[i]) .. '\n'); os.exit(2) end
        local src = fd:read('a'); fd:close()
        local map, n, iters = consumers.accessor_fields(src, bind)
        spec.accessors, spec.iters = spec.accessors or {}, spec.iters or {}
        for k, v in pairs(map) do spec.accessors[k] = v end
        for k, v in pairs(iters) do spec.iters[k] = v end
        io.stderr:write(('consumers: %d plain accessor(s), %d iterator(s) from %s\n'):format(n, vim.tbl_count(iters), mod))
    elseif a == '--apply' then apply = true
    elseif a == '--full' then full = true
    else root = a end
    i = i + 1
end
if not root or (not next(spec.calls) and not next(spec.fields) and not next(spec.rooted)) then
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

-- ── the seam rewriter ─────────────────────────────────────────────────────
-- (the PLAN is cartograph.encapsulate's — one source with the `encapsulate` tactic: safe rewrites applied, risky ones
-- listed as rows with their keys; the tactic answers them with decide = <key>=rewrite|skip)
if rwmap and rwmod and rwbind then
    local E = require 'cartograph.encapsulate'
    local p = E.plan(root, { calls = spec.calls, fields = spec.fields, rooted = spec.rooted, bless = spec.bless,
        rw = rwmap, mod = rwmod, bind = rwbind, files = files, owners = RWSKIP })
    emit('\nREWRITES%s:', apply and ' (applied)' or ' (plan — add --apply to write)')
    local nf = 0
    for _ in pairs(p.edits) do nf = nf + 1 end
    for _, w in ipairs(p.rewrites) do emit('  %s:%d  %s  ->  %s', w.file, w.line, w.from, w.to) end
    if apply then
        for f, text in pairs(p.edits) do
            local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(text); fd:close()
        end
    end
    emit('%d rewrites in %d files', #p.rewrites, nf)
    if #p.rows > 0 then
        emit('SKIPPED (risky — the encapsulate tactic decides them, decide = <key>=rewrite|skip):')
        emit('%s', E.render(p.rows, #p.rows))
    end
end
io.write(table.concat(out, '\n'), '\n')
vim.cmd('qall!')
