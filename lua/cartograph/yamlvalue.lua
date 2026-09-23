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
-- ⚠ A TEMPLATE IS NOT DATA: a document carrying `{{` is returned with `templated = true`, and
-- whatever parsed is NOT to be trusted as the values (helm charts, `.gotmpl`, updatecli).

local M = {}

local function node_text(node, src) return vim.treesitter.get_node_text(node, src) end

local function unescape_double(s)
    local map = { n = '\n', t = '\t', r = '\r', ['"'] = '"', ['\\'] = '\\', ['/'] = '/', ['0'] = '\0',
        a = '\a', b = '\b', e = '\27', f = '\f', v = '\v', [' '] = ' ', N = '\u{85}', _ = '\u{a0}' }
    return (s:gsub('\\(u%x%x%x%x)', function (u) return utf8.char(tonumber(u:sub(2), 16)) end)
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

local function block_scalar(text)
    local header, body = text:match('^([|>][^\n]*)\n?(.*)$')
    if not header then return '' end
    local style = header:sub(1, 1)
    local chomp = header:match('[+-]') or ''
    local explicit = tonumber(header:match('%d'))
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
        if t == 'double_quote_scalar' then return unescape_double(fold_flow(s:sub(2, -2))) end
        if t == 'single_quote_scalar' then return (fold_flow(s:sub(2, -2)):gsub("''", "'")) end
        if t == 'block_scalar' then return block_scalar(s) end
        return fold_flow(s)
    end
    value = function(node)
        if node == nil then return '' end
        local t = node:type()
        if t == 'block_node' or t == 'flow_node' then
            local anchor, content
            for c in node:iter_children() do
                local ct = c:type()
                if ct == 'anchor' then
                    for a in c:iter_children() do if a:type() == 'anchor_name' then anchor = node_text(a, src) end end
                elseif ct ~= 'tag' and ct ~= 'comment' and c:named() then content = c end
            end
            local v = content and value(content) or ''
            if anchor then anchors[anchor] = v end
            return v
        end
        if t == 'alias' then
            for a in node:iter_children() do
                if a:type() == 'alias_name' then
                    local v = anchors[node_text(a, src)]
                    return v == nil and '' or v
                end
            end
            return ''
        end
        if t == 'block_mapping' or t == 'flow_mapping' then
            local o, keys = {}, {}
            for c in node:iter_children() do
                local ct = c:type()
                if ct == 'block_mapping_pair' or ct == 'flow_pair' then
                    local k = c:field('key')[1]
                    local v = c:field('value')[1]
                    local key = k and value(k) or ''
                    if type(key) ~= 'string' then key = vim.inspect(key) end
                    if o[key] == nil then keys[#keys + 1] = key end
                    o[key] = value(v)
                elseif ct == 'flow_node' then -- a bare key in a flow mapping: `{ a, b: 1 }`
                    local key = value(c)
                    if type(key) == 'string' then
                        if o[key] == nil then keys[#keys + 1] = key end
                        o[key] = ''
                    end
                end
            end
            return { o = o, keys = keys }
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
                    local key = k and value(k) or ''
                    a[#a + 1] = { o = { [key] = value(v) }, keys = { key } }
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
            docs[#docs + 1] = { value = content and value(content) or '', templated = text:find('{{', 1, true) ~= nil }
        end
    end
    return docs
end

--- One document (the first), or nil and why. The common case for values files.
function M.read_one(src)
    local docs, why = M.read(src)
    if not docs then return nil, why end
    if #docs == 0 then return { o = {}, keys = {} }, nil, false end
    return docs[1].value, nil, docs[1].templated
end

return M
