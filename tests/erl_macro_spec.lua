-- A MACRO ARGUMENT IS A NAMED KEY, NOT AN OPAQUE EXPRESSION (CART-0812).
-- erlang's `macro_call_expr` covers two different things and the spec decides
-- between them: `?MODULE` is knowable from the file, `?NS_MAM_2` is not knowable
-- from this tree but its NAME is right there in the syntax.

local erl = require 'cartograph.spec.erlang'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'erlang')
end

--- classify the first macro_call_expr in `src` as the call loop would
local function classify(src, file)
    local parser = vim.treesitter.get_string_parser(src, 'erlang')
    local hit
    local function walk(n)
        if not hit and n:type() == 'macro_call_expr' then hit = n end
        for ch in n:iter_children() do if ch:named() then walk(ch) end end
    end
    walk(parser:parse()[1]:root())
    if not hit then return nil end
    return erl.arg_kinds.macro_call_expr(hit, src, file)
end

test('erlmacro: ?MODULE is the FILE, and is emitted as the literal it becomes', function ()
    if not ready() then skip 'no erlang parser' end
    -- 1615 occurrences in ejabberd, second only to ?T, every one of them a fact
    -- the file already states and every one of them rendered opaque before this
    local k, v = classify('f() -> g(?MODULE).\n', 'src/mod_mam.erl')
    eq('lit', k)
    eq('mod_mam', v)
    -- a header is a module too, by the same rule
    local k2, v2 = classify('f() -> g(?MODULE).\n', 'include/thing.hrl')
    eq('lit', k2); eq('thing', v2)
end)

test('erlmacro: ?MODULE with no file falls back to the NAME, never a guess', function ()
    if not ready() then skip 'no erlang parser' end
    local k, v = classify('f() -> g(?MODULE).\n', nil)
    eq('macro', k)
    eq('MODULE', v)
end)

test('erlmacro: an unknown macro keeps its NAME', function ()
    if not ready() then skip 'no erlang parser' end
    -- the value may live in a library the tree does not contain; a named key can
    -- be linked, counted and refused where an opaque `expr` can do none of those
    local k, name = classify('f() -> g(?SOME_UNMODELLED_THING).\n', 'src/x.erl')
    eq('macro', k)
    eq('SOME_UNMODELLED_THING', name)
end)

test('erlmacro: a distilled value rides along WITHOUT becoming a literal', function ()
    if not ready() then skip 'no erlang parser' end
    local k, name, v = classify('f() -> g(?NS_MAM_2).\n', 'src/mod_mam.erl')
    eq('macro', k)
    eq('NS_MAM_2', name)
    -- ⚠ the kind stays `macro` whether or not a vocabulary answered: THE SOURCE
    -- DOES NOT SAY THIS URI HERE, a library does, and a local -define could
    -- shadow it. A consumer joins on `v` knowing where it came from.
    if v ~= nil then eq('urn:xmpp:mam:2', v) end
end)
