-- The branch-value LENS (read-only): for a function, annotate each CFG BRANCH
-- with what flows through it — the values LIVE entering the branch, with `~` on
-- a value whose reaching is HEDGED (flows only via a conservative edge). A
-- demand-scoped consumer of the flow CFG: it re-parses the one function, so it
-- needs NO fold ([[cartograph-branch-value-lens]]). MVP = read-only report; the
-- path-predicate / shape / oracle-concrete overlays are later increments.

local flow = require 'cartograph.flow'
local M = {}

local FN = { function_definition = true, method_declaration = true,
    function_declaration = true, method = true, function_item = true,
    method_definition = true, arrow_function = true }

-- store node → a built flow (demand re-parse of its file, cfg from ts.spec).
local function build_flow(store, node)
    if not (node and node.file) then return nil, 'node has no file' end
    local ts = require 'cartograph.providers.treesitter'
    local atr = require 'cartograph.at'
    local lang = ts.lang_of(node.file)
    local spec = lang and ts.spec[lang]
    if not spec then return nil, 'no flow spec for ' .. tostring(lang) end
    local ok, lines = pcall(vim.fn.readfile, store.abs(node.file))
    if not ok then return nil, 'cannot read ' .. node.file end
    local src = table.concat(lines, '\n')
    local pok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not pok then return nil, 'no parser for ' .. lang end
    local sl, target = atr.sl(node.range), nil
    local function rec(n)
        if FN[n:type()] and select(1, n:range()) == sl and not target then target = n end
        for c in n:iter_children() do if c:named() then rec(c) end end
    end
    rec(parser:parse()[1]:root())
    if not target then return nil, 'could not locate the function AST' end
    local cfg = { pfield = spec.params_field, df_ids = spec.df_ids,
        regime = spec.regime,
        method = spec.is_method and spec.is_method(node.name or '', target) or false }
    return flow.build(target, src, cfg)
end

--- PURE: per branch point (a row with >1 distinct successor), what flows through
--- each outgoing edge. Returns (heads, hedged): heads = list of
--- { head, l, kind, branches = { { to=<row|'exit'>, l, pol, live={vars} } } };
--- hedged = { var -> true } for vars with any hedged reaching (rendered `~`).
function M.branches(fl)
    local S = fl.stmts
    local cfg = flow.successors(fl)
    local lv = flow.liveness(fl)
    local rc = flow.reaching_cfg(fl)
    local hedged = {}
    for _, e in ipairs(rc) do if e.hedged and next(e.hedged) then hedged[e.var] = true end end
    local out = {}
    for i, s in ipairs(S) do
        local seen, targets = {}, {}
        for _, t in ipairs(cfg.succ[i] or {}) do
            if not seen[t] then seen[t] = true; targets[#targets + 1] = t end
        end
        if #targets > 1 then
            local h = { head = i, l = s.l, kind = s.kind, branches = {} }
            for _, t in ipairs(targets) do
                local live = {}
                if t ~= 'exit' and lv.live_in[t] then
                    for v in pairs(lv.live_in[t]) do live[#live + 1] = v end
                    table.sort(live)
                end
                h.branches[#h.branches + 1] = { to = t, live = live,
                    l = (t ~= 'exit') and S[t].l or nil,
                    pol = (t ~= 'exit') and S[t].pol or nil }
            end
            out[#out + 1] = h
        end
    end
    return out, hedged
end

--- The read-only report for a focused function (store node id).
function M.report(store, fn_id)
    local node = store.node(fn_id)
    local fl, why = build_flow(store, node)
    if not fl then return { 'branch-values: ' .. (why or 'unavailable') } end
    local heads, hedged = M.branches(fl)
    local L = { ('branch-values: %s — what flows through each branch')
        :format((node and node.name) or fn_id), '' }
    if #heads == 0 then L[#L + 1] = '  (no branch points)'; return L end
    local function mark(vars)
        local o = {}
        for _, v in ipairs(vars) do o[#o + 1] = hedged[v] and (v .. '~') or v end
        return table.concat(o, ', ')
    end
    for _, h in ipairs(heads) do
        L[#L + 1] = ('%s @L%d'):format(h.kind, h.l)
        for _, b in ipairs(h.branches) do
            L[#L + 1] = ('  → %-7s %-6s  %s'):format(
                b.pol or (b.to == 'exit' and 'return' or 'next'),
                b.to == 'exit' and 'exit' or ('L' .. b.l),
                #b.live > 0 and mark(b.live) or '·')
        end
    end
    L[#L + 1] = ''
    L[#L + 1] = '(~ = value whose reaching is hedged — flows only via a conservative edge)'
    return L
end

return M
