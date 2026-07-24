-- Extract-helper: the verified transaction that factors a value-parameterizable
-- near-clone PAIR into a shared parameterized helper ([[cartograph-record-fold-arc]]
-- prereq #4 — the last, correctness-critical one). It rides the same txn contract as
-- move/merge (plan → dryrun → apply-with-journal, refusing on any drift), and adds two
-- gates of its own: the synthesized result must PARSE cleanly, and the helper + both
-- rewritten call sites must actually appear (a structural post-condition).
--
-- SOUNDNESS rests on the prereqs, each already verified before a plan is built:
--   • VALUE-parameterizable (clones.analyze_pair): every divergence is a leaf value with
--     a source range, so the hole lifts to a parameter (not a shape difference).
--   • BODY-EXTRACTABLE (untangle.body_extractable) for BOTH copies: top-level (free reads
--     are module/global, visible to a same-scope helper), no vararg, no self-recursion.
--   • The rewrite uses a TAIL CALL (`return helper(…)`), which preserves every return —
--     count, values, and early exits — because the whole body moves into the helper.
-- HARD CONSTRAINTS (refuse with a reason otherwise): same-file, Lua, equal param count,
-- single-line holes inside the body, a clean multi-line body, a free helper name. This is
-- the provably-safe subset; cross-file (needs shared-module wiring), non-Lua (differing
-- helper syntax), and structural pairs are deliberately out of scope.

local M = {}

local clones = require 'cartograph.clones'
local un = require 'cartograph.untangle'
local txn = require 'cartograph.txn'
local at = require 'cartograph.at'

-- leading-whitespace prefix of a line
local function indent_of(line) return (line or ''):match('^%s*') or '' end

-- a fresh helper name not already a function/method in the file
local function fresh_name(store, file, base)
    local taken = {}
    for _, n in ipairs(store.data.nodes) do
        if n.file == file and (n.kind == 'function' or n.kind == 'method') then
            taken[(n.name or ''):match('[%w_]+$') or n.name] = true
        end
    end
    local root = (base or 'shared'):match('[%w_]+$') or 'shared'
    local name = root .. '_extracted'
    local i = 2
    while taken[name] do name = root .. '_extracted' .. i; i = i + 1 end
    return name
end

-- does `text` parse (lua) with no ERROR/MISSING node? (the synthesis gate)
local function parses_clean(text)
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, 'lua')
    if not ok or not parser then return false end
    local root = parser:parse()[1]:root()
    if root:has_error() then return false end
    return true
end

-- source text of a single-line range (0-based), from the file lines
local function span_text(lines, r)
    return (lines[at.sl(r) + 1] or ''):sub(at.sc(r) + 1, at.ec(r))
end

