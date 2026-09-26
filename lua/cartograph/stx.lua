-- stx.lua — STROPHE `stx` TAGGED TEMPLATES READ AS XML ELEMENT TREES WITH HOLES (CART-1097).
-- @langs javascript — and the xml grammar, which langaudit cannot name (it has no extraction spec)
--
-- converse.js builds its XMPP stanzas as `stx` tagged template literals: XML text with `${...}` holes.
-- This is the CLIENT leg of the XMPP triple (CART-1087 phase 2): per stanza, the top element, its type,
-- and every (element name, namespace) it contains, holes marked. The leave-one-out gate (CART-0862)
-- compares it with what the ejabberd handlers read and what the codec spec declares; it is not built here.
--
-- ── WHAT `stx` DOES AT RUNTIME, FROM THE SOURCE (strophe.js 5.0.0 src/stanza.ts, the tarball whose
-- sha512 matches converse's package-lock) ─────────────────────────────────────────────────────────────
--   `Stanza.toString` concatenates the static strings with each value SPLICED AS TEXT: a Stanza or a
--   Builder as its serialization, an `UnsafeXML` raw, an array as its members joined, anything else
--   `xmlescape`d. Only the whole string is parsed (DOMParser), when the stanza is built.
--   ⇒ two consequences this reader relies on:
--     1. a string can never inject markup, so a content hole is TEXT unless its value is a
--        Stanza/Builder/UnsafeXML (named below as its FILL);
--     2. a nested `stx` fragment inherits the namespace in scope WHERE IT IS SPLICED, textually. So a
--        fragment's own tree records `ns.via = 'none'` for an undeclared namespace, and `M.inventory`
--        resolves it at the splice site (`via = 'spliced'`) — a separate, labelled step.
--   `Stanza.toElement` REFUSES (throws, when built) a top `iq`/`message`/`presence` whose namespace is
--   not jabber:client or jabber:server, so a top without xmlns is recorded as nil, never assumed.
--
-- ── HOW: PARSE A VIEW, READ FROM THE ORIGINAL (the luadialect.lua trick) ─────────────────────────────
-- Each `${...}` is replaced by a SAME-LENGTH placeholder chosen by the XML LEXER STATE at the hole:
--   attribute value (quoted)   `xxxx`          cannot close the value
--   between attributes         `_=""`/`__=""`  a synthetic attribute (a `${x}` is at least 4 bytes)
--   after `=`, unquoted        `"xx"`          a quoted value
--   content / comment / CDATA  `xxxx`
--   element or attribute name  `xxxx`
-- The view is parsed with tree-sitter-xml; every site is mapped back BY BYTE OFFSET (a hole's
-- expression may span lines, the placeholder does not, so the XML tree's rows are not the file's).
-- ★ A TEMPLATE IS UNPARSED, NEVER HALF-READ: an XML error node refuses it, and so does any hole that
-- is not placed at exactly one site of the kind the lexer predicted (the known-nonzero counter: a
-- placeholder that parsed but landed somewhere unexpected is caught here, not in a consumer).
--
-- ── THE RECORD (`M.templates(src, opts)`, one per `stx` call, in source order) ──────────────────────
--   { id, line, col (1-based, bytes), s, e (0-based byte range of the call), body_s,
--     ok, why, fragment (more than one root, or text beside the root: legal only when spliced),
--     roots = { element.. }, tree = roots[1] when there is exactly one,
--     holes = { hole.. }, parent, parent_hole (a template nested in another's hole) , bound_by }
--   element = { name, prefix, localname, name_hole, ns = { uri, via, expr, declared },
--               attrs = { {name, value | hole | parts}.. } (source order), attr = { name -> attr },
--               attr_holes = { hole index.. } (a whole attribute list from a hole),
--               children = { element | {text=} | {hole=i} .. } (whitespace-only text dropped),
--               path, line, col }
--   hole = { i, expr, s, e, line, col, pos (lexer), site = 'attr'|'attrs'|'content'|'name'|'comment'|'cdata'|'pi',
--            attr (for an attr site), element (its path), fill = 'text'|'element'|'elements'|'raw'|'unknown',
--            cond (a ternary or `??`: the value may be empty), nested = { template id.. }, bind (candidate id),
--            fill_via = 'const' (the fill read through a file-local const initializer, one hop) }
--   ⚠ a fill of 'text' at an 'attrs' site is a CLIENT BUG SHAPE: Strophe escapes it (`"` -> `&quot;`),
--   so the stanza does not parse whenever the value is non-empty.
--   ns.via: 'literal' | 'strophe' (built-in Strophe.NS) | 'addNamespace' (harvested) | 'const' (file-local
--           string const) | 'export' (a corpus-exported const) | 'unresolved' (expr kept) | 'none' | 'undeclared-prefix'
local M = {}

local xv = require('cartograph.xmlvalue')

--- strophe.js 5.0.0 src/constants.ts `_NS` (the built-in table; converse adds the rest with addNamespace)
M.STROPHE_NS = {
    AUTH = 'jabber:iq:auth',
    BIND = 'urn:ietf:params:xml:ns:xmpp-bind',
    BOSH = 'urn:xmpp:xbosh',
    CLIENT = 'jabber:client',
    COMPONENT = 'jabber:component:accept',
    DISCO_INFO = 'http://jabber.org/protocol/disco#info',
    DISCO_ITEMS = 'http://jabber.org/protocol/disco#items',
    DELAY = 'urn:xmpp:delay',
    FRAMING = 'urn:ietf:params:xml:ns:xmpp-framing',
    HTTPBIND = 'http://jabber.org/protocol/httpbind',
    MUC = 'http://jabber.org/protocol/muc',
    PROFILE = 'jabber:iq:profile',
    ROSTER = 'jabber:iq:roster',
    SASL = 'urn:ietf:params:xml:ns:xmpp-sasl',
    SERVER = 'jabber:server',
    SESSION = 'urn:ietf:params:xml:ns:xmpp-session',
    SM = 'urn:xmpp:sm:3',
    STANZAS = 'urn:ietf:params:xml:ns:xmpp-stanzas',
    STREAM = 'http://etherx.jabber.org/streams',
    VERSION = 'jabber:iq:version',
    XHTML = 'http://www.w3.org/1999/xhtml',
    XHTML_IM = 'http://jabber.org/protocol/xhtml-im',
}

M.STANZAS = { iq = true, message = true, presence = true }

local function ntext(n, src) return vim.treesitter.get_node_text(n, src) end
local function sbyte(n) return select(3, n:start()) end
local function ebyte(n) return select(3, n:end_()) end

local function line_index(src)
    local starts = { 0 }
    for p in src:gmatch('()\n') do starts[#starts + 1] = p end -- p is 1-based: the next line starts at byte p (0-based)
    return function(off)
        local lo, hi = 1, #starts
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            if starts[mid] <= off then lo = mid else hi = mid - 1 end
        end
        return lo, off - starts[lo] + 1
    end
end

local function js_root(src)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'javascript')
    if not ok then return nil, 'no javascript tree-sitter parser' end
    local tree = parser:parse()[1]
    if not tree then return nil, 'javascript parse failed' end
    return tree:root()
end

-- the tag must be the identifier `stx` itself: lit's html`...`, css`...` are tagged templates too
local function is_stx_call(n, src)
    if n:type() ~= 'call_expression' then return false end
    local f, a = n:field('function')[1], n:field('arguments')[1]
    return f ~= nil and a ~= nil and f:type() == 'identifier' and a:type() == 'template_string'
        and ntext(f, src) == 'stx', f, a
end

local function string_value(n, src)
    if n and n:type() == 'string' then return ntext(n, src):sub(2, -2) end
    return nil
end

-- ── constant namespace expressions ──────────────────────────────────────────────────────────
-- A tiny AST for the expressions converse writes namespaces with, evaluated later against corpus
-- tables: { k='str', v } | { k='ns', key } (Strophe.NS.K / NS.K) | { k='id', name } | { k='cat', parts }.
-- `subst` (a file's own string consts) replaces an identifier at build time; nil keeps it as an id.
local function const_expr(n, src, subst)
    if not n then return nil end
    local t = n:type()
    if t == 'string' then return { k = 'str', v = ntext(n, src):sub(2, -2) } end
    if t == 'parenthesized_expression' then return const_expr(n:named_child(0), src, subst) end
    if t == 'template_string' then
        local parts = {}
        for c in n:iter_children() do
            if c:type() == 'string_fragment' then parts[#parts + 1] = { k = 'str', v = ntext(c, src) }
            elseif c:type() == 'template_substitution' then
                local x = const_expr(c:named_child(0), src, subst)
                if not x then return nil end
                parts[#parts + 1] = x
            elseif c:type() == 'escape_sequence' then return nil end
        end
        return { k = 'cat', parts = parts }
    end
    if t == 'member_expression' then
        local text = ntext(n, src)
        local key = text:match('^[%w_.]-%f[%w]Strophe%.NS%.([%w_]+)$') or text:match('^NS%.([%w_]+)$')
        if key then return { k = 'ns', key = key } end
        return nil
    end
    if t == 'identifier' then
        local name = ntext(n, src)
        if subst and subst[name] then return { k = 'str', v = subst[name] } end
        return { k = 'id', name = name }
    end
    if t == 'binary_expression' then
        local op = n:field('operator')[1]
        if op and ntext(op, src) == '+' then
            local a, b = const_expr(n:field('left')[1], src, subst), const_expr(n:field('right')[1], src, subst)
            if a and b then return { k = 'cat', parts = { a, b } } end
        end
    end
    return nil
end
M._const_expr = const_expr

-- one walk over the JS tree: stx calls, const string declarations, addNamespace calls, stx-bound names
local function scan(root, src)
    local calls, consts, exported, ns, binds, ns_nodes, inits = {}, {}, {}, {}, {}, {}, {}
    local stack = { root }
    while #stack > 0 do
        local n = table.remove(stack)
        local t = n:type()
        local stx, _, args = is_stx_call(n, src)
        if stx then calls[#calls + 1] = { node = n, tpl = args } end
        if t == 'variable_declarator' then
            local name, value = n:field('name')[1], n:field('value')[1]
            if name and value and name:type() == 'identifier' then
                local id = ntext(name, src)
                local decl = n:parent()
                local is_const = decl and decl:type() == 'lexical_declaration' and decl:child(0) and decl:child(0):type() == 'const'
                local sv = string_value(value, src)
                if is_const then
                    inits[id] = inits[id] or {}
                    table.insert(inits[id], value)
                end
                -- a const is a string, or a constant expression over namespaces (`${Strophe.NS.PUBSUB}#event`)
                local cv = is_const and (sv or (value:type() ~= 'identifier' and const_expr(value, src, nil))) or nil
                if cv then
                    consts[id] = cv
                    if decl:parent() and decl:parent():type() == 'export_statement' then exported[id] = cv end
                end
                if is_stx_call(value, src) then
                    binds[id] = binds[id] or {}
                    table.insert(binds[id], sbyte(value))
                end
            end
        elseif t == 'call_expression' then
            local f, a = n:field('function')[1], n:field('arguments')[1]
            if f and a and ntext(f, src) == 'Strophe.addNamespace' then
                local k = string_value(a:named_child(0), src)
                if k and a:named_child(1) then ns_nodes[#ns_nodes + 1] = { k, a:named_child(1) } end
            end
        end
        for i = n:named_child_count() - 1, 0, -1 do stack[#stack + 1] = n:named_child(i) end
    end
    table.sort(calls, function(x, y) return sbyte(x.node) < sbyte(y.node) end)
    -- addNamespace values: an AST, the file's own consts substituted (they are only in scope here)
    for _, kn in ipairs(ns_nodes) do
        local x = const_expr(kn[2], src, consts)
        if x then ns[kn[1]] = x end
    end
    return { calls = calls, consts = consts, exported = exported, ns = ns, binds = binds, inits = inits }
end

--- The namespace tables one JS source contributes: { ns = {K -> const AST} (Strophe.addNamespace),
--- consts = {X -> string} (const declarations), exported = {X -> string} (exported ones) }.
function M.harvest(src)
    local root, why = js_root(src)
    if not root then return nil, why end
    local s = scan(root, src)
    return { ns = s.ns, consts = s.consts, exported = s.exported }
end

--- A namespace resolver over corpus tables { ns = {K -> const AST | uri string},
--- exported = {X -> string | const AST | false (exported by two files with different values)} }.
--- Returns function(ast, file_consts) -> uri | nil, via. The via names the OUTERMOST shape:
--- 'strophe' | 'addNamespace' (a Strophe.NS key), 'const' | 'export' (an identifier), 'literal'
--- (a string), 'composed' (a concatenation); nil and 'unresolved' when any part is unknown.
function M.resolver(tables)
    tables = tables or {}
    local ns, exported = tables.ns or {}, tables.exported or {}
    local function eval(x, fc, depth)
        if depth > 20 or type(x) ~= 'table' then return nil, 'unresolved' end
        if x.k == 'str' then return x.v, 'literal' end
        if x.k == 'ns' then
            local v = ns[x.key]
            if type(v) == 'string' then return v, 'addNamespace' end
            if type(v) == 'table' then
                local r = eval(v, nil, depth + 1)
                if r then return r, 'addNamespace' end
                return nil, 'unresolved'
            end
            if M.STROPHE_NS[x.key] then return M.STROPHE_NS[x.key], 'strophe' end
            return nil, 'unresolved'
        end
        if x.k == 'id' then
            for _, src_via in ipairs({ { fc, 'const' }, { exported, 'export' } }) do
                local v = src_via[1] and src_via[1][x.name]
                if type(v) == 'string' then return v, src_via[2] end
                if type(v) == 'table' then
                    -- an expression const: its own identifiers are the exporting file's, so only
                    -- corpus exports resolve them (no file consts)
                    local r = eval(v, src_via[2] == 'const' and fc or nil, depth + 1)
                    if r then return r, src_via[2] end
                    return nil, 'unresolved'
                end
            end
            return nil, 'unresolved'
        end
        if x.k == 'cat' then
            local out = {}
            for _, p in ipairs(x.parts) do
                local v = eval(p, fc, depth + 1)
                if not v then return nil, 'unresolved' end
                out[#out + 1] = v
            end
            if #x.parts == 1 then return out[1], select(2, eval(x.parts[1], fc, depth + 1)) end
            return table.concat(out), 'composed'
        end
        return nil, 'unresolved'
    end
    return function(ast, file_consts) return eval(ast, file_consts, 0) end
end

-- ── the view ────────────────────────────────────────────────────────────────────────────────
-- the lexer state at each hole, and the view with each hole replaced by a same-length placeholder
local function build_view(body, holes)
    local out, st, q = {}, 'content', nil
    local i, hi, n = 1, 1, #body
    local function at(s) return body:sub(i, i + #s - 1) == s end
    while i <= n do
        local h = holes[hi]
        if h and i == h.vs + 1 then
            local L = h.ve - h.vs
            local pos, ph
            if st == 'content' then pos = 'content'; ph = ('x'):rep(L)
            elseif st == 'value' then pos = 'attr'; ph = ('x'):rep(L)
            elseif (st == 'intag' or st == 'afterattr' or (st == 'tagname' and body:sub(i - 1, i - 1):match('[%w_:.-]')))
                and not (st == 'tagname' and L < 5) then
                -- between attributes, or GLUED to the tag name or a closing quote (`<subscriptions${a}/>`):
                -- the value must bring its own leading space, so the placeholder does too
                pos = 'attrs'
                if body:sub(i - 1, i - 1):match('%s') then ph = ('_'):rep(L - 3) .. '=""'
                else ph = ' ' .. ('_'):rep(L - 4) .. '=""' end
                st = 'intag'
            elseif st == 'aftereq' then pos = 'attr'; ph = '"' .. ('x'):rep(L - 2) .. '"'; st = 'intag'
            elseif st == 'tagname' or st == 'attrname' or st == 'endtag' then pos = 'name'; ph = ('x'):rep(L)
            else pos = st; ph = ('x'):rep(L) end -- comment, cdata, pi
            h.pos = pos
            out[#out + 1] = ph
            i = h.ve + 1
            hi = hi + 1
        else
            local c = body:sub(i, i)
            local step = 1
            if st == 'content' then
                if at('<!--') then st = 'comment'; step = 4
                elseif at('<![CDATA[') then st = 'cdata'; step = 9
                elseif at('<?') then st = 'pi'; step = 2
                elseif at('</') then st = 'endtag'; step = 2
                elseif c == '<' then st = 'tagname' end
            elseif st == 'tagname' then
                if c:match('%s') or c == '/' then st = 'intag' elseif c == '>' then st = 'content' end
            elseif st == 'intag' then
                if c == '>' then st = 'content' elseif c:match('[%w_:]') then st = 'attrname' end
            elseif st == 'attrname' then
                if c == '=' then st = 'aftereq' elseif c:match('%s') then st = 'afterattr'
                elseif c == '>' then st = 'content' elseif c == '/' then st = 'intag' end
            elseif st == 'afterattr' then
                if c == '=' then st = 'aftereq' elseif c == '>' then st = 'content' elseif c:match('[%w_:]') then st = 'attrname' end
            elseif st == 'aftereq' then
                if c == '"' or c == "'" then st = 'value'; q = c elseif not c:match('%s') then st = 'intag' end
            elseif st == 'value' then
                if c == q then st = 'intag' end
            elseif st == 'comment' then
                if at('-->') then st = 'content'; step = 3 end
            elseif st == 'cdata' then
                if at(']]>') then st = 'content'; step = 3 end
            elseif st == 'pi' then
                if at('?>') then st = 'content'; step = 2 end
            elseif st == 'endtag' then
                if c == '>' then st = 'content' end
            end
            out[#out + 1] = body:sub(i, i + step - 1)
            i = i + step
        end
    end
    return table.concat(out)
end

-- ── the XML walk ────────────────────────────────────────────────────────────────────────────
local function read_tree(view, body, holes, shift, resolve, file_consts, lc, body_s)
    local okp, parser = pcall(vim.treesitter.get_string_parser, view, 'xml')
    if not okp then return nil, 'no xml tree-sitter parser' end
    local tree = parser:parse()[1]
    if not tree then return nil, 'xml parse failed' end
    local root = tree:root()
    if root:has_error() then return nil, 'the xml does not parse (tree-sitter reports an error node)' end

    -- body offset of a view offset, and the original text of a view range
    local function bo(v) return v - shift end
    local function raw(vs, ve) return body:sub(bo(vs) + 1, bo(ve)) end
    local function holes_in(vs, ve)
        local r = {}
        for _, h in ipairs(holes) do
            if h.vs >= bo(vs) and h.ve <= bo(ve) then r[#r + 1] = h end
        end
        return r
    end
    local placed = {}
    local function place(h, site, extra)
        placed[h.i] = (placed[h.i] or 0) + 1
        h.site = site
        for k, v in pairs(extra or {}) do h[k] = v end
    end
    -- split a view range into decoded text pieces and hole references
    local function pieces(vs, ve, site, extra)
        local out, cur = {}, bo(vs)
        for _, h in ipairs(holes_in(vs, ve)) do
            if h.vs > cur then out[#out + 1] = xv.decode(body:sub(cur + 1, h.vs)) end
            out[#out + 1] = { hole = h.i }
            place(h, site, extra)
            cur = h.ve
        end
        if cur < bo(ve) then out[#out + 1] = xv.decode(body:sub(cur + 1, bo(ve))) end
        return out
    end
    local function where(vs)
        local l, c = lc(body_s + bo(vs)); return l, c
    end

    local function ns_of(a)
        if a.value then return { uri = a.value, via = 'literal', declared = true } end
        if a.hole then
            local h = holes[a.hole]
            local uri, via = resolve(h.cexpr, file_consts)
            return { uri = uri, via = via, expr = h.expr, declared = true }
        end
        -- a composed value (`${Strophe.NS.PUBSUB}#owner`): resolved when every hole is
        local parts, ast = {}, { k = 'cat', parts = {} }
        for _, p in ipairs(a.parts or {}) do
            if type(p) == 'table' then
                parts[#parts + 1] = '${' .. holes[p.hole].expr .. '}'
                ast.parts[#ast.parts + 1] = holes[p.hole].cexpr or { k = 'unknown' }
            else
                parts[#parts + 1] = p
                ast.parts[#ast.parts + 1] = { k = 'str', v = p }
            end
        end
        local uri, via = resolve(ast, file_consts)
        return { uri = uri, via = via, expr = table.concat(parts), declared = true }
    end
    local function inherit(ns)
        if not ns then return nil end
        return { uri = ns.uri, via = ns.via, expr = ns.expr, declared = false }
    end

    local function element(n, scope, ppath)
        local tag, content
        for c in n:iter_children() do
            local t = c:type()
            if t == 'STag' or t == 'EmptyElemTag' then tag = c elseif t == 'content' then content = c end
        end
        local el = { attrs = {}, attr = {}, attr_holes = {}, children = {} }
        el.line, el.col = where(sbyte(n))
        local decl = {}
        for c in tag:iter_children() do
            local t = c:type()
            if t == 'Name' and not el.name and not el.name_hole then
                local hs = holes_in(sbyte(c), ebyte(c))
                if #hs > 0 then
                    for _, h in ipairs(hs) do place(h, 'name') end
                    el.name_hole = hs[1].i
                else
                    el.name = raw(sbyte(c), ebyte(c))
                end
            elseif t == 'Attribute' then
                local whole
                for _, h in ipairs(holes) do
                    -- the placeholder IS the attribute (a glued one carries a leading space before it)
                    if h.pos == 'attrs' and h.vs <= bo(sbyte(c)) and bo(sbyte(c)) <= h.vs + 1 and h.ve == bo(ebyte(c)) then whole = h end
                end
                if whole then
                    place(whole, 'attrs')
                    el.attr_holes[#el.attr_holes + 1] = whole.i
                else
                    local a = {}
                    for x in c:iter_children() do
                        if x:type() == 'Name' then
                            local hs = holes_in(sbyte(x), ebyte(x))
                            for _, h in ipairs(hs) do place(h, 'name') end
                            a.name = raw(sbyte(x), ebyte(x))
                            if #hs > 0 then a.name_hole = hs[1].i end
                        elseif x:type() == 'AttValue' then
                            local ps = pieces(sbyte(x) + 1, ebyte(x) - 1, 'attr', { attr = a.name })
                            if #ps == 0 then a.value = ''
                            elseif #ps == 1 and type(ps[1]) == 'string' then a.value = ps[1]
                            elseif #ps == 1 then a.hole = ps[1].hole
                            else a.parts = ps end
                        end
                    end
                    if a.name == 'xmlns' then decl[''] = ns_of(a)
                    elseif a.name and a.name:sub(1, 6) == 'xmlns:' then decl[a.name:sub(7)] = ns_of(a) end
                    el.attrs[#el.attrs + 1] = a
                    if a.name then el.attr[a.name] = a end
                end
            end
        end
        local sc = setmetatable(decl, { __index = scope })
        if el.name then
            el.prefix, el.localname = el.name:match('^([^:]+):(.+)$')
            if not el.prefix then el.localname = el.name end
        end
        if el.prefix then
            el.ns = rawget(decl, el.prefix) or inherit(scope[el.prefix]) or { via = 'undeclared-prefix', declared = false }
        else
            el.ns = rawget(decl, '') or inherit(scope['']) or { via = 'none', declared = false }
        end
        el.path = (ppath and (ppath .. '/') or '') .. (el.name or ('${' .. holes[el.name_hole].expr .. '}'))
        for _, a in ipairs(el.attrs) do
            local function mark(i) holes[i].element = el.path end
            if a.hole then mark(a.hole) end
            for _, p in ipairs(a.parts or {}) do if type(p) == 'table' then mark(p.hole) end end
        end
        for _, i in ipairs(el.attr_holes) do holes[i].element = el.path end
        if el.name_hole then holes[el.name_hole].element = el.path end

        local texts = {}
        local function flush()
            if #texts == 0 then return end
            local s = table.concat(texts)
            texts = {}
            if s:find('%S') then el.children[#el.children + 1] = { text = s } end
        end
        if content then
            for c in content:iter_children() do
                local t = c:type()
                if t == 'element' then
                    flush()
                    el.children[#el.children + 1] = element(c, sc, el.path)
                elseif t == 'CharData' then
                    for _, p in ipairs(pieces(sbyte(c), ebyte(c), 'content', { element = el.path })) do
                        if type(p) == 'table' then flush(); el.children[#el.children + 1] = p else texts[#texts + 1] = p end
                    end
                elseif t == 'EntityRef' or t == 'CharRef' then
                    texts[#texts + 1] = xv.decode(raw(sbyte(c), ebyte(c)))
                elseif t == 'CDSect' then
                    for x in c:iter_children() do
                        if x:type() == 'CData' then
                            for _, p in ipairs(pieces(sbyte(x), ebyte(x), 'cdata', { element = el.path })) do
                                if type(p) == 'table' then flush(); el.children[#el.children + 1] = p else texts[#texts + 1] = p end
                            end
                        end
                    end
                else -- Comment, PI: holes inside are placed and dropped from the tree
                    local site = (t == 'Comment') and 'comment' or 'pi'
                    for _, h in ipairs(holes_in(sbyte(c), ebyte(c))) do place(h, site, { element = el.path }) end
                end
            end
            flush()
        end
        return el
    end

    local roots, stray = {}, false
    local top = root
    if shift > 0 then
        -- the wrapped view: the synthetic <_> element's content holds the real roots
        top = nil
        for c in root:iter_children() do if c:type() == 'element' then top = c end end
        for c in top:iter_children() do if c:type() == 'content' then top = c end end
    end
    for c in top:iter_children() do
        local t = c:type()
        if t == 'element' then roots[#roots + 1] = element(c, {}, nil)
        elseif t == 'CharData' then
            -- only in the wrapped view: a hole or text BESIDE the roots (a fragment's `${a}${b}`)
            for _, p in ipairs(pieces(sbyte(c), ebyte(c), 'content')) do
                if type(p) == 'table' then roots[#roots + 1] = p; stray = true
                elseif p:find('%S') then roots[#roots + 1] = { text = p }; stray = true end
            end
        elseif t == 'EntityRef' or t == 'CharRef' or t == 'CDSect' then
            stray = true
            for _, h in ipairs(holes_in(sbyte(c), ebyte(c))) do place(h, 'cdata') end
        elseif t == 'Comment' then
            for _, h in ipairs(holes_in(sbyte(c), ebyte(c))) do place(h, 'comment') end
        elseif t == 'prolog' then
            -- a comment BEFORE the root parses inside the prolog: place by the prolog child's own type
            for x in c:iter_children() do
                local site = x:type() == 'Comment' and 'comment' or 'pi'
                for _, h in ipairs(holes_in(sbyte(x), ebyte(x))) do place(h, site) end
            end
        end
    end
    -- ★ every hole at exactly one site, of the kind the lexer predicted
    for _, h in ipairs(holes) do
        if placed[h.i] ~= 1 then
            return nil, ('hole %d (${%s}) placed at %d sites, not 1'):format(h.i, h.expr, placed[h.i] or 0)
        end
        if h.site ~= h.pos then
            return nil, ('hole %d (${%s}) read as %s where the lexer predicted %s'):format(h.i, h.expr, h.site, h.pos)
        end
    end
    return roots, nil, stray
end

-- ── the JS side of a hole: what fills it ────────────────────────────────────────────────────
local MARKUP = { 'Stanza%.fromString%s*%(', 'Builder%.fromString%s*%(', '%$build%s*%(', '%$iq%s*%(', '%$msg%s*%(', '%$pres%s*%(' }

-- is `e` (or, through one arrow body, what it maps to) an `x.map(...)` call
local function is_map_call(e, src)
    if e:type() ~= 'call_expression' then return false end
    local f = e:field('function')[1]
    if not (f and f:type() == 'member_expression') then return false end
    local p = f:field('property')[1]
    return p ~= nil and ntext(p, src) == 'map'
end

local function classify_fill(e, src, nested, bind)
    local t = e:type()
    local text = ntext(e, src)
    local cond = (t == 'ternary_expression') or text:find('??', 1, true) ~= nil or nil
    -- `a ?? ''`, `c ? x : ''`: classify the markup-bearing side
    local core = e
    if t == 'binary_expression' then core = e:field('left')[1] or e end
    if t == 'ternary_expression' then core = e:field('consequence')[1] or e end
    local many = core:type() == 'array' or is_map_call(core, src)
    -- (a const initializer is classified without its nested list: the text still says `stx` + backtick)
    if #nested > 0 or text:find('stx`', 1, true) then return many and 'elements' or 'element', cond end
    if text:find('unsafeXML', 1, true) then return 'raw', cond end
    for _, pat in ipairs(MARKUP) do
        if text:find(pat) then return many and 'elements' or 'element', cond end
    end
    local ct = core:type()
    if ct == 'string' or ct == 'template_string' or ct == 'number' then return 'text', cond end
    if bind then return 'element', cond end
    return 'unknown', cond
end

--- Every `stx` tagged template in a JS source, read. opts.resolve = a M.resolver(...) function;
--- by default the built-in Strophe table plus this source's own addNamespace calls and consts.
function M.templates(src, opts)
    opts = opts or {}
    local root, why = js_root(src)
    if not root then return nil, why end
    local sc = scan(root, src)
    local resolve = opts.resolve or M.resolver({ ns = sc.ns, exported = sc.exported })
    local lc = line_index(src)
    local recs, by_start = {}, {}
    for idx, call in ipairs(sc.calls) do
        local tpl = call.tpl
        local body_s, body_e = sbyte(tpl) + 1, ebyte(tpl) - 1
        local body = src:sub(body_s + 1, body_e)
        local r = { id = idx, s = sbyte(call.node), e = ebyte(call.node), body_s = body_s, holes = {} }
        r.line, r.col = lc(r.s)
        for c in tpl:iter_children() do
            if c:type() == 'template_substitution' then
                local expr = c:named_child(0)
                local h = {
                    i = #r.holes + 1, s = sbyte(c), e = ebyte(c), vs = sbyte(c) - body_s, ve = ebyte(c) - body_s,
                    expr = expr and ntext(expr, src) or '', node = expr, cexpr = const_expr(expr, src, nil),
                }
                h.line, h.col = lc(h.s)
                r.holes[#r.holes + 1] = h
            end
        end
        recs[idx] = r
        by_start[r.s] = r
        r.body = body
    end
    -- nesting: the innermost hole (of another template) containing each call
    for _, r in ipairs(recs) do
        local best
        for _, u in ipairs(recs) do
            if u ~= r then
                for _, h in ipairs(u.holes) do
                    if h.s <= r.s and r.e <= h.e and (not best or (h.e - h.s) < (best.h.e - best.h.s)) then best = { u = u, h = h } end
                end
            end
        end
        if best then
            r.parent, r.parent_hole = best.u.id, best.h.i
            best.h.nested = best.h.nested or {}
            table.insert(best.h.nested, r.id)
        end
    end
    -- fills and candidate bindings (a hole that names a unique `const x = stx...` of this file)
    for _, r in ipairs(recs) do
        for _, h in ipairs(r.holes) do
            h.nested = h.nested or {}
            if h.node and h.node:type() == 'identifier' then
                local starts = sc.binds[h.expr]
                if starts and #starts == 1 and by_start[starts[1]] and by_start[starts[1]] ~= r then
                    h.bind = by_start[starts[1]].id
                    local b = by_start[starts[1]]
                    b.bound_by = b.bound_by or {}
                    table.insert(b.bound_by, { id = r.id, hole = h.i })
                end
            end
            if h.node then h.fill, h.cond = classify_fill(h.node, src, h.nested, h.bind) else h.fill = 'unknown' end
            -- ONE hop through a file-local `const x = <expr>` declared exactly once (`const to = from ?
            -- Stanza.unsafeXML(...) : ''`); a candidate, like a bind: scope is not checked
            if h.fill == 'unknown' and h.node and h.node:type() == 'identifier' then
                local ins = sc.inits[h.expr]
                if ins and #ins == 1 then
                    local f, c = classify_fill(ins[1], src, {}, nil)
                    if f ~= 'unknown' then h.fill, h.cond, h.fill_via = f, c, 'const' end
                end
            end
        end
    end
    -- the XML
    for _, r in ipairs(recs) do
        local view = build_view(r.body, r.holes)
        local roots, err, stray = read_tree(view, r.body, r.holes, 0, resolve, sc.consts, lc, r.body_s)
        if not roots then
            -- a fragment (several roots, or a hole beside a root) is legal when spliced: retry wrapped
            local w, werr, wstray = read_tree('<_>' .. view .. '</_>', r.body, r.holes, 3, resolve, sc.consts, lc, r.body_s)
            if w and (#w ~= 1 or wstray) then roots, err, stray = w, nil, true
            elseif not w and werr and not werr:find('does not parse', 1, true) then err = werr end
        end
        r.ok = roots ~= nil
        r.why = err
        if roots then
            r.roots = roots
            r.fragment = (stray or #roots ~= 1) or nil
            if #roots == 1 and not stray then r.tree = roots[1] end
        else
            -- never half-read: no hole keeps a site from a failed read
            for _, h in ipairs(r.holes) do h.site = nil; h.element = nil end
        end
        r.body = nil
        for _, h in ipairs(r.holes) do
            h.node = nil; h.vs = nil; h.ve = nil; h.cexpr = nil
            -- a fill is a claim about a SPLICED value: an attribute value or a name is always escaped text
            if h.site == 'attr' or h.site == 'name' then h.fill = nil; h.cond = nil end
        end
    end
    return recs
end

-- ── the per-stanza inventory (fragments spliced in) ─────────────────────────────────────────
local function attr_shown(a, holes)
    if not a then return nil end
    if a.value then return a.value end
    if a.hole then return '${' .. holes[a.hole].expr .. '}' end
    local out = {}
    for _, p in ipairs(a.parts or {}) do out[#out + 1] = type(p) == 'table' and ('${' .. holes[p.hole].expr .. '}') or p end
    return table.concat(out)
end
M.attr_shown = attr_shown

--- Per top-level template (not nested in a hole, not bound into another): { id, line, top, type,
--- ok, why, fragment, elements = { {name, uri, via, path, depth, from = 'self'|'nested'|'bound'} },
--- holes = { {site, fill, attr, element, expr, from}.. } }. A spliced fragment whose own namespace is
--- `none` takes the namespace in scope at its splice site (`via = 'spliced'`), which is what
--- Strophe's textual splice does.
--- THE DIRECTORY PASS, shared by tools/stxcensus.lua and the wire merge (xmppmerge.lua): pass 1 harvests the
--- namespace tables (addNamespace calls, exported consts) from the population, pass 2 reads every file's templates
--- under the resolver built from them. `opts.all` includes test files (their own exports then resolve the tests);
--- by default a test's constants are not the client's. -> { dir, files = { { rel, recs }… }, resolve, ns_files }
local function is_test_path(rel)
    for seg in rel:gmatch('[^/]+') do
        if seg == 'tests' or seg == 'test' or seg == '__tests__' or seg == 'spec' then return true end
    end
    local base = rel:match('[^/]+$')
    return base:match('%.test%.') ~= nil or base:match('%.spec%.') ~= nil
end
M.is_test_path = is_test_path

function M.scan(dir, opts)
    opts = opts or {}
    local rels = {}
    for name, kind in vim.fs.dir(dir, { depth = 50 }) do
        if kind == 'file' and (name:match('%.[mc]?js$') or (name:match('%.ts$') and not name:match('%.d%.ts$'))) then
            if opts.all or not is_test_path(name) then rels[#rels + 1] = name end
        end
    end
    table.sort(rels)
    local function read(p)
        local fd = io.open(p, 'rb'); if not fd then return nil end
        local s = fd:read('a'); fd:close(); return s
    end
    local ns, exported, ns_files = {}, {}, 0
    for _, rel in ipairs(rels) do
        local src = read(dir .. '/' .. rel)
        if src and (src:find('addNamespace', 1, true) or src:find('export const', 1, true)) then
            local h = M.harvest(src)
            if h then
                ns_files = ns_files + 1
                for k, v in pairs(h.ns) do ns[k] = v end
                for k, v in pairs(h.exported) do
                    if exported[k] == nil then exported[k] = v elseif not vim.deep_equal(exported[k], v) then exported[k] = false end
                end
            end
        end
    end
    local resolve = M.resolver({ ns = ns, exported = exported })
    local files = {}
    for _, rel in ipairs(rels) do
        local src = read(dir .. '/' .. rel)
        local recs, why
        if src and src:find('stx`', 1, true) then
            recs, why = M.templates(src, { resolve = resolve })
            if not recs then error(rel .. ': ' .. tostring(why)) end
        end
        files[#files + 1] = { rel = rel, recs = recs or {}, has_src = src ~= nil }
    end
    return { dir = dir, files = files, resolve = resolve, ns_files = ns_files, ns = ns, exported = exported }
end

function M.inventory(recs)
    local by_id = {}
    for _, r in ipairs(recs) do by_id[r.id] = r end
    local out = {}
    for _, r in ipairs(recs) do
        if not r.parent and not r.bound_by then
            local row = { id = r.id, line = r.line, ok = r.ok, why = r.why, fragment = r.fragment, elements = {}, holes = {} }
            if r.tree then
                row.top = r.tree.name
                row.type = attr_shown(r.tree.attr['type'], r.holes)
                row.top_ns = r.tree.ns.uri
            end
            local seen = {}
            local function walk_rec(rec, ctx, from, depth0, element_ns)
                if seen[rec.id] then return end
                seen[rec.id] = true
                if not rec.ok then
                    row.unparsed_fragments = (row.unparsed_fragments or 0) + 1
                    return
                end
                local function walk(el, depth)
                    local ns = el.ns
                    if ns.via == 'none' and ctx then ns = { uri = ctx.uri, via = 'spliced', expr = ctx.expr } end
                    row.elements[#row.elements + 1] = { name = el.name or ('${' .. rec.holes[el.name_hole].expr .. '}'),
                        uri = ns.uri, via = ns.via, expr = ns.expr, path = el.path, depth = depth, from = from }
                    for _, i in ipairs(el.attr_holes) do
                        local h = rec.holes[i]
                        row.holes[#row.holes + 1] = { site = h.site, fill = h.fill, element = h.element, expr = h.expr, from = from }
                    end
                    for _, a in ipairs(el.attrs) do
                        local hs = {}
                        if a.hole then hs[1] = a.hole end
                        for _, p in ipairs(a.parts or {}) do if type(p) == 'table' then hs[#hs + 1] = p.hole end end
                        for _, i in ipairs(hs) do
                            local h = rec.holes[i]
                            row.holes[#row.holes + 1] = { site = 'attr', attr = a.name, element = h.element, expr = h.expr, from = from }
                        end
                    end
                    for _, c in ipairs(el.children) do
                        if c.hole then
                            local h = rec.holes[c.hole]
                            row.holes[#row.holes + 1] = { site = h.site, fill = h.fill, element = h.element, expr = h.expr, from = from, cond = h.cond }
                            local here = { uri = ns.uri, expr = ns.expr }
                            for _, nid in ipairs(h.nested or {}) do walk_rec(by_id[nid], here, 'nested', depth + 1) end
                            if h.bind then walk_rec(by_id[h.bind], here, 'bound', depth + 1) end
                        elseif c.name or c.name_hole then
                            walk(c, depth + 1)
                        end
                    end
                end
                for _, el in ipairs(rec.roots or {}) do
                    if el.hole then
                        -- a hole beside a fragment's roots: spliced where the fragment is
                        local h = rec.holes[el.hole]
                        row.holes[#row.holes + 1] = { site = h.site, fill = h.fill, expr = h.expr, from = from, cond = h.cond }
                        for _, nid in ipairs(h.nested or {}) do walk_rec(by_id[nid], ctx, 'nested', depth0 + 1) end
                        if h.bind then walk_rec(by_id[h.bind], ctx, 'bound', depth0 + 1) end
                    elseif el.name or el.name_hole then
                        walk(el, depth0)
                    end
                end
            end
            walk_rec(r, nil, 'self', 0)
            out[#out + 1] = row
        end
    end
    return out
end

return M
