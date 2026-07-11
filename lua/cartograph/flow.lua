-- FLOW — the fine-grained statement+control model, the df successor
-- ([[cartograph-df-strangler]]). df collapses control statements' bodies into
-- one row; flow emits statements at EVERY nesting level and records a
-- CONTROL-PARENT (the region tree = CFG dominance df can't express). Increment
-- 1: the STRUCTURE only (l/kind/parent/pol), on-demand from an AST node (like
-- cfg.lua); def/use/dep + fold + extraction-fusion are later strangler steps.
--
-- PARITY ORACLE: flow's TOP-LEVEL rows (parent==0) reproduce df's coarse
-- statement partition (same lines) — that is what lets df's read-contract and
-- its `.l`-span consumers (extract/trace/reorder) stay unchanged while new
-- consumers opt into the fine view.

local M = {}

local BODY = { block = true, compound_statement = true }
-- control statements: recurse into their sub-regions
local CTRL = { if_statement = true, while_statement = true, for_statement = true,
    for_numeric_statement = true, for_generic_statement = true,
    foreach_statement = true, repeat_statement = true, do_statement = true,
    switch_statement = true, match_expression = true, try_statement = true }
-- clause nodes carrying a sub-region's statements
local CLAUSE = { else_statement = true, elseif_statement = true,
    else_clause = true, elseif_clause = true, else_if_clause = true,
    case_statement = true, default_statement = true,
    catch_clause = true, finally_clause = true }
local ELSEIF = { elseif_statement = true, elseif_clause = true, else_if_clause = true }

local function line(n) return (select(1, n:range())) + 1 end

-- the function body region (php `body` field / lua block child)
local function fn_body(fn)
    local b = fn:field('body')[1]
    if b then return b end
    for c in fn:iter_children() do if c:named() and BODY[c:type()] then return c end end
    return nil -- no body block (e.g. `function() end`) → no statements; NEVER
    -- fall back to `fn` itself (that walks the parameters as bogus statements)
end

function M.build(fnnode)
    local stmts = {}
    local emit, region, clause -- fwd

    -- emit `node` as a statement row (parent/pol) and recurse its sub-regions
    function emit(node, parent, pol)
        local t = node:type()
        local idx = #stmts + 1
        stmts[idx] = { l = line(node), kind = CTRL[t] and t or 'stmt',
            parent = parent, pol = pol }
        if CTRL[t] then
            local cond = node:field('condition')[1]
            for gc in node:iter_children() do
                if gc:named() and gc ~= cond and gc:type() ~= 'comment' then
                    local gt = gc:type()
                    if BODY[gt] then
                        region(gc, idx, 'body')          -- php block body / loop body
                    elseif CLAUSE[gt] then
                        clause(gc, idx)                  -- else/elseif/case/catch
                    elseif not BODY[gt] then
                        emit(gc, idx, 'body')            -- lua inline body statement
                    end
                end
            end
        end
    end

    -- a block/region: its direct named children are statements
    function region(block, parent, pol)
        for c in block:iter_children() do
            if c:named() and c:type() ~= 'comment' then emit(c, parent, pol) end
        end
    end

    -- a clause (else/elseif/case/catch): elseif is its own guard (control row);
    -- the rest region their statements under `parent`
    function clause(node, parent)
        if ELSEIF[node:type()] then
            emit(node, parent, 'elseif')
            return
        end
        local ct = node:type()
        local pol = ct:find('else') and 'else' or ct:find('case') and 'case'
            or ct:find('catch') and 'catch' or ct:find('finally') and 'finally'
            or ct:find('default') and 'default' or 'clause'
        local b = node:field('body')[1]
        if b and BODY[b:type()] then region(b, parent, pol) return end
        for c in node:iter_children() do
            if c:named() and c:type() ~= 'comment' then
                if BODY[c:type()] then region(c, parent, pol)
                else emit(c, parent, pol) end
            end
        end
    end

    local body = fn_body(fnnode)
    if body then region(body, 0, nil) end
    return { stmts = stmts }
end

--- coarse projection: the TOP-LEVEL statements (parent==0) — the df partition.
function M.coarse(flow)
    local out = {}
    for _, s in ipairs(flow.stmts) do
        if s.parent == 0 then out[#out + 1] = { l = s.l } end
    end
    return out
end

return M
