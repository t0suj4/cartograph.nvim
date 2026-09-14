-- Hoist-nested-closure: lift a nested `local function` out to module scope — the
-- giant-function decomposition verb (e.g. the closures buried in a 1800-line M.extract).
-- The inverse of untangle.body_extractable's nested-refusal: a nested closure is hoistable
-- exactly when it CAPTURES NOTHING from its enclosing function(s) — every free read must
-- resolve to a module-level name or a global, never an enclosing local/param (which would
-- become nil at module scope). A capture means "parameterize it first" (the extract-helper
-- job), so we refuse and name the captured variable. Rides the txn contract like reorder.
--
-- SOUND SUBSET (refuse otherwise): the closure captures no enclosing local, uses no `...`,
-- its name doesn't collide with an existing module-level def, and it occupies whole source
-- lines (not shared with other code). Recursion by its own name is fine — the name follows
-- it to module scope. Collision → refuse (renaming + call-site rewrite is banked).

local M = {}
local at = require 'cartograph.at'
local txn = require 'cartograph.txn'

-- outer strictly contains inner (by range, inclusive; a distinct node)
local function contains(outer, inner)
    if not (outer and inner) then return false end
    if at.sl(outer) > at.sl(inner) or at.el(outer) < at.el(inner) then return false end
    if at.sl(outer) == at.sl(inner) and at.sc(outer) > at.sc(inner) then return false end
    if at.el(outer) == at.el(inner) and at.ec(outer) < at.ec(inner) then return false end
    return true
end

-- ⚠ `body_facts` MOVED TO `expr.free` (CART-0912). The question it answers —
-- which names does this function READ that it does not DEFINE — turned out to be
-- the one three other instruments were each answering badly over TEXT: the
-- move-set's capture rung (`body:find`), a free-identifier scan (CALL targets
-- only) and the parts fence. Text has syntactic roles and the IR does not, which
-- is why `key` (a value), `slice` (a call) and `RUNG_RANK` (an index) each hid
-- from a different one of them. This was the correct implementation, private to
-- one module; promoting it is the fix.
local function body_facts(store, id, skip)
    return require('cartograph.expr').free(store, id, { skip = skip })
end

