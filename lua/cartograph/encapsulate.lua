-- cartograph.encapsulate — ENCAPSULATE FIELD as a plan: route a record shape's field reads through an accessor
-- module, so its REPRESENTATION can change behind it (CART-1664: range records built as three tables each; the store
-- already folds them to columns read through cartograph.at). The roster is consumers.lua's (field-sensitive shape
-- flow, seeded by PRODUCERS — calls, fields, rooted fields); this module plans the rewrites the seam rewriter
-- (tools/consumers.lua --rw) made, and adds the INTERROGATION: a rewrite it cannot take on its own is a ROW with a
-- key and a reason, decided by an answer instead of a hand edit.
--   SAFE (applied): a deref whose path ends in a mapped suffix, a full single-line chain, outside the representation's
--     owners. The accessors are identity on the raw record (at.sl(r) == r.start.line), so the rewrite cannot change
--     behaviour whatever the receiver really is: a name-matched false positive costs a rewrite, never a wrong one.
--   RISKY (a row: decide = { [key] = 'rewrite' | 'skip' }): an OWNER file (it produces / folds / validates the raw
--     record: rewriting is still identity, but the owner may be MEANT to read raw), a multi-line chain, a partial
--     (prefix-tainted) chain.
--   ESCAPES (stage = 'close': decide = { [key] = 'ok' }): the record passed as an argument, stored, returned, indexed
--     by `#` / `[]` — coverage stops there. CLOSURE holds when every escape is answered `ok` (the reader on the far
--     side goes through the accessor) and no raw deref remains: the precondition for switching the PRODUCER.
-- The key of a row is `file:line:col` (1-based line, 0-based col, as the roster reports).
local consumers = require 'cartograph.consumers'

local M = {}

local function key_of(s) return ('%s:%d:%d'):format(s.file, s.line, s.col or 0) end

local function is_owner(f, owners)
    for _, pat in ipairs(owners) do if f:find(pat) then return true end end
    return false
end

