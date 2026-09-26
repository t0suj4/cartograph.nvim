-- cartograph.algebraread — THE LOSSLESS READER: source text → algebra term (CART-0961).
--
-- @langs lua
-- ONE GRAMMAR IS AUDITED AND THAT IS THE CLAIM. The reader is lossless only where
-- a round-trip has been proven (`A.cst_print(read(src)) == src`, byte for byte),
-- and that proof exists for lua. A second grammar is not a wider `@langs` line,
-- it is a second audit — see the RESERVED note below.
--
-- ★★★ THIS IS THE ONE UNPORTED PIECE, AND IT GATES THE WHOLE EDIT SIDE. The
-- 2026-09-19 re-vendor brought 90 new algebra exports and `origin.unported`
-- records why 41 of them could not be used: the donor installs its tree-sitter
-- parse hook from `experiments/lua_reader.lua`, which is an experiments script
-- and not the algebra, so it did not come with the code. Without it
-- `A.grammars.lua.parse` returns nil and every operator that consumes a TERM
-- READ FROM SOURCE — the reader, SURGERY's spans and hunks, EXTRACT,
-- DESTINATIONS, RESOLVE's scope graphs — is UNAVAILABLE here. Not wrong:
-- unavailable, which is its own answer and a worse one to leave standing.
--
-- ★★ IT IS ADAPTATION, NOT VENDORING, AND THAT IS WHY IT IS ITS OWN FILE.
-- `lua/cartograph/algebra/*` is the donor's code under a stamp that
-- `tools/vendordrift.lua` watches; a hand-written module dropped in there would
-- read as donor drift forever [⚠ SUPERSEDED 2026-09-23: the copy is AUTHORITATIVE and
-- our edits are the normal state — `origin.authority`, CART-1041; the parts-protocol
-- point below still holds], and the parts fence walks that directory
-- expecting every file to be `return function (M, SHARED)`. Wiring OUR
-- tree-sitter in is a behaviour change we author, so it lands beside the seam
-- with its own test rather than inside a mechanical copy.
--
-- ★★★ THE ORACLE SHIPPED WITH THE REQUIREMENT. A reader is lossless iff
--
--     A.cst_print(read(src)) == src        byte for byte, no exceptions
--
-- and that is decidable on every file we own. It holds over all 231 files under
-- `lua/` (5.6 MB, ~2.6 s), which is what tests/algebraread_spec.lua asserts.
-- ⇒ THERE IS NOTHING TO JUDGE HERE. The test is not a sample of behaviour, it
-- is the definition, run over the whole corpus we have.
--
-- ⚠ AND IDENTITY IS A DEAD PIN FOR THE ONE FAILURE THAT MATTERS MOST. A
-- tree-sitter MISSING node is ZERO-WIDTH: it contributes no text, so a term
-- built over a truncated file prints back to that file exactly and identity
-- PASSES on a source the reader did not understand. Measured on
-- `local s = "abc`: tree-sitter inserts a MISSING `"` at depth 5, width 0.
-- ⇒ THE REACHABLE GUARD IS `has_error()`, WHICH COVERS IT — measured on
-- NVIM v0.11.5, where that same source reports has_error true. The version is
-- part of the measurement: `has_error()` is Neovim's, not ours, and the day it
-- stops flagging a merely-MISSING tree is exactly the day the hole opens. The
-- explicit `missing()` check below is a
-- SECOND FENCE for the day a tree carries a missing node without flagging the
-- tree. It is unreachable today and says so; the spec pins the OUTCOME (a
-- truncated source refuses by name) rather than which fence fired, because that
-- is the claim that has to survive an nvim upgrade.
--
-- HOW THE TERM IS SHAPED (the donor's design, kept verbatim so the terms are
-- interchangeable with the ones its own fixtures carry):
--   · a named leaf becomes `(<type> "text")`; an anonymous leaf is the bare text
--   · WHITESPACE IS A LITERAL KID. tree-sitter keeps inter-token gaps out of the
--     tree; the reader puts each one back as a `lit` between the kids it
--     separates, and the file's leading and trailing gaps lie outside the root's
--     own range and are added around it. This is the whole of "lossless".
--     ⚠ AND THE CORPUS IS SILENT ON THE EDGE GAPS: measured, removing them
--     still round-trips all 231 files, because every file we own starts with a
--     token and ends where the root ends. Only the hand-written cases in the
--     spec catch it — the whole-tree law is not a superset of them.
--   · the node type becomes the term KIND, which is why a type that collides
--     with an algebra kind must refuse rather than be silently accepted.
local M = {}

local unpack = table.unpack or unpack

--- ⚠ THE COLLISION SET, AND IT IS A HARD-CODED READING OF THE DONOR'S TERM
--- VOCABULARY. `k` is one namespace: if a grammar has a node type named `pair`
--- (JSON does) the term it builds is indistinguishable from the algebra's own
--- pair node, and every operator downstream would read it as one. The list can
--- go stale if the donor mints a new kind — so the GUARD, not the list, is the
--- protection: an unaudited grammar refuses BY NAME the first time it hits one.
--- ★ EXPORTED, AND READ THROUGH THE MODULE TABLE ON PURPOSE. A caller auditing
--- a new grammar needs to see the set, and the guard itself is otherwise
--- untestable here: no grammar bundled with Neovim has a colliding type, so a
--- spec pins the MECHANISM by adding a type `lua` really produces and checking
--- that the read refuses by name. A guard that cannot be made to fire is a
--- guard nobody has checked.
M.RESERVED = { hole = true, seq = true, lit = true, name = true, pair = true,
    embed = true, cursor = true, present = true, absent = true, table = true,
    kv = true, src = true }

