-- xmppspec — xmpp_codec.spec read as DESCENDABLE DATA with an OFFERED INTERPRETATION: the table that lifts Erlang
-- record patterns into XMPP protocol terms, and the XMPP triple's PAYLOAD leg (CART-1096, under CART-1087 / CART-0842).
--
-- @langs erlang
-- The spec is Erlang terms (xmpp's specs/xmpp_codec.spec, ~634 `-xml(Name, #elem{…})` forms), so nothing here
-- generalises across grammars: the descent is the erlang tree-sitter parse, the interpretation is fxml_gen's
-- -xml / #elem / #attr / #cdata / #ref vocabulary.
--
-- ★★★ WHY. An ejabberd handler reads its request in a CLAUSE HEAD,
--     process_local_iq(#iq{type = get, sub_els = [#disco_info{node = Node}]} = IQ)
-- and erlrecords (CART-1095) says which RECORD FIELDS that reads. This file says what those fields ARE on the wire:
-- `disco_info` is decoded from <query xmlns="http://jabber.org/protocol/disco#info">, its field `node` from the
-- attribute @node. Joined, the head READS <iq type="get"><query xmlns=".../disco#info" node="?Node"/></iq>: the Erlang
-- code lifted into protocol terms, the "interpretation layer" the Erlang parser was missing.
--
-- ── THREE LAYERS (cartograph-descendable-data) ────────────────────────────────────────────────────────────────────
--   1. DESCENT    M.term(node, src) (erllit.term): any Erlang term literal -> a plain value (atom / bin / int / list / tuple /
--                 record / expr-text). Nothing -xml-specific; a non-literal is kept as its EXPRESSION TEXT.
--   2. INTERPRET  M.parse_source / M.read: each -xml term read under fxml_gen's record vocabulary, DEFAULTS APPLIED
--                 at interpretation time (fxml_gen.hrl: #attr{required=false, default='$unset'}, #cdata{label='$cdata',
--                 required=false}, #elem{xmlns=<<"">>, cdata=#cdata{}, ignore_els=false}, #ref{min=0, max=infinity}).
--                 M.label_sources / M.field answer "where does this record field come from on the wire".
--   3. LIFT       M.lift(facts, spec): a clause head's read set (CART-0957's fact shape) -> protocol terms.
--
-- ── THE RULES ARE THE GENERATOR'S, NOT GUESSES (read from fxml_gen.beam's abstract code, p1_xml-1.1.49) ─────────────
--   label of an #attr / #ref with no `label`   prepare_label: '$' .. lowercase(name)  ('xml:lang' needs an explicit one)
--   is a result atom a LABEL                    is_label: '$_els' and '$_' are; any other '$_…' / '$-…' is NOT; any
--                                               other '$…' is; everything else is a CONSTANT
--   which source a label comes from            get_spec_by_label: '$_els' -> the element's unknown children
--                                               (sub_els), '$_' -> nothing on the wire: a record field THIS element
--                                               does not carry (iq/message/presence `meta`, ps_error's `feature`
--                                               in the 23 pubsub error variants),
--                                               else the FIRST of [cdata | attrs ++ refs] whose label matches; when
--                                               that first hit is a #ref, EVERY #ref sharing the label (a list field
--                                               collecting several child element kinds)
--   record field name of a label               label_to_record_field: '$_els' -> sub_els, '$x' -> x (only for the
--                                               GENERATED records; iq/message/presence/ps_error/… are declared by
--                                               hand in the spec, and xmpp_codec.hrl is what the compiler sees)
--
-- ── THE SHAPE ─────────────────────────────────────────────────────────────────────────────────────────────────────
--   spec  = { path, entries = { [name] = entry }, order = { name, … }, refused = { { line, name?, why }, … },
--             by_record = { [record] = { name, … } },   -- every -xml whose result is that record, SPEC ORDER
--             records   = { [record] = decl },          -- the spec's own -record forms (erlrecords decl shape)
--             decls     = nil | { [record] = decl },    -- attached by M.attach_records (xmpp_codec.hrl's scope)
--             forms = N }                               -- -xml forms seen (= #order + #refused)
--   entry = { name = 'disco_info', line, last,
--             element = 'query',
--             xmlns   = 'http://…' | { 'jabber:client', … },
--             module  = 'xep0030', ignore_els = false,
--             result  = { kind = 'record', record = 'disco_info', fields = { '$node', …, { const = 'closed-node' } } }
--                     | { kind = 'tuple', fields = { '$node', '$xdata' } }  -- an ANONYMOUS tuple {Node, XData}
--                     | { kind = 'label', label = '$cdata' }      -- the element decodes to ONE value (a scalar child)
--                     | { kind = 'const', const = 'true' },       -- the element's PRESENCE decodes to a constant
--             attrs = { { name, label, declared_label = bool, required, default, always_encode, dec, enc, line } },
--             cdata = nil | { label, required, default, dec, enc, line },  -- nil = the #cdata{} DEFAULT applies
--             refs  = { { name, label, declared_label = bool, min, max, default, line } },
--             extra = nil | { key, … } }                   -- #elem keys fxml_gen does not define (a finding)
--   default / dec / enc are the VERBATIM TERM TEXT (`<<"">>`, `{dec_int, [0, infinity]}`); max is a number or
--   'infinity'.
--
-- ⚠ APPROXIMATIONS, stated: dec/enc functions are not run, so an attribute's DECODED value type (jid, integer, enum)
--   is text, and a head that descends INTO a decoded value (`from = #jid{luser = U}`) is a named frontier;
--   xdata_codec's .xdata forms (muc_roomconfig etc.) are a second generator and are not read here.

local tsutil = require 'cartograph.spec.tsutil' -- (tsutil.inext: indexed child iteration, CART-1453)
local M = {}

local function read(path)
    local fd = io.open(path, 'r')
    if not fd then return nil end
    local s = fd:read('a'); fd:close()
    return s
end

-- ══ 1. DESCENT: Erlang term literal -> plain value ═════════════════════════════════════════════════════════════════
-- lives in erllit (generic: rebar.config readers use it too); M.term keeps this module's surface

local erllit = require 'cartograph.erllit'
local unquote_atom = erllit.unquote_atom
M.term = erllit.term

-- ══ 2. INTERPRETATION: fxml_gen's vocabulary ════════════════════════════════════════════════════════════════════════

--- fxml_gen is_label/1, verbatim.
function M.is_label(a)
    if type(a) ~= 'string' then return false end
    if a == '$_els' or a == '$_' then return true end
    if a:match('^%$[_%-]') then return false end
    return a:match('^%$.') ~= nil
end

--- fxml_gen prepare_label/2: an explicit label wins, else '$' .. lowercase(name).
function M.prepare_label(label, name)
    if label then return label end
    return '$' .. tostring(name):lower()
end

--- fxml_gen label_to_record_field/1 (the GENERATED records only).
function M.label_field(label)
    if label == '$_els' then return 'sub_els' end
    return (label:gsub('^%$', ''))
end

local ELEM_KEYS = { name = true, module = true, xmlns = true, cdata = true, ignore_els = true, result = true,
    attrs = true, refs = true }

local function flag(t)
    if not t then return false end
    return t.t == 'atom' and t.v == 'true'
end

local function strv(t)
    if not t then return nil end
    if t.t == 'bin' or t.t == 'atom' then return t.v end
    return nil
end

local function read_attr(r)
    local nm = strv(r.fields.name)
    if not nm then return nil, '#attr with no literal name' end
    local lab = r.fields.label and r.fields.label.t == 'atom' and r.fields.label.v or nil
    return {
        name = nm, label = M.prepare_label(lab, nm), declared_label = lab ~= nil,
        required = flag(r.fields.required),
        default = r.fields.default and r.fields.default.text or nil,
        always_encode = flag(r.fields.always_encode),
        dec = r.fields.dec and r.fields.dec.text or nil,
        enc = r.fields.enc and r.fields.enc.text or nil,
        line = r.line,
    }
end

local function read_ref(r)
    local nm = strv(r.fields.name)
    if not nm then return nil, '#ref with no literal name' end
    local lab = r.fields.label and r.fields.label.t == 'atom' and r.fields.label.v or nil
    local function num(t, dflt)
        if not t then return dflt end
        if t.t == 'int' then return t.v end
        if t.t == 'atom' then return t.v end
        return t.text
    end
    return {
        name = nm, label = M.prepare_label(lab, nm), declared_label = lab ~= nil,
        min = num(r.fields.min, 0), max = num(r.fields.max, 'infinity'),
        default = r.fields.default and r.fields.default.text or nil,
        line = r.line,
    }
end

local function read_cdata(r)
    local lab = r.fields.label and r.fields.label.t == 'atom' and r.fields.label.v or nil
    return {
        label = lab or '$cdata', declared_label = lab ~= nil,
        required = flag(r.fields.required),
        default = r.fields.default and r.fields.default.text or nil,
        dec = r.fields.dec and r.fields.dec.text or nil,
        enc = r.fields.enc and r.fields.enc.text or nil,
        line = r.line,
    }
end

local function read_result(t)
    if t.t == 'tuple' then
        local tag = t.items[1]
        if not (tag and tag.t == 'atom') then return nil, 'result tuple has no atom tag' end
        -- `{'$node', '$xdata'}` (8 in xmpp_codec.spec): the first element is a LABEL, so this is an ANONYMOUS tuple
        -- {Node, XData}, not a record; the parent field holds it and a head reaches its slots by a { tuple } step
        local anon = M.is_label(tag.v)
        local res = anon and { kind = 'tuple', fields = {} } or { kind = 'record', record = tag.v, fields = {} }
        for i = anon and 1 or 2, #t.items do
            local it = t.items[i]
            local k = anon and i or i - 1
            if it.t ~= 'atom' then return nil, 'result tuple slot ' .. k .. ' is not an atom: ' .. it.text end
            res.fields[k] = M.is_label(it.v) and it.v or { const = it.v }
        end
        return res
    elseif t.t == 'atom' then
        if M.is_label(t.v) then return { kind = 'label', label = t.v } end
        return { kind = 'const', const = t.v }
    end
    return nil, 'result is neither a tuple nor an atom: ' .. t.text
end

--- Read one `#elem{…}` term (already descended) under the name `name`. -> entry | nil, why
function M.elem(name, t)
    if t.t ~= 'recterm' or t.name ~= 'elem' then return nil, 'second argument is not an #elem{} record' end
    local f = t.fields
    local e = { name = name, element = strv(f.name), module = strv(f.module), ignore_els = flag(f.ignore_els),
        attrs = {}, refs = {} }
    if not e.element then return nil, '#elem has no literal name' end
    if not f.result then return nil, '#elem has no result' end
    local res, why = read_result(f.result)
    if not res then return nil, why end
    e.result = res
    if not f.xmlns then e.xmlns = ''
    elseif f.xmlns.t == 'bin' then e.xmlns = f.xmlns.v
    elseif f.xmlns.t == 'list' then
        e.xmlns = {}
        for _, x in ipairs(f.xmlns.items) do
            if x.t ~= 'bin' then return nil, 'xmlns list holds a non-literal: ' .. x.text end
            e.xmlns[#e.xmlns + 1] = x.v
        end
    else return nil, 'xmlns is not a literal: ' .. f.xmlns.text end
    if f.attrs then
        if f.attrs.t ~= 'list' then return nil, 'attrs is not a list literal' end
        for _, a in ipairs(f.attrs.items) do
            if a.t ~= 'recterm' or a.name ~= 'attr' then return nil, 'attrs holds a non-#attr: ' .. a.text end
            local ra, w = read_attr(a)
            if not ra then return nil, w end
            e.attrs[#e.attrs + 1] = ra
        end
    end
    if f.refs then
        if f.refs.t ~= 'list' then return nil, 'refs is not a list literal' end
        for _, r in ipairs(f.refs.items) do
            if r.t ~= 'recterm' or r.name ~= 'ref' then return nil, 'refs holds a non-#ref: ' .. r.text end
            local rr, w = read_ref(r)
            if not rr then return nil, w end
            e.refs[#e.refs + 1] = rr
        end
    end
    if f.cdata then
        if f.cdata.t ~= 'recterm' or f.cdata.name ~= 'cdata' then return nil, 'cdata is not a #cdata{}' end
        e.cdata = read_cdata(f.cdata)
    end
    for _, k in ipairs(t.keys) do
        if not ELEM_KEYS[k] then e.extra = e.extra or {}; e.extra[#e.extra + 1] = k end
    end
    return e
end

--- Parse the spec text. Pure: (src, path) -> spec. Every `-xml` form is either an entry or a refusal with a reason.
function M.parse_source(src, path)
    local spec = { path = path, entries = {}, order = {}, refused = {}, by_record = {}, records = {}, forms = 0 }
    local view = require('cartograph.parseview').view(src, 'erlang')
    local okp, parser = pcall(vim.treesitter.get_string_parser, view, 'erlang')
    local tree = okp and parser and parser:parse()[1]
    if not tree then spec.unparsed = true; return spec end
    local root = tree:root()
    for _, form in tsutil.inext, root, -1 do
        if form:type() == 'wild_attribute' then
            local an = form:field('name')[1]
            local ai = an and an:field('name')[1]
            local aname = ai and unquote_atom(vim.treesitter.get_node_text(ai, src))
            if aname == 'xml' then
                spec.forms = spec.forms + 1
                local line = form:start() + 1
                local function refuse(why, nm) spec.refused[#spec.refused + 1] = { line = line, name = nm, why = why } end
                -- `-xml(Name, #elem{…})` is not an Erlang attribute the grammar knows (a wild attribute takes ONE
                -- term), so the parse is ALWAYS paren_expr( ERROR(atom ',') record_expr ): measured 634/634. The
                -- shape is required exactly; anything else is refused by name rather than guessed at.
                local v = form:field('value')[1]
                local nm, body, extra = nil, nil, 0
                if v and v:type() == 'paren_expr' then
                    for _, ch in tsutil.inext, v, -1 do
                        if ch:named() then
                            if ch:type() == 'ERROR' and not nm then
                                local a = ch:named_child(0)
                                if a and a:type() == 'atom' and ch:named_child_count() == 1 then
                                    nm = unquote_atom(vim.treesitter.get_node_text(a, src))
                                else extra = extra + 1 end
                            elseif not body and ch:type() ~= 'ERROR' then body = ch
                            else extra = extra + 1 end
                        end
                    end
                end
                if not v or v:type() ~= 'paren_expr' then refuse('value is not a parenthesised pair')
                elseif not nm then refuse('no `Name,` before the element (a one-argument -xml)')
                elseif not body or extra > 0 then refuse('not exactly (Name, Elem)', nm)
                elseif body:has_error() then refuse('parse error inside the element', nm)
                elseif spec.entries[nm] then refuse('duplicate -xml name (first at line ' .. spec.entries[nm].line .. ')', nm)
                else
                    local e, why = M.elem(nm, M.term(body, src))
                    if not e then refuse(why, nm)
                    else
                        e.line, e.last = line, form:end_() + 1
                        spec.entries[nm] = e
                        spec.order[#spec.order + 1] = nm
                        if e.result.kind == 'record' then
                            local r = e.result.record
                            spec.by_record[r] = spec.by_record[r] or {}
                            table.insert(spec.by_record[r], nm)
                        end
                    end
                end
            end
        end
    end
    -- the spec's own -record forms (iq, message, presence, ps_error, …): erlrecords reads them, not a second reader
    for _, d in ipairs(require('cartograph.erlrecords').parse_source(src, path).records) do
        spec.records[d.name] = spec.records[d.name] or d
    end
    return spec
end

function M.read(path)
    local src = read(path)
    if not src then return nil, 'unreadable: ' .. tostring(path) end
    return M.parse_source(src, path)
end

--- Attach the record declarations the COMPILER sees (erlrecords scope of xmpp_codec.hrl / xmpp.hrl):
--- { [name] = decl }. They then win over the spec's own -record forms and the generator's label rule.
function M.attach_records(spec, decls)
    spec.decls = decls
    spec._fields = nil
    return spec
end

--- The ordered field names of a record, and where they came from:
---   'hrl'     an attached declaration (what the compiler sees)
---   'spec'    a -record form in the spec itself (hand-declared: iq, message, presence, ps_error, …)
---   'derived' the generator's label_to_record_field over the FIRST producing -xml's result (a generated record)
--- -> names, source | nil, why
function M.record_fields(spec, record)
    spec._fields = spec._fields or {}
    local c = spec._fields[record]
    if c then return c.names, c.source end
    local names, source
    local d = spec.decls and spec.decls[record]
    if d then source = 'hrl' else d = spec.records[record]; source = d and 'spec' end
    if d then
        names = {}
        for i, f in ipairs(d.fields) do names[i] = f.name end
    else
        local first = spec.by_record[record] and spec.entries[spec.by_record[record][1]]
        if not first then return nil, 'no -xml produces #' .. record .. ' and no declaration is attached' end
        names, source = {}, 'derived'
        for i, s in ipairs(first.result.fields) do
            if type(s) == 'table' then return nil, ('#%s slot %d is the constant %s in its first producer: a hand-'
                .. 'declared record, and no declaration is attached'):format(record, i, s.const) end
            names[i] = M.label_field(s)
        end
    end
    spec._fields[record] = { names = names, source = source }
    return names, source
end

--- Where a label's value comes from in one entry, by the generator's own rule (get_spec_by_label). -> { src, … }
---   { kind = 'els' }                      the element's unknown children (sub_els), decoded by whatever -xml matches
---   { kind = 'ignored' }                  '$_': not on the wire
---   { kind = 'cdata', label, required, default, dec, enc, declared = bool }
---   { kind = 'attr', name, label, required, default, dec, enc }
---   { kind = 'ref', name, label, min, max, default }        (one per #ref sharing the label: a list of kinds)
---   { kind = 'unknown' }                  the label is in the result but nothing declares it
function M.label_sources(entry, label)
    if label == '$_els' then return { { kind = 'els' } } end
    if label == '$_' then return { { kind = 'ignored' } } end
    local cd = entry.cdata or { label = '$cdata', required = false }
    if cd.label == label then
        return { { kind = 'cdata', label = label, required = cd.required, default = cd.default, dec = cd.dec,
            enc = cd.enc, declared = entry.cdata ~= nil } }
    end
    for _, a in ipairs(entry.attrs) do
        if a.label == label then
            return { { kind = 'attr', name = a.name, label = label, required = a.required, default = a.default,
                dec = a.dec, enc = a.enc } }
        end
    end
    local out = {}
    for _, r in ipairs(entry.refs) do
        if r.label == label then
            out[#out + 1] = { kind = 'ref', name = r.name, label = label, min = r.min, max = r.max, default = r.default }
        end
    end
    if #out > 0 then return out end
    return { { kind = 'unknown', label = label } }
end

--- THE INTERPRETATION of one record field: every -xml that produces `record`, and for each, where `field` comes from.
--- Several -xml may produce one record (xmlns variants, constant-discriminated variants like ps_error): ALL are
--- returned, in spec order; this never picks one. -> rows | nil, why
---   row = { xml, element, xmlns, index, label = '$node' | nil, const = 'closed-node' | nil, sources = { src, … } }
function M.field(spec, record, field)
    local xs = spec.by_record[record]
    if not xs then return nil, 'unknown_record: no -xml produces #' .. record end
    local names, why = M.record_fields(spec, record)
    if not names then return nil, why end
    local idx
    for i, n in ipairs(names) do if n == field then idx = i break end end
    if not idx then return nil, ('unknown_field: #%s has no field %s'):format(record, field) end
    local rows = {}
    for _, x in ipairs(xs) do
        local e = spec.entries[x]
        local slot = e.result.fields[idx]
        local row = { xml = x, element = e.element, xmlns = e.xmlns, index = idx }
        if slot == nil then row.sources = { { kind = 'unknown', why = 'result tuple has no slot ' .. idx } }
        elseif type(slot) == 'table' then row.const = slot.const; row.sources = {}
        else row.label = slot; row.sources = M.label_sources(e, slot) end
        rows[#rows + 1] = row
    end
    return rows
end

local function xmlns_text(x)
    if type(x) == 'table' then return table.concat(x, '|') end
    return x
end

--- One source as protocol prose: `@node on <query xmlns="…">`, `text of <name>`, `<identity> children (0..inf)`.
function M.describe(spec, entry, src)
    local host = ('<%s xmlns="%s">'):format(entry.element, xmlns_text(entry.xmlns))
    if src.kind == 'attr' then return ('@%s on %s'):format(src.name, host) end
    if src.kind == 'cdata' then return 'text of ' .. host end
    if src.kind == 'els' then return 'any child element of ' .. host end
    if src.kind == 'ignored' then return 'not on the wire' end
    if src.kind == 'ref' then
        local t = spec.entries[src.name]
        local tn = t and ('<%s xmlns="%s">'):format(t.element, xmlns_text(t.xmlns)) or ('?' .. src.name)
        return ('%s children of %s (%s..%s)'):format(tn, host, tostring(src.min), tostring(src.max))
    end
    return 'unknown: ' .. tostring(src.label)
end

--- Cross-check every record-result -xml against the record's declared fields: ARITY (result slots vs field count)
--- and NAMES (the generator's label_to_record_field vs the declared name at the same position). A hand-declared
--- record legitimately differs in names; that is reported with `hand = true`, not hidden. A '$_' slot names no field
--- (it is a field the element does not carry) and is COUNTED as `ignored`, never compared.
--- -> { arity = { row… }, names = { row… }, checked = N, ignored = N, undeclared = { record… } }
function M.check_fields(spec)
    local out = { arity = {}, names = {}, checked = 0, undeclared = {}, ignored = 0 }
    local seen = {}
    for _, x in ipairs(spec.order) do
        local e = spec.entries[x]
        if e.result.kind == 'record' then
            local r = e.result.record
            local d = spec.decls and spec.decls[r] or spec.records[r]
            if not d then
                if not seen[r] then seen[r] = true; out.undeclared[#out.undeclared + 1] = r end
            else
                out.checked = out.checked + 1
                local hand = spec.records[r] ~= nil
                if #e.result.fields ~= #d.fields then
                    out.arity[#out.arity + 1] = { xml = x, record = r, result = #e.result.fields,
                        declared = #d.fields, hand = hand }
                end
                for i, s in ipairs(e.result.fields) do
                    local dn = d.fields[i] and d.fields[i].name
                    if s == '$_' then out.ignored = out.ignored + 1
                    elseif type(s) == 'string' and dn and M.label_field(s) ~= dn then
                        out.names[#out.names + 1] = { xml = x, record = r, index = i, label = s, declared = dn,
                            hand = hand }
                    end
                end
            end
        end
    end
    return out
end

-- ══ 3. THE LIFT: a clause head's read set -> protocol terms ═════════════════════════════════════════════════════════
--
-- facts (CART-0957's eo.heads[k].facts): { name = 'N', path = steps, arg = i } a binding, or
-- { value = 'get', ty = 'atom', path = steps, arg = i } a constant. steps, outermost first:
--   { rec = 'iq', field = 'sub_els' } · { tuple = i, arity = n } · { elem = i } · { head = true } · { tail = true }
--   · { map = 'k' }
--
-- THE RESULT:
--   { args = { [i] = V }, frontier = { { arg, path = 'text', reason, detail, fact }, … } }
--   V (a VALUE slot) = { binds = { 'IQ', … }, consts = { { value, ty }, … },
--                        card = 'one' | 'many',               -- 'many': a list field (a ref with max ≠ 1, sub_els)
--                        record = 'iq' | nil,                  -- set by a { rec } step
--                        alts = { E, … },                      -- one per -xml that can produce this value
--                        items = { { pos = '1' | 'head' | 'tail', value = V }, … },  -- card 'many' only
--                        carried = true when the binding was also placed on a scalar child's label,
--                        arg, at = steps }                     -- where this value sits (frontier rows cite it)
--   E (an ELEMENT, one -xml) = { xml, element, xmlns, record,
--                        excluded = nil | 'why',              -- a constant in the head contradicts this variant,
--                                                             --   or a later { rec } / { tuple } step ruled it out
--                        attrs = { { name, field, label, binds, consts }, … },
--                        cdata = nil | { field, label, binds, consts },
--                        kids  = { { field, label, via = 'ref' | 'els', value = V }, … },
--                        fixed = { { field, const, binds, consts }, … },   -- constant result slots the head touched
--                        offwire = { { field, binds, consts }, … } }       -- '$_' fields (meta)
-- Frontier reasons (never dropped silently): unknown_record, unknown_field, unknown_label, unknown_ref,
--   record_mismatch, arity, scalar_descent (into a decoded attr/cdata value), not_on_wire, step_kind (a step this
--   value cannot take: a tuple/map step on an element, a list step on a single value), no_variant.

local function steptext(s)
    if s.rec then return ('#%s.%s'):format(s.rec, tostring(s.field)) end
    if s.elem then return '[' .. s.elem .. ']' end
    if s.head then return '[H|_]' end
    if s.tail then return '[_|T]' end
    if s.tuple then return ('{%d/%d}'):format(s.tuple, s.arity or 0) end
    if s.map then return '#{' .. tostring(s.map) .. '}' end
    return '?'
end

function M.pathtext(steps)
    local t = {}
    for i, s in ipairs(steps or {}) do t[i] = steptext(s) end
    return #t > 0 and table.concat(t, ' ') or '(whole argument)'
end

local function add(slot, fact)
    if fact.name then slot.binds[#slot.binds + 1] = fact.name
    else slot.consts[#slot.consts + 1] = { value = fact.value, ty = fact.ty } end
end

local function new_value(card, cands, arg, at)
    return { binds = {}, consts = {}, card = card or 'one', cands = cands, alts = {}, items = {}, _alt = {}, _item = {},
        arg = arg, at = at }
end

local function prefix(steps, n)
    local t = {}
    for k = 1, n do t[k] = steps[k] end
    return t
end

local function keyed(list, index, key, make)
    local hit = index[key]
    if hit then return hit end
    hit = make()
    index[key] = hit
    list[#list + 1] = hit
    return hit
end

function M.lift(facts, spec)
    local st = { frontier = {} }
    local args = {}
    local cur -- the fact being placed, for frontier rows

    local function front(reason, detail, where)
        local row = { arg = cur.arg, path = M.pathtext(cur.path), reason = reason, detail = detail, fact = cur }
        st.frontier[#st.frontier + 1] = row
        if where then where.frontier = where.frontier or {}; table.insert(where.frontier, row) end
    end

    local place_value, place_label, place_slot

    local function new_elem(x)
        local e = spec.entries[x]
        return { xml = x, element = e.element, xmlns = e.xmlns,
            record = e.result.kind == 'record' and e.result.record or nil,
            attrs = {}, kids = {}, fixed = {}, offwire = {}, _attr = {}, _kid = {}, _fixed = {}, _off = {} }
    end

    local function ensure_alt(V, x)
        return keyed(V.alts, V._alt, x, function () return new_elem(x) end)
    end

    -- ★ ORDER-INDEPENDENCE: a whole-value binding that arrived FIRST made alts for every scalar candidate (terminal);
    -- a later { rec } / { tuple } step narrows the candidates, and the alts it did not keep must stop being live, or
    -- the result would depend on the order the facts came in
    local function exclude_others(V, keep, why)
        local k = {}
        for _, x in ipairs(keep) do k[x] = true end
        V.carried = nil -- no scalar child stays live, so the whole-value binding is drawn on the value again
        for _, E in ipairs(V.alts) do
            if not k[E.xml] then E.excluded = E.excluded or (why .. '; ' .. E.xml .. ' does not decode to that') end
        end
    end

    -- a { rec = R } step on V: narrow V's candidates to the -xml that produce #R
    local function narrow(V, rec)
        if V.record then
            if V.record ~= rec then
                front('record_mismatch', ('one value matched as #%s and #%s'):format(V.record, rec), V)
                return false
            end
            return true
        end
        local keep = {}
        if V.cands then
            for _, x in ipairs(V.cands) do
                local e = spec.entries[x]
                if e and e.result.kind == 'record' and e.result.record == rec then keep[#keep + 1] = x end
            end
            if #keep == 0 then
                front('record_mismatch', ('#%s is not what this position decodes to (it holds %s)'):format(rec,
                    table.concat(V.cands, ' | ')), V)
                return false
            end
        else
            for _, x in ipairs(spec.by_record[rec] or {}) do keep[#keep + 1] = x end
            if #keep == 0 then
                front('unknown_record', ('no -xml produces #%s'):format(rec), V)
                return false
            end
        end
        V.record = rec
        V.cands = keep
        exclude_others(V, keep, ('the head matches #%s here'):format(rec))
        for _, x in ipairs(keep) do ensure_alt(V, x) end
        return true
    end

    local function place_field(E, field, steps, i)
        local entry = spec.entries[E.xml]
        local names, why = M.record_fields(spec, E.record)
        if not names then front('unknown_field', why, E) return end
        local idx
        for k, n in ipairs(names) do if n == field then idx = k break end end
        if not idx then front('unknown_field', ('#%s has no field %s'):format(E.record, tostring(field)), E) return end
        local slot = entry.result.fields[idx]
        if slot == nil then
            front('arity', ('%s: result tuple has no slot %d for #%s.%s'):format(E.xml, idx, E.record, field), E)
            return
        end
        place_slot(E, slot, field, steps, i)
    end

    -- one result slot (a label or a constant) of E, reached as `field` (a record field name, or '{i}' for a slot of
    -- an anonymous tuple result)
    function place_slot(E, slot, field, steps, i)
        if type(slot) == 'table' then
            local f = keyed(E.fixed, E._fixed, field, function ()
                return { field = field, const = slot.const, binds = {}, consts = {} } end)
            if i <= #steps then
                front('scalar_descent', ('%s.%s is the constant %s'):format(E.xml, field, slot.const), E)
                return
            end
            add(f, cur)
            if cur.value ~= nil and tostring(cur.value) ~= slot.const then
                E.excluded = E.excluded or ('%s decodes %s as the constant %s; the head requires %s'):format(
                    E.xml, E.record and ('#' .. E.record .. '.' .. field) or field, slot.const, tostring(cur.value))
            end
            return
        end
        place_label(E, slot, field, steps, i)
    end

    function place_label(E, label, field, steps, i)
        local entry = spec.entries[E.xml]
        local srcs = M.label_sources(entry, label)
        local k = srcs[1].kind
        if k == 'ignored' then
            local s = keyed(E.offwire, E._off, field, function () return { field = field, binds = {}, consts = {} } end)
            add(s, cur)
            front('not_on_wire', ('%s.%s (%s) is not encoded on the wire'):format(E.xml, tostring(field), label), E)
        elseif k == 'attr' or k == 'cdata' then
            local s
            if k == 'attr' then
                s = keyed(E.attrs, E._attr, srcs[1].name, function ()
                    return { name = srcs[1].name, field = field, label = label, dec = srcs[1].dec, binds = {},
                        consts = {} } end)
            else
                E.cdata = E.cdata or { field = field, label = label, dec = srcs[1].dec, binds = {}, consts = {} }
                s = E.cdata
            end
            if i <= #steps then
                front('scalar_descent', ('into the decoded value of %s (dec = %s)'):format(
                    k == 'attr' and ('@' .. srcs[1].name) or 'the text', tostring(srcs[1].dec or 'none')), s)
                return
            end
            add(s, cur)
        elseif k == 'els' or k == 'ref' then
            local cands, card = nil, 'many'
            if k == 'ref' then
                cands, card = {}, 'one'
                for _, r in ipairs(srcs) do
                    if not spec.entries[r.name] then
                        front('unknown_ref', ('%s refs %s, which is no -xml'):format(E.xml, r.name), E)
                    else cands[#cands + 1] = r.name end
                    if r.max ~= 1 then card = 'many' end
                end
                if #cands == 0 then return end
            end
            local kid = keyed(E.kids, E._kid, label, function ()
                return { field = field, label = label, via = k,
                    value = new_value(card, cands, cur.arg or 1, prefix(steps, i - 1)) } end)
            place_value(kid.value, steps, i)
        else
            front('unknown_label', ('%s: %s is in the result but no attr/cdata/ref declares it'):format(E.xml, label), E)
        end
    end

    -- the path ENDS at V: bind/constrain the whole value; a single child whose -xml decodes to ONE label (a scalar
    -- child like <name>text</name>) carries the binding onto that label, so it lands where the text actually is
    local function terminal(V)
        add(V, cur)
        if V.card ~= 'one' or not V.cands or V.record then return end
        for _, x in ipairs(V.cands) do
            local e = spec.entries[x]
            if e.result.kind == 'label' then
                V.carried = true
                place_label(ensure_alt(V, x), e.result.label, nil, {}, 1)
            elseif e.result.kind == 'const' then
                local E = ensure_alt(V, x)
                if cur.value ~= nil and tostring(cur.value) ~= e.result.const then
                    E.excluded = E.excluded or ('%s decodes to the constant %s; the head requires %s'):format(x,
                        e.result.const, tostring(cur.value))
                end
            end
        end
    end

    function place_value(V, steps, i)
        if i > #steps then return terminal(V) end
        local s = steps[i]
        if V.card == 'many' then
            if s.elem or s.head or s.tail then
                local pos = s.elem and tostring(s.elem) or (s.head and 'head' or 'tail')
                local item = keyed(V.items, V._item, pos, function ()
                    return { pos = pos, value = new_value(s.tail and 'many' or 'one', V.cands, cur.arg or 1,
                        prefix(steps, i)) } end)
                return place_value(item.value, steps, i + 1)
            end
            return front('step_kind', steptext(s) .. ' on a list-valued position', V)
        end
        if s.rec then
            if not narrow(V, s.rec) then return end
            if s.field == nil then return end
            for _, E in ipairs(V.alts) do
                if E.record == s.rec then place_field(E, s.field, steps, i + 1) end
            end
            return
        end
        if s.tuple and V.cands and not V.record then
            -- an ANONYMOUS tuple result ({'$node', '$xdata'}): keep the candidates of that arity, place slot i
            local keep = {}
            for _, x in ipairs(V.cands) do
                local e = spec.entries[x]
                if e.result.kind == 'tuple' and (not s.arity or #e.result.fields == s.arity) then keep[#keep + 1] = x end
            end
            if #keep == 0 then
                return front('record_mismatch', ('no %d-tuple is what this position decodes to (it holds %s)'):format(
                    s.arity or 0, table.concat(V.cands, ' | ')), V)
            end
            V.cands = keep
            exclude_others(V, keep, ('the head matches a %d-tuple here'):format(s.arity or 0))
            for _, x in ipairs(keep) do
                local E = ensure_alt(V, x)
                local slot = spec.entries[x].result.fields[s.tuple]
                if slot == nil then front('arity', ('%s has no tuple slot %d'):format(x, s.tuple), E)
                else place_slot(E, slot, '{' .. s.tuple .. '}', steps, i + 1) end
            end
            return
        end
        return front('step_kind', steptext(s) .. (V.cands and ' on an element value' or ' on a value that is not '
            .. 'known to be a list'), V)
    end

    for _, f in ipairs(facts) do
        cur = f
        local a = f.arg or 1
        args[a] = args[a] or new_value('one', nil, a, {})
        place_value(args[a], f.path or {}, 1)
    end

    -- a value whose every variant a constant excluded decodes from NOTHING: say so
    local function sweep(V)
        local live = 0
        for _, E in ipairs(V.alts) do
            if not E.excluded then live = live + 1 end
            for _, kd in ipairs(E.kids) do sweep(kd.value) end
        end
        for _, it in ipairs(V.items) do sweep(it.value) end
        if #V.alts > 0 and live == 0 and V.record then
            cur = { arg = V.arg, path = V.at }
            front('no_variant', ('every -xml producing #%s is excluded by a constant in the head'):format(V.record), V)
        end
    end
    for _, V in pairs(args) do sweep(V) end
    return { args = args, frontier = st.frontier }
end

-- ── rendering: the structured value as protocol text (for people; consumers read the table) ─────────────────────

local function constraint(slot)
    local t = {}
    for _, b in ipairs(slot.binds) do t[#t + 1] = '?' .. b end
    for _, c in ipairs(slot.consts) do t[#t + 1] = tostring(c.value) end
    return table.concat(t, '&')
end

local render_value

local function render_elem(E)
    local out = { '<', E.element, (' xmlns="%s"'):format(xmlns_text(E.xmlns)) }
    for _, a in ipairs(E.attrs) do out[#out + 1] = (' %s="%s"'):format(a.name, constraint(a)) end
    local body = {}
    if E.cdata then body[#body + 1] = constraint(E.cdata) end
    for _, kd in ipairs(E.kids) do body[#body + 1] = render_value(kd.value) end
    if #body == 0 then out[#out + 1] = '/>'
    else out[#out + 1] = '>' .. table.concat(body) .. '</' .. E.element .. '>' end
    return table.concat(out)
end

function render_value(V)
    -- a binding carried onto a scalar child's label is drawn THERE (<name>?N</name>), not twice
    local pre = (#V.binds > 0 or #V.consts > 0) and not V.carried and (constraint(V):gsub('%?', '') .. '=') or ''
    if V.card == 'many' then
        local t = {}
        for _, it in ipairs(V.items) do t[#t + 1] = render_value(it.value) end
        return pre == '' and table.concat(t) or (pre .. '[' .. table.concat(t) .. ']')
    end
    local live = {}
    for _, E in ipairs(V.alts) do if not E.excluded then live[#live + 1] = render_elem(E) end end
    if #live == 0 then return #V.binds > 0 and ('?' .. table.concat(V.binds, '&')) or constraint(V) end
    local body = #live == 1 and live[1] or ('(' .. table.concat(live, ' | ') .. ')')
    return pre .. body
end

--- The lifted value of one argument as protocol text:
---   IQ=<iq xmlns="jabber:client|…" type="get"><query xmlns="http://jabber.org/protocol/disco#info" node="?Node"/></iq>
function M.render(V) return render_value(V) end

-- ── THE ENCODE DIRECTION (CART-1138): a decoded term -> the #xmlel term fxml's generated encoder builds for it ──────
local function A() return assert(require('cartograph.algebra').load()) end
local unpack = table.unpack or unpack

-- ★ AN ABSENT ATTRIBUTE IS NOT "ABSENT" ON THE SERVER: the generated decoder fills it in. fxml_gen's rule, read off
-- the generated source (xmpp/src/*.erl, `decode_<xml>_attr_<name>(__TopXMLNS, undefined) -> V`): an explicit
-- default wins; else a REQUIRED one is a decode error (the request is invalid: 'absent', which only a variable
-- accepts); else one with a converting decoder -> `undefined`; else `<<>>`. The same for cdata; a single ref ->
-- `undefined`. ACCEPTED BY AN ORACLE: tools/xmppmerge.lua --check-absent compares this rule with every generated
-- clause (408 on xmpp 02893ce). THE ENCODER's omission rule is its inverse: a value equal to it is not written.
function M.absent_value(src, is_cdata)
    local a = A()
    if src.default ~= nil and src.default ~= '$unset' then
        local d = tostring(src.default)
        -- a list default (caps' `exts = []`) is the empty list, not the text "[]"
        if vim.trim(d) == '[]' then return a.node('list') end
        d = d:match('^<<"(.*)">>$') or (d == '<<>>' and '') or d:gsub("^'(.*)'$", '%1')
        return a.lit(d)
    end
    if src.required == true or src.required == 'true' then return a.node('absent') end
    -- ★ TOUCH-UP (CART-1138, the grammar's round trip): an absent CDATA is <<>> whatever decodes it. The generated
    -- `decode_<x>_cdata(__TopXMLNS, <<>>) -> <<>>` precedes the converting clause (sasl_challenge's base64), unlike an
    -- attribute's `(…, undefined) -> undefined`. The attribute oracle (408 clauses) never saw a cdata.
    if is_cdata or src.kind == 'cdata' then return a.lit('') end
    -- a CHECKER keeps the binary (xmpp_lang validates, it does not convert): absent stays <<>>. Found by the oracle
    -- (tools/xmppmerge.lua --check-absent): the first cut said `undefined` and the generated code disagreed on 15
    -- xml:lang / hreflang attributes out of 408.
    if src.dec and src.dec ~= '' and not src.dec:find('xmpp_lang', 1, true) then return a.lit('undefined') end
    return a.lit('')
end

--- xmpp_codec:choose_top_xmlns: an element with ONE namespace uses it; one with several keeps its parent's when that is
--- among them, else takes the first
local function choose_top(E, top)
    if type(E.xmlns) == 'table' then
        for _, x in ipairs(E.xmlns) do if x == top then return top end end
        return E.xmlns[1] or top
    end
    if E.xmlns == nil or E.xmlns == '' then return top end
    return E.xmlns
end
M.choose_top = choose_top

--- THE ENCODER, read off the same -xml forms the decoder reads, by fxml_gen's rules (derived from its generated code,
--- xmpp/src/*.erl, and accepted against it by tools/xmppencode.lua):
---   element   {xmlel, Name, Attrs, Children}; an xmlns attribute when the element's namespace differs from the parent's
---   attrs     each #attr, in REVERSE spec order (the generator prepends), then the xmlns one: a REQUIRED or
---             `always_encode` attr always, another only when its value is not the absent value (the decoder's
---             inverse); `enc` applied
---   children  cdata first ({xmlcdata, Text}, omitted when absent), then each #ref's elements in spec order (a list
---             field: every item, a single one: omitted when undefined; refs sharing a label: the ref whose element
---             decodes to the item's record), then sub_els (each by its own record's -xml)
--- A hole stays a hole where it sits (an attribute of unknown value, a child of unknown shape).
--- opts = { enc = fn(enc_text, value, entry) -> term (the encoded binary, a lit or a hole) — required when an attr
---          declares `enc` (tools/xmppencode.lua evaluates the library's own function) }
--- -> xmlel term | nil, why
function M.encode(spec, term, top, opts)
    opts = opts or {}
    local a = A()
    -- every name and value on the wire is a binary; the element and text tags are atoms (fxml's #xmlel{} / {xmlcdata, _})
    local function lit(v)
        local l = a.lit(v)
        l.lk = (v == 'xmlel' or v == 'xmlcdata') and 'atom' or 'bin'
        return l
    end
    -- equal to the absent value: a literal by its text, a list default ([]) structurally
    local function same(x, y)
        if not (x and y and x.k == y.k) then return false end
        if x.k == 'lit' then return tostring(x.v) == tostring(y.v) end
        return x.k ~= 'hole' and a.eq(x, y)
    end
    local enc_entry
    -- the -xml a term encodes by: a record's first entry (spec order); a tuple / label / const value needs its ref's
    local function by_term(t)
        local r = t.k and t.k:match('^rec:(.+)$')
        local names = r and spec.by_record[r]
        return names and spec.entries[names[1]] or nil
    end
    local function encode_value(src, v, E)
        if v.k == 'hole' then return v end
        if src.enc and src.enc ~= '' then
            if not opts.enc then return a.hole('enc:' .. src.enc) end
            return opts.enc(src.enc, v, E)
        end
        if v.k == 'lit' then return lit(tostring(v.v)) end
        return a.hole('unencodable ' .. tostring(v.k))
    end
    function enc_entry(E, v, parent_top)
        local R = E.result or {}
        -- the value a label names, read off v by the result's shape
        local function value_of(label)
            if R.kind == 'record' or R.kind == 'tuple' then
                for i, f in ipairs(R.fields or {}) do if f == label then return v.kids and v.kids[i] end end
                return nil
            end
            if R.kind == 'label' and R.label == label then return v end
            return nil
        end
        -- the element's namespace: a declared #attr named xmlns is a record field (choose_top_xmlns(Xmlns, NSList,
        -- Top) in the generated code); the namespace rule below writes it, so it is not an ordinary attribute
        local nsattr
        for _, at in ipairs(E.attrs or {}) do if at.name == 'xmlns' then nsattr = at end end
        local newtop = choose_top(E, parent_top)
        if nsattr then
            local nv = value_of(nsattr.label)
            if nv and nv.k == 'lit' and tostring(nv.v) ~= '' then newtop = tostring(nv.v) end
        end
        -- attributes: the xmlns one first in the accumulator, then each #attr prepended (so reverse spec order)
        local acc = {}
        if newtop ~= parent_top then acc[1] = a.node('tuple', lit('xmlns'), lit(newtop)) end
        for _, at in ipairs(E.attrs or {}) do
            local val = at ~= nsattr and value_of(at.label) or nil
            if val ~= nil then
                -- `always_encode = true` (roster_item's subscription): written even at its default
                local required = at.required == true or at.required == 'true'
                local always = at.always_encode == true or at.always_encode == 'true'
                local skip = not required and not always and val.k ~= 'hole' and same(val, M.absent_value(at))
                if not skip then table.insert(acc, 1, a.node('tuple', lit(at.name), encode_value(at, val, E))) end
            end
        end
        -- children: cdata, the refs in spec order (by label group), then sub_els
        local kids = {}
        local cd = E.cdata or { label = '$cdata' }
        local cv = value_of(cd.label)
        if cv ~= nil and cv.k == 'hole' then kids[#kids + 1] = a.node('tuple', lit('xmlcdata'), cv)
        elseif cv ~= nil and not same(cv, M.absent_value(cd, true)) then
            kids[#kids + 1] = a.node('tuple', lit('xmlcdata'), encode_value(cd, cv, E))
        end
        local seen_label = {}
        for _, rf in ipairs(E.refs or {}) do
            if not seen_label[rf.label] then
                seen_label[rf.label] = true
                local rv = value_of(rf.label)
                local group = {}
                for _, r2 in ipairs(E.refs) do if r2.label == rf.label then group[#group + 1] = r2 end end
                local function ref_for(item)
                    if #group == 1 then return spec.entries[group[1].name] end
                    local rec = item.k and item.k:match('^rec:(.+)$')
                    for _, r2 in ipairs(group) do
                        local RE = spec.entries[r2.name]
                        if RE and RE.result and RE.result.record == rec then return RE end
                    end
                    return nil
                end
                local items = {}
                if rv == nil then
                elseif rf.max == 1 or rf.max == '1' then
                    -- a single child is left out at its absent value: the ref's declared default (bind's resource,
                    -- `default = <<"">>`), else undefined
                    local absent = (rf.default ~= nil and rf.default ~= '$unset') and M.absent_value({ default = rf.default })
                        or a.lit('undefined')
                    -- a REQUIRED child (min = 1: xdata's option value, http upload's get/put) is always written
                    local required = tonumber(rf.min) == 1
                    if required or not same(rv, absent) then items[1] = rv end
                elseif rv.k == 'list' then
                    for _, x in ipairs(rv.kids or {}) do items[#items + 1] = x end
                else items[1] = rv end
                for _, item in ipairs(items) do
                    if item.k == 'hole' then kids[#kids + 1] = item
                    else
                        local RE = ref_for(item)
                        kids[#kids + 1] = RE and enc_entry(RE, item, newtop) or a.hole('no -xml for ' .. tostring(item.k))
                    end
                end
            end
        end
        local sv = value_of('$_els')
        if sv and sv.k == 'list' then
            for _, x in ipairs(sv.kids or {}) do
                if x.k == 'hole' then kids[#kids + 1] = x
                else
                    local SE = by_term(x)
                    kids[#kids + 1] = SE and enc_entry(SE, x, newtop) or a.hole('no -xml for ' .. tostring(x.k))
                end
            end
        elseif sv and sv.k == 'hole' then kids[#kids + 1] = sv end
        return a.node('tuple', lit('xmlel'), lit(E.element), a.node('list', unpack(acc, 1, #acc)),
            a.node('list', unpack(kids, 1, #kids)))
    end
    if opts.entry then return enc_entry(opts.entry, term, top or '') end
    local E = by_term(term)
    if not E then return nil, 'no -xml produces ' .. tostring(term.k) end
    return enc_entry(E, term, top or '')
end

--- SAMPLE TERMS for an entry, the oracles' input (tools/xmppencode.lua, tools/xmppgrammar.lua): MINIMAL (every field
--- at the value the decoder gives an absent one, required attributes at a sample) or MAXIMAL (every attribute and cdata
--- at a sample, every list ref with one sampled child, `depth` levels). A sample follows the field's decoder: an
--- enumeration's first value, an integer 1, a boolean true, a jid u@s/r, a plain binary "x". Given the library's program
--- `P` (erlterms), a decoder none of those names is RUN instead: the first candidate text it decodes completely gives
--- the sample (xep0220's nameprep, xep0215's dec_host). -> term, unsampled count
function M.sample_term(spec, E, maximal, depth, P)
    local a = A()
    local function lit(v, lk) local l = a.lit(v); l.lk = lk; return l end
    local JID = a.node('rec:jid', lit('u', 'bin'), lit('s', 'bin'), lit('r', 'bin'), lit('u', 'bin'), lit('s', 'bin'), lit('r', 'bin'))
    local unsampled = 0
    local function sample(src, E2)
        local dec = src.dec or ''
        if dec == '' or dec:find('xmpp_lang', 1, true) then return lit('x', 'bin') end
        local enums = dec:match('dec_enum,%s*%[%[([^%]]*)%]')
        if enums then
            local first = vim.trim((enums:match('^([^,]+)') or '')):gsub("^'(.*)'$", '%1')
            if first ~= '' then return lit(first, 'atom') end
        end
        if dec:find('dec_int', 1, true) then return lit('1', 'int') end
        if dec:find('dec_bool', 1, true) then return lit('true', 'atom') end
        if dec:find('{jid,', 1, true) then return JID end
        -- ★ DERIVED, not listed: the decoder itself says which text it accepts (`{f, []}` or `{m, f, []}`)
        local m, f = dec:match('^{%s*([%w_]+)%s*,%s*([%w_]+)%s*,%s*%[%s*%]%s*}$')
        if not m then f = dec:match('^{%s*([%w_]+)%s*,%s*%[%s*%]%s*}$'); m = E2 and E2.module end
        if P and m and f then
            local ET = require 'cartograph.erlterms'
            for _, text in ipairs { 'x', '1', 'u@s/r' } do
                local t = ET.call(P, m, f, { lit(text, 'bin') }, ET.session())
                if ET.status(t) == 'complete' then return t end
            end
        end
        return nil
    end
    local function term_for(E2, max, d)
        local R = E2.result
        local kids = {}
        for fi, f in ipairs(R.fields or {}) do
            if type(f) == 'table' and f.const ~= nil then kids[fi] = lit((tostring(f.const):gsub("^'(.*)'$", '%1')), 'atom')
            elseif f == '$_els' then kids[fi] = a.node('list')
            elseif f == '$_' then
                -- a field not on the wire keeps the record's DECLARED default (iq/message/presence meta = #{})
                local decl = (spec.decls or {})[R.record] or (spec.records or {})[R.record]
                local fld = decl and decl.fields and decl.fields[fi]
                local d = fld and fld.default
                kids[fi] = d and require('cartograph.erlterms').default_term(d) or lit('undefined', 'atom')
            else
                local srcs = M.label_sources(E2, f)
                local s1 = srcs[1]
                if s1.kind == 'attr' or s1.kind == 'cdata' then
                    local required = s1.required == true or s1.required == 'true'
                    -- an xmlns attribute that is a field names the element's namespace: "" chooses it; free text would
                    -- move the element to a namespace no -xml decodes
                    local v = (required or max) and (s1.kind == 'attr' and s1.name == 'xmlns' and lit('', 'bin') or sample(s1, E2)) or nil
                    if (required or max) and not v then unsampled = unsampled + 1 end
                    kids[fi] = v or M.absent_value(s1)
                    if kids[fi].k == 'absent' then kids[fi] = lit('undefined', 'atom') end
                elseif s1.kind == 'ref' then
                    local many = false
                    for _, r in ipairs(srcs) do if r.max ~= 1 then many = true end end
                    local items = {}
                    if max and d > 0 and many then
                        local RE = spec.entries[s1.name]
                        local c = RE and RE.result and RE.result.kind == 'record' and term_for(RE, true, d - 1)
                        if c then items[1] = c end
                    end
                    local absent = (s1.default ~= nil and s1.default ~= '$unset') and M.absent_value({ default = s1.default })
                        or lit('undefined', 'atom')
                    -- a REQUIRED single child (min = 1: carbons' forwarded, a mix join) has no absent value: sample one
                    local single_required = not many and tonumber(s1.min) == 1
                    if single_required then
                        local RE = spec.entries[s1.name]
                        local c = RE and RE.result and RE.result.kind == 'record' and d >= 0 and term_for(RE, max, d - 1)
                        if c then absent = c else unsampled = unsampled + 1 end
                    end
                    kids[fi] = many and a.node('list', unpack(items)) or absent
                else kids[fi] = lit('undefined', 'atom') end
            end
        end
        return a.node('rec:' .. R.record, unpack(kids, 1, #(R.fields or {})))
    end
    local t = term_for(E, maximal, depth or 1)
    return t, unsampled
end

--- one -xml entry's encoding of a value (a record, a tuple, or the scalar of a label/const result)
function M.encode_entry(spec, E, value, top, opts)
    local o = {}
    for k, v in pairs(opts or {}) do o[k] = v end
    o.entry = E
    return M.encode(spec, value, top, o)
end

return M
