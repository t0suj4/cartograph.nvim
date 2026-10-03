-- xmppgrammar — THE XMPP WIRE AS AN ALGEBRA GRAMMAR (CART-1138): bytes <-> #xmlel <-> the decoded record, DERIVED and
-- then touched up where the derivation fell short. Registered as A.grammar('xmpp', { parse, print }), so a message on
-- the wire is an embed('xmpp', template): instantiate PRINTS it, match PARSES a reply and continues inside.
-- @langs erlang
--
-- THREE LAYERS, each from what the machine already has:
--   record <-> #xmlel   ENCODE: xmppspec.encode (the -xml forms by fxml_gen's rules; 498/498 against xmpp's own
--                       generated encoder). DECODE: xmpp's OWN generated decoder (xmpp_codec:decode/1), evaluated by
--                       erlterms from source — the library's code, not a restatement of it.
--   #xmlel -> bytes     the PRINTER. fxml:element_to_binary is a NIF (its Erlang body is nif_error): no source. Its
--                       rules were OBSERVED on the running library (erl is installed), and every one is checked against
--                       it by tools/xmppgrammar.lua:
--                         <name/> for no children, else <name …>children</name> (an empty cdata is a child)
--                         attributes in list order as k='v'
--                         text escapes  & < > " '  to their entities; \r and control characters are DROPPED
--                         an attribute escapes & < " ' (NOT >), and \n \t \r as &#xA; &#x9; &#xD;
--                       ⚠ TOUCH-UP: fxml:crypt (Erlang, readable from the beam) escapes all five in both places — it is
--                       NOT what the NIF does. The source a derivation would have read was the wrong source.
--   bytes -> #xmlel     the READER: tree-sitter's xml grammar (a published grammar, as the algebra's lossless lua
--                       reader is). Adjacent text, entity and CDATA pieces are ONE cdata, whitespace kept — as
--                       fxml_stream:parse_element gives it.
-- THE LAWS (checked, not assumed): read(print(el)) = el MODULO ATTRIBUTE ORDER (XML gives it no meaning, and fxml's own
-- parse does not keep it: namespace declarations come first); decode(read(print(encode(r)))) = r; print agrees with
-- fxml:element_to_binary byte for byte, read with fxml_stream:parse_element term for term.
local M = {}
local unpack = table.unpack or unpack

local function A() return assert(require('cartograph.algebra').load()) end
local function lit(v, lk) local l = A().lit(v); l.lk = lk; return l end