--- @param A table the loaded algebra
--- @param src string source text
--- @param lang string tree-sitter language
--- @return table|nil term, string|nil why
local function read(A, src, lang)
    local okp, parser = pcall(vim.treesitter.get_string_parser, require('cartograph.parseview').view(src, lang), lang)
    if not okp or not parser then
        return nil, ('no tree-sitter parser for `%s`'):format(lang)
    end
    local oktree, tree = pcall(function() return parser:parse()[1] end)
    if not oktree or not tree then
        return nil, ('tree-sitter could not parse the source as `%s`'):format(lang)
    end
    local root = tree:root()
    if root:has_error() then
        return nil, ('does not parse as `%s` (tree-sitter reports an error node)'):format(lang)
    end
    local function term(node)
        local ty = node:type()
        if M.RESERVED[ty] then
            error(('tree-sitter type collides with an algebra kind: `%s`'):format(ty), 0)
        end
        local _, _, sb, _, _, eb = node:range(true)
        if node:child_count() == 0 then
            -- ⚠ zero-width and childless: a MISSING node reaches exactly here, and
            -- it would contribute the empty string and print back clean.
            if node:missing() then
                error(('the tree is missing a `%s` the grammar requires'):format(ty), 0)
            end
            local text = src:sub(sb + 1, eb)
            if node:named() then return A.node(ty, A.lit(text)) end
            return A.lit(text)
        end
        local kids, cursor = {}, sb
        for child in node:iter_children() do
            local _, _, cs, _, _, ce = child:range(true)
            -- the gap tree-sitter keeps out of the tree
            if cs > cursor then kids[#kids + 1] = A.lit(src:sub(cursor + 1, cs)) end
            kids[#kids + 1] = term(child)
            cursor = ce
        end
        if eb > cursor then kids[#kids + 1] = A.lit(src:sub(cursor + 1, eb)) end
        return A.node(ty, unpack(kids))
    end
    local ok, t = pcall(term, root)
    if not ok then return nil, tostring(t) end
    -- the file's leading and trailing gaps lie OUTSIDE the root's range
    local _, _, rs, _, _, re = root:range(true)
    local kids = {}
    if rs > 0 then kids[#kids + 1] = A.lit(src:sub(1, rs)) end
    for _, c in ipairs(t.kids or {}) do kids[#kids + 1] = c end
    if re < #src then kids[#kids + 1] = A.lit(src:sub(re + 1)) end
    t.kids = kids
    return t
end

--- the parse hook the donor's `lua` grammar asks for: `A.parsers.lua`.
--- ★ BUILT OVER THE ALGEBRA THE SEAM JUST LOADED, so reading never re-enters
--- `algebra.load()` — the hook is installed as the last step of loading.
--- @param A table the loaded algebra
--- @return function parse
function M.parser(A)
    return function (src) return read(A, src, 'lua') end
end

--- read source text as an algebra term.
--- ⚠ `lang` IS EXPOSED BUT ONLY `lua` IS AUDITED. The donor registers one
--- grammar and RESERVED is one grammar's collision set; another language is not
--- forbidden, it is UNCHECKED — and the collision guard is what makes that safe
--- to say, because an unaudited grammar refuses by name instead of minting a
--- term that lies about its kinds. A second language is a second grammar plus
--- its own audit, not a flag.
--- @param src string
--- @param lang string|nil default 'lua'
--- @return table|nil term, string|nil why
function M.read(src, lang)
    local A, why = require('cartograph.algebra').load()
    if not A then return nil, why end
    return read(A, src, lang or 'lua')
end

--- the identity law over a directory tree: `cst_print(read(f)) == contents(f)`.
--- ★ THE LAW IS THE TEST AND THE TEST IS THE LAW — this is what the spec runs
--- over `lua/`, and what any consumer should run over a corpus before trusting
--- a hunk written back into it.
--- ⚠ THIS IS HARNESS SHAPE LIVING IN `lua/`: it globs a directory and reads
--- files, which is `tools/` work by the absorption ledger's own doctrine (an
--- arrow used only from tools/ is a MEASUREMENT, not a capability). It is here
--- because the spec is its consumer and because a caller about to write hunks
--- back into a tree should be able to re-run the law from the shipped code
--- rather than a script. Counted as what it is, not as part of the read surface.
--- @param dir string
--- @return table { files, ok, bad = { {file, why} }, bytes }
function M.identity(dir)
    local A, why = require('cartograph.algebra').load()
    if not A then return { files = 0, ok = 0, bad = { { dir, why } }, bytes = 0 } end
    local files = vim.fn.globpath(dir, '**/*.lua', false, true)
    table.sort(files)
    local out = { files = #files, ok = 0, bad = {}, bytes = 0 }
    for _, f in ipairs(files) do
        local fd = io.open(f, 'rb')
        if fd then
            local src = fd:read('*a')
            fd:close()
            out.bytes = out.bytes + #src
            local t, err = read(A, src, 'lua')
            if not t then
                out.bad[#out.bad + 1] = { f, err }
            elseif A.cst_print(t) ~= src then
                out.bad[#out.bad + 1] = { f, 'print(read(src)) ~= src' }
            else
                out.ok = out.ok + 1
            end
        end
    end
    return out
end

return M
