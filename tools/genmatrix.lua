-- genmatrix — COMBINATORIAL control-form generation (CART-0405).
--
-- ★ THE BESTIARY IS A ONE-DIMENSIONAL CENSUS AND EVERY BUG WAS TWO-DIMENSIONAL.
-- tools/gen.lua's control bestiary plants each FORM once, and `ctrlcensus --coverage` asks
-- "does this corpus contain this form" — 13/13 for java, 10/10 for js, honest numbers about
-- the wrong question. Every defect the row model gave up this week was at an INTERSECTION:
--
--   elsif x CHAIN-LENGTH-2      CART-0397  everything past link 1 had NO ROWS (shipped)
--   block x CONDITION-POSITION  CART-0363B a different emit path entirely
--   block x ASSIGNMENT-RHS      CART-0363B no field on the row's node can find it
--   rescue x INSIDE-A-BLOCK     CART-0363B the clause routing had to survive one more level
--   block x NO-OWNER (bare)     CART-0401  a region with no rows, where no census looks
--   modifier x LOOP             CART-0394  the cell nobody has ever emitted
--
-- CART-0394 says it outright: "the missing cell is the INTERSECTION — MODIFIER x LOOP —
-- which no count asks about." A per-form bestiary cannot plant any of them, however complete
-- its form list. So: emit the CROSS PRODUCT, one method per cell, named by its coordinates.
--
-- ★ WHAT MAKES THIS AFFORDABLE IS THAT THE ANSWER KEY IS GONE. gen.lua's analysis tier
-- plants ground truth (~60 lines of emitter per scenario), which is why it is lua-only. A
-- grid feeds ORACLES THAT NEED NO KEY instead — rowcensus (a planted region must have rows),
-- expr.gate (reads == use u rmw), dfparity (coarse == the independent df), translit
-- (emit -> reparse -> identical IR). The cost is the emitter, not the key.
--
-- ★ AND NOTHING IS PERSISTED. tools/bench.lua materializes a synthetic corpus ONLY WHEN ITS
-- DIRECTORY IS MISSING, so a cached corpus is authoritative and the only guard against it
-- going stale is a hand-bumped GEN_VERSION inside the path (`java-g6-s1`). That is the
-- stale-cache shape, one layer up from the extractor's own. This module has NO version and
-- writes nowhere: tools/gridgate.lua mints it into a tempdir per run and checks determinism
-- by minting it TWICE. `--out` exists for a human inspecting a red cell; no gate reads it.
--
-- ── THE AXES ────────────────────────────────────────────────────────────────────────────
--   FORM   the control statement under test
--   SHELL  what encloses it — top / inside a loop / inside an if / inside a catch
--   BODY   empty / one statement / two / the SAME form nested once
--   CHAIN  1..3 links, for the forms that chain (else-if, catch, switch arms)
--
-- ★ EVERY CELL CARRIES THE NODE-TYPE HISTOGRAM IT CLAIMS TO HAVE PLANTED, counted by the
-- emitter as it writes. "It parsed" is not "it planted the form" — `ctrlcensus --coverage`
-- exists because synjava contained `if` and `for` and was called complete. A cell that does
-- not produce the node type it meant to is a SILENT ZERO, and the exact count (not >= 1)
-- is what makes a dropped INNER form visible when the SHELL contributes the same type.
--
-- ★ AND THE POPULATION IS DELIBERATELY WRONG. 82 of 92 real java `switch_rule`s are
-- expression-bodied; a uniform grid says otherwise. This answers "can this form be SEEN at
-- all", never "how much does it matter" — so its census is pinned APART from the real
-- corpora and must never be used to recalibrate one.

local M = {}