--- Build a plan to extract `pair` (a clones.near / near_of pair) into a helper, or
--- (nil, reason) if the sound subset's constraints aren't met.
function M.plan(store, pair)
    if not (pair and pair.a and pair.b) then return nil, 'no near-clone pair' end
    local a, b = pair.a, pair.b
    if a.file ~= b.file then
        return nil, 'cross-file pair — the helper needs a shared module (not yet supported)'
    end
    if not a.file:match('%.lua$') then return nil, 'only Lua is supported for now' end
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
    local text = txn.read_file(root, a.file)
    if not text then return nil, 'cannot read ' .. a.file end
    local lines = vim.split(text, '\n', { plain = true })

    -- body span [open,close] (0-based) of a fn: first stmt line .. line before its `end`
    local function body_span(id, stmt_lines)
        local node = store.node(id)
        local sig0b = at.sl(node.range)
        local open0b = (stmt_lines[1] or 0) - 1
        local close0b = at.el(node.range) - 1
        if open0b <= sig0b or close0b < open0b then return nil end
        return sig0b, open0b, close0b
    end
    local a_sig, a_open, a_close = body_span(a.id, a.lines)
    local b_sig, b_open, b_close = body_span(b.id, b.lines)
    if not (a_sig and b_sig) then return nil, 'a body is not a clean multi-line block' end
    -- disjoint (a fn cannot enclose the other — near-clones are siblings)
    if not (a_close < b_sig or b_close < a_sig) then
        return nil, 'the two functions overlap (nested?) — cannot extract'
    end

    -- hole PARAMETERS: one per distinct varying leaf; hp<i> names, checked vs A's params
    local hp = {}
    for i = 1, #analysis.holes do
        local name = 'hp' .. i
        for _, p in ipairs(va.params) do
            if p == name then return nil, 'a parameter is already named ' .. name end
        end
        hp[i] = name
    end
    -- every hole site must be single-line and inside the copy's body
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

    local hname = fresh_name(store, a.file, a.name)
    local sig_indent = indent_of(lines[a_sig + 1])
    local body_indent = indent_of(lines[a_open + 1])

    -- helper body = A's body lines, each hole's A-site replaced by its hp name
    local body = {}
    for i = a_open, a_close do body[#body + 1] = lines[i + 1] end
    local subs = {}                              -- body-line offset → { {sc,ec,name}, … }
    for i, p in ipairs(analysis.holes) do
        for _, r in ipairs(p.sites_a) do
            local off = at.sl(r) - a_open
            subs[off] = subs[off] or {}
            subs[off][#subs[off] + 1] = { sc = at.sc(r), ec = at.ec(r), name = hp[i] }
        end
    end
    for off, list in pairs(subs) do
        table.sort(list, function (x, y) return x.sc > y.sc end) -- right-to-left
        local l = body[off + 1]
        for _, s in ipairs(list) do l = l:sub(1, s.sc) .. s.name .. l:sub(s.ec + 1) end
        body[off + 1] = l
    end

    -- helper signature params = A's params ++ hole params
    local hparams = {}
    for _, p in ipairs(va.params) do hparams[#hparams + 1] = p end
    for _, name in ipairs(hp) do hparams[#hparams + 1] = name end
    local helper = { sig_indent .. ('local function %s(%s)'):format(hname, table.concat(hparams, ', ')) }
    for _, l in ipairs(body) do helper[#helper + 1] = l end
    helper[#helper + 1] = sig_indent .. 'end'
    helper[#helper + 1] = ''

    -- a copy's replacement body: `return hname(<its params>, <its fillings>)`
    local function call_line(params, sites_key)
        local args = {}
        for _, p in ipairs(params) do args[#args + 1] = p end
        for _, p in ipairs(analysis.holes) do
            args[#args + 1] = span_text(lines, p[sites_key][1]) -- the leaf's source, verbatim
        end
        return body_indent .. ('return %s(%s)'):format(hname, table.concat(args, ', '))
    end
    local call_a = call_line(va.params, 'sites_a')
    local call_b = call_line(vb.params, 'sites_b')

    -- ops: insert the helper before the EARLIER fn, replace each body with its call.
    -- (from0b > to0b means a pure insert; applied bottom-up in edits_for so disjoint
    -- regions never shift each other.)
    local earlier_sig = math.min(a_sig, b_sig)
    local ops = {
        { from0b = earlier_sig, to0b = earlier_sig - 1, new = helper },
        { from0b = a_open, to0b = a_close, new = { call_a } },
        { from0b = b_open, to0b = b_close, new = { call_b } },
    }

    return {
        verb = 'extract-helper',
        generation = store.generation,
        file = a.file,
        helper = hname,
        nparams = #hp,
        ops = ops,
        a = { id = a.id, name = a.name, ref = store.ref_of(a.id) },
        b = { id = b.id, name = b.name, ref = store.ref_of(b.id) },
        touched = { a.file },
        stamps = { [a.file] = txn.disk_stamp(root, a.file) },
    }
end

--- The edit callback (pure splice) — shared by preview and apply.
function M.edits_for(plan)
    return function (rel, before)
        if rel ~= plan.file then return before end
        local lines = vim.split(before, '\n', { plain = true })
        local ops = {}
        for _, o in ipairs(plan.ops) do ops[#ops + 1] = o end
        table.sort(ops, function (x, y) return x.from0b > y.from0b end) -- bottom-up
        for _, op in ipairs(ops) do
            for _ = op.from0b, op.to0b do table.remove(lines, op.from0b + 1) end
            for i = #op.new, 1, -1 do table.insert(lines, op.from0b + 1, op.new[i]) end
        end
        return table.concat(lines, '\n')
    end
end

--- Dry-run: (before, after) maps, nothing written.
function M.preview(store, plan)
    return txn.dryrun(store, plan, M.edits_for(plan))
end

--- Apply: the txn ladder + two synthesis gates (parses-clean + structural post-check).
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
    -- synthesis gates: the result must parse, and carry the helper + both calls
    local _, after = M.preview(store, plan)
    local text = after and after[plan.file]
    if not text then return nil, 'preview failed' end
    if not parses_clean(text) then
        return nil, 'the synthesized result does not parse — refusing (a synthesis bug, not your code)'
    end
    local need = ('local function %s('):format(plan.helper)
    local calls = select(2, text:gsub(('%s('):format(plan.helper):gsub('([^%w])', '%%%1'), ''))
    if not text:find(need, 1, true) or calls < 2 then
        return nil, 'the helper or a call site is missing from the result — refusing'
    end
    return txn.execute(store, plan, {
        helper = plan.helper, into = plan.file,
        a = plan.a.ref, b = plan.b.ref,
    }, M.edits_for(plan))
end

return M
