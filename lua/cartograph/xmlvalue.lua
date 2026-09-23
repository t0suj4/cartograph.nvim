-- xmlvalue.lua — AN XML DOCUMENT AS DATA, in the same keyed form yamlvalue gives (CART-1042).
--
-- USER (2026-09-23): "Do the XML, I think we'll have to treat it like any other extensible data
-- format." So XML gets what YAML got: ONE generic reader into the kv form the algebra's keyed
-- operations read (`kv_generalize`, `kv_classify`, `drift.anchor`), and DIALECTS on top (a
-- `pom.xml` is a dialect, as a helmfile is a YAML dialect) — never a reader per dialect.
--
-- ── THE CONVENTION, and it is a CHOICE (XML is not map-shaped) ────────────────────────
--   element with no attributes and no child elements   -> its text, exactly ("" when empty)
--   otherwise an object:
--     attribute a                                       -> key "@a"
--     child elements                                    -> key = the child's name; a name that
--                                                          occurs MORE THAN ONCE is an ARRAY in
--                                                          document order; keys keep first order
--     text of a MIXED element (non-blank)               -> key "#text" (the text pieces joined)
--   whitespace-only text between elements               -> dropped (indentation, not data)
--   comments, processing instructions, the prolog       -> dropped
-- ⚠ WHAT THE CONVENTION LOSES, SAID: the INTERLEAVING of differently-named siblings (a, b, a keeps
-- a's two values in an array and b separately), and the placement of text inside mixed content.
-- Data-shaped XML (a POM, a config) does not use either; document-shaped XML (XHTML, DocBook)
-- does, and belongs to the positional reader (`algebraread` over the tree), not to this one.
--
-- ── NAMESPACES ARE XML'S EXTENSION MECHANISM, SO THEY ARE RESOLVED, NOT STRIPPED ────────
-- A prefix means whatever the nearest in-scope `xmlns:p` declares (a scope hierarchy, like
-- every other one in this repo). A name in the document's HOME namespace (the root element's)
-- is written bare; a name in any other namespace is `{uri}local`, so two extensions that both
-- say `<c>` never collide. Unprefixed ATTRIBUTES are in no namespace (the XML rule). `xmlns`
-- declarations are consumed, not reported as attributes.
-- ⚠ Text and attributes are DECODED: the five predefined entities and character references;
-- CDATA is literal; attribute whitespace (tab, CR, LF) is normalised to spaces; line ends to LF.
-- An entity the document does not predefine (a DTD entity) is kept as written and counted.

local M = {}

M.XMLNS = 'http://www.w3.org/2000/xmlns/'
M.XML = 'http://www.w3.org/XML/1998/namespace'

local PREDEF = { amp = '&', lt = '<', gt = '>', quot = '"', apos = "'" }

local function node_text(n, src) return vim.treesitter.get_node_text(n, src) end