-- ── java ────────────────────────────────────────────────────────────────────────────────
-- `node` = the tree-sitter type the form is claimed to plant. `chain` = how many links the
-- form can carry (absent = 1). `nobody` = the BODY variants this form cannot legally take.
-- ★ `unbraced` IS THE C-FAMILY AXIS, and it is not a corner: `if (c) stmt;` with no block.
-- A braced body is a `block`, which flow's BODY set recognises and du stops at; an unbraced
-- one is the statement itself, which neither does — so the head row harvests its own body.
-- Illegal for the forms whose grammar REQUIRES a block (sync, try) and meaningless for a
-- switch arm, which is a statement LIST rather than a single statement.
local JAVA_FORMS = {
    { id = 'ifs',      node = 'if_statement',                  chain = 3 },
    { id = 'whiles',   node = 'while_statement' },
    { id = 'dowhile',  node = 'do_statement' },
    { id = 'for3',     node = 'for_statement' },
    { id = 'foreach',  node = 'enhanced_for_statement' },
    { id = 'switchg',  node = 'switch_block_statement_group',  chain = 3,
        nobody = { empty = true, unbraced = true } },
    { id = 'switchr',  node = 'switch_rule',                   chain = 3,
        nobody = { empty = true, unbraced = true } },
    { id = 'trycatch', node = 'catch_clause',                  chain = 3,
        nobody = { unbraced = true } },
    { id = 'tryres',   node = 'try_with_resources_statement',  nobody = { unbraced = true } },
    { id = 'sync',     node = 'synchronized_statement',        nobody = { unbraced = true } },
    { id = 'labeled',  node = 'labeled_statement' },
}
-- ★ SHELL IS "WHAT ENCLOSES THE FORM", and each entry is a DIFFERENT EMIT PATH, not decor.
-- `inelse` is not `inif` (the alternative branch is reached by other code than the
-- consequence); `indo` is a POST loop's body (the condition is re-emitted AFTER it);
-- `inlambda` is a body flow stops at on the promise that something else mints a node for it.
local SHELLS = { 'top', 'inloop', 'inif', 'inelse', 'indo', 'incatch', 'inlambda' }
local BODIES = { 'empty', 'one', 'two', 'nest', 'unbraced' }