--- spec = { calls, fields, rooted, bless } (consumers' producer seeds); rw = { [suffix] = accessor }; mod, bind = the
--- accessor module and its local name; files = rel paths under root; owners = patterns (default consumers.OWNERS);
--- decide = { [key] = answer } -> { edits = { [file] = new text }, rewrites = { … }, rows = { undecided risky … },
--- escapes = { … }, roster = the roster }
function M.plan(root, args)
    local spec = { calls = args.calls or {}, fields = args.fields or {}, rooted = args.rooted or {}, bless = args.bless or {},
        params = args.params }
    local owners = args.owners or consumers.OWNERS
    local decide = args.decide or {}
    local r = consumers.roster(root, args.files, spec)
    local edits, rewrites, rows = {}, {}, {}
    local byfile = {}
    -- (the accessor module's own file IS the accessors: its raw reads are their implementation, no row)
    local self_file = 'lua/' .. args.mod:gsub('%.', '/') .. '.lua'
    for _, s in ipairs(r.sites) do
        if s.file == self_file or decide[s.file] == 'other' then goto next_site end
        local suf2 = s.path:match('([%w_]+%.[%w_]+)$')
        local suf1 = s.path:match('([%w_]+)$')
        local acc, stem
        if suf2 and args.rw[suf2] then acc, stem = args.rw[suf2], s.stem2
        elseif suf1 and args.rw[suf1] then acc, stem = args.rw[suf1], s.stem1 end
        if acc then
            local why
            if not (s.ext and stem) then why = 'no extent'
            elseif s.pre then why = 'prefix taint (partial chain)'
            elseif s.ext[1] ~= s.ext[3] then why = 'multi-line chain'
            elseif is_owner(s.file, owners) then why = 'owner file (it may be meant to read the raw record)' end
            local k = key_of(s)
            local answer = decide[k]
            -- (only an OWNER row can be answered `rewrite`: the others have no single-line splice to make)
            local owner_only = why and why:find('^owner file')
            if not why or (answer == 'rewrite' and owner_only) then
                byfile[s.file] = byfile[s.file] or {}
                table.insert(byfile[s.file], { ext = s.ext, to = ('%s.%s(%s)'):format(args.bind, acc, stem), key = k, path = s.path })
            elseif answer ~= 'skip' then
                rows[#rows + 1] = { key = k, file = s.file, line = s.line, path = s.path,
                    why = (answer == 'rewrite') and (why .. ' — no automatic splice: answer skip, or edit it by hand') or why }
            end
        end
        ::next_site::
    end
    local escapes = {}
    for _, e in ipairs(r.frontier) do
        local k = key_of(e)
        if decide[k] ~= 'ok' and decide[e.file] ~= 'other' and e.file ~= self_file then escapes[#escapes + 1] = { key = k, file = e.file, line = e.line, kind = e.kind, detail = e.detail, via = e.via, idx = e.idx, taint = e.taint } end
    end
    local files = vim.tbl_keys(byfile)
    table.sort(files)
    local bindpat = '^local%s+' .. args.bind .. '%s*=%s*require%s*%(?%s*[\'"]' .. args.mod:gsub('%W', '%%%0') .. '[\'"]'
    for _, f in ipairs(files) do
        local list = byfile[f]
        -- bottom-up so earlier splices do not shift later extents
        table.sort(list, function (a, b) return a.ext[1] > b.ext[1] or (a.ext[1] == b.ext[1] and a.ext[2] > b.ext[2]) end)
        local fd = io.open(root .. '/' .. f, 'r')
        local text = fd and fd:read('a'); if fd then fd:close() end
        if text then
            local lines = vim.split(text, '\n', { plain = true })
            for _, ed in ipairs(list) do
                local ln = lines[ed.ext[1] + 1]
                lines[ed.ext[1] + 1] = ln:sub(1, ed.ext[2]) .. ed.to .. ln:sub(ed.ext[4] + 1)
                rewrites[#rewrites + 1] = { file = f, line = ed.ext[1] + 1, from = ln:sub(ed.ext[2] + 1, ed.ext[4]), to = ed.to, key = ed.key }
            end
            -- the accessor's BINDING at the top level (a file that requires the module under another name, or inside a
            -- function, does not bind it), before the first line of code: it dominates every use
            local has, first_code = false, nil
            for j, ln in ipairs(lines) do
                if ln:find(bindpat) then has = true break end
                if not first_code and not ln:match('^%s*%-%-') and not ln:match('^%s*$') and not ln:match('^#!') then first_code = j end
            end
            if not has then table.insert(lines, first_code or 1, ("local %s = require '%s'"):format(args.bind, args.mod)) end
            edits[f] = table.concat(lines, '\n')
        end
    end
    return { edits = edits, rewrites = rewrites, rows = rows, escapes = escapes, roster = r }
end

-- ★ THE AUTO POLICY (CART-1664: "make the decisions — it should accelerate the loop, so experiments are cheaper"): the
-- answers a person would give by rule, each RECORDED with the rule that gave it, an explicit decide = … always wins.
--   bless      the accessor module's EXPORTS (parsed from it, never listed): a call to one of them, under any local
--              name (`at.sl(r)` where the file binds `at`), reads through the seam — no escape
--   (NOT follow: seeding a stored-into field BY NAME and re-running exploded on cartograph — `e`, `name`, `file` became
--   seeds and 10,675 escapes opened. A store is followed only into a field ALREADY seeded, below.)
--   rows       an OWNER file's deref -> rewrite (identity on the raw record); an unspliceable one (no extent, a partial
--              or multi-line chain) -> skip
--   other      a FILE with escapes of the seeded name that never reads the shape's own fields (no deref ending in a
--              mapped suffix, no call into the accessor module) holds ANOTHER shape under that name — cartograph's
--              algebra keeps tree POSITIONS in `.at` — answered decide = <file>=other (a heuristic: recorded, and the
--              acceptance after a producer switch is the suite + the row joins, never this rule)
--   derived    a scalar COMPUTED from the shape (`local l = atr.sl(r)` handed on) -> ok: no representation in it
--   escapes    an argument to a builtin that is PURE, reads none of its contents and hands it back nowhere (effects'
--              SIGS: type, rawequal, tostring) -> ok; a store into a SEEDED field, or into the list a seeded field
--              holds (`e.at[#e.at + 1] = r`) -> ok (its readers are in the roster)
-- Whatever no rule answers stays a row: the real decision list.
local function exports_of(root, mod)
    local rel = 'lua/' .. mod:gsub('%.', '/') .. '.lua'
    local fd = io.open(root .. '/' .. rel) or (function ()
        local hit = vim.api.nvim_get_runtime_file(rel, false)[1]
        return hit and io.open(hit)
    end)()
    local out = {}
    if fd then
        local src = fd:read('a'); fd:close()
        for name in src:gmatch('function%s+M%.([%w_]+)%s*%(') do out[name] = true end
    end
    return out
end
local function neutral(name)
    local sg = require('cartograph.effects').SIGS.lua.exact[name]
    return sg and sg.pure and not sg.reads and not sg.returns_arg and not sg.yields_arg and not sg.w and not sg.calls
end
-- name -> { files defining a function of that LAST name segment } (`function M.f(`, `function C:f(`, `local function
-- f(`, `f = function(`), over the files the roster scans — an over-approximation of the callee, the safe direction)
local function defs_index(root, files)
    local idx = {}
    local function add(name, f)
        local l = idx[name]
        if not l then l = {}; idx[name] = l end
        if l[#l] ~= f then l[#l + 1] = f end
    end
    for _, f in ipairs(files) do
        local fd = io.open(root .. '/' .. f)
        local src = fd and fd:read('a'); if fd then fd:close() end
        if src then
            for name in src:gmatch('function%s+[%w_.:]-([%w_]+)%s*%(') do add(name, f) end
            for name in src:gmatch('([%w_]+)%s*=%s*function%s*%(') do add(name, f) end
        end
    end
    return idx
end

function M.plan_auto(root, args)
    args = vim.deepcopy(args)
    args.bless = args.bless or {}
    for name in pairs(exports_of(root, args.mod)) do args.bless[name] = true end
    args.fields = args.fields or {}
    local seeded = function (f) return args.fields[f] or args.rooted and args.rooted[f] end
    -- FOLLOW an argument into its callee: the record passed as argument k of `X(…)` seeds parameter k of every
    -- function named X the tree defines (consumers' parameter seeds, CART-1345), the roster runs again — to a fixpoint
    -- (at most `rounds`). A callee the tree does not define (a builtin, an external) is not followed.
    local defs = defs_index(root, args.files)
    args.params = args.params or {}
    local followed, nfollow = {}, 0
    local p
    for _ = 1, tonumber(args.rounds or 6) do
        p = M.plan(root, args)
        local grew = false
        for _, e in ipairs(p.escapes) do
            local callee = e.kind == 'arg' and e.idx and tostring(e.detail or ''):match('([%w_]+)%(%)$')
            local files = callee and not neutral(callee) and defs[callee]
            if files and not followed[e.key] then
                followed[e.key] = callee
                for _, f in ipairs(files) do
                    local l = args.params[f]
                    if not l then l = {}; args.params[f] = l end
                    local dup
                    for _, x in ipairs(l) do if x.name == callee and x.idx == e.idx then dup = true end end
                    if not dup then l[#l + 1] = { name = callee, idx = e.idx, kind = e.taint or 'elem' }; grew = true; nfollow = nfollow + 1 end
                end
            end
        end
        if not grew then break end
    end
    local decide, decisions = vim.deepcopy(args.decide or {}), {}
    local function answer(key, a, rule)
        if decide[key] then return end -- (an explicit answer wins)
        decide[key] = a
        decisions[#decisions + 1] = { key = key, answer = a, rule = rule }
    end
    for key, callee in pairs(followed) do answer(key, 'ok', 'followed:' .. callee) end
    -- (files that read the shape: a deref ending in a mapped suffix, or a seamed call)
    local reads = {}
    for _, s in ipairs(p.roster.sites) do
        local suf2, suf1 = s.path:match('([%w_]+%.[%w_]+)$'), s.path:match('([%w_]+)$')
        if (suf2 and args.rw[suf2]) or (suf1 and args.rw[suf1]) then reads[s.file] = true end
    end
    for _, s in ipairs(p.roster.seamed or {}) do reads[s.file] = true end
    for _, e in ipairs(p.escapes) do
        if not reads[e.file] and not decide[e.file] then answer(e.file, 'other', 'no-shape-deref-in-file') end
    end
    for _, r in ipairs(p.rows) do
        if r.why:find('^owner file') then answer(r.key, 'rewrite', 'owner-identity')
        else answer(r.key, 'skip', 'unspliceable') end
    end
    for _, e in ipairs(p.escapes) do
        local callee = e.kind == 'arg' and tostring(e.detail or ''):match('^([%w_.]+)%(%)$')
        if e.kind == 'derived' then answer(e.key, 'ok', 'derived-scalar') -- (a value COMPUTED from the shape — a line number —
        -- leaves; it does not depend on the record's representation)
        elseif callee and neutral(callee) then answer(e.key, 'ok', 'neutral-builtin:' .. callee)
        elseif e.kind == 'store' and e.detail then
            local d = tostring(e.detail)
            local f = d:match('^[%w_]+$') or d:match('%.([%w_]+)$') or d:match('([%w_]+)%[#') -- (`x.at[#x.at + 1]`: the list a field holds)
            if f and seeded(f) then answer(e.key, 'ok', 'stored-into-seeded:' .. f) end
        end
    end
    args.decide = decide
    local final = M.plan(root, args)
    final.decisions, final.seeds = decisions, args.fields
    return final
end

--- one row per line, for a decision's text: `key  why/kind  detail`
function M.render(rows, n)
    local out = {}
    for i = 1, math.min(#rows, n or 20) do
        local x = rows[i]
        out[#out + 1] = ('  %s  %s'):format(x.key, x.why or (tostring(x.kind) .. ' ' .. tostring(x.detail or x.via or '')))
    end
    if #rows > (n or 20) then out[#out + 1] = ('  … and %d more'):format(#rows - (n or 20)) end
    return table.concat(out, '\n')
end

return M
