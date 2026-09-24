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
--
-- ── AMBIGUITY IS KEPT; A TIEBREAKER DECIDES LATER ───────────────────────────────────────
-- USER (2026-09-24): "support multiple attributes on XML so the tiebreaker can come in later, it
-- will be useful for detecting diverging implementation-defined behavior". A DUPLICATE ATTRIBUTE
-- is not refused by the reader: `@k` holds every value in document order as an array (an
-- attribute is otherwise always a string, so the array is unambiguous), and `r.duplicates` lists
-- where. Choosing is a separate, NAMED step — `M.tiebreak(value, policy)` — because implementations
-- choose differently, and the places where two policies give different answers ARE the divergence
-- (`M.divergences`). Policies and who is MEASURED to follow each (2026-09-24, one document with
-- `<x k="first" k="second">`):
--   reject  XML 1.0 (a well-formedness error); Python's expat/ElementTree ("duplicate attribute");
--           Maven's MXParser ("duplicated attributes k and k")
--   first   the HTML5 tokenizer (SPECIFIED: a later duplicate is dropped; not measured here)
--   last    Python html.parser + `dict(attrs)`, the common lenient idiom (html.parser itself KEEPS both)
--   keep    no decision: every value, as the reader returns it
-- A caller that needs XML-conformant data asks for `reject` explicitly (the ElementTree join does).
--
-- ── MORE AMBIGUITY, SAME SHAPE (2026-09-24, "do the other ambiguous cases") ────────────────
--   DTD ENTITIES   a reference to an INTERNAL entity the document declares (`<!ENTITY e "x">`) is
--                  `{ amb = 'entity', literal = '&e;…', expand = 'x…' }` in `r.raw`; an EXTERNAL one
--                  (`SYSTEM "file:…"`) is NEVER fetched, so its expansion is unknown, with the reason;
--                  expansion stops at depth 10 or 100000 bytes (the billion-laughs shape)
--   CONTROL CHARS  a character XML 1.0 forbids (U+0001…) no longer refuses the read: `r.forbidden`
--                  lists each, and the policy decides
-- `r.value` = `decide(r, M.READER)`: duplicates kept, entities literal, control characters kept —
-- what this reader returned before, less the control-character refusal. Measured 2026-09-24:
--                   duplicate attr   internal entity   control char
--   expat (Python)  reject           expand            reject
--   JAXP (JDK 21)   reject           expand            reject
--   REXML (Ruby)    reject           expand            reject
--   Maven MXParser  reject           REJECT            KEEP (its own writer then refuses it)
--   html.parser     keep → last      literal           keep
--   HTML5 (spec)    first            literal           keep (a parse error, the character kept)

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
    local forbidden = {}
    for pos in src:gmatch('()[\1-\8\11\12\14-\31]') do
        forbidden[#forbidden + 1] = { cp = src:byte(pos), byte = pos }
    end
    -- the DTD's INTERNAL general entities (parameter entities and external ones are not expandable
    -- here: an external entity is never fetched)
    local decl, external = {}, {}
    for c in root:iter_children() do
        if c:type() == 'prolog' then
            for d in c:iter_children() do
                if d:type() == 'doctypedecl' then
                    for g in d:iter_children() do
                        if g:type() == 'GEDecl' then
                            local gname, gval, ext
                            for x in g:iter_children() do
                                if x:type() == 'Name' then gname = node_text(x, src)
                                elseif x:type() == 'EntityValue' then gval = node_text(x, src):sub(2, -2)
                                elseif x:type() == 'ExternalID' then ext = true end
                            end
                            if gname and decl[gname] == nil and external[gname] == nil then
                                if ext then external[gname] = true else decl[gname] = gval or '' end
                            end
                        end
                    end
                end
            end
        end
    end
    -- the replacement text of an entity, references inside it expanded; nil and why
    local function expand(name, depth, budget)
        if external[name] then return nil, ('&%s; is an EXTERNAL entity (never fetched)'):format(name) end
        local v = decl[name]
        if v == nil then return nil, ('&%s; is not declared'):format(name) end
        if depth > 10 then return nil, 'entity expansion deeper than 10 (a billion-laughs shape)' end
        local failed
        local out = v:gsub('&#x%x+;', charref):gsub('&#%d+;', charref):gsub('&([%w_.:-]+);', function(n)
            if failed then return '' end
            if PREDEF[n] then return PREDEF[n] end
            local r, why = expand(n, depth + 1, budget)
            if r == nil then failed = why; return '' end
            return r
        end)
        if failed then return nil, failed end
        budget.n = budget.n + #out
        if budget.n > 100000 then return nil, 'entity expansion beyond 100000 bytes (a billion-laughs shape)' end
        return out
    end
    local undefined = 0
    local bad_cdata = false
    local duplicates = {}

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
            local lit = node_text(n, src)
            if name and (decl[name] ~= nil or external[name]) then
                local x, why = expand(name, 1, { n = 0 })
                return { literal = lit, expand = x, why = why, name = name }
            end
            return lit
        end
        if t == 'CharRef' then return charref(node_text(n, src)) or node_text(n, src) end
        return nil
    end
    -- join text parts; any ENTITY part makes the whole an ambiguity node with both readings
    local function join_parts(parts)
        local amb = false
        for _, p in ipairs(parts) do if type(p) == 'table' then amb = true; break end end
        if not amb then return table.concat(parts) end
        local lit, exp, why, names = {}, {}, nil, {}
        for _, p in ipairs(parts) do
            if type(p) == 'table' then
                lit[#lit + 1] = p.literal
                names[#names + 1] = p.name
                if p.expand == nil then why = why or p.why else exp[#exp + 1] = p.expand end
            else lit[#lit + 1] = p; exp[#exp + 1] = p end
        end
        return { amb = 'entity', literal = table.concat(lit), expand = (why == nil) and table.concat(exp) or nil, why = why, names = names }
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
            local parts, last = {}, 1
            local s = raw:gsub('&#x%x+;', charref):gsub('&#%d+;', charref)
            for a, n, b in s:gmatch('()&([%w_.:-]+);()') do
                parts[#parts + 1] = s:sub(last, a - 1)
                if PREDEF[n] then parts[#parts + 1] = PREDEF[n]
                else
                    undefined = undefined + 1
                    if decl[n] ~= nil or external[n] then
                        local x, why = expand(n, 1, { n = 0 })
                        parts[#parts + 1] = { literal = '&' .. n .. ';', expand = x, why = why, name = n }
                    else parts[#parts + 1] = '&' .. n .. ';' end
                end
                last = b
            end
            parts[#parts + 1] = s:sub(last)
            local j = join_parts(parts)
            if type(j) == 'table' then
                j.literal = j.literal:gsub('[\t\r\n]', ' ')
                if j.expand then j.expand = j.expand:gsub('[\t\r\n]', ' ') end
                return j
            end
            out = { j }
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
            -- a DUPLICATE attribute (after namespace resolution): XML calls it not well-formed, and
            -- implementations DISAGREE on what to do with it — so every value is kept, in order
            if o[k] ~= nil then
                if type(o[k]) == 'string' then o[k] = { a = { o[k] } } end
                table.insert(o[k].a, a[2])
                duplicates[#duplicates + 1] = { element = qname or '?', attr = k, count = #o[k].a }
            else
                keys[#keys + 1] = k
                o[k] = a[2]
            end
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
        local text = join_parts(texts)
        if #keys == 0 and not any_child then return name, text end
        local plain = type(text) == 'table' and text.literal or text
        if plain:find('%S') then
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
            local r = { root = name, raw = value, undefined_entities = undefined, duplicates = duplicates, forbidden = forbidden }
            r.value = M.decide(r, M.READER)
            return r
        end
    end
    return nil, 'no root element'
end

-- ── tiebreakers ─────────────────────────────────────────────────────────────────────────
M.POLICIES = { 'reject', 'first', 'last', 'keep' }

--- Pick from the values of one ambiguous name under a policy: the value, or nil and why.
function M.pick(list, policy)
    if policy == 'first' then return list[1] end
    if policy == 'last' then return list[#list] end
    if policy == 'keep' then return { a = list } end
    if policy == 'reject' then return nil, ('%d values for one name'):format(#list) end
    error('unknown tiebreak policy ' .. tostring(policy))
end

--- The value with every duplicate attribute decided by `policy`; nil and why under `reject`.
function M.tiebreak(v, policy, path)
    path = path or '$'
    if type(v) ~= 'table' then return v end
    if v.a then
        local a = {}
        for i, x in ipairs(v.a) do
            local r, why = M.tiebreak(x, policy, path .. '[' .. i .. ']')
            if r == nil and why then return nil, why end
            a[i] = r
        end
        return { a = a }
    end
    local o, keys = {}, {}
    for _, k in ipairs(v.keys) do
        local x = v.o[k]
        if k:sub(1, 1) == '@' and type(x) == 'table' and x.a then
            local r, why = M.pick(x.a, policy)
            if r == nil then return nil, ('a duplicate attribute %s at %s: %s'):format(k, path, why) end
            x = r
        else
            local r, why = M.tiebreak(x, policy, path .. '.' .. k)
            if r == nil and why then return nil, why end
            x = r
        end
        o[k] = x
        keys[#keys + 1] = k
    end
    return { o = o, keys = keys }
end

-- ── implementations: how each decides every kind of ambiguity (measured, see the header) ─────
M.READER = { ['duplicate-attribute'] = 'keep', entity = 'literal', ['control-char'] = 'keep' }
M.IMPLEMENTATIONS = {
    expat = { ['duplicate-attribute'] = 'reject', entity = 'expand', ['control-char'] = 'reject' },
    jaxp = { ['duplicate-attribute'] = 'reject', entity = 'expand', ['control-char'] = 'reject' },
    rexml = { ['duplicate-attribute'] = 'reject', entity = 'expand', ['control-char'] = 'reject' },
    maven = { ['duplicate-attribute'] = 'reject', entity = 'reject', ['control-char'] = 'keep' },
    ['html.parser+dict'] = { ['duplicate-attribute'] = 'last', entity = 'literal', ['control-char'] = 'keep' },
    html5 = { ['duplicate-attribute'] = 'first', entity = 'literal', ['control-char'] = 'keep', spec = true },
}

--- A read document DECIDED under an implementation profile: its value, or nil and why.
function M.decide(r, profile)
    profile = profile or M.READER
    if #(r.forbidden or {}) > 0 and profile['control-char'] == 'reject' then
        local f = r.forbidden[1]
        return nil, ('a character XML 1.0 forbids (U+%04X) at byte %d'):format(f.cp, f.byte)
    end
    local function walk(v, path)
        if type(v) ~= 'table' then return v end
        if v.amb == 'entity' then
            local pol = profile.entity
            if pol == 'literal' then return v.literal end
            if pol == 'reject' then return nil, ('could not resolve entity &%s; (this implementation reads no DTD)'):format(v.names[1]) end
            if v.expand == nil then return nil, v.why end
            return v.expand
        end
        if v.a then
            local a = {}
            for i, x in ipairs(v.a) do local d, why = walk(x, path .. '[' .. i .. ']'); if d == nil then return nil, why end; a[i] = d end
            return { a = a }
        end
        local o, keys = {}, {}
        for _, k in ipairs(v.keys) do
            local x = v.o[k]
            if k:sub(1, 1) == '@' and type(x) == 'table' and x.a then
                local picked, why = M.pick(x.a, profile['duplicate-attribute'])
                if picked == nil then return nil, ('a duplicate attribute %s at %s: %s'):format(k, path, why) end
                if type(picked) == 'table' and picked.a then
                    local a = {}
                    for i, y in ipairs(picked.a) do local d, dwhy = walk(y, path); if d == nil then return nil, dwhy end; a[i] = d end
                    x = { a = a }
                else
                    local d, dwhy = walk(picked, path); if d == nil then return nil, dwhy end; x = d
                end
            else
                local d, why = walk(x, path .. '.' .. k)
                if d == nil then return nil, why end
                x = d
            end
            o[k] = x; keys[#keys + 1] = k
        end
        return { o = o, keys = keys }
    end
    return walk(r.raw or r.value, '$')
end

--- ★ WHERE IMPLEMENTATIONS WOULD DISAGREE (a read document and implementation NAMES): every
--- duplicate attribute, entity reference and forbidden character whose outcome differs. Rows:
--- { path, kind, outcomes = {name -> outcome} }.
function M.implementation_divergences(r, names)
    if not names then names = {}; for n in pairs(M.IMPLEMENTATIONS) do names[#names + 1] = n end; table.sort(names) end
    local out = {}
    local function row(path, kind, detail, outcome_of)
        local outcomes, seen, distinct = {}, {}, 0
        for _, n in ipairs(names) do
            local o = outcome_of(M.IMPLEMENTATIONS[n])
            outcomes[n] = o
            if not seen[o] then seen[o] = true; distinct = distinct + 1 end
        end
        if distinct > 1 then out[#out + 1] = { path = path, kind = kind, detail = detail, outcomes = outcomes } end
    end
    if #(r.forbidden or {}) > 0 then
        row('$', 'control-char', ('U+%04X at byte %d'):format(r.forbidden[1].cp, r.forbidden[1].byte), function(p)
            return p['control-char'] == 'reject' and 'rejected' or 'kept'
        end)
    end
    local function walk(v, path)
        if type(v) ~= 'table' then return end
        if v.amb == 'entity' then
            row(path, 'entity', v.literal, function(p)
                if p.entity == 'literal' then return 'literal ' .. v.literal end
                if p.entity == 'reject' then return 'rejected' end
                return v.expand and ('expanded ' .. v.expand) or ('rejected: ' .. v.why)
            end)
            return
        end
        if v.a then for i, x in ipairs(v.a) do walk(x, path .. '[' .. i .. ']') end return end
        for _, k in ipairs(v.keys) do
            local x = v.o[k]
            if k:sub(1, 1) == '@' and type(x) == 'table' and x.a then
                row(path, 'duplicate-attribute', k, function(p)
                    local picked = M.pick(x.a, p['duplicate-attribute'])
                    if picked == nil then return 'rejected' end
                    return type(picked) == 'table' and 'kept all' or ('the value ' .. tostring(picked))
                end)
            else walk(x, path .. '.' .. k) end
        end
    end
    walk(r.raw or r.value, '$')
    return out
end

--- ★ WHERE IMPLEMENTATIONS WOULD DISAGREE: every duplicate attribute whose outcome differs between
--- the given policies (default: all but `keep`). One row per site: path, name, and per policy the
--- value or `rejected`.
function M.divergences(v, policies)
    policies = policies or { 'reject', 'first', 'last' }
    local out = {}
    local function walk(x, path)
        if type(x) ~= 'table' then return end
        if x.a then for i, y in ipairs(x.a) do walk(y, path .. '[' .. i .. ']') end return end
        for _, k in ipairs(x.keys) do
            local y = x.o[k]
            if k:sub(1, 1) == '@' and type(y) == 'table' and y.a then
                local outcomes, distinct, seen = {}, 0, {}
                for _, p in ipairs(policies) do
                    local r = M.pick(y.a, p)
                    local shown = r == nil and 'rejected' or (type(r) == 'table' and 'keep' or r)
                    outcomes[p] = shown
                    if not seen[shown] then seen[shown] = true; distinct = distinct + 1 end
                end
                if distinct > 1 then out[#out + 1] = { path = path, attr = k, values = y.a, outcomes = outcomes } end
            else
                walk(y, path .. '.' .. k)
            end
        end
    end
    walk(v, '$')
    return out
end

return M
