-- hrldistill — distil an erlang MACRO VOCABULARY from header files, CART-0812.
--
--   nvim --headless -u NONE -l tools/hrldistill.lua --from <dir-or-.hrl> [--out P]
--
-- ★★★ WHY A VOCABULARY AND NOT A CORPUS (CART-0794). ejabberd registers its IQ
-- handlers by XMPP namespace — `add_iq_handler(ejabberd_local, Host, ?NS_MAM_2,
-- ?MODULE, process_iq)` — and converse.js declares the same namespaces as
-- literals: `Strophe.addNamespace('MAM','urn:xmpp:mam:2')`. The two halves of that
-- boundary are joined by the URI and by nothing else: joining the projects' macro
-- NAMES finds 8 pairs, joining their URIs finds 30, and the sets disagree
-- (`?NS_MAM_2` <-> `Strophe.NS.MAM`, `?NS_CLIENT_STATE` <-> `Strophe.NS.CSI`).
-- THE URI IS THE IDENTITY AND THE NAMES ARE PER-PROJECT ALIASES.
--
-- The URIs live in neither tree. They are in `github.com/processone/xmpp`, which
-- ejabberd's rebar.config pins and does not vendor — a protocol boundary's key
-- table lives in a LIBRARY BOTH SIDES DEPEND ON, which is what a wire protocol
-- looks like from inside one endpoint. Extracting 40k lines of unrelated erlang to
-- read one header would be the wrong shape; a name->value table consumed as a KEY
-- is exactly what an L2 artifact already is.
--
-- ⚠ WHAT IT REFUSES IS RECORDED, NOT DROPPED. Of ejabberd's 163 `-define(NS_*)`,
-- 47 are COMPOSED rather than a plain literal (`?NS_ADMIN_ANNOUNCE` and family are
-- built from a base) and this cannot evaluate them. The artifact carries the
-- refused count so a reader can tell an absent name from an unmodelled one — a
-- profile may only subtract ([[cartograph-stdlib-profile]]).

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local out = repo .. '/lua/cartograph/spec/profile/erl-macros.mpack'
local from, i = nil, 1
while arg and arg[i] do
    if arg[i] == '--out' then out = arg[i + 1]; i = i + 2
    elseif arg[i] == '--from' then from = arg[i + 1]; i = i + 2
    else i = i + 1 end
end
if not from then
    print('usage: hrldistill.lua --from <dir-or-.hrl> [--out P]'); os.exit(2)
end
from = vim.fn.fnamemodify(from, ':p'):gsub('/$', '')

local files = {}
if vim.fn.isdirectory(from) == 1 then
    files = vim.fn.glob(from .. '/**/*.hrl', false, true)
else
    files = { from }
end
table.sort(files) -- an artifact field: order is output (CART-0790)
if #files == 0 then print('hrldistill: no .hrl under ' .. from); os.exit(2) end

-- ⚠ PARSED, NOT GREPPED. A line-oriented first cut read `-define(NAME, <<"...">>)`
-- with a pattern and refused 48 of 164 — including NS_DISCO_ITEMS, NS_CHATSTATES
-- and NS_MUC_USER, which are perfectly simple defines that happen to WRAP ONTO A
-- SECOND LINE. It reported them as refused rather than dropping them, which is the
-- design working, and the fix is the repo's own standing lesson: a structural
-- query sees what a line pattern cannot.
local bench = dofile(repo .. '/tools/bench.lua')
bench.bootstrap()
if not pcall(vim.treesitter.language.add, 'erlang') then
    print('hrldistill: no erlang parser'); os.exit(2)
end

local function text(n, src) return vim.treesitter.get_node_text(n, src) end

