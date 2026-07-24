-- Extract-helper: the verified transaction that factors a value-parameterizable
-- near-clone PAIR into a shared parameterized helper ([[cartograph-record-fold-arc]]
-- prereq #4). It rides the move/merge txn contract (plan → dryrun → apply-with-journal,
-- refusing on any drift), and adds two synthesis gates: the result must PARSE cleanly and
-- must contain the helper + both rewritten call sites.
--
-- Two placements:
--   SAME-FILE — the helper is a `local function` inserted before the earlier copy; both
--     bodies become `return helper(…)`.
--   CROSS-FILE — the helper becomes `M.helper` in a NEW shared module (plan.create); each
--     copy's file gains `local <alias> = require '<mod>'` and its body becomes
--     `return <alias>.helper(…)`. The require path is a language guess (root-relative) so
--     it rides as a HAZARD to verify — the same honesty extract-module uses.
--
-- SOUNDNESS rests on the prereqs, each verified before a plan is built:
--   • VALUE-parameterizable (clones.analyze_pair): every divergence is a leaf value with a
--     source range → it lifts to a parameter.
--   • BODY-EXTRACTABLE (untangle.body_extractable) for BOTH copies: top-level, no vararg,
--     no self-recursion. CROSS-FILE additionally requires every FREE READ to be a global
--     (not a source-file local — that would break on the move).
--   • The rewrite is a TAIL CALL (`return helper(…)`), preserving every return.
-- HARD CONSTRAINTS (refuse with a reason otherwise): Lua, equal param count, single-line
-- holes inside the body, a clean multi-line body, a free helper name.

local M = {}

local clones = require 'cartograph.clones'
local un = require 'cartograph.untangle'
local txn = require 'cartograph.txn'
local at = require 'cartograph.at'

local function indent_of(line) return (line or ''):match('^%s*') or '' end

-- a fresh helper name not already a function/method in the given files
local function fresh_name(store, files, base)
    local fset, taken = {}, {}
    for _, f in ipairs(files) do fset[f] = true end
    for _, n in ipairs(store.data.nodes) do
        if fset[n.file] and (n.kind == 'function' or n.kind == 'method') then
            taken[(n.name or ''):match('[%w_]+$') or n.name] = true
        end
    end
    local root = (base or 'shared'):match('[%w_]+$') or 'shared'
    local name, i = root .. '_extracted', 2
    while taken[name] do name = root .. '_extracted' .. i; i = i + 1 end
    return name
end

-- top-level def names in a file (fn/method/var) — the cross-file move must not read these
local function file_locals(store, file)
    local s = {}
    for _, n in ipairs(store.data.nodes) do
        if n.file == file and n.name
            and (n.kind == 'function' or n.kind == 'method' or n.kind == 'var') then
            s[n.name] = true
        end
    end
    return s
end

local function parses_clean(text)
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, 'lua')
    if not ok or not parser then return false end
    return not parser:parse()[1]:root():has_error()
end

local function span_text(lines, r)
    return (lines[at.sl(r) + 1] or ''):sub(at.sc(r) + 1, at.ec(r))
end

-- the 0-based line to insert a new import AFTER (last existing import, else top)
local function import_point(lines, pats)
    local last = 0
    for i, l in ipairs(lines) do
        for _, p in ipairs(pats or {}) do
            if l:match(p) then last = i; break end
        end
    end
    return last
end

-- body statement span [sig, open, close] (0-based) of a fn, or nil if not a clean block
local function body_span(store, id, stmt_lines)
    local node = store.node(id)
    local sig0b = at.sl(node.range)
    local open0b = (stmt_lines[1] or 0) - 1
    local close0b = at.el(node.range) - 1
    if open0b <= sig0b or close0b < open0b then return nil end
    return sig0b, open0b, close0b
end