--- emit the java grid. Returns { files = {name -> src}, cells = {...}, skipped = {...} }
--- A cell is { m = <method name>, form, shell, body, chain, want = { [node type] = n } }.
--- `skipped` is NOT silent: an illegal combination is recorded with its reason, because a
--- dropped cell that nobody counts reads exactly like a covered one.
local function java(opts)
    opts = opts or {}
    local fname = 'Grid.java'
    local B, cells, skipped = {}, {}, {}
    local function w(l) B[#B + 1] = l end
    local pad = function (n) return ('    '):rep(n) end

    w('import java.util.List;')
    w('')
    w('public class Grid {')
    w('    static int step(int v) { return v + 1; }')
    w('    static int twice(int v) { return v * 2; }')
    w('    enum Mode { FAST, SLOW, OFF }')
    w('')

    -- the per-cell emitter. `want` accumulates the node-type histogram AS IT WRITES, so the
    -- claim and the code cannot drift: there is one place that decides both.
    local function cell(form, shell, body, chain)
        local want = {}
        local function claim(t) want[t] = (want[t] or 0) + 1 end
        local lbl = 0

        -- BODY: the statements a form encloses. `nest` re-enters the SAME form at chain 1,
        -- which is the axis CART-0397 lived on (a chain, not a form, was truncated).
        local emit_form -- fwd
        local function emit_body(kind, ind)
            if kind == 'empty' then return end
            if kind == 'one' or kind == 'unbraced' then
                w(pad(ind) .. 'acc = step(acc);') return
            end
            if kind == 'two' then
                w(pad(ind) .. 'acc = step(acc);')
                w(pad(ind) .. 'acc = twice(acc);')
                return
            end
            emit_form(form, 1, 'one', ind) -- nest
        end
        -- `unbraced` drops the braces the other variants carry. Kept as a pair of helpers so
        -- every form opts in the same way and no form can half-support it.
        local function ob(kind, p, head) -- open brace (or not)
            w(p .. head .. (kind == 'unbraced' and '' or ' {'))
        end
        local function cb(kind, p, tail) -- close brace (or not)
            if kind ~= 'unbraced' then w(p .. '}' .. (tail or '')) elseif tail then w(p .. tail) end
        end

        function emit_form(f, nchain, bodykind, ind)
            local p = pad(ind)
            if f == 'ifs' then
                claim('if_statement')
                if bodykind == 'unbraced' then
                    -- the chain still chains; only the braces go
                    w(p .. 'if (m > 0)')
                    emit_body(bodykind, ind + 1)
                    for i = 2, nchain do
                        claim('if_statement')
                        w(p .. 'else if (m > ' .. i .. ')')
                        emit_body(bodykind, ind + 1)
                    end
                    if nchain > 1 then
                        w(p .. 'else')
                        emit_body(bodykind, ind + 1)
                    end
                else
                    w(p .. 'if (m > 0) {')
                    emit_body(bodykind, ind + 1)
                    for i = 2, nchain do
                        claim('if_statement') -- java spells `else if` as a NESTED if_statement
                        w(p .. '} else if (m > ' .. i .. ') {')
                        emit_body(bodykind, ind + 1)
                    end
                    if nchain > 1 then
                        w(p .. '} else {')
                        emit_body(bodykind, ind + 1)
                    end
                    w(p .. '}')
                end
            elseif f == 'whiles' then
                claim('while_statement')
                ob(bodykind, p, 'while (acc < 1)')
                emit_body(bodykind, ind + 1)
                if bodykind ~= 'unbraced' then w(p .. '    break;') end
                cb(bodykind, p)
            elseif f == 'dowhile' then
                claim('do_statement')
                ob(bodykind, p, 'do')
                emit_body(bodykind, ind + 1)
                if bodykind == 'unbraced' then w(p .. 'while (false);')
                else w(p .. '} while (false);') end
            elseif f == 'for3' then
                claim('for_statement')
                ob(bodykind, p, 'for (int i = 0; i < 2; i++)')
                emit_body(bodykind, ind + 1)
                cb(bodykind, p)
            elseif f == 'foreach' then
                claim('enhanced_for_statement')
                ob(bodykind, p, 'for (String x : xs)')
                emit_body(bodykind, ind + 1)
                if bodykind ~= 'unbraced' then w(p .. '    acc += x.length();') end
                cb(bodykind, p)
            elseif f == 'switchg' then
                claim('switch_expression')
                w(p .. 'switch (m) {')
                for i = 1, nchain do
                    claim('switch_block_statement_group')
                    w(p .. '    case ' .. i .. ':')
                    emit_body(bodykind, ind + 2)
                    w(p .. '        break;')
                end
                claim('switch_block_statement_group')
                w(p .. '    default:')
                emit_body(bodykind, ind + 2)
                w(p .. '}')
            elseif f == 'switchr' then
                claim('switch_expression')
                w(p .. 'switch (Mode.FAST) {')
                for i = 1, nchain do
                    claim('switch_rule')
                    -- both arm shapes: EXPRESSION-bodied is the real-world majority
                    -- (82 of 92 in the elasticsearch sample), block-bodied is the rarer
                    -- path a block-only fixture would exercise and call covered.
                    if bodykind == 'one' and i == 1 then
                        w(p .. '    case FAST -> acc = step(acc);')
                    else
                        w(p .. '    case ' .. ({ 'FAST', 'SLOW', 'OFF' })[i] .. ' -> {')
                        emit_body(bodykind, ind + 2)
                        w(p .. '    }')
                    end
                end
                claim('switch_rule')
                w(p .. '    default -> {')
                emit_body(bodykind, ind + 2)
                w(p .. '    }')
                w(p .. '}')
            elseif f == 'trycatch' then
                claim('try_statement')
                w(p .. 'try {')
                emit_body(bodykind, ind + 1)
                local ex = { 'IllegalStateException', 'IllegalArgumentException', 'RuntimeException' }
                for i = 1, nchain do
                    claim('catch_clause')
                    w(p .. '} catch (' .. ex[i] .. ' e' .. i .. ') {')
                    emit_body(bodykind, ind + 1)
                end
                w(p .. '}')
            elseif f == 'tryres' then
                claim('try_with_resources_statement')
                claim('catch_clause') -- Reader.close() throws, so the resource form needs one
                w(p .. 'try (java.io.StringReader r = new java.io.StringReader("s")) {')
                emit_body(bodykind, ind + 1)
                w(p .. '} catch (Exception e) {')
                w(p .. '    acc = twice(acc);')
                w(p .. '}')
            elseif f == 'sync' then
                claim('synchronized_statement')
                w(p .. 'synchronized (lock) {')
                emit_body(bodykind, ind + 1)
                w(p .. '}')
            elseif f == 'labeled' then
                lbl = lbl + 1
                claim('labeled_statement')
                claim('while_statement')
                ob(bodykind, p, 'L' .. lbl .. ': while (acc < 1)')
                emit_body(bodykind, ind + 1)
                if bodykind ~= 'unbraced' then w(p .. '    break L' .. lbl .. ';') end
                cb(bodykind, p)
            else
                error('genmatrix: no java emitter for form ' .. tostring(f))
            end
        end

        -- SHELL: what encloses the form. Each shell contributes its OWN node type to the
        -- claim, which is why the gate compares exact counts — a shell `if` must not be able
        -- to stand in for a dropped inner one.
        local name = ('c_%s_%s_%s_ch%d'):format(form, shell, body, chain)
        w('    static int ' .. name .. '(int m, List<String> xs, Object lock) {')
        w('        int acc = 0;')
        if shell == 'top' then
            emit_form(form, chain, body, 2)
        elseif shell == 'inloop' then
            claim('for_statement')
            w('        for (int s = 0; s < 2; s++) {')
            emit_form(form, chain, body, 3)
            w('        }')
        elseif shell == 'inif' then
            claim('if_statement')
            w('        if (m > 0) {')
            emit_form(form, chain, body, 3)
            w('        }')
        elseif shell == 'inelse' then
            -- ★ NOT THE SAME PATH AS `inif`: the ALTERNATIVE branch is reached by different
            -- code than the consequence, and CART-0397 was a bug that lived only there.
            claim('if_statement')
            w('        if (m > 0) {')
            w('            acc = step(acc);')
            w('        } else {')
            emit_form(form, chain, body, 3)
            w('        }')
        elseif shell == 'indo' then
            -- a POST loop's body: its condition is re-emitted AFTER the body, so anything
            -- ordering-sensitive sees a different row sequence here than in a pre-loop
            claim('do_statement')
            w('        do {')
            emit_form(form, chain, body, 3)
            w('        } while (false);')
        elseif shell == 'inlambda' then
            -- ★ flow STOPS at a lambda ("the nested-fn STOP, not the enclosure set: only
            -- where a node is MINTED to hold the rows"). Java mints one for an anonymous
            -- class method and NOT for a lambda, so this shell asks whether the promise
            -- holds. Measured before the axis existed: it does not — the body vanishes.
            claim('lambda_expression')
            w('        Runnable r = () -> {')
            emit_form(form, chain, body, 3)
            w('        };')
            w('        r.run();')
        elseif shell == 'incatch' then
            claim('try_statement')
            claim('catch_clause')
            w('        try {')
            w('            acc = step(acc);')
            w('        } catch (RuntimeException e0) {')
            emit_form(form, chain, body, 3)
            w('        }')
        end
        w('        return acc;')
        w('    }')
        w('')
        cells[#cells + 1] = { m = name, form = form, shell = shell,
            body = body, chain = chain, want = want }
    end

    for _, F in ipairs(JAVA_FORMS) do
        for _, shell in ipairs(SHELLS) do
            for _, body in ipairs(BODIES) do
                for chain = 1, (F.chain or 1) do
                    if F.nobody and F.nobody[body] then
                        skipped[#skipped + 1] = { form = F.id, shell = shell, body = body,
                            chain = chain, why = 'body variant not legal for this form' }
                    else
                        cell(F.id, shell, body, chain)
                    end
                end
            end
        end
    end
    w('}')
    return { files = { [fname] = table.concat(B, '\n') .. '\n' },
        cells = cells, skipped = skipped, file = fname, lang = 'java' }
end

local LANGS = { java = java }

--- Emit the grid for `lang`. Pure: returns text, writes nothing.
---@param lang string
---@param opts table|nil
function M.grid(lang, opts)
    local f = LANGS[lang]
    if not f then
        error('genmatrix: no grid for ' .. tostring(lang)
            .. ' (have: ' .. table.concat(vim.tbl_keys(LANGS), ', ') .. ')')
    end
    return f(opts)
end

function M.langs()
    local out = {}
    for k in pairs(LANGS) do out[#out + 1] = k end
    table.sort(out)
    return out
end

--- Materialize a grid into `dir`. The ONLY writer, and nothing in a gate calls it with a
--- path that outlives the run (see the ★ note at the top).
function M.write(g, dir)
    vim.fn.mkdir(dir, 'p')
    for name, src in pairs(g.files) do
        vim.fn.writefile(vim.split(src, '\n', { plain = true }), dir .. '/' .. name)
    end
    return dir
end

return M