--- Plan to hoist the nested closure `closure_id` to module scope, or (nil, reason).
function M.plan(store, closure_id)
    local node = store.node and store.node(closure_id)
    if not node then return nil, 'no such function' end
    if node.kind ~= 'function' and node.kind ~= 'method' then return nil, 'not a function' end
    if not node.file:match('%.lua$') then return nil, 'only Lua is supported for now' end

    -- enclosing functions (same file, strictly containing the closure)
    local encl = {}
    for _, n in ipairs(store.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.id ~= closure_id
            and n.file == node.file and contains(n.range, node.range) then
            encl[#encl + 1] = n
        end
    end
    if #encl == 0 then return nil, 'already at module scope (not a nested closure)' end
    -- the outermost enclosing fn = the hoist anchor (insert before it)
    local anchor = encl[1]
    for _, n in ipairs(encl) do if at.sl(n.range) < at.sl(anchor.range) then anchor = n end end

    local short = (node.name or ''):match('[%w_]+$') or node.name
    local self = body_facts(store, closure_id)
    if not self then return nil, 'no analyzable body' end
    if self.vararg then return nil, 'the closure uses vararg `...` from its enclosing scope' end

    -- CAPTURE gate: no free read may be a local/param of ANY enclosing function
    local encl_locals = {}
    -- the ranges of EVERY function nested inside this enclosing one: their
    -- declarations are theirs, not the parent's
    for _, e in ipairs(encl) do
        local inner = {}
        for _, n2 in ipairs(store.data.nodes) do
            if (n2.kind == 'function' or n2.kind == 'method') and n2.id ~= e.id
                and n2.file == e.file and contains(e.range, n2.range) then
                inner[#inner + 1] = n2.range
            end
        end
        local f = body_facts(store, e.id, inner)
        if f then
            for k in pairs(f.params) do encl_locals[k] = true end
            for k in pairs(f.defs) do encl_locals[k] = true end
        end
    end
    -- ★★★ THE WRITE CAPTURE, WHICH THIS GATE COULD NOT SEE (CART-0905). `reads`
    -- is every use NOT in `params` and NOT in `defs`, so a name this body
    -- ASSIGNS lands in `defs` and is excluded from `reads` — invisible here.
    -- MEASURED: a closure doing `count = count + n` on an enclosing local was
    -- ALLOWED to hoist while one that merely READ it was refused. Hoisting the
    -- first turns the assignment into a write to a GLOBAL and silently destroys
    -- the closure; `parses` cannot catch it, because it parses.
    --
    -- ⚠ CONSERVATIVE BY CONSTRUCTION, AND DELIBERATELY SO. A name in both this
    -- body's `defs` and an enclosing local is EITHER a write to that local OR a
    -- local of the same name SHADOWING it. Telling the two apart needs the
    -- declaration-vs-assignment distinction — the spec declares it
    -- (`write_gate` + `is_write`, 11 specs) and computes it at ingest as
    -- `MF_WRITE`, but no accessor reaches it from here. Refusing BOTH
    -- over-refuses a shadow and never under-refuses a write, which is the only
    -- safe direction for a verb that edits code.
    for d in pairs(self.defs) do
        if d ~= short and encl_locals[d] then
            return nil, ('assigns enclosing local `%s` (or shadows it) — hoisting'
                .. ' would write a different variable'):format(d),
                { writes = d }
        end
    end
    -- ★★★ THE WHOLE SET, NOT AN ARBITRARY ELEMENT. `reads` is a SET, so
    -- returning on the first match reports one captured name chosen by hash
    -- order — the same closure named `live` on one run and `scratch` on the
    -- next. A caller deciding whether a FAMILY captures uniformly (CART-0904)
    -- would be comparing coin flips, and a lift built on one name would miss
    -- every other capture the body still makes.
    local captured = {}
    for r in pairs(self.reads) do
        if r ~= short and encl_locals[r] then captured[#captured + 1] = r end
    end
    table.sort(captured)

    for _, r in ipairs(captured) do
        if true then
            -- ⚠ THE NAME RIDES AS STRUCTURE, NOT ONLY IN THE MESSAGE. A caller
            -- that needs to know WHICH local is captured — `clones`, deciding
            -- whether a family's members all capture the same one — would
            -- otherwise have to parse a string we formatted, which is the
            -- pattern CART-0746 cost a day to. Extra returns are ignored by
            -- every existing caller.
            return nil, ('captures enclosing local `%s` — parameterize it first (extract-helper)'):format(r),
                { captures = r, captured = captured }
        end
    end

    -- COLLISION: a module-level def already named `short` (not inside any function)
    for _, n in ipairs(store.data.nodes) do
        if n.file == node.file and n.id ~= closure_id and n.name
            and (n.name:match('[%w_]+$') == short)
            and (n.kind == 'function' or n.kind == 'method' or n.kind == 'var') then
            local nested = false
            for _, e in ipairs(store.data.nodes) do
                if (e.kind == 'function' or e.kind == 'method') and e.id ~= n.id
                    and e.file == n.file and contains(e.range, n.range) then nested = true; break end
            end
            if not nested then return nil, ('a module-level `%s` already exists'):format(short) end
        end
    end

    -- source span (whole lines); refuse if shared with other code on its boundary lines
    local s0, e0 = at.sl(node.range), at.el(node.range)
    local root = store.data.root
    local text = txn.read_file(root, node.file)
    if not text then return nil, 'cannot read ' .. node.file end
    local flines = vim.split(text, '\n', { plain = true })
    local first = flines[s0 + 1] or ''
    -- the closure must start the line (only leading whitespace before it)
    if not first:match('^%s*local%s+function') and not first:match('^%s*function') then
        return nil, 'the closure does not start its own line (shared with other code)'
    end
    local base_indent = first:match('^%s*') or ''
    local src_lines = {}
    for i = s0, e0 do
        local l = flines[i + 1] or ''
        -- de-indent by the closure's base indent so it sits cleanly at module level
        src_lines[#src_lines + 1] = (l:sub(1, #base_indent) == base_indent) and l:sub(#base_indent + 1) or l
    end

    local dst0 = at.sl(anchor.range) -- insert before the outermost enclosing fn
    return txn.protocol({
        verb = 'hoist-closure', generation = store.generation,
        guards = { 'parses' }, -- CART-0769: every text-editing verb owes rung 0
        file = node.file, name = short, anchor = anchor.name,
        src_s0 = s0, src_e0 = e0, src_lines = src_lines, dst0 = dst0,
        ref = store.ref_of(closure_id), fn_id = closure_id,
        touched = { node.file },
        stamps = { [node.file] = txn.disk_stamp(root, node.file) },
    }, M.edits_for)
end

--- The edit callback: cut the nested closure and re-insert it (de-indented) before the
--- outermost enclosing function.
function M.edits_for(plan)
    return function (rel, before)
        if rel ~= plan.file then return before end
        local lines = vim.split(before, '\n', { plain = true })
        for _ = plan.src_s0, plan.src_e0 do table.remove(lines, plan.src_s0 + 1) end
        -- a blank line separates the hoisted closure from the enclosing fn
        local block = {}
        for _, l in ipairs(plan.src_lines) do block[#block + 1] = l end
        block[#block + 1] = ''
        local ins0 = plan.dst0 -- dst is above the removed span (a nested closure sits below its fn's start)
        for i = #block, 1, -1 do table.insert(lines, ins0 + 1, block[i]) end
        return table.concat(lines, '\n')
    end
end

function M.preview(store, plan)
    return txn.dryrun(store, plan)
end

function M.apply(store, plan)
    if next(store.moveset or {}) then return nil, 'a move-set is staged — apply or clear it first' end
    -- txn.verify covers the file-stamp CAS (the whole file is unchanged since planning),
    -- so the closure's source is guaranteed intact — no separate span-CAS needed.
    local bad = txn.verify(store, plan, { { id = plan.fn_id, name = plan.name, ref = plan.ref, what = 'closure' } })
    if bad then return nil, bad end
    -- the result must parse clean (a body/scope-changing edit)
    local _, after = M.preview(store, plan)
    local ok, parser = pcall(vim.treesitter.get_string_parser, after and after[plan.file] or '', 'lua')
    if not (ok and parser and not parser:parse()[1]:root():has_error()) then
        return nil, 'the hoisted result does not parse — refusing'
    end
    return txn.execute(store, plan, { name = plan.name, from = plan.anchor })
end

return M
