-- ERLANG VALUES AS TERMS (lua/cartograph/erlterms.lua, CART-1112 step 1): what a function BUILDS, in the decoded-record
-- encoding the wire merge unifies on. Every form the later steps own becomes a HOLE that names its step.

local function need() if not parser_available('erlang') then skip 'no erlang parser' end end

local RECS = {
    iq = { 'id', 'type', 'lang', 'from', 'to', 'sub_els', 'meta' },
    disco_info = { 'node', 'identities', 'features', 'xdata' },
}
local DEFAULTS = {
    iq = { id = '<<>>', lang = '<<>>', sub_els = '[]', meta = '#{}' },
    disco_info = { node = '<<>>', identities = '[]', features = '[]', xdata = '[]' },
}
local CTX = { module = 'mod_t',
    record_fields = function (r) return RECS[r] end,
    defaults = function (r) return DEFAULTS[r] end }

-- the term of the LAST expression of the only clause in `src`
local function last_term(src)
    local ET = require 'cartograph.erlterms'
    local root = vim.treesitter.get_string_parser(src, 'erlang'):parse()[1]:root()
    local body = root:named_child(0):named_child(0):field('body')[1]
    local last
    for c in body:iter_children() do if c:named() then last = c end end
    local term, holes = ET.term(last, src, CTX)
    return require('cartograph.algebra').load().show(term), holes, ET.status(term)
end

local function reasons(holes)
    local out = {}
    for _, w in pairs(holes) do out[#out + 1] = w end
    table.sort(out)
    return out
end

test('erlterms: a record literal takes its declared defaults for the fields it does not set', function ()
    need()
    local shown, _, st = last_term('f() -> #disco_info{node = <<"x">>, features = [<<"urn:a">>]}.\n')
    eq('(rec:disco_info "x" (nil) (cons "urn:a" (nil)) (nil))', shown)
    eq('complete', st)
end)

test('erlterms: a variable is its single-assignment binding; an update keeps the base; macros read the vocabulary', function ()
    need()
    local shown, holes = last_term(table.concat({
        'f() ->',
        '    D = #disco_info{node = ?NS_DISCO_INFO},',
        '    I = #iq{type = result, sub_els = [D]},',
        '    I#iq{id = ?MODULE}.', '' }, '\n'))
    eq('(rec:iq "mod_t" "result" "" "undefined" "undefined" (cons (rec:disco_info "http://jabber.org/protocol/disco#info" (nil) (nil) (nil)) (nil)) (map))', shown)
    eq({}, reasons(holes))
end)

test('erlterms: what the later steps own is a hole that names its step', function ()
    need()
    local shown, holes, st = last_term(table.concat({
        'f(P, #iq{lang = L}) ->',
        '    X = case P of a -> 1; _ -> 2 end,',
        '    #disco_info{node = P, identities = L, features = g(), xdata = X}.', '' }, '\n'))
    eq('partial', st)
    local r = reasons(holes)
    local joined = table.concat(r, ' | ')
    ok(joined:find('step 4', 1, true), 'a parameter: ' .. joined)
    ok(joined:find('step 3', 1, true), 'a call result')
    ok(joined:find('step 2', 1, true), 'a case value')
    eq(4, #r, 'P and L are head names (parameters), g() a call, X a case: ' .. joined)
    ok(shown:find('^%(rec:disco_info'), 'the structure is still known: ' .. shown)
end)
