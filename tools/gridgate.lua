-- gridgate — run the COMBINATORIAL grid (tools/genmatrix.lua) past the keyless oracles.
--
--   nvim --headless -u NONE -l tools/gridgate.lua [<lang>] [--show <class>] [--out DIR]
--
-- ★ NOTHING IS PERSISTED (CART-0405). The grid is minted into a tempdir per run and the
-- generator is the only artifact. tools/bench.lua materializes a synthetic corpus ONLY WHEN
-- ITS DIRECTORY IS MISSING, so a cached corpus is authoritative and the sole guard against
-- staleness is a hand-bumped GEN_VERSION inside the path — the stale-cache shape, one layer
-- above the extractor's own. Regenerating removes the guard by removing what it guards.
-- `--out DIR` writes a copy for a HUMAN to read; no check below ever reads from it.
--
-- ★ WHICH MAKES DETERMINISM A GATE, NOT A PROPERTY. If the corpus is minted per run, a
-- non-deterministic emitter turns every pinned number into a flake — and an INDISTINGUISHABLE
-- one, because a generator wobble and a real regression produce the same delta. So step 1
-- mints it TWICE and requires the bytes to match. (The hazard is not the RNG — this grid has
-- none. It is a `pairs()` over a hash table deciding file or method ORDER.)
--
-- ★ AND A DOUBLE-MINT CANNOT SEE ACROSS PROCESSES, WHICH IS WHERE THE REST OF IT LIVES. Two
-- mints in ONE Lua state share everything a state has, so nondeterminism that is STABLE
-- WITHIN a process and varies BETWEEN them — a string-hash seed reaching a `pairs()`, an
-- environment variable, a clock — agrees with itself and passes. So the grid's sha256 is
-- PINNED alongside the census. That digest is the only check spanning runs, machines and
-- days, which is exactly the population a regenerate-every-time corpus lives in.
-- ★ It also answers a question the counts cannot: DID THE CORPUS MOVE, OR THE ANALYZER? A
-- census delta alone is ambiguous, and the "one attributable mover" discipline depends on
-- telling those apart. hash same + counts moved = the analyzer. hash moved = you edited the
-- grid, and the counts are a new baseline rather than a regression.
--
-- ── FIVE CHECKS, IN COST ORDER ──────────────────────────────────────────────────────────
--  0 IDENTITY     the grid's sha256, pinned — did the corpus change at all?
--  1 DETERMINISM  two mints, byte-identical
--  2 COVERAGE     every cell planted the node types it CLAIMS, at the exact counts it
--                 claims. "It parsed" is not "it planted the form": ctrlcensus --coverage
--                 exists because synjava held `if` and `for` and was called complete. Exact
--                 counts, not >= 1, so a SHELL `if` cannot stand in for a dropped inner one.
--  3 OPENED       every planted control row with a non-empty body must HAVE CHILD ROWS. This
--                 is the per-cell form of the rowcensus question, and it is the one that
--                 would have caught CART-0397 (a truncated elsif chain) and CART-0401 (a
--                 bare block) the day each shipped — a region with no rows, named by the
--                 coordinates that produced it.
--  4 EXPR         the expression IR's self-gate (CART-0395) over the whole grid.
--
-- ★ THE FIRST RUN IS EXPECTED TO BE RED, and that is the deliverable, not a setback. So the
-- result is a PINNED CENSUS (M.EXPECTED below), diffed like rowcensus/dfparity/exprcensus —
-- a count that ROSE is a new hole, a class that GOES is a fix. This gate is deliberately NOT
-- wired into the push-time sweep until its pin has been reviewed cell by cell.

