-- annotate — attach prose to a definition. CART-0780, and the write verb the
-- arc's own metric asked for.
--
-- ★★ WHY THIS ONE. CART-0763 measured a day's work and concluded "the work is
-- INSERTION"; it then picked "add an entry to a declared table" as the commonest
-- case and `txn_plan_declare` shipped for it. Re-running the same metric over 24
-- commits says the diagnosis was right and the specialisation was wrong:
--     COMMENT PROSE                1171 of 2334 added lua/ lines   50.2%
--     bare `local x = ...`          224                             9.6%
--     TABLE MEMBER (declare's case) 106                             4.5%
-- A comment block is ELEVEN TIMES the case the previous verb was built for.
--
-- ★★ AND THE COMMENT PREFIX IS SLICED FROM A REAL COMMENT, NEVER DECLARED. This
-- is `declare`'s lesson one level over: the donor supplies the surface because it
-- IS the surrounding style. A per-language table of `--` / `//` / `#` is wrong
-- the first time it meets a docblock convention, a block comment, or a file that
-- indents differently — and every language would need an entry before the verb
-- worked there at all.
--
-- ★ THE DONOR IS THE PROJECT, NOT ONLY THE FILE, and that is measured rather than
-- assumed. Files holding a definition that also hold a comment:
--     self      189 of 189   100.0%
--     desynced   91 of  97    93.8%
--     grocy      94 of 157    59.9%   <- file-only slicing refuses 40% here
-- Comment STYLE is a property of a project and a language, not of one file, so
-- the search widens to the same language elsewhere in the tree before refusing.
-- Which donor was used rides on the plan, because "we borrowed the style from
-- another file" is a thing a caller should be able to see.

local M = {}

local atr = require 'cartograph.at'
local txn = require 'cartograph.txn'
local tsutil = require 'cartograph.spec.tsutil'

local function parse_root(text, lang)
    local okp, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    if not okp or not parser then return nil end
    local okt, tree = pcall(function () return parser:parse()[1] end)
    if not okt or not tree then return nil end
    return tree:root()
end

--- Every candidate line-comment prefix in a text: the leading punctuation run of
--- each comment that occupies ONE line. Candidates, not a choice — which one
--- survives is decided by trying the REAL edit.
local function candidate_prefixes(text, lang)
    local root = parse_root(text, lang)
    if not root then return {} end
    local out, seen = {}, {}
    local lines = vim.split(text, '\n', { plain = true })
    local function walk(n)
        if tsutil.is_comment(n) then
            local sr, sc, er, ec = n:range()
            if sr == er then
                local p = ((lines[sr + 1] or ''):sub(sc + 1, ec)):match('^(%p+)')
                if p and not seen[p] then seen[p] = true; out[#out + 1] = p end
            end
        end
        for c in n:iter_children() do walk(c) end
    end
    walk(root)
    return out
end

--- ★★★ VALIDATE THE EDIT, NOT A PROBE — and the difference is not academic.
--- The first cut spliced ONE line `prefix .. ' probe'` into the file and compared
--- skeletons. It accepted `--[[` on a file whose only comment was
--- `--[[ one line ]]`, because the probe went in at line 1 and the EXISTING
--- comment's `]]` closed it: inert by accident of position. The real edit is N
--- lines at the adhesion point with no `]]` to rescue it, and it would have
--- swallowed the file.
--- ⚠ A PROBE IS NOT THE EDIT. Two things differed — how many lines, and where —
--- and either alone was enough to make the answer wrong. So this takes the exact
--- lines at the exact position and asks `comment-inert`'s own question.
---@return boolean
local function block_is_inert(host, lang, at_line, block)
    local pg = require 'cartograph.planguards'
    local base = pg.code_skeleton(host, lang)
    if not base then return false end
    local lines = vim.split(host, '\n', { plain = true })
    for i = #block, 1, -1 do table.insert(lines, at_line + 1, block[i]) end
    return pg.code_skeleton(table.concat(lines, '\n'), lang) == base
end

--- Candidate prefixes, target file first, then any file of the same language.
--- ★ THE DONOR IS THE PROJECT, NOT ONLY THE FILE — measured: files holding a
--- definition that also hold a comment are 100% on our own tree, 93.8% on
--- desynced and only 59.9% on grocy, so file-only slicing would refuse 40% of
--- grocy. Comment STYLE is a language-and-project property.
---@return table list of { prefix, donor }
function M.prefix_candidates(store, rel, lang)
    local root = store.data.root
    local out = {}
    local text = txn.read_file(root, rel)
    for _, p in ipairs(text and candidate_prefixes(text, lang) or {}) do
        out[#out + 1] = { prefix = p, donor = rel }
    end
    local ts = require 'cartograph.providers.treesitter'
    local seen = {}
    for _, n in ipairs(store.data.nodes or {}) do
        local f = n.file
        if f and not seen[f] and f ~= rel and ts.parse_lang(f) == lang then
            seen[f] = true
            local t = txn.read_file(root, f)
            for _, p in ipairs(t and candidate_prefixes(t, lang) or {}) do
                out[#out + 1] = { prefix = p, donor = f }
            end
        end
    end
    return out
end

--- Build the plan.
---@param opts table { node = <id>, text = 'the prose' (may contain newlines) }
function M.plan(store, opts)
    opts = opts or {}
    local n = opts.node and store.node(opts.node)
    if not n then return nil, 'no symbol to annotate' end
    if not n.file then return nil, n.name .. ' has no file' end
    local prose = opts.text
    if type(prose) ~= 'string' or prose:gsub('%s', '') == '' then
        return nil, 'no prose to attach'
    end
    local ts = require 'cartograph.providers.treesitter'
    local lang = ts.parse_lang(n.file)
    if not lang then return nil, 'no parser for ' .. n.file end
    local root = store.data.root
    local text = txn.read_file(root, n.file)
    if not text then return nil, 'cannot read ' .. n.file end
    local lines = vim.split(text, '\n', { plain = true })


    -- ★ THE INSERTION POINT IS THE ADHESION START, which is the same function the
    -- MOVE verb uses to decide which comment lines travel with a definition
    -- (`txn.attach_above`). Reusing it means "the block this verb writes" and
    -- "the block a move would carry" are the same block by construction, rather
    -- than two rules that agree until they do not.
    local first = atr.sl(n.range)
    local okp, tsm = pcall(require, 'cartograph.providers.treesitter')
    local s = txn.attach_above(lines, first, okp and tsm.attach_pats(n.file) or {})

    -- indentation from the definition's own line, so the block lines up with the
    -- thing it describes rather than with the file
    local indent = (lines[first + 1] or ''):match('^[ \t]*') or ''
    -- ★ TRY EACH CANDIDATE AGAINST THE REAL EDIT and keep the first that leaves
    -- the code untouched. A prefix is not "a line comment" in the abstract; it is
    -- a prefix that comments THIS block out at THIS position, which is the only
    -- claim the write needs.
    local out, donor, prefix
    for _, c in ipairs(M.prefix_candidates(store, n.file, lang)) do
        local block = {}
        for _, l in ipairs(vim.split(prose, '\n', { plain = true })) do
            block[#block + 1] = (l == '') and (indent .. c.prefix)
                or (indent .. c.prefix .. ' ' .. l)
        end
        if block_is_inert(text, lang, s, block) then
            out, donor, prefix = block, c.donor, c.prefix
            break
        end
    end
    if not out then
        return nil, ('no comment style in this tree turns that prose into an inert '
            .. 'comment for %s — every candidate prefix changed the code'):format(n.file)
    end

    local plan = {
        verb = 'annotate',
        -- ⚠ `comment-inert` IS NOT OPTIONAL HERE and `parses` cannot replace it:
        -- prose containing `--[[`, `*/` or a docblock terminator can CLOSE the
        -- comment early and turn the rest into CODE. The result may parse
        -- PERFECTLY and mean something else entirely.
        guards = { 'parses', 'comment-inert' },
        generation = store.generation,
        touched = { n.file },
        stamps = { [n.file] = txn.disk_stamp(root, n.file) },
        hazards = {},
        target = { id = n.id, name = n.name, file = n.file, ref = store.ref_of(n.id) },
        prose = out,
        donor = donor,
        prefix = prefix,
        ins = { { after = s - 1, lines = out } },
    }
    if donor ~= n.file then
        plan.hazards[#plan.hazards + 1] = ('%s holds no line comment, so the prose '
            .. 'style was taken from %s'):format(n.file, donor)
    end
    return txn.protocol(plan, M.edits_for)
end

function M.edits_for(plan)
    return function (rel, before)
        if rel ~= plan.target.file then return before end
        return txn.edit_file(before, nil, nil, plan.ins)
    end
end

function M.preview(store, plan) return txn.dryrun(store, plan) end

function M.apply(store, plan)
    local bad = txn.verify(store, plan, { { id = plan.target.id, ref = plan.target.ref,
        name = plan.target.name, what = 'symbol' } })
    if bad then return nil, bad end
    return txn.execute(store, plan, 'annotate: attach prose to ' .. plan.target.name)
end

return M