-- name -> the VALUE node plus its source, collected first because a composed
-- define may name a macro defined further down the file
local defs, order, ndef = {}, {}, 0
for _, f in ipairs(files) do
    local fd = io.open(f, 'r')
    if fd then
        local src = fd:read('a'); fd:close()
        local okp, parser = pcall(vim.treesitter.get_string_parser, src, 'erlang')
        local tree = okp and parser:parse()[1]
        if tree then
            local function walk(n)
                if n:type() == 'pp_define' then
                    local nm, val
                    for ch in n:iter_children() do
                        if ch:named() then
                            local t = ch:type()
                            if t == 'macro_lhs' then
                                for g in ch:iter_children() do
                                    if g:named() and (g:type() == 'var' or g:type() == 'atom') then
                                        nm = text(g, src); break
                                    end
                                end
                            elseif t ~= 'macro_lhs' and not val then
                                val = ch
                            end
                        end
                    end
                    if nm and nm:match('^[%w_]+$') then
                        ndef = ndef + 1
                        -- FIRST DEFINITION WINS, matching the preprocessor; the
                        -- file list is sorted so the choice is not a hash walk
                        if defs[nm] == nil then
                            defs[nm] = { node = val, src = src }
                            order[#order + 1] = nm
                        end
                    end
                end
                for ch in n:iter_children() do if ch:named() then walk(ch) end end
            end
            walk(tree:root())
        end
    end
end

-- ★★ EVALUATE TO A FIXPOINT, because a composed define is not unknowable — it is
-- a CONCATENATION of things this table already holds. `-define(NS_ADMIN_X,
-- <<(?NS_ADMIN)/binary, "#x">>)` is `?NS_ADMIN` plus "#x", and refusing it would
-- discard a value the header states as plainly as the simple ones. What stays
-- refused is what mentions a macro nothing here defines, or a shape that is not a
-- concatenation of literals at all.
local vals = {}
local function eval(node, src, depth)
    if not node or depth > 8 then return nil end
    local t = node:type()
    if t == 'string' then
        local raw = text(node, src)
        return (raw:gsub('^"', ''):gsub('"$', ''))
    elseif t == 'binary' then
        local out = {}
        for ch in node:iter_children() do
            if ch:named() then
                if ch:type() ~= 'bin_element' then return nil end
                local part
                for g in ch:iter_children() do
                    if g:named() then
                        local gt = g:type()
                        if gt == 'bit_type_list' then break end -- `/binary`, not a value
                        part = eval(g, src, depth + 1)
                        break
                    end
                end
                if part == nil then return nil end
                out[#out + 1] = part
            end
        end
        return #out > 0 and table.concat(out) or nil
    elseif t == 'paren_expr' then
        for ch in node:iter_children() do
            if ch:named() then return eval(ch, src, depth + 1) end
        end
        return nil
    elseif t == 'macro_call_expr' then
        for ch in node:iter_children() do
            if ch:named() and (ch:type() == 'var' or ch:type() == 'atom') then
                return vals[text(ch, src)] -- nil until that macro resolves
            end
        end
        return nil
    end
    return nil
end

for _ = 1, 6 do
    local progress = false
    for _, nm in ipairs(order) do
        if vals[nm] == nil then
            local d = defs[nm]
            local v = eval(d.node, d.src, 0)
            if v then vals[nm] = v; progress = true end
        end
    end
    if not progress then break end
end

local nrefused, refused_sample = 0, {}
for _, nm in ipairs(order) do
    if vals[nm] == nil then
        nrefused = nrefused + 1
        if #refused_sample < 6 then refused_sample[#refused_sample + 1] = nm end
    end
end

local nvals = 0
for _ in pairs(vals) do nvals = nvals + 1 end
if nvals == 0 then
    print('hrldistill: no macro resolved to a string literal — refusing to write'
        .. ' an empty vocabulary, which would look installed and model nothing.')
    os.exit(2)
end

local names = {}
for k in pairs(vals) do names[#names + 1] = k end
table.sort(names)

local fd = assert(io.open(out, 'wb'))
fd:write(vim.mpack.encode({
    schema = 1, kind = 'erl-macros', lang = 'erlang',
    -- not a wall clock: the artifact is checked in, and a timestamp would make it
    -- differ on every run for no content reason (the erldistill lesson)
    stamp = ('erlmacros-%d-%d'):format(nvals, nrefused),
    source = from:gsub('^' .. vim.pesc(vim.env.HOME or ''), '~'),
    names = names, values = vals,
    -- ⚠ THE HONEST HALF: how many defines this could NOT evaluate. A consumer that
    -- reads `values` without reading this believes the table is complete.
    refused = nrefused,
}))
fd:close()
print(('hrldistill: %s — %d defines, %d resolved to a literal, %d REFUSED'
    .. ' (composed, e.g. %s) -> %s'):format(
    from:gsub('^' .. vim.pesc(vim.env.HOME or ''), '~'), ndef, nvals, nrefused,
    table.concat(refused_sample, ', '), out:gsub('^' .. vim.pesc(repo) .. '/', '')))