-- ── the #xmlel term: tuple("xmlel", Name, list(tuple(K, V)…), list(child…)), a text child tuple("xmlcdata", T) ──
function M.el(name, attrs, kids)
    local a = A()
    local as = {}
    for _, kv in ipairs(attrs or {}) do as[#as + 1] = a.node('tuple', lit(kv[1], 'bin'), lit(kv[2], 'bin')) end
    return a.node('tuple', lit('xmlel', 'atom'), lit(name, 'bin'), a.node('list', unpack(as)), a.node('list', unpack(kids or {})))
end
function M.cdata(s) return A().node('tuple', lit('xmlcdata', 'atom'), lit(s, 'bin')) end
local function is_el(t) return t and t.k == 'tuple' and t.kids and t.kids[1] and t.kids[1].k == 'lit' and t.kids[1].v == 'xmlel' end
local function is_cdata(t) return t and t.k == 'tuple' and t.kids and t.kids[1] and t.kids[1].k == 'lit' and t.kids[1].v == 'xmlcdata' end

--- an #xmlel term with every attribute list sorted: equality where XML's is — the attributes are a SET, in the order
--- the TERM relation declares (A.equality('term').less, consistent with term equality — CART-1398); child lists keep
--- their order (attributes and children are both `list` nodes, so no theory over the kind could say it)
function M.canon(t)
    if not t.kids then return t end
    local kids = {}
    for i, c in ipairs(t.kids) do kids[i] = M.canon(c) end
    local out = A().rebuild(t, kids)
    if t.k == 'tuple' and kids[1] and kids[1].k == 'lit' and kids[1].v == 'xmlel' and kids[3] then
        local as = {}
        for i, kv in ipairs(kids[3].kids or {}) do as[i] = kv end
        table.sort(as, A().equality('term').less)
        out.kids[3] = A().node('list', unpack(as))
    end
    return out
end

-- ── THE PRINTER (observed rules; see the header) ─────────────────────────────────────────────────────────────────
local TEXT_ESC = { ['&'] = '&amp;', ['<'] = '&lt;', ['>'] = '&gt;', ['"'] = '&quot;', ["'"] = '&apos;', ['\r'] = '' }
local ATTR_ESC = { ['&'] = '&amp;', ['<'] = '&lt;', ['"'] = '&quot;', ["'"] = '&apos;', ['\n'] = '&#xA;',
    ['\t'] = '&#x9;', ['\r'] = '&#xD;' }
local function esc(s, map)
    return (s:gsub('[%z\1-\31&<>"\']', function (c)
        if map[c] then return map[c] end
        if c:byte() >= 32 then return c end           -- `>` in an attribute: kept
        if c == '\n' or c == '\t' then return c end  -- in text: kept
        return ''                                      -- any other control character: dropped
    end))
end
function M.print_el(t)
    local out, ok, why = {}, true, nil
    local function go(x)
        if is_cdata(x) then
            local v = x.kids[2]
            if v.k ~= 'lit' then ok, why = false, 'a text child that is not known'; return end
            out[#out + 1] = esc(tostring(v.v), TEXT_ESC)
            return
        end
        if not is_el(x) then ok, why = false, 'not an #xmlel: ' .. tostring(x.k); return end
        local name = x.kids[2]
        if name.k ~= 'lit' then ok, why = false, 'an element name that is not known'; return end
        out[#out + 1] = '<' .. tostring(name.v)
        for _, kv in ipairs(x.kids[3].kids or {}) do
            local k, v = kv.kids and kv.kids[1], kv.kids and kv.kids[2]
            if not (k and v and k.k == 'lit' and v.k == 'lit') then ok, why = false, 'an attribute that is not known'; return end
            out[#out + 1] = (" %s='%s'"):format(tostring(k.v), esc(tostring(v.v), ATTR_ESC))
        end
        local kids = x.kids[4].kids or {}
        if #kids == 0 then out[#out + 1] = '/>'; return end
        out[#out + 1] = '>'
        for _, c in ipairs(kids) do go(c); if not ok then return end end
        out[#out + 1] = '</' .. tostring(name.v) .. '>'
    end
    go(t)
    if not ok then return nil, why end
    return table.concat(out)
end

-- ── THE READER (tree-sitter xml) ─────────────────────────────────────────────────────────────────────────────────
local ENT = { amp = '&', lt = '<', gt = '>', quot = '"', apos = "'" }
local function utf8_char(n)
    if n < 0x80 then return string.char(n) end
    if n < 0x800 then return string.char(0xC0 + math.floor(n / 64), 0x80 + n % 64) end
    if n < 0x10000 then return string.char(0xE0 + math.floor(n / 4096), 0x80 + math.floor(n / 64) % 64, 0x80 + n % 64) end
    return string.char(0xF0 + math.floor(n / 262144), 0x80 + math.floor(n / 4096) % 64, 0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
end
local function decode_refs(s)
    return (s:gsub('&(#?x?)([%w]+);', function (p, v)
        if p == '#x' then return utf8_char(tonumber(v, 16) or 0) end
        if p == '#' then return utf8_char(tonumber(v) or 0) end
        return ENT[v] or ('&' .. v .. ';')
    end))
end
function M.read(text)
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, 'xml')
    if not ok then return nil, 'no xml parser' end
    local root = parser:parse()[1]:root()
    if root:has_error() then return nil, 'the text does not parse as XML' end
    local function t(n) return vim.treesitter.get_node_text(n, text) end
    local function attrs_of(tag)
        local out = {}
        for c in tag:iter_children() do
            if c:type() == 'Attribute' then
                local nm, val
                for d in c:iter_children() do
                    if d:type() == 'Name' then nm = t(d) elseif d:type() == 'AttValue' then val = t(d) end
                end
                if nm and val then out[#out + 1] = { nm, decode_refs(val:sub(2, -2)) } end
            end
        end
        -- ★ TOUCH-UP, observed: fxml_stream puts the namespace declarations FIRST (xmlns, xmlns:p), the other
        -- attributes after in document order. XML gives attribute order no meaning; the runtime's term does.
        local ns, rest = {}, {}
        for _, kv in ipairs(out) do
            if kv[1] == 'xmlns' or kv[1]:match('^xmlns:') then ns[#ns + 1] = kv else rest[#rest + 1] = kv end
        end
        for _, kv in ipairs(rest) do ns[#ns + 1] = kv end
        return ns
    end
    local function element(n)
        local name, attrs, kids = nil, {}, {}
        local text_buf
        local function flush() if text_buf then kids[#kids + 1] = M.cdata(text_buf); text_buf = nil end end
        local function addtext(s) text_buf = (text_buf or '') .. s end
        for c in n:iter_children() do
            local ty = c:type()
            if ty == 'STag' or ty == 'EmptyElemTag' then
                for d in c:iter_children() do if d:type() == 'Name' then name = t(d); break end end
                attrs = attrs_of(c)
            elseif ty == 'content' then
                for d in c:iter_children() do
                    local dt = d:type()
                    if dt == 'element' then flush(); kids[#kids + 1] = element(d)
                    elseif dt == 'CharData' then addtext(t(d))
                    elseif dt == 'EntityRef' or dt == 'CharRef' then addtext(decode_refs(t(d)))
                    elseif dt == 'CDSect' then
                        for e in d:iter_children() do if e:type() == 'CData' then addtext(t(e)) end end
                    end
                end
            end
        end
        flush()
        return M.el(name, attrs, kids)
    end
    for c in root:iter_children() do
        if c:type() == 'element' then return element(c) end
    end
    return nil, 'no element'
end

-- ── THE GRAMMAR over records ─────────────────────────────────────────────────────────────────────────────────────
--- opts = { spec = xmpp_codec.spec path, otp = OTP source root } -> G = { encode, decode, print, parse }
function M.new(opts)
    opts = opts or {}
    local XS = require 'cartograph.xmppspec'
    local ET = require 'cartograph.erlterms'
    local ER = require 'cartograph.erlrecords'
    local X = require 'cartograph.xmppserver'
    local spec = assert(XS.read(opts.spec))
    local xmpp = vim.fn.fnamemodify(opts.spec, ':h:h')
    local hrl = xmpp .. '/include/xmpp.hrl'
    if vim.fn.filereadable(hrl) == 1 then
        local sc = ER.new {}:scope(hrl)
        if sc then XS.attach_records(spec, sc.records) end
    end
    local E = ER.new { include_dirs = { xmpp .. '/include' }, apps = { xmpp = xmpp } }
    local P = X.program(xmpp .. '/src', E, { otp = opts.otp })
    local G = { spec = spec, program = P }
    -- the encoder's primitives: the library's own enc functions
    local function enc(text, v, E2)
        local m, f = text:match('^{%s*([%w_]+)%s*,%s*([%w_]+)%s*,')
        if not m then f = text:match('^{%s*([%w_]+)%s*,'); m = E2.module end
        if not f then return A().hole('enc ' .. text) end
        return (ET.call(P, m, f, { v }, ET.session()))
    end
    function G.encode(record) return XS.encode(spec, record, '', { enc = enc }) end
    -- the decoded record: xmpp's generated decoder, evaluated; a tuple {r, …} of a record the spec knows IS #r{}
    local function as_record(t)
        if not t.kids then return t end
        local kids = {}
        for i, c in ipairs(t.kids) do kids[i] = as_record(c) end
        local h = kids[1]
        if t.k == 'tuple' and h and h.k == 'lit' then
            local names = XS.record_fields(spec, tostring(h.v))
            if names and #names == #kids - 1 then return A().node('rec:' .. tostring(h.v), unpack(kids, 2, #kids)) end
        end
        return A().rebuild(t, kids)
    end
    function G.decode(el)
        local saved = ET.MAX_DEPTH
        ET.MAX_DEPTH = math.max(saved, 16)   -- a generated decoder is a deep chain of small functions
        local t, holes = ET.call(P, 'xmpp_codec', 'decode', { el }, ET.session())
        ET.MAX_DEPTH = saved
        return as_record(t), holes
    end
    function G.print(record)
        local el, why = G.encode(record)
        if not el then return nil, why end
        return M.print_el(el)
    end
    function G.parse(text)
        local el, why = M.read(text)
        if not el then return nil end
        local r = G.decode(el)
        return r
    end
    return G
end

--- register as the algebra's 'xmpp' grammar (instantiate prints under it, match parses under it)
function M.register(G)
    A().grammar('xmpp', { parse = G.parse, print = G.print })
    return G
end

return M
