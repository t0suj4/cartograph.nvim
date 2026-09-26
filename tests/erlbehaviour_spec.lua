-- THE BEHAVIOUR-CALLBACK ALIBI (CART-1117). `-behaviour(B)` obliges a module to define B's callbacks, and B's
-- engine calls them through a VARIABLE module, so they read callerless. On ejabberd 38% of dead-function
-- findings were such callbacks. The alibi is lint.lua's shared contract predicate — so the alibi verb and the
-- dead-function rule are asked the SAME question here, and must agree (CART-0674's "both, or neither").
--
-- ★★★ THE GUARDS ARE THE FIXTURE. "every function named like a callback is alive" passes the positive rows
-- trivially and destroys the rule; each look-alike below is a different way the premise could over-reach:
--   a callback's NAME at a different ARITY                 stays dead   (depends/1, handle_cast/3)
--   the -callback arity a REGEX reads off a nested fun type  stays dead  (set_invitee/1)
--   a module that does not DECLARE the behaviour           stays dead   (other.erl)
--   a `?MACRO` behaviour with no same-file -define           stays dead  (unknown.erl)
-- and the positives each pin one producer: an in-tree -callback, an OPTIONAL one, the runtime's (the
-- distilled otp-api artifact — gen_server's handle_call/3), and a macro resolved through a same-file -define.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local lint = require 'cartograph.lint'
local eb = require 'cartograph.erlbehaviour'

local function have_erlang()
    return parser_available('erlang') and pcall(vim.treesitter.get_string_parser, '', 'erlang')
end

-- ★ THE REAL SHAPE, from ejabberd's mod_invites.erl: a nested `fun(() -> OkOrError)` type as the first
-- argument AND a `when` guard. The measuring probe's regex read this as arity 1.
local MYBEH = [[
-module(mybeh).
-callback set_invitee(Fun :: fun(() -> OkOrError),
                                Host :: binary(),
                                Token :: binary(),
                                Invitee :: binary(),
                                AccountName :: binary()) -> OkOrError | {error, conflict}
 when OkOrError :: ok | {error, term()}.
-callback depends(binary(), list()) -> [{module(), hard | soft}].
-callback mod_doc() -> map().
-callback g(X, % a comment between arguments is not an argument
            ?T) -> X when X :: atom().
-optional_callbacks([mod_doc/0]).
]]

local IMPL = [[
-module(impl).
-behaviour(mybeh).
-behaviour(gen_server).
set_invitee(F, _Host, _Token, _Invitee, _AccountName) -> F.
set_invitee(F) -> F.
depends(_Host, _Opts) -> [].
depends(_Host) -> [].
mod_doc() -> #{}.
handle_call(_Req, _From, S) -> {reply, ok, S}.
handle_cast(_Msg, _Extra, S) -> {noreply, S}.
]]

-- the same names, and NO -behaviour line: the tree selects the producer, so this module gets nothing
local OTHER = [[
-module(other).
depends(_Host, _Opts) -> [].
handle_call(_Req, _From, S) -> {reply, ok, S}.
]]

local MACRO = [[
-module(macro).
-ifndef(GS).
-define(GS, gen_server).
-endif.
-behaviour(?GS).
handle_cast(_Msg, S) -> {noreply, S}.
]]

local UNKNOWN = [[
-module(unknown).
-behaviour(?NOT_DEFINED_HERE).
handle_info(_Msg, S) -> {noreply, S}.
]]

test('erlbehaviour: -callback arity is read off the signature FIELD — a nested fun type, a guard, a comment', function ()
    if not have_erlang() then skip('no erlang parser') end
    local F = eb.parse_source(MYBEH)
    ok(F.by['set_invitee/5'], 'set_invitee is arity 5: ' .. vim.inspect(vim.tbl_keys(F.by)))
    eq(nil, F.by['set_invitee/1'], 'NOT the regex answer: `fun(() -> R)` is one argument, not the end of the list')
    ok(F.by['depends/2'] and F.by['mod_doc/0'], 'plain callbacks')
    ok(F.by['g/2'], 'a comment between arguments is not an argument: ' .. vim.inspect(vim.tbl_keys(F.by)))
    eq(true, F.by['mod_doc/0'].optional, '-optional_callbacks marks mod_doc/0')
    eq(nil, F.by['depends/2'].optional)
    local I = eb.parse_source(IMPL)
    eq('mybeh', I.behaviours[1].name)
    eq('gen_server', I.behaviours[2].name)
    local Mc = eb.parse_source(MACRO)
    eq('gen_server', Mc.behaviours[1].name, 'a same-file -define resolves the macro')
    eq('GS', Mc.behaviours[1].macro)
    local U = eb.parse_source(UNKNOWN)
    eq(nil, U.behaviours[1].name, 'no same-file -define: the behaviour stays unnamed')
end)

test('lint: a declared behaviour\'s callbacks are alibied (tree, optional, runtime, macro); look-alikes are not', function ()
    if not have_erlang() then skip('no erlang parser') end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for name, src in pairs({ ['mybeh.erl'] = MYBEH, ['impl.erl'] = IMPL, ['other.erl'] = OTHER,
                             ['macro.erl'] = MACRO, ['unknown.erl'] = UNKNOWN }) do
        local fd = assert(io.open(root .. '/' .. name, 'w')); fd:write(src); fd:close()
    end
    local data = ts.extract(root)
    store.ingest(data)
    local ali = lint.alibi(store)
    local dead = {}
    for _, f in ipairs(lint.run(store, { only = { ['dead-function'] = true } })) do
        local nm = f.message:match("'([^']+)'")
        dead[(f.file:match('([^/]+)$')) .. ':' .. f.line] = nm
    end
    -- (file, name, arity) -> the behaviour alibi's record, false when none, and whether dead-function reports it
    local function probe(file, nm, arity)
        for _, n in ipairs(data.nodes) do
            if n.file:match('([^/]+)$') == file and n.name == nm and eb.arity_of(n) == arity then
                local hit = false
                for _, a in ipairs(ali(n).alibis) do
                    if a.kind == 'behaviour-callback' then hit = a end
                end
                local line = require('cartograph.at').sl(n.range) + 1
                return hit, dead[file .. ':' .. line] ~= nil
            end
        end
        error(('NO SUCH NODE %s %s/%d'):format(file, nm, arity))
    end
    local ok_run, err = pcall(function ()
        -- ── the positives: one per producer ──
        local h, reported = probe('impl.erl', 'set_invitee', 5)
        ok(h, 'the tree callback set_invitee/5 is alibied')
        eq('matched', h.tier, 'name + arity is a MATCH, not a proof')
        eq('tree', h.evidence.producer)
        eq('mybeh', h.evidence.behaviour)
        eq(2, h.evidence.line, 'the evidence names the -behaviour line')
        ok(h.evidence.callback_file:match('mybeh%.erl$') and h.evidence.callback_line == 2,
            'and the -callback declaration: ' .. vim.inspect(h.evidence))
        eq(false, reported, 'dead-function agrees: not reported')
        h, reported = probe('impl.erl', 'mod_doc', 0)
        ok(h, 'an OPTIONAL callback that is defined is still a callback')
        eq(true, h.evidence.optional)
        eq(false, reported)
        h, reported = probe('impl.erl', 'handle_call', 3)
        ok(h, 'gen_server handle_call/3 is alibied through the runtime artifact')
        eq('runtime', h.evidence.producer)
        ok(h.evidence.app and h.evidence.app:match('^stdlib'), 'the supplying app is named: ' .. tostring(h.evidence.app))
        eq(false, reported)
        h, reported = probe('macro.erl', 'handle_cast', 2)
        ok(h, '-behaviour(?GS) resolves through the same-file -define')
        eq('GS', h.evidence.macro)
        eq(false, reported)
        -- ── the guards ──
        h, reported = probe('impl.erl', 'depends', 1)
        eq(false, h, 'a callback NAME at a different ARITY is not the callback')
        eq(true, reported, 'and dead-function still reports it')
        h, reported = probe('impl.erl', 'set_invitee', 1)
        eq(false, h, 'the regex arity (1) is not the declared arity (5)')
        eq(true, reported)
        h, reported = probe('impl.erl', 'handle_cast', 3)
        eq(false, h, 'gen_server declares handle_cast/2, not /3')
        eq(true, reported)
        h, reported = probe('other.erl', 'depends', 2)
        eq(false, h, 'a module that does not DECLARE the behaviour gets nothing')
        eq(true, reported)
        h, reported = probe('other.erl', 'handle_call', 3)
        eq(false, h, 'not even an OTP callback name')
        eq(true, reported)
        h, reported = probe('unknown.erl', 'handle_info', 2)
        eq(false, h, 'an unresolved macro behaviour selects nothing')
        eq(true, reported)
    end)
    vim.fn.delete(root, 'rf')
    if not ok_run then error(err, 0) end
end)

test('otp-api artifact: the runtime\'s behaviour callbacks are distilled, with optional flags and the app', function ()
    local api = require('cartograph.spec.profile').load('otp-api')
    ok(api and api.behaviours, 'the artifact carries behaviours (tools/erldistill.lua)')
    local gs = api.behaviours.gen_server
    ok(gs and gs.app and gs.app:match('^stdlib'), 'gen_server is stdlib\'s')
    local by = {}
    for _, c in ipairs(gs.callbacks) do by[c.name .. '/' .. c.arity] = c end
    ok(by['handle_call/3'] and by['handle_cast/2'] and by['init/1'], 'the required callbacks')
    eq(nil, by['handle_call/3'].optional)
    eq(true, by['handle_info/2'] and by['handle_info/2'].optional, 'handle_info/2 is optional')
end)