--- Build a plan to extract `pair` into a helper, or (nil, reason). For a CROSS-FILE pair,
--- opts.dest (a new module's project-relative path) is required.
function M.plan(store, pair, opts)
    if not (pair and pair.a and pair.b) then return nil, 'no near-clone pair' end
    local a, b = pair.a, pair.b
    local xfile = a.file ~= b.file
    if not (a.file:match('%.lua$') and b.file:match('%.lua$')) then
        return nil, 'only Lua is supported for now'
    end
    local analysis = clones.analyze_pair(pair)
    if analysis.kind ~= 'value' then
        return nil, ('not value-parameterizable (%s) — nothing to lift cleanly'):format(analysis.kind)
    end
    local va = un.body_extractable(store, a.id)
    if not va.ok then return nil, ('%s body not liftable: %s'):format(a.name, va.reason) end
    local vb = un.body_extractable(store, b.id)
    if not vb.ok then return nil, ('%s body not liftable: %s'):format(b.name, vb.reason) end
    if #va.params ~= #vb.params then
        return nil, 'the two functions take a different number of parameters'
    end

    local root = store.data.root
    local dest, alias, require_line
    local hazards = {}
    if xfile then
        dest = opts and opts.dest
        if not dest then
            return nil, 'cross-file: pass a destination module path (:CartographExtractHelperApply <dir/name.lua>)'
        end
        if dest:sub(1, 1) == '/' or dest:find('%.%.') then
            return nil, 'the destination must be a plain path inside the project'
        end
        if txn.read_file(root, dest) then return nil, dest .. ' already exists — pick a new module path' end
        -- FREE-READ gate: a moved body must read only globals, not source-file locals
        for _, side in ipairs({ { v = va, f = a.file, n = a.name }, { v = vb, f = b.file, n = b.name } }) do
            local loc = file_locals(store, side.f)
            for r in pairs(side.v.reads or {}) do
                if loc[r] then
                    return nil, ('%s reads file-local `%s` — cannot move it to another module')
                        :format(side.n, r)
                end
            end
        end
        require_line, alias = require('cartograph.providers.treesitter').import_line(a.file, dest)
        if not require_line then return nil, 'cannot form a require line for this language' end
        hazards[#hazards + 1] = ('verify the require path in `%s` resolves to %s'):format(require_line, dest)
    end

    local lines_a = vim.split(txn.read_file(root, a.file) or '', '\n', { plain = true })
    local lines_b = xfile and vim.split(txn.read_file(root, b.file) or '', '\n', { plain = true }) or lines_a
    local a_sig, a_open, a_close = body_span(store, a.id, a.lines)
    local b_sig, b_open, b_close = body_span(store, b.id, b.lines)
    if not (a_sig and b_sig) then return nil, 'a body is not a clean multi-line block' end
    if not xfile and not (a_close < b_sig or b_close < a_sig) then
        return nil, 'the two functions overlap (nested?) — cannot extract'
    end

    -- hole PARAMETERS + validation (single-line, inside each body)
    local hp = {}
    for i = 1, #analysis.holes do
        local name = 'hp' .. i
        for _, p in ipairs(va.params) do if p == name then return nil, 'a parameter is already named ' .. name end end
        hp[i] = name
    end
    for i, p in ipairs(analysis.holes) do
        for _, side in ipairs({ { s = p.sites_a, open = a_open, close = a_close },
            { s = p.sites_b, open = b_open, close = b_close } }) do
            for _, r in ipairs(side.s) do
                if at.sl(r) ~= at.el(r) then return nil, ('hole %d spans multiple lines'):format(i) end
                if at.sl(r) < side.open or at.sl(r) > side.close then
                    return nil, ('hole %d is outside a body'):format(i)
                end
            end
        end
    end

    local hname = fresh_name(store, xfile and {} or { a.file }, a.name)
    local body_indent = indent_of(lines_a[a_open + 1])

    -- helper body = A's body lines, each hole's A-site replaced by its hp name
    local body = {}
    for i = a_open, a_close do body[#body + 1] = lines_a[i + 1] end
    local subs = {}
    for i, p in ipairs(analysis.holes) do
        for _, r in ipairs(p.sites_a) do
            local off = at.sl(r) - a_open
            subs[off] = subs[off] or {}
            subs[off][#subs[off] + 1] = { sc = at.sc(r), ec = at.ec(r), name = hp[i] }
        end
    end
    for off, list in pairs(subs) do
        table.sort(list, function (x, y) return x.sc > y.sc end)
        local l = body[off + 1]
        for _, s in ipairs(list) do l = l:sub(1, s.sc) .. s.name .. l:sub(s.ec + 1) end
        body[off + 1] = l
    end

    local hparams = {}
    for _, p in ipairs(va.params) do hparams[#hparams + 1] = p end
    for _, name in ipairs(hp) do hparams[#hparams + 1] = name end

    -- a copy's replacement body: `return <callee>(<its params>, <its fillings>)`
    local function call_line(callee, params, sites_key, src)
        local args = {}
        for _, p in ipairs(params) do args[#args + 1] = p end
        for _, p in ipairs(analysis.holes) do args[#args + 1] = span_text(src, p[sites_key][1]) end
        return body_indent .. ('return %s(%s)'):format(callee, table.concat(args, ', '))
    end

    local plan = {
        verb = 'extract-helper', generation = store.generation,
        helper = hname, nparams = #hp, xfile = xfile,
        files = {}, hazards = hazards,
        a = { id = a.id, name = a.name, ref = store.ref_of(a.id), file = a.file },
        b = { id = b.id, name = b.name, ref = store.ref_of(b.id), file = b.file },
    }

    if not xfile then
        -- helper as a local before the earlier copy; both bodies → return helper(…)
        local sig_indent = indent_of(lines_a[a_sig + 1])
        local helper = { sig_indent .. ('local function %s(%s)'):format(hname, table.concat(hparams, ', ')) }
        for _, l in ipairs(body) do helper[#helper + 1] = l end
        helper[#helper + 1] = sig_indent .. 'end'
        helper[#helper + 1] = ''
        plan.files[a.file] = { ops = {
            { from0b = math.min(a_sig, b_sig), to0b = math.min(a_sig, b_sig) - 1, new = helper },
            { from0b = a_open, to0b = a_close, new = { call_line(hname, va.params, 'sites_a', lines_a) } },
            { from0b = b_open, to0b = b_close, new = { call_line(hname, vb.params, 'sites_b', lines_b) } },
        } }
        plan.touched = { a.file }
    else
        -- new module holding M.<hname>; each caller gains a require + a delegating body
        local mod = { 'local M = {}', '', ('function M.%s(%s)'):format(hname, table.concat(hparams, ', ')) }
        for _, l in ipairs(body) do mod[#mod + 1] = l end
        mod[#mod + 1] = 'end'; mod[#mod + 1] = ''; mod[#mod + 1] = 'return M'; mod[#mod + 1] = ''
        plan.create = { file = dest, lines = mod }
        plan.creates = { [dest] = true }
        plan.helper_call = alias .. '.' .. hname
        local ipa = import_point(lines_a, require('cartograph.providers.treesitter').import_pats(a.file))
        local ipb = import_point(lines_b, require('cartograph.providers.treesitter').import_pats(b.file))
        plan.files[a.file] = { ops = {
            { from0b = ipa, to0b = ipa - 1, new = { require_line } },
            { from0b = a_open, to0b = a_close, new = { call_line(plan.helper_call, va.params, 'sites_a', lines_a) } },
        } }
        plan.files[b.file] = { ops = {
            { from0b = ipb, to0b = ipb - 1, new = { require_line } },
            { from0b = b_open, to0b = b_close, new = { call_line(plan.helper_call, vb.params, 'sites_b', lines_b) } },
        } }
        plan.touched = { a.file, b.file, dest }
        table.sort(plan.touched)
    end

    plan.stamps = {}
    for _, f in ipairs(plan.touched) do
        if not (plan.creates and plan.creates[f]) then plan.stamps[f] = txn.disk_stamp(root, f) end
    end
    return plan
end

--- The edit callback (pure splice) — shared by preview and apply.
function M.edits_for(plan)
    return function (rel, before)
        if plan.create and rel == plan.create.file then
            return table.concat(plan.create.lines, '\n')
        end
        local fe = plan.files[rel]
        if not fe then return before end
        local lines = vim.split(before, '\n', { plain = true })
        local ops = {}
        for _, o in ipairs(fe.ops) do ops[#ops + 1] = o end
        table.sort(ops, function (x, y) return x.from0b > y.from0b end) -- bottom-up
        for _, op in ipairs(ops) do
            for _ = op.from0b, op.to0b do table.remove(lines, op.from0b + 1) end
            for i = #op.new, 1, -1 do table.insert(lines, op.from0b + 1, op.new[i]) end
        end
        return table.concat(lines, '\n')
    end
end

function M.preview(store, plan)
    return txn.dryrun(store, plan, M.edits_for(plan))
end

function M.apply(store, plan)
    if next(store.moveset or {}) then
        return nil, 'a move-set is staged — apply or clear it first'
    end
    local refspecs = {
        { id = plan.a.id, name = plan.a.name, ref = plan.a.ref, what = 'clone' },
        { id = plan.b.id, name = plan.b.name, ref = plan.b.ref, what = 'clone' },
    }
    local bad = txn.verify(store, plan, refspecs)
    if bad then return nil, bad end
    -- synthesis gates: every touched/created file parses, and the helper + both calls exist
    local _, after = M.preview(store, plan)
    if not after then return nil, 'preview failed' end
    local defsite = plan.xfile and plan.create.file or plan.a.file
    for _, rel in ipairs(plan.touched) do
        if not parses_clean(after[rel] or '') then
            return nil, ('the synthesized %s does not parse — refusing (a synthesis bug, not your code)'):format(rel)
        end
    end
    local defpat = plan.xfile and ('function M.%s('):format(plan.helper)
        or ('local function %s('):format(plan.helper)
    if not (after[defsite] or ''):find(defpat, 1, true) then
        return nil, 'the helper definition is missing from the result — refusing'
    end
    -- both call sites present (same-file: 2 in one file; cross-file: 1 in each caller)
    local callee = plan.xfile and plan.helper_call or plan.helper
    local ncalls = 0
    for _, rel in ipairs(plan.touched) do
        if rel ~= (plan.xfile and plan.create.file) then
            ncalls = ncalls + select(2, (after[rel] or ''):gsub(callee:gsub('([^%w])', '%%%1') .. '%(', ''))
        end
    end
    if ncalls < 2 then return nil, 'a call site is missing from the result — refusing' end
    return txn.execute(store, plan, {
        helper = plan.helper, xfile = plan.xfile,
        a = plan.a.ref, b = plan.b.ref,
    }, M.edits_for(plan))
end

return M
