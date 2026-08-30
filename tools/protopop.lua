-- protopop — WHAT IS IN THE PROTOTYPE POPULATION, and what the data-stage reading
-- cannot type (CART-0638, after CART-0637).
--   nvim --headless -u NONE -l tools/protopop.lua <root-or-dir-of-roots> [--samples N]
--
-- ★ THIS TOOL EXISTS BECAUSE A GREP ANSWERED THE QUESTION WRONG. The residual
-- population — records the reader registered but could not type — was classified by
-- probing SOURCE TEXT for a `type =` line near the record, which reported "87 arrays
-- of typed prototypes" out of 162. It was wrong: the largest single contributor uses
-- the INLINE `data:extend({{…}})` form the reader already expands, and the probe was
-- matching nested `type = "item"` inside ingredient tables. The fix built on that
-- number moved the residue 162 -> 154.
--
-- ★★ A GREP OVER SOURCE TEXT CANNOT CLASSIFY WHAT THE READER SAW. The question is
-- about the reader's records, so it must be asked of the reader's records —
-- `cartograph.prototypes.all` and the literal expression each record kept. Same
-- discipline as ctrlcensus reading flow.classes() rather than a second copy: an
-- audit tool holding its own idea of the answer audits itself.
--
-- ── THE TAXONOMY, from the IR and nothing else ──────────────────────────────────
-- Every residual record is bucketed by the SHAPE OF ITS TABLE LITERAL:
--   array-typed      holds table elements, at least one declaring `type=`. These are
--                    prototypes and SHOULD have been expanded — if any appear, the
--                    by-name expansion missed a registration path, which is a defect.
--   array-untyped    holds table elements, none declaring `type=`. Either a list that
--                    is not prototypes, or prototypes typed from somewhere else (the
--                    shared-base merge). The interesting bucket.
--   named-no-type    only named fields, none of them `type`. A helper, or a prototype
--                    whose type arrives by mutation.
--   computed-keys    at least one key the reader could not read. Honest frontier.
--   empty            no readable entries at all.
--   anonymous-arg    the REGISTRAR'S ARGUMENT was unreadable — a call, or a name
--                    never tracked. The READER's own frontier, and it names it
--                    itself (`anonymous`), so this reads the reader rather than
--                    inventing a second answer.
--   no-literal       ⚠ THE RECORD KEPT NO EXPRESSION. Reported as its own bucket and
--                    never folded into another: `_lit` is retained only on the
--                    `local x = {…}` path, so a record from any other path is
--                    UNCLASSIFIABLE BY THIS TOOL rather than empty. Silently calling
--                    it `empty` would be this tool making the mistake it was built to
--                    correct.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/protopop%.lua$')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = here .. '/?.lua;' .. here .. '/../lua/?.lua;'
    .. here .. '/../lua/?/init.lua;' .. package.path

local root = arg and arg[1]
if not root then
    print('usage: protopop.lua <root-or-dir-of-roots> [--samples N]')
    os.exit(2)
end
root = vim.fn.expand(root)
local SAMPLES = 6
for i = 2, #(arg or {}) do
    if arg[i] == '--samples' then SAMPLES = tonumber(arg[i + 1]) or SAMPLES end
end

