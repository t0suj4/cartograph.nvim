-- SUPPLY A RECONSTRUCTION'S PROLOGUE BINDINGS BY RE-EMITTING THEM (CART-0296).
--
-- ── THE COST THIS REPAYS ────────────────────────────────────────────────────
-- CART-0289 compiles a subject from its own declaration and does NOT load the module, so
-- `satisfied_by` correctly stops claiming the module load answers a same-file definition —
-- there is no module load. The hole keeps its `derived` tier (our analysis really did find
-- the definition) and gains no VALUE, and runoracle requires a value for every non-oracle
-- hole. Result: emittable and unrunnable, which is the CART-0284 distinction biting the
-- population CART-0289 created. Measured by `holecensus --verify`: 441 functions refused
-- before running, 395 of those holes same-file fixtures, 278 under a reconstruction.
--
-- ── AND THE ANSWER IS NOT AN EVALUATOR ──────────────────────────────────────
-- Three measurements were needed to see it, and two of them were wrong first. The last one
-- said 218 of these names were "not a module-level binding" — which was my line parser's
-- bug (a file-level `local function` sits INSIDE its own function-node range, so excluding
-- function ranges excluded the declaration itself). What the names actually are:
--     local at = require 'cartograph.at'        a REQUIRE
--     local function map_of(node) … end          a DECLARATION
--     local SUSPEND = { yield = true, … }        a TABLE, often multi-line
-- None of that needs evaluating in OUR process and serializing the result. RE-EMIT THE
-- DECLARATION and let the spec's own runtime evaluate it: no serializer limits (a function
-- value has no literal form, and this sidesteps that entirely), no fabrication, and the
-- spec runs THE SAME SOURCE the file runs. Partial evaluation in its most honest form is
-- not evaluation at all.
--
-- ── WHAT IS REFUSED, AND WHY THAT LINE ──────────────────────────────────────
-- Re-emitting `local db = connect()` would PERFORM the connection at spec load. So a
-- declaration is supplied only when evaluating it cannot reach the world: a `require` (the
-- spec already carries the aligned package.path as a derived premise), a literal, a table
-- constructor free of calls, or a function declaration (defining a closure runs nothing).
-- Anything else is refused BY NAME, and the hole stays a hole.
--
-- TIER: `derived`. We re-derived the binding from the file's own source; we did not observe
-- the subject's environment. The subject remains a RECONSTRUCTION at `derived`, so nothing
-- here strengthens the conclusion the spec supports — see the weakest-link rule.

local M = {}
local at = require 'cartograph.at'

-- How far a multi-line declaration may run before we give up. A table constructor spanning
-- more than this is not worth a spec's preamble.
M.MAX_LINES = 60

--- Every line of `file` that lies inside some OTHER function's body, so a module-level scan
--- can skip them. A file-level `local function foo()` is NOT excluded by its own range —
--- that bug cost a measurement, and it is the whole reason this module exists in this shape.
local function inner_lines(store, rel, selfname)
    local out = {}
    for _, m in ipairs(store.data.nodes or {}) do
        if (m.kind == 'function' or m.kind == 'method') and m.range and m.file == rel
            and m.name ~= selfname then
            local sl, el = at.sl(m.range) + 1, at.el(m.range) + 1
            -- a file-level local function's OWN declaration line stays visible: only its
            -- interior is masked, so a nested binding cannot masquerade as module-level
            for i = sl + 1, el do out[i] = true end
        end
    end
    return out
end

local CALL = '[%w_%.%]\'"]%s*%('

--- Is this declaration text safe to re-emit — that is, does evaluating it stay inside the
--- process? Returns (kind, nil) or (nil, why).
function M.classify(text)
    local body = (text or ''):gsub('^%s+', '')
    if body:match('^local%s+function%s') or body:match('^function%s') then
        return 'function'
    end
    local rhs = body:match('^local%s+[%w_]+%s*=%s*(.*)$')
    if not rhs then
        if body:match('^local%s+[%w_]+%s*$') then return 'literal' end   -- `local x`
        return nil, 'not a simple module-level binding'
    end
    -- a REQUIRE and nothing else: the spec already aligns package.path as a derived premise
    local mod = rhs:match('^require%s*%(?%s*[\'"]([%w%._%-/]+)[\'"]%s*%)?%s*$')
    if mod then return 'require' end
    if rhs:match('^{') then
        -- a constructor is safe only if nothing inside it CALLS: `{ a = f() }` would run f
        if rhs:gsub('%b{}', function (s) return s end):match(CALL)
            or rhs:match(CALL) then
            return nil, ('the table constructor calls something (`%s`), and re-emitting it'
                .. ' would PERFORM that call at spec load'):format(
                (rhs:match('([%w_%.]+%s*%()') or '?'):gsub('%s+', ''))
        end
        return 'table'
    end
    if rhs:match(CALL) then
        return nil, ('the declaration calls `%s`, and re-emitting it would PERFORM that'
            .. ' call at spec load'):format((rhs:match('([%w_%.]+)%s*%(') or '?'))
    end
    return 'literal'