-- ⚠ LuaJIT HAS NO `utf8` LIBRARY (it is Lua 5.3's): encode code points by hand
local function utf8char(cp)
    if not cp or cp < 0 or cp > 0x10FFFF then return nil end
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local function charref(s)
    local hex = s:match('^&#x(%x+);$')
    if hex then return utf8char(tonumber(hex, 16)) end
    local dec = s:match('^&#(%d+);$')
    if dec then return utf8char(tonumber(dec)) end
    return nil
end

--- Read one document into { root, value, undefined_entities } or nil and why.
function M.read(src)
    local okp, parser = pcall(vim.treesitter.get_string_parser, src, 'xml')
    if not okp then return nil, 'no xml tree-sitter parser' end
    local tree = parser:parse()[1]
    if not tree then return nil, 'xml parse failed' end
    local root = tree:root()
    if root:has_error() then return nil, 'the xml does not parse (tree-sitter reports an error node)' end
    -- ⚠ WELL-FORMEDNESS THE GRAMMAR DOES NOT ENFORCE (measured against ElementTree): XML 1.0 forbids
    -- C0 control characters other than tab/LF/CR anywhere (a hive test plan carries a raw U+0001)
    local bad = src:find('[\1-\8\11\12\14-\31]')
    if bad then
        return nil, ('a character XML 1.0 forbids (U+%04X) at byte %d'):format(src:byte(bad), bad)
    end
    local undefined = 0
    local bad_cdata = false

    -- the text of a content piece (CharData / references / CDATA), decoded
    local function piece(n)
        local t = n:type()
        if t == 'CharData' then return (node_text(n, src):gsub('\r\n', '\n'):gsub('\r', '\n')) end
        if t == 'CDSect' then
            for c in n:iter_children() do
                if c:type() == 'CData' then
                    local d = node_text(c, src)
                    -- ⚠ A CDATA ENDS AT THE FIRST `]]>`. tree-sitter-xml mis-tokenises `…]]]>` and runs
                    -- past it (TSGAP-0009: two hadoop jdiff files lost their following elements into
                    -- the text). A CData containing `]]>` is therefore a WRONG TREE: refuse it.
                    if d:find(']]>', 1, true) then bad_cdata = true end
                    return d
                end
            end
            return ''
        end
        if t == 'EntityRef' then
            local name
            for c in n:iter_children() do if c:type() == 'Name' then name = node_text(c, src) end end
            if name and PREDEF[name] then return PREDEF[name] end
            undefined = undefined + 1
            return node_text(n, src)
        end
        if t == 'CharRef' then return charref(node_text(n, src)) or node_text(n, src) end
        return nil
    end

    local function attr_value(av)
        local out = {}
        for c in av:iter_children() do
            local p = piece(c)
            if p then out[#out + 1] = p end
        end
        if #out == 0 then
            -- a plain AttValue: the text between the quotes
            local raw = node_text(av, src)
            out[1] = raw:sub(2, -2)
        else
            -- the quotes are anonymous children; the pieces are the decoded parts, but plain text
            -- between references is not a named child — rebuild from the raw text instead
            local raw = node_text(av, src):sub(2, -2)
            local s = raw:gsub('&#x%x+;', charref):gsub('&#%d+;', charref):gsub('&(%a+);', function (n)
                if PREDEF[n] then return PREDEF[n] end
                undefined = undefined + 1
                return '&' .. n .. ';'
            end)
            out = { s }
        end
        return (table.concat(out):gsub('[\t\r\n]', ' '))
    end

    local home -- the root element's namespace
    local function element(n, scope)
        local tag, attrs, content = n, {}, nil
        for c in n:iter_children() do
            local t = c:type()
            if t == 'STag' or t == 'EmptyElemTag' then tag = c
            elseif t == 'content' then content = c end
        end
        local qname
        local decl, raw_attrs = {}, {}
        for c in tag:iter_children() do
            if c:type() == 'Name' and not qname then qname = node_text(c, src)
            elseif c:type() == 'Attribute' then
                local an, av
                for x in c:iter_children() do
                    if x:type() == 'Name' then an = node_text(x, src) elseif x:type() == 'AttValue' then av = attr_value(x) end
                end
                if an then
                    if an == 'xmlns' then decl[''] = av or ''
                    elseif an:sub(1, 6) == 'xmlns:' then decl[an:sub(7)] = av or ''
                    else raw_attrs[#raw_attrs + 1] = { an, av or '' } end
                end
            end
        end
        -- the in-scope namespaces: this element's declarations over its parent's
        local sc = setmetatable(decl, { __index = scope })
        local function resolve(q, is_attr)
            local prefix, localname = q:match('^([^:]+):(.+)$')
            local uri
            if prefix then
                if prefix == 'xml' then uri = M.XML else uri = sc[prefix] end
                if uri == nil then return q end -- an undeclared prefix: keep the name as written
            else
                localname = q
                uri = (not is_attr) and sc[''] or nil
            end
            if uri == nil or uri == '' or (not is_attr and uri == home) then return localname end
            return '{' .. uri .. '}' .. localname
        end
        if home == nil then
            -- ★ HOME is the ROOT ELEMENT'S OWN namespace — its prefix's, or the default — not
            -- the default namespace alone (a prefixed root `<j:ejb-jar xmlns:j=…>` is in j's)
            local p = (qname or ''):match('^([^:]+):')
            home = (p and sc[p]) or (not p and sc['']) or ''
        end
        local name = resolve(qname or '?', false)
        local o, keys, texts, any_child = {}, {}, {}, false
        for _, a in ipairs(raw_attrs) do
            local k = '@' .. resolve(a[1], true)
            -- a DUPLICATE attribute (after namespace resolution) makes the document not well-formed
            if o[k] ~= nil then error({ xml_refusal = ('a duplicate attribute %s on <%s>'):format(k, qname or '?') }, 0) end
            keys[#keys + 1] = k
            o[k] = a[2]
        end
        local counts = {}
        if content then
            for c in content:iter_children() do
                local t = c:type()
                if t == 'element' then
                    any_child = true
                    local cn, cv = element(c, sc)
                    if o[cn] == nil then keys[#keys + 1] = cn; o[cn] = cv; counts[cn] = 1
                    else
                        if counts[cn] == 1 then o[cn] = { a = { o[cn] } } end
                        counts[cn] = counts[cn] + 1
                        table.insert(o[cn].a, cv)
                    end
                else
                    local p = piece(c)
                    if p then texts[#texts + 1] = p end
                end
            end
        end
        local text = table.concat(texts)
        if #keys == 0 and not any_child then return name, text end
        if text:find('%S') then
            if o['#text'] == nil then keys[#keys + 1] = '#text' end
            o['#text'] = text
        end
        return name, { o = o, keys = keys }
    end

    for c in root:iter_children() do
        if c:type() == 'element' then
            local okr, name, value = pcall(element, c, {})
            if not okr then
                if type(name) == 'table' and name.xml_refusal then return nil, name.xml_refusal end
                error(name, 0)
            end
            if bad_cdata then
                return nil, 'the tree mis-tokenises a CDATA section (its text contains `]]>`) — the tree is wrong, so the document is refused'
            end
            return { root = name, value = value, undefined_entities = undefined }
        end
    end
    return nil, 'no root element'
end

return M
