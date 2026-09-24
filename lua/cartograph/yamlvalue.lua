-- yamlvalue.lua — A YAML DOCUMENT AS DATA, in the keyed form the algebra's kv operations
-- read (CART-1042).
--
-- ★ WHY A THIRD YAML READER IS NOT A THIRD COPY. `k8s.lua` reads a manifest TEXTUALLY for a
-- handful of flat keys, and `ansible.lua` walks the tree for task lists; neither yields the
-- WHOLE document as a value. Helm values, helmfiles and hiera are data whose meaning is the
-- full tree — every key, every nesting — so they need the tree as a value: objects
-- `{ o = {k = v}, keys = {ordered} }`, arrays `{ a = {...} }`, scalars as STRINGS. That is
-- exactly `kv_generalize` / `kv_classify` / `drift.anchor`'s input.
--
-- ★★ SCALARS STAY STRINGS, ON PURPOSE (PyYAML's BaseLoader contract). A key tree must not turn
-- `no:` into false or `1.10` into 1.1, and a comparison between two files must compare what
-- was WRITTEN. The acceptance oracle is PyYAML's CBaseLoader over a real corpus, per document.
-- ⚠ SAME CONTRACT, SAME LIMITS: a merge key `<<` is an ordinary key (BaseLoader does not merge);
-- aliases ARE resolved (the composer does that); an empty value is the empty string; a
-- duplicate key keeps its first position and its last value.
--
-- ── AMBIGUITY IS KEPT; IMPLEMENTATIONS ARE PROFILES (CART-1053) ─────────────────────────
-- USER (2026-09-24): "do the other ambiguous cases" (after XML's duplicate attributes). What YAML
-- implementations disagree on is recorded in `doc.raw`, never decided by the reader:
--   { amb = 'scalar', text }            every PLAIN scalar: its type is the RESOLVER's decision
--   { pairs = { {k, plain, v}, … } }    a MAPPING, as ordered pairs: duplicates and merge keys (a plain
--                                       `<<`) are left in place — which keys are the SAME key is each
--                                       implementation's own equality (the profile's `identity`)
--   { amb = 'tag', tag, value }         an EXPLICIT tag (`!Sub`, `!!str`) on any node: PyYAML and
--                                       ruamel REJECT an unknown one, Psych and YAML::XS IGNORE it,
--                                       yq KEEPS it; a standard `!!str`/`!!int`/… forces the type
-- `doc.value` is `decide(raw, BASE)` — the BaseLoader contract above, unchanged for every consumer.
-- An IMPLEMENTATION is a PROFILE (duplicate-key policy, merge policy, scalar resolver, key typing),
-- each MEASURED 2026-09-24 on probe documents and ported from the installed sources where there
-- are sources (PyYAML resolver.py/constructor.py, ruamel resolver.py, Psych scalar_scanner.rb):
--   pyyaml-base  last, literal, failsafe (all strings)       pyyaml-safe  last, merge, YAML 1.1
--   ruamel-safe  REJECT, merge, YAML 1.2 (010 -> 10)         psych-safe   last, merge, Psych's own
--   yaml-xs      last, literal, null/true/false only         yq           KEEPS BOTH, merge, go-yaml
-- `typed(raw, profile)` gives what that implementation would load (every scalar "type:value");
-- `divergences(doc, names)` lists the sites where the named implementations disagree — Norway
-- (`no` false in PyYAML/Psych, a string in ruamel/yq), `1:20` (80 in PyYAML, 4800 in Psych, a
-- string elsewhere), `010` (8 or 10), `1,000` (1000 in Psych only), a GitHub Actions `on:` key
-- (a boolean key in YAML 1.1).
-- ⚠ A TEMPLATE IS NOT DATA: a document carrying `{{` is returned with `templated = true`, and
-- whatever parsed is NOT to be trusted as the values (helm charts, `.gotmpl`, updatecli).

local M = {}

local function node_text(node, src) return vim.treesitter.get_node_text(node, src) end

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

local function unescape_double(s)
    local map = { n = '\n', t = '\t', r = '\r', ['"'] = '"', ['\\'] = '\\', ['/'] = '/', ['0'] = '\0',
        a = '\a', b = '\b', e = '\27', f = '\f', v = '\v', [' '] = ' ', N = '\u{85}', _ = '\u{a0}' }
    return (s:gsub('\\(u%x%x%x%x)', function (u) return utf8char(tonumber(u:sub(2), 16)) end)
        :gsub('\\(x%x%x)', function (x) return string.char(tonumber(x:sub(2), 16)) end)
        :gsub('\\(.)', function (c) return map[c] or ('\\' .. c) end))
end

-- flow scalar line folding: a line break (with surrounding spaces) becomes one space; an empty
-- line becomes a newline
local function fold_flow(s)
    if not s:find('\n', 1, true) then return s end
    local lines = vim.split(s, '\n', { plain = true })
    local out, pending_nl = {}, 0
    for i, l in ipairs(lines) do
        local t = (i == 1) and l:gsub('%s+$', '') or (i == #lines and l:gsub('^%s+', '') or l:gsub('^%s+', ''):gsub('%s+$', ''))
        if i > 1 and t == '' and i < #lines then pending_nl = pending_nl + 1
        else
            if i > 1 then out[#out + 1] = pending_nl > 0 and ('\n'):rep(pending_nl) or ' ' end
            pending_nl = 0
            out[#out + 1] = t
        end
    end
    return table.concat(out)
end

local function block_scalar(text, no_final_break)
    local header, body = text:match('^([|>][^\n]*)\n?(.*)$')
    if not header then return '' end
    local style = header:sub(1, 1)
    -- the indicators are ONLY the characters right after `|`/`>`: a header comment is not one
    -- (`|  # noqa command-instead-of-module` read its `-` as strip chomping — the join caught it)
    local ind = header:match('^[|>]([%d+-]*)') or ''
    local chomp = ind:match('[+-]') or ''
    local explicit = tonumber(ind:match('%d'))
    local lines = vim.split(body, '\n', { plain = true })
    local indent = explicit
    if not indent then
        for _, l in ipairs(lines) do
            if l:match('%S') then indent = #l:match('^( *)'); break end
        end
        indent = indent or 0
    end
    local content = {}
    for _, l in ipairs(lines) do content[#content + 1] = l:sub(indent + 1) end
    -- trailing empty lines are governed by chomping
    while #content > 0 and content[#content]:match('^%s*$') do table.remove(content) end
    local s
    if style == '|' then s = table.concat(content, '\n')
    else
        local out, prev_more = {}, false
        for i, l in ipairs(content) do
            local more = l:match('^%s') ~= nil or l == ''
            if i > 1 then
                if l == '' then out[#out + 1] = '\n'
                elseif prev_more or more then out[#out + 1] = '\n'
                elseif content[i - 1] ~= '' then out[#out + 1] = ' ' end
            end
            if l ~= '' then out[#out + 1] = l end
            prev_more = more and l ~= ''
        end
        s = table.concat(out)
    end
    if s == '' then return '' end
    if chomp == '-' then return s end
    -- a block that ends the FILE without a line break has no final break to clip or keep (wildfly's
    -- mp-testsuite-manual.yml ends mid-line; PyYAML/ruamel/Psych/libyaml all give no trailing newline)
    if no_final_break and not body:find('\n%s*$') then return s end
    if chomp == '+' then
        local trailing = 0
        for i = #lines, 1, -1 do if lines[i]:match('^%s*$') then trailing = trailing + 1 else break end end
        return s .. ('\n'):rep(math.max(trailing, 1))
    end
    return s .. '\n'
end

--- Every document of `src` as a value.
--- @return table|nil docs { { value, templated } }, string|nil why
function M.read(src)
    local okp, parser = pcall(vim.treesitter.get_string_parser, src, 'yaml')
    if not okp then return nil, 'no yaml tree-sitter parser' end
    local tree = parser:parse()[1]
    if not tree then return nil, 'yaml parse failed' end
    local root = tree:root()
    if root:has_error() then return nil, 'the yaml does not parse (tree-sitter reports an error node)' end
    local anchors = {}
    local value
    local function scalar(node)
        local t = node:type()
        local s = node_text(node, src)
        if t == 'double_quote_scalar' then
            -- ★ AN ESCAPED LINE BREAK (`\` ending a line) removes the break AND the next line's leading
            -- white space, keeping what was written before the backslash — BEFORE folding, which would
            -- otherwise turn the break into one more space (wildfly `artifact\` / `\ via`, quarkus's
            -- multi-line `if:` with lines ending in ` \`: two spaces where YAML has one). A run of
            -- backslashes escapes the break only when it is ODD (`\\` is a literal backslash).
            local body = s:sub(2, -2):gsub('(\\+)\r?\n[ \t]*', function(bs)
                if #bs % 2 == 1 then return bs:sub(2) .. '\0ESCBR' end
                return nil
            end)
            local folded = fold_flow(body):gsub('%z?ESCBR', ''):gsub('\0ESCBR', '')
            return unescape_double(folded)
        end
        if t == 'single_quote_scalar' then return (fold_flow(s:sub(2, -2)):gsub("''", "'")) end
        if t == 'block_scalar' then
            -- ⚠ the node ends BEFORE trailing white space on its last line (quarkus's `- ` item lost its
            -- space): take that white space from the source, and see whether a line break follows
            local _, _, eb = node:end_()
            local tail = src:sub(eb + 1):match('^[ \t]*') or ''
            local after = src:sub(eb + 1 + #tail, eb + 1 + #tail)
            return block_scalar(s .. tail, after == '')
        end
        -- a PLAIN scalar: its type is the resolver's decision, so it stays undecided in the raw tree
        return { amb = 'scalar', text = fold_flow(s) }
    end
    local function text_of(v)
        if type(v) == 'table' and v.amb == 'tag' then return text_of(v.value) end -- a tagged key's text
        return type(v) == 'table' and v.amb == 'scalar' and v.text or v
    end
    value = function(node)
        if node == nil then return { amb = 'scalar', text = '' } end
        local t = node:type()
        if t == 'block_node' or t == 'flow_node' then
            local anchor, content, tagname
            for c in node:iter_children() do
                local ct = c:type()
                if ct == 'anchor' then
                    for a in c:iter_children() do if a:type() == 'anchor_name' then anchor = node_text(a, src) end end
                elseif ct == 'tag' then tagname = node_text(c, src)
                elseif ct ~= 'comment' and c:named() then content = c end
            end
            local v = content and value(content) or { amb = 'scalar', text = '' }
            if tagname then v = { amb = 'tag', tag = tagname, value = v } end
            if anchor then anchors[anchor] = v end
            return v
        end
        if t == 'alias' then
            for a in node:iter_children() do
                if a:type() == 'alias_name' then
                    local v = anchors[node_text(a, src)]
                    return v == nil and { amb = 'scalar', text = '' } or v
                end
            end
            return ''
        end
        if t == 'block_mapping' or t == 'flow_mapping' then
            -- ★ AN ORDERED LIST OF PAIRS, NOT A MAP: which keys are the SAME key is the implementation's
            -- decision (`true:`/`yes:` are one key to PyYAML and two to ruamel; `1:`/`"1":` are two to
            -- PyYAML and one to YAML::XS and yq), so duplicates are grouped per profile, never here
            local pairs_ = {}
            local function put(kraw, v)
                local key = text_of(kraw)
                if type(key) ~= 'string' then key = vim.inspect(key) end
                pairs_[#pairs_ + 1] = { k = key, plain = type(kraw) == 'table' and kraw.amb == 'scalar', v = v }
            end
            for c in node:iter_children() do
                local ct = c:type()
                if ct == 'block_mapping_pair' or ct == 'flow_pair' then
                    local k = c:field('key')[1]
                    local v = c:field('value')[1]
                    put(k and value(k) or { amb = 'scalar', text = '' }, value(v))
                elseif ct == 'flow_node' then -- a bare key in a flow mapping: `{ a, b: 1 }`
                    put(value(c), { amb = 'scalar', text = '' })
                end
            end
            return { pairs = pairs_ }
        end
        if t == 'block_sequence' then
            local a = {}
            for c in node:iter_children() do
                if c:type() == 'block_sequence_item' then
                    local item
                    for x in c:iter_children() do if x:named() and x:type() ~= 'comment' then item = x end end
                    a[#a + 1] = value(item)
                end
            end
            return { a = a }
        end
        if t == 'flow_sequence' then
            local a = {}
            for c in node:iter_children() do
                if c:type() == 'flow_node' then a[#a + 1] = value(c)
                elseif c:type() == 'flow_pair' then -- `[a: 1]` is a single-pair mapping
                    local k, v = c:field('key')[1], c:field('value')[1]
                    local kraw = k and value(k) or { amb = 'scalar', text = '' }
                    local key = text_of(kraw)
                    if type(key) ~= 'string' then key = vim.inspect(key) end
                    a[#a + 1] = { pairs = { { k = key, plain = type(kraw) == 'table' and kraw.amb == 'scalar', v = value(v) } } }
                end
            end
            return { a = a }
        end
        if t == 'plain_scalar' or t == 'double_quote_scalar' or t == 'single_quote_scalar' or t == 'block_scalar' then
            return scalar(node)
        end
        -- a scalar's inner node (string_scalar, integer_scalar, …): its parent decides
        for c in node:iter_children() do if c:named() then return value(c) end end
        return node_text(node, src)
    end
    local docs = {}
    for d in root:iter_children() do
        if d:type() == 'document' then
            local content
            for c in d:iter_children() do if c:named() and c:type() ~= 'comment' then content = c end end
            local text = node_text(d, src)
            local raw = content and value(content) or { amb = 'scalar', text = '' }
            docs[#docs + 1] = { raw = raw, value = M.decide(raw, M.BASE), templated = text:find('{{', 1, true) ~= nil }
        end
    end
    return docs
end

-- ── resolvers: a plain scalar's TYPE, per implementation ───────────────────────────────────
-- Each returns (type, canonical value): types str/int/float/bool/null/timestamp/symbol/value.
-- Canonical: an int in decimal ('big' beyond 2^53, where doubles stop being exact), a float by
-- '%.17g' (inf/-inf/nan), a bool true/false; null and timestamp carry no value.
local function re_any(s, pats) for _, p in ipairs(pats) do if s:match(p) then return true end end return false end
local function float_canon(x)
    if x ~= x then return 'nan' end
    if x == math.huge then return 'inf' end
    if x == -math.huge then return '-inf' end
    if x == 0 and 1 / x < 0 then return '-0' end
    return ('%.17g'):format(x)
end
local function int_canon(x)
    if math.abs(x) >= 2 ^ 53 then return 'big' end
    return ('%d'):format(x)
end
local function digits_in(s, base)
    local n = 0
    for c in s:gmatch('.') do
        local d = tonumber(c, 36)
        if d == nil or d >= base then return nil end
        n = n * base + d
    end
    return n
end
local function base60(parts, tonum)
    local n = 0
    for _, p in ipairs(parts) do n = n * 60 + tonum(p) end
    return n
end
M._float_canon, M._int_canon = float_canon, int_canon

local R = {}
M.RESOLVERS = R

-- the four PyYAML/ruamel timestamp shapes (date; date + time, optional fraction and zone)
local function is_timestamp(s)
    if s:match('^%d%d%d%d%-%d%d%-%d%d$') then return true end
    local rest = s:match('^%d%d%d%d%-%d%d?%-%d%d?[Tt](.*)$') or s:match('^%d%d%d%d%-%d%d?%-%d%d?[ \t]+(.*)$')
    if not rest then return false end
    local tm, tail = rest:match('^(%d%d?:%d%d:%d%d)(.*)$')
    if not tm then return false end
    tail = tail:gsub('^%.%d*', '')
    tail = tail:gsub('^[ \t]*', '')
    return tail == '' or tail == 'Z' or tail:match('^[-+]%d%d?$') ~= nil or tail:match('^[-+]%d%d?:%d%d$') ~= nil
end

R.failsafe = function(s) return 'str', s end

-- PyYAML SafeLoader: resolver.py's implicit resolvers IN REGISTRATION ORDER (bool, float, int,
-- merge, null, timestamp, value), constructor.py's int/float construction
local PY_BOOL = { yes = 1, Yes = 1, YES = 1, no = 0, No = 0, NO = 0, ['true'] = 1, True = 1, TRUE = 1,
    ['false'] = 0, False = 0, FALSE = 0, on = 1, On = 1, ON = 1, off = 0, Off = 0, OFF = 0 }
local PY_NULL = { ['~'] = true, null = true, Null = true, NULL = true, [''] = true }
local function py_float_matches(s)
    return re_any(s, { '^[-+]?%d[%d_]*%.[%d_]*$', '^[-+]?%d[%d_]*%.[%d_]*[eE][-+]%d+$', '^%.%d[%d_]*$',
        '^%.%d[%d_]*[eE][-+]%d+$', '^[-+]?%.inf$', '^[-+]?%.Inf$', '^[-+]?%.INF$', '^%.nan$', '^%.NaN$', '^%.NAN$' })
        or (s:match('^[-+]?%d[%d_]*:') and s:match('^[-+]?%d[%d_]*[:%d]*%.[%d_]*$') and (function()
            local body = s:match('^[-+]?%d[%d_]*(.-)%.[%d_]*$')
            return body ~= '' and body:gsub(':[0-5]?%d', '') == ''
        end)())
end
local function py_int_matches(s)
    if re_any(s, { '^[-+]?0b[01_]+$', '^[-+]?0[0-7_]+$', '^[-+]?0$', '^[-+]?[1-9][%d_]*$', '^[-+]?0x[%x_]+$' }) then return true end
    local head, body = s:match('^([-+]?[1-9][%d_]*)(:.+)$')
    return head ~= nil and body:gsub(':[0-5]?%d', '') == ''
end
local function py_int_value(s)
    local v = s:gsub('_', '')
    local sign = v:sub(1, 1) == '-' and -1 or 1
    if v:match('^[-+]') then v = v:sub(2) end
    if v == '0' then return 0 end
    if v:sub(1, 2) == '0b' then return sign * digits_in(v:sub(3), 2) end
    if v:sub(1, 2) == '0x' then return sign * digits_in(v:sub(3):lower(), 16) end
    if v:sub(1, 1) == '0' then return sign * digits_in(v, 8) end
    if v:find(':', 1, true) then return sign * base60(vim.split(v, ':', { plain = true }), tonumber) end
    return sign * tonumber(v)
end
local function py_float_value(s)
    local v = s:gsub('_', ''):lower()
    local sign = v:sub(1, 1) == '-' and -1 or 1
    if v:match('^[-+]') then v = v:sub(2) end
    if v == '.inf' then return sign * math.huge end
    if v == '.nan' then return 0 / 0 end
    if v:find(':', 1, true) then return sign * base60(vim.split(v, ':', { plain = true }), tonumber) end
    return sign * tonumber(v)
end
R.pyyaml = function(s)
    local c = s:sub(1, 1)
    if c:match('[yYnNtTfFoO]') and PY_BOOL[s] then return 'bool', PY_BOOL[s] == 1 and 'true' or 'false' end
    if c:match('[-+%d.]') and py_float_matches(s) then return 'float', float_canon(py_float_value(s)) end
    if c:match('[-+%d]') and py_int_matches(s) then return 'int', int_canon(py_int_value(s)) end
    if PY_NULL[s] then return 'null' end
    if c:match('%d') and is_timestamp(s) then return 'timestamp' end
    if s == '=' then return 'value' end
    return 'str', s
end

-- ruamel.yaml safe loader, YAML 1.2 (its default): resolver.py's (1, 2) resolvers, constructor.py
-- (a leading 0 is DECIMAL in 1.2; `0o` is octal; no sexagesimal; exponent sign optional)
R.ruamel = function(s)
    local c = s:sub(1, 1)
    if c:match('[tTfF]') and ({ ['true'] = 1, True = 1, TRUE = 1, ['false'] = 0, False = 0, FALSE = 0 })[s] then
        return 'bool', s:lower() == 'true' and 'true' or 'false'
    end
    if c:match('[-+%d.]') and re_any(s, { '^[-+]?%d[%d_]*%.[%d_]*$', '^[-+]?%d[%d_]*%.[%d_]*[eE][-+]?%d+$',
        '^[-+]?%d[%d_]*[eE][-+]?%d+$', '^[-+]?%.[%d_]+$', '^[-+]?%.[%d_]+[eE][-+]%d+$', '^[-+]?%.inf$',
        '^[-+]?%.Inf$', '^[-+]?%.INF$', '^%.nan$', '^%.NaN$', '^%.NAN$' }) then
        local v = s:gsub('_', ''):lower()
        local sign = v:sub(1, 1) == '-' and -1 or 1
        if v:match('^[-+]') then v = v:sub(2) end
        if v == '.inf' then return 'float', float_canon(sign * math.huge) end
        if v == '.nan' then return 'float', 'nan' end
        return 'float', float_canon(sign * tonumber(v))
    end
    if c:match('[-+%d]') and re_any(s, { '^[-+]?0b[01_]+$', '^[-+]?0o?[0-7_]+$', '^[-+]?[%d_]+$', '^[-+]?0x[%x_]+$' }) then
        local v = s:gsub('_', '')
        local sign = v:sub(1, 1) == '-' and -1 or 1
        if v:match('^[-+]') then v = v:sub(2) end
        local n
        if v == '0' then n = 0
        elseif v:sub(1, 2) == '0b' then n = digits_in(v:sub(3), 2)
        elseif v:sub(1, 2) == '0x' then n = digits_in(v:sub(3):lower(), 16)
        elseif v:sub(1, 2) == '0o' then n = digits_in(v:sub(3), 8)
        else n = tonumber(v) end
        if n == nil then return 'str', s end -- `_` alone: ruamel's constructor raises; the join names it
        return 'int', int_canon(sign * n)
    end
    if PY_NULL[s] then return 'null' end
    if c:match('%d') and is_timestamp(s) then return 'timestamp' end
    if s == '=' then return 'value' end
    return 'str', s
end

-- Psych (Ruby 3.2, psych 5.0.1): scalar_scanner.rb#tokenize, branch by branch, legacy integers
-- (commas allowed: strict_integer defaults to false), and ITS sexagesimal: 60 ** |e - 2|
local function ruby_integer(v) -- Integer() after deleting ',' and '_': 0b / 0x / leading-0 octal / decimal
    local sign = v:sub(1, 1) == '-' and -1 or 1
    if v:match('^[-+]') then v = v:sub(2) end
    if v:sub(1, 2) == '0b' then return sign * digits_in(v:sub(3), 2) end
    if v:sub(1, 2) == '0x' then return sign * digits_in(v:sub(3):lower(), 16) end
    if #v > 1 and v:sub(1, 1) == '0' then return sign * digits_in(v:sub(2), 8) end
    return sign * tonumber(v)
end
R.psych = function(s)
    if s == '' then return 'null' end
    if (s:match('^[^%d.:-]?[%a_%s!@#$%%^&*(){}<>|/\\~;=]') and s:match('^[^%d.:-]?[%a_%s!@#$%%^&*(){}<>|/\\~;=]+')) or s:find('\n') then
        if #s > 5 then return 'str', s end
        local l = s:lower()
        if not l:match('^[ytonf~]') then return 'str', s end
        if s == '~' or l == 'null' then return 'null' end
        if l == 'yes' or l == 'true' or l == 'on' then return 'bool', 'true' end
        if l == 'no' or l == 'false' or l == 'off' then return 'bool', 'false' end
        return 'str', s
    end
    if s:match('^%-?%d%d%d%d%-%d%d?%-%d%d?[Tt ]') and s:match('%d%d?:%d%d:%d%d') then return 'timestamp' end
    if s:match('^%d%d%d%d%-%d%d?%-%d%d?$') then
        local m, d = s:match('^%d%d%d%d%-(%d%d?)%-(%d%d?)$')
        m, d = tonumber(m), tonumber(d)
        if m >= 0 and m <= 12 and d >= 0 and d <= 31 then return 'timestamp' end
    end
    local l = s:lower()
    if l == '.inf' or l == '+.inf' then return 'float', 'inf' end
    if l == '-.inf' then return 'float', '-inf' end
    if l == '.nan' then return 'float', 'nan' end
    if s:match('^:.') then return 'symbol', (s:match('^:(["\'])(.*)%1') and select(2, s:match('^:(["\'])(.*)%1')) or s:sub(2)) end
    local sx = s:match('^[-+]?%d[%d_]*(:[0-5]?%d:?[0-5]?%d?)$')
    local head = s:match('^([-+]?%d[%d_]*):')
    local function psych60(tonum)
        local parts = vim.split(s, ':', { plain = true })
        local n = 0
        for e, p in ipairs(parts) do n = n + tonum(p) * 60 ^ math.abs((e - 1) - 2) end
        return n
    end
    local function colon_parts_ok(body)
        local k = 0
        for _ in body:gmatch(':[0-5]?%d') do k = k + 1 end
        return body:gsub(':[0-5]?%d', '') == '' and k >= 1 and k <= 2
    end
    if head and colon_parts_ok(s:sub(#head + 1)) then
        return 'int', int_canon(psych60(function(p) return tonumber((p:gsub('_', ''))) or 0 end))
    end
    local fhead, fbody = s:match('^([-+]?%d[%d_]*)(:.-)%.[%d_]*$')
    if fhead and colon_parts_ok(fbody) then
        return 'float', float_canon(psych60(function(p) return tonumber((p:gsub('_', ''))) or 0 end))
    end
    if s:match('^[-+]?[%d][%d_,]*%.%d*$') or s:match('^[-+]?[%d][%d_,]*%.%d*[eE][-+]%d+$')
        or s:match('^[-+]?%.%d*$') or s:match('^[-+]?%.%d*[eE][-+]%d+$') then
        if s:match('^[-+]?%.$') then return 'str', s end
        local v = s:gsub('[,_]', ''):gsub('%.([Ee])', '%1'):gsub('%.$', '')
        local x = tonumber(v)
        if x == nil then return 'str', s end
        return 'float', float_canon(x)
    end
    if re_any(s, { '^[-+]?0b[01_,]+$', '^[-+]?0[0-7_,]+$', '^[-+]?0$', '^[-+]?0x[%x_,]+$' })
        or (s:match('^[-+]?[1-9][%d,_]*$') and not s:find('[,_][,_]') and not s:find('[,_]$')) then
        local n = ruby_integer((s:gsub('[,_]', '')))
        if n == nil then return 'str', s end
        return 'int', int_canon(n)
    end
    return 'str', s
end

-- go-yaml v3 (yq): TYPES ONLY — yq reports go-yaml's tag, but its values come from yq's own
-- parser (`0b11` fails to encode), so a value is not claimed. Measured: `010` int, `08` float,
-- `1:20` str, `-0` float, `yEs` str.
R.goyaml = function(s)
    local MAP = { ['true'] = 'bool', True = 'bool', TRUE = 'bool', ['false'] = 'bool', False = 'bool', FALSE = 'bool',
        ['~'] = 'null', null = 'null', Null = 'null', NULL = 'null', [''] = 'null',
        ['.nan'] = 'float', ['.NaN'] = 'float', ['.NAN'] = 'float', ['.inf'] = 'float', ['.Inf'] = 'float', ['.INF'] = 'float',
        ['+.inf'] = 'float', ['+.Inf'] = 'float', ['+.INF'] = 'float', ['-.inf'] = 'float', ['-.Inf'] = 'float', ['-.INF'] = 'float',
        ['<<'] = 'merge' }
    if MAP[s] then return MAP[s] end
    local c = s:sub(1, 1)
    if c:match('[-+%d]') then
        if s:match('^%d%d%d%d%-%d%d?%-%d%d?$') or (s:match('^%d%d%d%d%-%d%d?%-%d%d?[Tt ]%d') and s:match('%d%d?:%d%d?:%d%d?')) then return 'timestamp' end
        if s == '-0' then return 'float' end
        local p = s:gsub('_', '')
        local body = p:gsub('^[-+]', '')
        if body:match('^0[xX]%x+$') or body:match('^0[bB][01]+$') or body:match('^0[oO][0-7]+$') or body:match('^0[0-7]*$') or body:match('^[1-9]%d*$') then return 'int' end
        if p:match('^[-+]?%.%d+$') or p:match('^[-+]?%.%d+[eE][-+]?%d+$') or p:match('^[-+]?%d+%.?%d*$') or p:match('^[-+]?%d+%.?%d*[eE][-+]?%d+$') then return 'float' end
    elseif c == '.' then
        local x = tonumber(s)
        if x then return 'float' end
    end
    return 'str', s
end

-- YAML::XS (libyaml's Perl binding): plain `~`, `null`, `` are undef; `true`/`false` booleans;
-- everything else a Perl STRING (one that numifies if it looks like a number — Perl is untyped)
R['libyaml-perl'] = function(s)
    if s == '~' or s == 'null' or s == '' then return 'null' end
    if s == 'true' then return 'bool', 'true' end
    if s == 'false' then return 'bool', 'false' end
    return 'str', s
end

--- The type and canonical value of a PLAIN scalar under a resolver.
function M.resolve(text, resolver)
    local f = R[resolver] or error('unknown resolver ' .. tostring(resolver))
    return f(text)
end

-- ── profiles: an implementation = how it decides every kind of ambiguity ───────────────────────
-- ★ KEY IDENTITY IS PART OF THE PROFILE (measured 2026-09-24, user: "I wonder if duplicate yaml key
-- rule depends on value type"). It does NOT depend on the value's type — no implementation deep-merges
-- two mapping values, map/map is last-wins/reject/keep like scalar/scalar. It DOES depend on the KEY:
-- which keys are the same key is each language's equality —
--   python (PyYAML, ruamel)  constructed keys by Python ==: True == 1 == 1.0, `010` == `8`, `~` == `null`
--   ruby   (Psych)           Hash#eql?: type-sensitive (true is not 1, 1 is not 1.0)
--   perl   (YAML::XS)        the key's Perl STRING: `true` is "1", `false`/`~`/`null`/`` are ""
--   text   (yq, BaseLoader)  the key's text: `1` and `"1"` are ONE key to yq, `16` and `0x10` two
-- and the duplicate policy (last / reject / keep) applies to groups of the SAME key under it, so ruamel
-- rejects `16:`+`0x10:` and `true:`+`1:`, while PyYAML silently keeps the last of each.
M.BASE = { ['duplicate-key'] = 'last', ['merge-key'] = 'literal', scalar = 'failsafe', keys = 'string', tag = 'ignore', identity = 'text' }
M.IMPLEMENTATIONS = {
    ['pyyaml-base'] = M.BASE,
    ['pyyaml-safe'] = { ['duplicate-key'] = 'last', ['merge-key'] = 'merge', scalar = 'pyyaml', keys = 'typed', tag = 'reject-unknown', identity = 'python' },
    ['ruamel-safe'] = { ['duplicate-key'] = 'reject', ['merge-key'] = 'merge', scalar = 'ruamel', keys = 'typed', tag = 'reject-unknown', identity = 'python' },
    ['psych-safe'] = { ['duplicate-key'] = 'last', ['merge-key'] = 'merge-override', scalar = 'psych', keys = 'typed', tag = 'ignore', identity = 'ruby' },
    ['yaml-xs'] = { ['duplicate-key'] = 'last', ['merge-key'] = 'literal', scalar = 'libyaml-perl', keys = 'perl', sorted = true, untyped = true, tag = 'untyped', identity = 'perl' },
    -- (yq, measured on quarkus's empty and comment-only files: an EMPTY STREAM is ONE null document)
    yq = { ['duplicate-key'] = 'keep', ['merge-key'] = 'merge-override', scalar = 'goyaml', keys = 'typed', types_only = true, tag = 'keep',
        empty_stream = 'null-document', identity = 'text' },
}

-- the STANDARD tags a typed loader honours (a `!!x` shorthand or its full `tag:yaml.org,2002:x`)
local STANDARD = { str = 'str', int = 'int', float = 'float', bool = 'bool', null = 'null', map = 'map', seq = 'seq',
    timestamp = 'timestamp', binary = 'binary', set = 'set', omap = 'omap', pairs = 'pairs', merge = 'merge', value = 'value' }
local function standard_tag(t)
    local short = t:match('^!!(.+)$') or t:match('^!<tag:yaml%.org,2002:(.+)>$')
    return short and STANDARD[short] or nil
end
M._standard_tag = standard_tag

local function tag(t, canon, profile)
    if profile.types_only then return t end
    if canon == nil then return t end
    return t .. ':' .. canon
end

-- a key's TYPE under a profile (a types-only resolver has no canonical value: `type:text`)
local function key_tag(pair, profile)
    if not pair.plain then return 'str:' .. pair.k end
    local t, c = M.resolve(pair.k, profile.scalar)
    if profile.types_only then return t .. ':' .. pair.k end
    if c == nil then return t end
    return t .. ':' .. c
end
local function perl_key(pair)
    if pair.plain then
        local t, c = M.resolve(pair.k, 'libyaml-perl')
        if t == 'null' then return '' end
        if t == 'bool' then return c == 'true' and '1' or '' end
    end
    return pair.k
end
local IDENTITY = {
    text = function(pair) return pair.k end,
    ruby = function(pair, profile) return key_tag(pair, profile) end,
    perl = function(pair) return perl_key(pair) end,
    python = function(pair, profile)
        local tg = key_tag(pair, profile)
        local t, c = tg:match('^(%a+):?(.*)$')
        if t == 'bool' then return 'n:' .. (c == 'true' and '1' or '0') end
        if t == 'int' then return 'n:' .. c end
        if t == 'float' then
            local x = tonumber(c)
            if x and x == x and x == math.floor(x) and math.abs(x) < 2 ^ 53 then return 'n:' .. ('%d'):format(x) end
            return 'f:' .. c
        end
        return tg
    end,
}
M._identity = function(k, plain, profile) return IDENTITY[profile.identity or 'text']({ k = k, plain = plain }, profile) end

-- how a key is SHOWN: its text (decide) or what the implementation loads (typed)
local function key_display(pair, profile, mode)
    if mode == 'decide' then return pair.k end
    if profile.keys == 'perl' then return 'str:' .. perl_key(pair) end
    if profile.keys == 'typed' then return key_tag(pair, profile) end
    return 'str:' .. pair.k
end

local ENTRIES = setmetatable({}, { __mode = 'k' }) -- a converted mapping -> its { id, disp } list (for merges)

local convert

-- ★ TWO MERGE ALGORITHMS, MEASURED (2026-09-24) — they differ in VALUE, not only in order:
--   'merge'           PyYAML/ruamel (flatten_mapping): every `<<`'s pairs in document order — a list of
--                     sources REVERSED — then the mapping's own pairs; each assignment overwrites, a key
--                     keeps the place it FIRST appeared. Own keys win; an earlier source in a list beats
--                     a later one; a LATER `<<` key beats an earlier one. `{a: 1, <<: {a: 0}}` gives a = 1.
--   'merge-override'  Psych (revive_hash: hash.merge!) and yq (its default, which it WARNS is not to the
--                     spec): pairs replayed IN DOCUMENT ORDER — a `<<` overwrites keys written before it,
--                     keys written after it overwrite it. `{a: 1, <<: {a: 0}}` gives a = 0.
-- Assignment is by IDENTITY, so a merged `16` and an own `0x10` are the same key where the language says so.
local function resolve_map(x, profile, mode)
    local merge_on = profile['merge-key'] ~= 'literal'
    local idf = IDENTITY[profile.identity or 'text']
    local groups, order = {}, {}
    local conv = function(v) return convert(v, profile, mode) end
    for i, p in ipairs(x.pairs) do
        if not (merge_on and p.plain and p.k == '<<') then
            local id = idf(p, profile)
            local g = groups[id]
            if not g then g = { id = id, first = p, n = 0 }; groups[id] = g; order[#order + 1] = g end
            g.n = g.n + 1
            g.last = i
        end
    end
    local pol = profile['duplicate-key']
    for _, g in ipairs(order) do
        if g.n > 1 and pol == 'reject' then return nil, ('a key written %d times: %s'):format(g.n, g.first.k) end
    end
    -- ruamel (measured): a REPEATED `<<` is a duplicate key too; PyYAML/Psych/yq merge every one
    if pol == 'reject' and merge_on then
        local merges = 0
        for _, p in ipairs(x.pairs) do if p.plain and p.k == '<<' then merges = merges + 1 end end
        if merges > 1 then return nil, ('a key written %d times: <<'):format(merges) end
    end
    local o, keys, ids, by_id = {}, {}, {}, {}
    local function assign(id, disp, v)
        local slot = by_id[id]
        if slot then o[slot] = v; return end
        if o[disp] ~= nil then disp = disp .. ' #' .. id end -- two keys that SHOW alike (decide mode, `1` and `"1"`)
        by_id[id] = disp; keys[#keys + 1] = disp; ids[#ids + 1] = id; o[disp] = v
    end
    -- the sources of one `<<`: a mapping, or a list of them (applied reversed: an earlier one wins)
    local function sources_of(v)
        local d, why = conv(v)
        if d == nil then return nil, why end
        local list = (type(d) == 'table' and d.a) and d.a or { d }
        local out = {}
        for i = #list, 1, -1 do out[#out + 1] = list[i] end
        return out
    end
    local function apply_source(src)
        if type(src) ~= 'table' or not src.o then return end
        local ents = ENTRIES[src]
        for i, k in ipairs(src.keys) do assign(ents and ents[i] or k, k, src.o[k]) end
    end
    -- an own group's value under the duplicate policy (converted), for groups written more than once
    local dup_value = {}
    local function own_value(g, p)
        if g.n > 1 and pol == 'keep' then
            if dup_value[g.id] == nil then
                local a = {}
                for _, q in ipairs(x.pairs) do
                    if not (merge_on and q.plain and q.k == '<<') and idf(q, profile) == g.id then
                        local d, why = conv(q.v); if d == nil then return nil, why end; a[#a + 1] = d
                    end
                end
                dup_value[g.id] = { o = { __dup = { a = a } }, keys = { '__dup' } }
            end
            return dup_value[g.id]
        end
        return conv(p.v)
    end
    if merge_on and profile['merge-key'] == 'merge-override' then
        local done_keep = {}
        for _, p in ipairs(x.pairs) do
            if p.plain and p.k == '<<' then
                local srcs, why = sources_of(p.v); if srcs == nil then return nil, why end
                local h = { o = {}, keys = {} }
                local hid = {}
                for _, src in ipairs(srcs) do
                    if type(src) == 'table' and src.o then
                        local ents = ENTRIES[src]
                        for i, k in ipairs(src.keys) do
                            local id = ents and ents[i] or k
                            if hid[id] == nil then h.keys[#h.keys + 1] = k; hid[id] = #h.keys end
                            h.o[h.keys[hid[id]]] = src.o[k]
                        end
                    end
                end
                local hents = {}
                for i, k in ipairs(h.keys) do for id, pos in pairs(hid) do if pos == i then hents[i] = id end end end
                ENTRIES[h] = hents
                apply_source(h)
            else
                local g = groups[idf(p, profile)]
                if not (g.n > 1 and pol == 'keep' and done_keep[g.id]) and not (pol == 'first' and done_keep[g.id]) then
                    local v, why = own_value(g, p); if v == nil then return nil, why end
                    assign(g.id, key_display(g.first, profile, mode), v)
                    done_keep[g.id] = true
                end
            end
        end
    else
        if merge_on then
            for _, p in ipairs(x.pairs) do
                if p.plain and p.k == '<<' then
                    local srcs, why = sources_of(p.v); if srcs == nil then return nil, why end
                    for _, src in ipairs(srcs) do apply_source(src) end
                end
            end
        end
        local seen_first = {}
        for _, p in ipairs(x.pairs) do
            if not (merge_on and p.plain and p.k == '<<') then
                local g = groups[idf(p, profile)]
                local take = true
                if g.n > 1 and (pol == 'keep' or pol == 'first') then take = not seen_first[g.id] end
                if take then
                    local v, why = own_value(g, p); if v == nil then return nil, why end
                    assign(g.id, key_display(g.first, profile, mode), v)
                    seen_first[g.id] = true
                end
            end
        end
    end
    if mode == 'typed' and profile.sorted then
        local idx = {}
        for i, k in ipairs(keys) do idx[k] = ids[i] end
        table.sort(keys)
        for i, k in ipairs(keys) do ids[i] = idx[k] end
    end
    local out = { o = o, keys = keys }
    ENTRIES[out] = ids
    return out
end

function convert(v, profile, mode)
    if type(v) ~= 'table' then return mode == 'typed' and tag('str', v, profile) or v end
    if v.amb == 'scalar' then
        if mode == 'decide' then return v.text end
        local t, c = M.resolve(v.text, profile.scalar)
        return tag(t, c, profile)
    end
    if v.amb == 'tag' then
        local std = standard_tag(v.tag)
        if profile.tag == 'reject-unknown' and not std then
            return nil, ('could not determine a constructor for the tag %s'):format(v.tag)
        end
        -- YAML::XS (measured): `!!bool` on a scalar is an ERROR ("bad tag found for scalar")
        if profile.tag == 'untyped' and std == 'bool' then return nil, 'bad tag found for scalar: tag:yaml.org,2002:bool' end
        local inner = v.value
        if mode == 'decide' then return convert(inner, profile, mode) end
        local text = type(inner) == 'string' and inner or (type(inner) == 'table' and inner.amb == 'scalar' and inner.text) or nil
        if profile.tag == 'untyped' then
            -- YAML::XS: local tags ignored; !!str/!!int/!!float give Perl scalars; !!null gives undef
            if std == 'null' then return 'null' end
            if text ~= nil then return tag('str', text, profile) end
            return convert(inner, profile, mode)
        end
        if not std then
            if profile.tag == 'keep' and text ~= nil then return 'tag:' .. v.tag end
            return convert(inner, profile, mode)
        end
        if text == nil or std == 'map' or std == 'seq' then return convert(inner, profile, mode) end
        -- a STANDARD tag forces the type; the value comes from the tag's constructor
        if std == 'str' then return tag('str', text, profile) end
        if std == 'null' then return 'null' end
        local t, c = M.resolve(text, profile.scalar)
        if t == std then return tag(t, c, profile) end
        if std == 'int' then local n = tonumber((text:gsub('[_,]', ''))); return tag('int', n and int_canon(n) or nil, profile) end
        if std == 'float' then local n = tonumber((text:gsub('_', ''))); return tag('float', n and float_canon(n) or nil, profile) end
        if std == 'bool' then local l = text:lower(); return tag('bool', (l == 'true' or l == 'yes' or l == 'on') and 'true' or 'false', profile) end
        return tag(std, nil, profile)
    end
    if v.a then
        local a = {}
        for i, x in ipairs(v.a) do
            local d, why = convert(x, profile, mode); if d == nil then return nil, why end; a[i] = d
        end
        return { a = a }
    end
    if v.pairs then return resolve_map(v, profile, mode) end
    return v
end

--- A raw value DECIDED under a profile, as strings (the kv form every consumer reads); nil and
--- why when the profile rejects it.
function M.decide(v, profile) return convert(v, profile or M.BASE, 'decide') end

--- What an implementation would LOAD: every scalar "type:value" (a quoted one is always a
--- string), keys as it shows them; nil and why when it would refuse.
function M.typed(v, profile) return convert(v, profile, 'typed') end

-- ★ PERL IS UNTYPED: YAML::XS's "10" IS the number 10 to a Perl consumer, so it is not a divergence
-- from int:10. What IS one: a string that numifies to ANOTHER number — "010" is 10 to Perl and 8 to
-- PyYAML; "0x1F" and "1_000" numify to 0 and 1 (Perl reads the leading decimal digits only).
-- looks_like_number: optional sign, digits with an optional fraction, an optional exponent.
local function perl_number(v)
    if not (v:match('^[-+]?%d+%.?%d*$') or v:match('^[-+]?%d*%.%d+$') or v:match('^[-+]?%d+%.?%d*[eE][-+]?%d+$')
        or v:match('^[-+]?%d*%.%d+[eE][-+]?%d+$')) then return nil end
    return tonumber(v)
end
M._perl_number = perl_number

--- A whole STREAM as an implementation loads it: every document typed; nil and why if refused.
--- An empty stream is zero documents, except where the profile says one null document (yq).
function M.typed_stream(docs, profile)
    local a = {}
    for i, d in ipairs(docs) do
        local t, why = M.typed(d.raw, profile)
        if t == nil then return nil, why end
        a[i] = t
    end
    if #a == 0 and profile.empty_stream == 'null-document' then a[1] = 'null' end
    return { a = a }
end

--- ★ WHERE IMPLEMENTATIONS DISAGREE: every ambiguity site whose outcome differs between the named
--- implementations (default: all). Rows: { path, kind, text, outcomes = {name -> outcome} }.
function M.divergences(raw, names)
    if not names then names = {}; for n in pairs(M.IMPLEMENTATIONS) do names[#names + 1] = n end; table.sort(names) end
    local out = {}
    local function same(a, b, pa, pb) -- a types-only outcome agrees with any value of its type
        if a == b then return true end
        if a:sub(1, 1) == '{' or b:sub(1, 1) == '{' then return false end -- a decided mapping: exact
        -- an untyped (Perl) string agrees with a number it numifies to EXACTLY
        local function untyped_agrees(u, t)
            local sv = u:match('^str:(.*)$')
            local ty, num = t:match('^(%a+):(.*)$')
            if not sv or (ty ~= 'int' and ty ~= 'float') then return false end
            local pn = perl_number(sv)
            return pn ~= nil and tonumber(num) ~= nil and pn == tonumber(num)
        end
        if pa.untyped and untyped_agrees(a, b) then return true end
        if pb.untyped and untyped_agrees(b, a) then return true end
        if pa.types_only or pb.types_only then return (a:match('^[^:]+') == b:match('^[^:]+')) end
        return false
    end
    local function row(path, kind, text, outcome_of)
        local outcomes, first, differ = {}, nil, false
        for _, n in ipairs(names) do
            local p = M.IMPLEMENTATIONS[n]
            outcomes[n] = outcome_of(p)
            if first == nil then first = n
            elseif not same(outcomes[first], outcomes[n], M.IMPLEMENTATIONS[first], p) then differ = true end
        end
        if differ then out[#out + 1] = { path = path, kind = kind, text = text, outcomes = outcomes } end
    end
    local function walk(x, path)
        if type(x) ~= 'table' then return end
        if x.amb == 'scalar' then
            row(path, 'scalar', x.text, function(p) local t, c = M.resolve(x.text, p.scalar); return tag(t, c, p) end)
            return
        end
        if x.amb == 'tag' then
            if not standard_tag(x.tag) then
                row(path, 'tag', x.tag, function(p)
                    if p.tag == 'reject-unknown' then return 'rejected' end
                    if p.tag == 'untyped' then return 'ignored' end
                    if p.tag == 'keep' then return 'kept ' .. x.tag end
                    return 'ignored'
                end)
            end
            walk(x.value, path)
            return
        end
        if x.a then for i, y in ipairs(x.a) do walk(y, path .. '[' .. i .. ']') end return end
        if not x.pairs then return end
        -- DUPLICATES: which pairs are the same key, and what the policy does with them, per profile
        row(path, 'duplicate-key', nil, function(p)
            local idf, groups, order = IDENTITY[p.identity or 'text'], {}, {}
            for _, q in ipairs(x.pairs) do
                if not (p['merge-key'] ~= 'literal' and q.plain and q.k == '<<') then
                    local id = idf(q, p)
                    if not groups[id] then groups[id] = {}; order[#order + 1] = id end
                    table.insert(groups[id], q.k)
                end
            end
            local parts = {}
            for _, id in ipairs(order) do
                if #groups[id] > 1 then
                    local pol = p['duplicate-key']
                    parts[#parts + 1] = table.concat(groups[id], '=') .. ' ' .. (pol == 'reject' and 'rejected' or pol == 'keep' and 'kept all' or ('the ' .. pol))
                end
            end
            return #parts == 0 and 'distinct' or table.concat(parts, '; ')
        end)
        -- MERGES: only where the decided mappings really differ
        local has_merge = false
        for _, q in ipairs(x.pairs) do if q.plain and q.k == '<<' then has_merge = true end end
        if has_merge then
            row(path, 'merge-key', '<<', function(p)
                local d = M.decide(x, p)
                if d == nil then return 'rejected' end
                local parts = {}
                for _, k in ipairs(d.keys) do parts[#parts + 1] = k .. '=' .. vim.inspect(d.o[k], { newline = '', indent = '' }) end
                return '{' .. table.concat(parts, ', ') .. '}'
            end)
        end
        for _, q in ipairs(x.pairs) do
            if q.plain and q.k ~= '<<' then
                row(path .. '.' .. q.k, 'key', q.k, function(p) return key_display(q, p, 'typed') end)
            end
            walk(q.v, path .. '.' .. q.k)
        end
    end
    walk(raw, '$')
    return out
end

--- One document (the first), or nil and why. The common case for values files.
function M.read_one(src)
    local docs, why = M.read(src)
    if not docs then return nil, why end
    if #docs == 0 then return { o = {}, keys = {} }, nil, false end
    return docs[1].value, nil, docs[1].templated
end

return M
