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
if rwmap and rwmod and rwbind then
    local edits, skipped = {}, {} -- edits[file] = { {ext, to} }
    for _, s in ipairs(r.sites) do
        -- prefer a 2-segment suffix (sub-path accessor, stem2); fall back to a
        -- 1-segment suffix (record-field accessor, stem1) — e.g. `c.file`
        local suf2 = s.path:match('([%w_]+%.[%w_]+)$')
        local suf1 = s.path:match('([%w_]+)$')
        local acc, stem
        if suf2 and rwmap[suf2] then acc, stem = rwmap[suf2], s.stem2
        elseif suf1 and rwmap[suf1] then acc, stem = rwmap[suf1], s.stem1 end
        if acc then
            local skip
            for _, pat in ipairs(RWSKIP) do
                if s.file:find(pat) then skip = 'owner file' break end
            end
            if not skip and s.pre then skip = 'prefix taint (partial chain)' end
            if not skip and not (s.ext and stem) then skip = 'no extent' end
            if not skip and s.ext[1] ~= s.ext[3] then skip = 'multi-line chain' end
            if skip then
                skipped[#skipped + 1] = { s = s, why = skip }
            else
                edits[s.file] = edits[s.file] or {}
                table.insert(edits[s.file], { ext = s.ext,
                    to = ('%s.%s(%s)'):format(rwbind, acc, stem) })
            end
        end
    end
    local files2, ne = {}, 0
    for f in pairs(edits) do files2[#files2 + 1] = f end
    table.sort(files2)
    emit('\nREWRITES%s:', apply and ' (applied)' or ' (plan — add --apply to write)')
    for _, f in ipairs(files2) do
        -- bottom-up so earlier splices don't shift later extents
        table.sort(edits[f], function (a, b)
            return a.ext[1] > b.ext[1] or (a.ext[1] == b.ext[1] and a.ext[2] > b.ext[2])
        end)
        local lines = vim.fn.readfile(root .. '/' .. f)
        for _, ed in ipairs(edits[f]) do
            local ln = lines[ed.ext[1] + 1]
            local before = ln:sub(1, ed.ext[2])
            local after = ln:sub(ed.ext[4] + 1)
            emit('  %s:%d  %s  ->  %s', f, ed.ext[1] + 1,
                ln:sub(ed.ext[2] + 1, ed.ext[4]), ed.to)
            lines[ed.ext[1] + 1] = before .. ed.to .. after
            ne = ne + 1
        end
        -- ensure the accessor module is required (after the last top require)
        local has, last_req = false, 0
        for j, ln in ipairs(lines) do
            if ln:find(rwmod:gsub('%W', '%%%0'), 1, false) then has = true break end
            if j <= 60 and ln:match('^local [%w_]+%s*=%s*require') then last_req = j end
        end
        if not has then
            table.insert(lines, last_req + 1,
                ("local %s = require '%s'"):format(rwbind, rwmod))
            emit('  %s:+  local %s = require \'%s\'', f, rwbind, rwmod)
        end
        if apply then vim.fn.writefile(lines, root .. '/' .. f) end
    end
    emit('%d rewrites in %d files', ne, #files2)
    if #skipped > 0 then
        emit('SKIPPED (manual):')
        for _, k in ipairs(skipped) do
            emit('  %s:%d  %-14s %s', k.s.file, k.s.line, k.s.path, k.why)
        end
    end
end
io.write(table.concat(out, '\n'), '\n')
vim.cmd('qall!')