-- a dir whose children are roots (a mods folder) vs a single root
local function roots_of(p)
    if vim.uv.fs_stat(p .. '/info.json') then return { p } end
    local out, it = {}, vim.uv.fs_scandir(p)
    while it do
        local n, t = vim.uv.fs_scandir_next(it)
        if not n then break end
        if t == 'directory' then out[#out + 1] = p .. '/' .. n end
    end
    table.sort(out)
    if #out == 0 then return { p } end
    return out
end

--- CLASSIFY ONE RECORD from its retained literal. Pure: everything it needs is on the
--- record, so a bucket can be reproduced without re-running an extraction.
local function classify(p)
    local lit = p._lit
    if not (lit and lit.k == 'table') then
        -- ⚠ NO RETAINED EXPRESSION. `_lit` rides only the `local x = {…}` path, so
        -- everything else lands here — and after CART-0639 this became 73% of the
        -- residue, i.e. the tool's own blind spot became the answer. That is the
        -- failure this file was written to avoid, so it is split rather than shrugged.
        --
        -- `anonymous` is the reader's OWN word for "the registrar's argument was not
        -- readable at all — a call, or a name never tracked". It is a real and
        -- different frontier from an unreadable literal, and the reader already
        -- names it, so read the reader rather than inventing a second answer.
        if p.anonymous then return 'anonymous-arg' end
        return 'no-literal'
    end
    local named, arrays, computed, typed = 0, 0, 0, false
    for _, kid in ipairs(lit.kids or {}) do
        if kid.k == 'pair' then
            local key = kid.key
            if key and key.k == 'lit' and type(key.v) == 'string' then
                named = named + 1
                if key.v == 'type' then typed = true end
            else
                computed = computed + 1
            end
        elseif kid.k == 'table' then
            arrays = arrays + 1
            -- does THIS element declare a type? that is what makes the array a group
            -- of prototypes rather than a list of anything else
            for _, gk in ipairs(kid.kids or {}) do
                if gk.k == 'pair' and gk.key and gk.key.k == 'lit'
                    and gk.key.v == 'type' then typed = true end
            end
        end
    end
    if computed > 0 then return 'computed-keys' end
    if arrays > 0 then return typed and 'array-typed' or 'array-untyped' end
    if named > 0 then return 'named-no-type' end
    return 'empty'
end

local bench = require 'bench'
local store = require 'cartograph.store'
local roots = roots_of(root)
local tally, samples, nroots, nrec = {}, {}, 0, 0
for _, r in ipairs(roots) do
    local okx, data = pcall(bench.extract, r, { nocache = true })
    if okx then
        store.ingest(data)
        local ok2, mods = pcall(require('cartograph.prototypes').all, store)
        if ok2 and mods then
            nroots = nroots + 1
            for _, m in ipairs(mods) do
                for _, p in ipairs(m.protos) do
                    -- THE RESIDUAL POPULATION: registered, a literal, still untyped,
                    -- and not a container whose elements were already expanded
                    if p.basis == 'literal' and not p.declared_type
                        and p.registered and not p.container then
                        nrec = nrec + 1
                        local b = classify(p)
                        tally[b] = (tally[b] or 0) + 1
                        samples[b] = samples[b] or {}
                        if #samples[b] < SAMPLES then
                            samples[b][#samples[b] + 1] = ('%s  %s:%d  var=%s')
                                :format(vim.fn.fnamemodify(r, ':t'), m.file, p.line,
                                    tostring(p.var))
                        end
                    end
                end
            end
        end
    end
end

print(('protopop — %d root(s) read, %d residual record(s)'):format(nroots, nrec))
print('  (registered by the data stage, a table literal, and still without a type)')
if nrec == 0 then
    print('  nothing residual: every registered literal carries a readable `type=`')
    os.exit(0)
end
-- ORDER IS FIXED, not frequency-sorted: a reader comparing two runs needs the rows in
-- the same places, and the interesting bucket is not always the biggest one.
local ORDER = { 'array-typed', 'array-untyped', 'named-no-type', 'computed-keys',
    'empty', 'anonymous-arg', 'no-literal' }
local NOTE = {
    ['array-typed'] = 'A DEFECT IF NON-ZERO — these are prototypes and the by-name'
        .. ' expansion should have reached them',
    ['array-untyped'] = 'the interesting bucket: a list whose elements are typed'
        .. ' somewhere else, or not prototypes at all',
    ['named-no-type'] = 'a helper, or a prototype whose type arrives by mutation',
    ['computed-keys'] = 'honest frontier — the reader could not read the keys',
    ['empty'] = 'no readable entries',
    ['anonymous-arg'] = 'the REGISTRAR ARGUMENT was unreadable — a call, or a name'
        .. ' never tracked. The reader\'s own frontier, not this tool\'s',
    ['no-literal'] = 'UNCLASSIFIABLE BY THIS TOOL: the record kept no expression'
        .. ' (only the `local x = {…}` path retains one), NOT the same as empty',
}
local seen = 0
for _, b in ipairs(ORDER) do
    local n = tally[b] or 0
    seen = seen + n
    print(('\n  %-14s %4d  (%4.1f%%)  %s'):format(b, n, 100 * n / nrec, NOTE[b]))
    for _, s in ipairs(samples[b] or {}) do print('      ' .. s) end
end
-- ⚠ THE PARTITION INVARIANT. A bucket added to `classify` and not to ORDER would be
-- silently invisible and every percentage above would be wrong — the failure this
-- project has already paid for twice in census tools.
if seen ~= nrec then
    print(('\n⚠ BUCKET PARTITION BROKEN: %d of %d record(s) fell in no printed bucket,'
        .. ' so every percentage above is wrong'):format(nrec - seen, nrec))
    os.exit(1)
end
