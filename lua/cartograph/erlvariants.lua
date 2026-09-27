-- erlvariants — ONE CALL, SEVERAL DEFINITIONS, ONE PER BUILD: preprocessor variants (CART-1133). erlang.
-- @langs erlang
--
-- ★ THE REFUSAL WAS HONEST AND INCOMPLETE. ejabberd_web_admin.erl defines lists_zipwith3/5 twice:
--     -ifdef(OTP_BELOW_26).   lists_zipwith3(…) -> <a hand-rolled zip>.   -endif.
--     -ifndef(OTP_BELOW_26).  lists_zipwith3(…) -> lists:zipwith3(…).     -endif.
-- A call to it names two same-file definitions, and the resolver refuses `samefile` — right, it cannot know which.
-- But the tree says exactly which ONE runs in any build: the two are mutually exclusive by the preprocessor. So the
-- honest answer is not "unknown", it is the SET, each member the target under one configuration — and with only a
-- refusal both definitions read as dead (14 of the 29 dead-function findings left on ejabberd: ejabberd_app's
-- ELIXIR/else pairs, lists_zipwith3, lists_zip3_pad).
--
-- EXCLUSIVE, DERIVED FROM THE BRANCHES (erlfeatures.regions): each definition gets its condition path — the
-- (macro, defined?) pairs of the -ifdef/-ifndef/-else branches around it. Two definitions are VARIANTS when some
-- macro appears in both paths with opposite polarity (one region's two branches, or an -ifdef and an -ifndef of the
-- same macro). A `samefile` refusal whose candidates are pairwise variants gets a hedged ref to EACH, `variant = true`,
-- and its rule becomes `variants` (the set is known; which member runs is the build's). Which branch compiles BY
-- DEFAULT is erlfeatures' question, deliberately not asked here: both members are live code in some build.
-- ⚠ SESSION-LIVE, a post-pass (cartograph.postpass), like erldispatch.
local M = {}

local F = require 'cartograph.erlfeatures'

-- a definition's condition path: { [macro] = true (defined) | false (undefined) }; nil for a contradiction
local function path_at(regions, line)
    local p = {}
    for _, r in ipairs(regions) do
        local then_a, then_b = r.start + 1, (r.else_ or r.stop) - 1
        local else_a, else_b = r.else_ and r.else_ + 1, r.else_ and r.stop - 1
        local pol
        if line >= then_a and line <= then_b then pol = r.kind == 'ifdef'
        elseif else_a and line >= else_a and line <= else_b then pol = r.kind ~= 'ifdef' end
        if pol ~= nil then p[r.macro] = pol end
    end
    return p
end

local function exclusive(a, b)
    for m, pol in pairs(a) do if b[m] ~= nil and b[m] ~= pol then return m end end
    return nil
end

function M.attach(data)
    local stats = { refusals = 0, variants = 0, edges = 0, rows = {} }
    local root = data and data.root
    if not root or root:match('^%w+://') then return stats end
    local byid = {}
    for _, n in ipairs(data.nodes or {}) do byid[n.id] = n end
    local regions = {}
    local at = require 'cartograph.at'
    local refEdge = {}
    for _, e in ipairs(data.edges or {}) do if e.kind == 'ref' then refEdge[e.from .. '\31' .. e.to] = e end end
    for _, c in ipairs(data.calls or {}) do
        local r = c.refused
        if r and r.rule == 'samefile' and r.cands and #r.cands >= 2 and c.file and c.file:match('%.erl$') and c.fn then
            stats.refusals = stats.refusals + 1
            regions[c.file] = regions[c.file] or F.regions(root .. '/' .. c.file)
            local paths, ok_all, macro = {}, true, nil
            for i, id in ipairs(r.cands) do
                local n = byid[id]
                local sl = n and n.range and (type(n.range) == 'table' and n.range.start and n.range.start.line or at.sl(n.range))
                if not sl then ok_all = false; break end
                paths[i] = path_at(regions[c.file], sl + 1)
            end
            for i = 1, ok_all and #paths or 0 do
                for j = i + 1, #paths do
                    local m = exclusive(paths[i], paths[j])
                    if not m then ok_all = false end
                    macro = macro or m
                end
            end
            if ok_all then
                stats.variants = stats.variants + 1
                r.rule = 'variants'
                r.macro = macro
                for _, id in ipairs(r.cands) do
                    local k = c.fn .. '\31' .. id
                    local e = refEdge[k]
                    if not e then
                        e = { from = c.fn, to = id, kind = 'ref', at = {}, inferred = true, variant = true }
                        refEdge[k] = e
                        data.edges[#data.edges + 1] = e
                        stats.edges = stats.edges + 1
                    end
                    if c.at then e.at[#e.at + 1] = c.at end
                end
                stats.rows[#stats.rows + 1] = { file = c.file, line = c.line, callee = c.callee, macro = macro, cands = r.cands }
            end
        end
    end
    data.erlvariants = stats
    return stats
end

function M.summary(s)
    if not s or s.variants == 0 then return nil end
    return ('erlvariants: %d of %d same-file refusals are preprocessor variants (one definition per build); %d edge(s)')
        :format(s.variants, s.refusals, s.edges)
end

return M