end

--- THE MODULE-LEVEL DECLARATION of `name`, as text. Returns (text, kind) or (nil, why).
--- Multi-line declarations are grown until they COMPILE — the same trick CART-0289 uses to
--- find a declaration's end, and for the same reason: counting `end`s or matching braces
--- here would be a parser, and a bad one.
function M.decl_of(store, node, lines, name)
    local rel = node.file
    local masked = inner_lines(store, rel, name)
    local esc = name:gsub('%W', '%%%0')
    local pats = {
        '^local%s+function%s+' .. esc .. '%f[^%w_]',
        '^local%s+' .. esc .. '%f[^%w_]',
    }
    local ld = loadstring or load
    for i, l in ipairs(lines or {}) do
        if not masked[i] and l then
            local hit = false
            for _, p in ipairs(pats) do if l:match(p) then hit = true; break end end
            if hit then
                for n = 1, M.MAX_LINES do
                    if not lines[i + n - 1] then break end
                    local text = table.concat(lines, '\n', i, i + n - 1)
                    if ld(text) then
                        local kind, why = M.classify(text)
                        if not kind then return nil, why end
                        return text, kind
                    end
                end
                return nil, ('the declaration of `%s` does not compile within %d lines')
                    :format(name, M.MAX_LINES)
            end
        end
    end
    return nil, ('no module-level declaration of `%s` in %s'):format(name, rel)
end

--- SUPPLY every valueless same-file fixture hole of a plan. Returns (n, refusals).
--- Refusals are per NAME and are not an error: a partial preamble is better than none, and
--- an unsupplied fixture stays a hole that will fail loudly.
function M.supply(store, plan)
    local node = store.node(plan.fn_id)
    if not node then return nil, 'no such function' end
    local lines = store.content(node)
    local n, refusals = 0, {}
    for _, h in ipairs(plan.holes) do
        if h.kind == 'fixture' and h.tier == 'derived' and not h.value
            and not h.satisfied_by and not h.decl then
            local text, kind = M.decl_of(store, node, lines, h.name)
            if text then
                h.decl, h.decl_kind = text, kind
                h.basis = ('re-emitted from %s\'s own module-level declaration (a %s), so'
                    .. ' the spec evaluates the SAME SOURCE the file does rather than a'
                    .. ' value we serialized'):format(node.file, kind)
                h.by, h.filled_tier = 'prologue', 'derived'
                n = n + 1
            else
                refusals[#refusals + 1] = { name = h.name, why = kind }
            end
        end
    end
    plan.prologue = n > 0 and n or nil
    return n, refusals
end

--- The supply as report rows.
function M.report(store, plan)
    local L, A = {}, {}
    local function add(s, a) L[#L + 1] = s; A[#A + 1] = a end
    add(('prologue supply — %s (%s)'):format(plan.fn, plan.file), { file = plan.file })
    add('  a RECONSTRUCTED subject does not load its module, so the same-file names it reads', nil)
    add('  have no value. These are RE-EMITTED from their own declarations: the spec runs the', nil)
    add('  same source the file runs, which needs no evaluator and no serializer.', nil)
    add('', nil)
    local any = false
    for _, h in ipairs(plan.holes) do
        if h.kind == 'fixture' then
            any = true
            if h.decl then
                add(('  %-16s %s  [%s]'):format(h.name,
                    (h.decl:gsub('%s+', ' '):sub(1, 46)), h.decl_kind), nil)
            elseif h.satisfied_by then
                add(('  %-16s satisfied by %s'):format(h.name, h.satisfied_by), nil)
            else
                add(('  %-16s STILL A HOLE'):format(h.name), nil)
            end
        end
    end
    if not any then add('  this function reads no same-file names', nil) end
    return L, A
end

return M