local here = debug.getinfo(1, 'S').source:sub(2)
local repo = vim.fn.fnamemodify(here, ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local gm = dofile(repo .. '/tools/genmatrix.lua')
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local flow = require 'cartograph.flow'
local expr = require 'cartograph.expr'

-- ── args ────────────────────────────────────────────────────────────────────────────────
local lang, show, outdir = nil, nil, nil
local i = 1
while arg and arg[i] do
    local a = arg[i]
    if a == '--show' then show = arg[i + 1]; i = i + 1
    elseif a == '--out' then outdir = arg[i + 1]; i = i + 1
    elseif not a:match('^%-%-') then lang = a end
    i = i + 1
end
lang = lang or 'java'

local M = {}
local fail = 0
local function say(s) io.stdout:write(s .. '\n') end

-- ── 1. determinism ──────────────────────────────────────────────────────────────────────
-- the grid's IDENTITY: sha256 over the sorted (name, content) pairs, plus one per file so a
-- mismatch names the file rather than the corpus.
local function digest(g)
    local names = {}
    for k in pairs(g.files) do names[#names + 1] = k end
    table.sort(names)
    local per, acc = {}, {}
    for _, n in ipairs(names) do
        per[n] = vim.fn.sha256(g.files[n])
        acc[#acc + 1] = n .. '\1' .. per[n]
    end
    return vim.fn.sha256(table.concat(acc, '\2')), per, names
end

local g1 = gm.grid(lang)
local g2 = gm.grid(lang)
local HASH, PERFILE, FILENAMES = digest(g1)
do
    -- ── 0. SELFTEST: a digest that cannot fire proves nothing ────────────────────────────
    -- The house rule (tools/langaudit.lua carries the same one): an audit reports a clean
    -- zero for two reasons, and only one of them is good. So perturb ONE byte of the grid in
    -- memory and require the digest to move. Costs a hash; buys the right to believe a PASS.
    local probe = {}
    for k, v in pairs(g1.files) do probe[k] = v end
    probe[FILENAMES[1]] = probe[FILENAMES[1]] .. '\n// selftest\n'
    if digest({ files = probe }) == HASH then
        say('gridgate: the IDENTITY CHECK CANNOT FIRE — a perturbed grid hashes the same.')
        os.exit(1)
    end
end
do
    -- ── 1a. WITHIN a run: two mints must be byte-identical ──────────────────────────────
    local h2, per2, names2 = digest(g2)
    if HASH ~= h2 then
        say('gridgate: NON-DETERMINISTIC — two mints of the same grid differ IN ONE PROCESS.')
        for _, n in ipairs(FILENAMES) do
            if PERFILE[n] ~= per2[n] then say('    differs: ' .. n) end
        end
        if #FILENAMES ~= #names2 then say('    the FILE SET itself differs') end
        say('  Every pinned number below would be a flake, and a generator wobble is')
        say('  indistinguishable from a regression. Look for a pairs() deciding order.')
        os.exit(1)
    end
end

local dir = vim.fn.tempname()
gm.write(g1, dir)
if outdir then gm.write(g1, outdir); say('gridgate: copy for reading at ' .. outdir) end

say(('gridgate %s — %d cell(s), %d skipped, sha %s, into %s')
    :format(lang, #g1.cells, #g1.skipped, HASH:sub(1, 12), dir))
-- ★ A SKIPPED CELL IS REPORTED, NEVER SILENT: a combination dropped without a count reads
-- exactly like one that was covered, which is the defect this whole grid exists to remove.
if #g1.skipped > 0 then
    local by, ks = {}, {}
    for _, s in ipairs(g1.skipped) do
        local k = s.form .. ' / ' .. s.why
        if not by[k] then ks[#ks + 1] = k end
        by[k] = (by[k] or 0) + 1
    end
    -- SORTED, because the report is read by diffing it: an unordered `pairs()` here made two
    -- identical runs print their skip lines in different orders. Cosmetic, and caught within
    -- minutes of writing the comment above warning about exactly this.
    table.sort(ks)
    for _, k in ipairs(ks) do say(('  SKIPPED %3d  %s'):format(by[k], k)) end
end

-- ── 2. coverage: did each cell plant what it claims? ────────────────────────────────────
local src = table.concat(vim.fn.readfile(dir .. '/' .. g1.file), '\n')
local okp, parser = pcall(vim.treesitter.get_string_parser, src, lang)
if not (okp and parser) then say('gridgate: NO PARSER for ' .. lang); os.exit(2) end
local root = parser:parse()[1]:root()

-- method name -> node, so a cell is checked against ITS OWN subtree
local mnode = {}
local function findm(n)
    if n:type() == 'method_declaration' then
        local nm = n:field('name')[1]
        if nm then mnode[vim.treesitter.get_node_text(nm, src)] = n end
    end
    for c in n:iter_children() do if c:named() then findm(c) end end
end
findm(root)

local cats = { cells = #g1.cells, skipped = #g1.skipped }
local inst = {}
local function record(class, s)
    cats[class] = (cats[class] or 0) + 1
    local L = inst[class]; if not L then L = {}; inst[class] = L end
    L[#L + 1] = s
end

for _, c in ipairs(g1.cells) do
    local n = mnode[c.m]
    if not n then
        record('coverage:no-method', c.m)
    else
        local hist = {}
        local function count(x)
            hist[x:type()] = (hist[x:type()] or 0) + 1
            for y in x:iter_children() do if y:named() then count(y) end end
        end
        count(n)
        for t, want in pairs(c.want) do
            local got = hist[t] or 0
            if got ~= want then
                record('coverage:' .. t, ('%s wanted %d got %d'):format(c.m, want, got))
            end
        end
    end
end

-- ── 3+4. the ROW model and the expression IR, over the extracted grid ───────────────────
store.ingest(ts.extract(dir))
local bym = {}
for _, nd in ipairs(store.data.nodes) do
    if nd.kind == 'function' or nd.kind == 'method' then bym[nd.name or ''] = nd end
end

for _, c in ipairs(g1.cells) do
    -- java methods are CLASS-QUALIFIED in the node name (`Grid::c_ifs_top_one_ch1`)
    local nd = bym[c.m] or bym['Grid::' .. c.m]
    if not nd then
        record('rows:no-node', c.m)
    else
        local fl = flow.record(nd)
        local S = fl and fl.stmts or {}
        local haskid = {}
        for _, s in ipairs(S) do if s.parent and s.parent > 0 then haskid[s.parent] = true end end
        -- ★ EVERY CONTROL ROW WITH A NON-EMPTY BODY MUST HAVE CHILDREN. A control row with
        -- none is either an honestly empty body or a form that failed to open, and the CELL
        -- knows which — `body == 'empty'` is the only legitimate case.
        for k, s in ipairs(S) do
            -- ★ A `cond` ROW IS A LEAF BY DESIGN, not a form that failed to open: a POST
            -- loop (do-while) strips its condition off the head and re-emits it AFTER the
            -- body, so the ordering is right for a var def'd in the body and read in the
            -- test. Same for a bare `label` marker. Measured before this exclusion: all 16
            -- `dowhile` cells reported opaque, which is the check being wrong rather than
            -- flow — and worth the two lines, because an oracle that cries wolf on a whole
            -- axis is how a real hole on that axis gets waved through.
            local leaf = s.kind == 'cond' or s.kind == 'label'
            if s.kind and s.kind ~= 'stmt' and not leaf and not haskid[k]
                and c.body ~= 'empty' then
                record('opaque:' .. (s.t or s.kind), ('%s L%d'):format(c.m, s.l))
            end
        end
        if #S == 0 then record('rows:empty', c.m) end
        local oke, got = pcall(expr.of, store, nd.id)
        if oke and got and got.fl then
            for _, d in ipairs(expr.gate(got.fl, got.lang)) do
                local row = (got.fl.stmts or {})[d.row] or {}
                record('expr:' .. tostring(row.t or row.kind or '?'),
                    ('%s L%d missing={%s} extra={%s}'):format(c.m, d.line,
                        table.concat(d.missing, ','), table.concat(d.extra, ',')))
            end
        end
    end
end

-- ── report ──────────────────────────────────────────────────────────────────────────────
local ord = {}
for k, v in pairs(cats) do
    if k ~= 'cells' and k ~= 'skipped' then ord[#ord + 1] = { k = k, v = v } end
end
table.sort(ord, function (a, b)
    if a.v ~= b.v then return a.v > b.v end
    return a.k < b.k
end)
local parts = { ('cells=%d skipped=%d'):format(cats.cells, cats.skipped) }
for _, e in ipairs(ord) do parts[#parts + 1] = e.k .. '=' .. e.v end
say('  census: ' .. table.concat(parts, ' '))

if show then
    local L = inst[show]
    say(('%s: %d instance(s)'):format(show, L and #L or 0))
    for j = 1, math.min(#(L or {}), 40) do say('    ' .. L[j]) end
end

-- ★ PINNED, NOT ZERO. The grid's job is to make holes VISIBLE; a hole is not a reason to
-- keep the number hidden. Same discipline as rowcensus/dfparity/exprcensus.EXPECTED.
M.EXPECTED = {
    -- Calibrated on arrival, 2026-08-12, after reviewing every class the first run produced.
    -- ★ THE FIRST RUN PAID FOR THE GRID IMMEDIATELY, and in the way only a grid can:
    --   expr:if_statement 36  — EVERY `c_ifs_*_ch2` and `_ch3` cell, and NO `_ch1` cell.
    --     That pattern NAMES THE AXIS — if x CHAIN-LENGTH — without anyone guessing it. Java
    --     spells `else if` as a NESTED if_statement, which is neither a BODY nor a CLAUSE, so
    --     the outer head's expression IR swallowed the whole chain's bodies. FIXED in
    --     expr.lua (a nested control statement is its own row, so it is not this head's
    --     expression). The per-form bestiary HAS an `else if` — with exactly one link, so it
    --     never could have shown this.
    --   opaque: 16  — every `dowhile` cell, and it was THE CHECK that was wrong: a POST
    --     loop's re-emitted `cond` row is a leaf by design. Fixed above. Worth the two lines:
    --     an oracle that cries wolf across a whole axis is how a real hole on that axis gets
    --     waved through.
    -- WHAT REMAINS IS ONE KNOWN, TICKETED CLASS — CART-0400, the try-with-resources binder,
    -- declined on purpose in CART-0395 because its `resources` child holds the initializers
    -- too. Pinned rather than zeroed, for exactly the reason exprcensus is: an open class is
    -- not a reason to keep the number invisible.
    -- COVERAGE IS CLEAN: 0 cells failed to plant the node types they claim, at the exact
    -- counts they claim — so the 280 numbers below are about the analyzer, not the emitter.
    java = { hash = 'e680f20542833cb6ca0b355752dfef8aab531ba75c86d99461cd5f7e0f01a55f',
        cells = 280, skipped = 24, ['expr:try_with_resources_statement'] = 20 },
}
local pin = M.EXPECTED[lang]
if not pin then
    say('  NOT CALIBRATED: review the census above, then pin M.EXPECTED[' .. lang .. ']')
    say('       hash = ' .. HASH)
    os.exit(0)
end
-- ★ THE HASH ANSWERS A QUESTION THE COUNTS CANNOT: DID THE CORPUS MOVE, OR THE ANALYZER?
-- A census delta alone is ambiguous — an emitter edit and a flow/expr regression produce the
-- same shape of red, and the whole "one attributable mover" discipline depends on telling
-- them apart. The hash separates them: hash SAME + counts moved = the analyzer changed;
-- hash MOVED = you edited the grid, and the counts are a new baseline, not a regression.
-- ★ AND IT COVERS THE BLIND SPOT IN THE DOUBLE-MINT ABOVE. Two mints in ONE process share a
-- Lua state, so any nondeterminism that is STABLE WITHIN a process and varies ACROSS them —
-- a string-hash seed reaching a `pairs()`, an env var, a clock — agrees with itself and
-- passes. A pinned digest is the only check that spans runs, machines and days, which is
-- exactly the population a regenerate-every-time corpus lives in.
-- IT ADDS NO CEREMONY: an intentional grid edit already forces a census re-pin. This just
-- fails EARLIER and says which file, instead of leaving you to infer it from moved counts.
if pin.hash and pin.hash ~= HASH then
    say(('    hash %s→%s  — THE GRID ITSELF CHANGED, so every count below is a new baseline')
        :format(pin.hash:sub(1, 12), HASH:sub(1, 12)))
    for _, n in ipairs(FILENAMES) do say(('        %s  %s'):format(PERFILE[n]:sub(1, 12), n)) end
    fail = fail + 1
end
for k, v in pairs(cats) do
    if pin[k] ~= v then
        say(('    %s %s→%d'):format(k, pin[k] == nil and '(new)' or pin[k], v)); fail = fail + 1
    end
end
for k, v in pairs(pin) do
    if k ~= 'hash' and cats[k] == nil then
        say(('    %s %d→0 (GONE)'):format(k, v)); fail = fail + 1
    end
end
say(fail == 0 and 'GRIDGATE: PASS' or ('GRIDGATE: FAIL (' .. fail .. ' delta)'))
os.exit(fail == 0 and 0 or 1)
