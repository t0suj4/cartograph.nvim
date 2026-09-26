-- stxcensus — every Strophe `stx` tagged template under a directory, read as an XML element tree
-- with holes (lua/cartograph/stx.lua, CART-1097): how many parse, what each stanza sends.
--
--   nvim --headless -u NONE -l tools/stxcensus.lua <dir> [--all] [--stanzas] [--json <out>]
--
--   --all        include test files (default: PRODUCTION only; see TEST below)
--   --stanzas    print one block per top-level template: top element, type, every (element, namespace)
--   --json <out> write the per-file records and stanza inventory as JSON
--
-- POPULATION. Files ending .js/.mjs/.cjs/.ts, never .d.ts (a declaration file carries no runtime code;
-- converse's .d.ts copies of JSDoc examples are where a line grep over-counts). Only files containing
-- the text "stx`" are parsed (a tagged template cannot be written without it).
-- TEST = a path segment named tests, test, __tests__ or spec, or a *.test.* / *.spec.* file name.
-- NAMESPACES resolve through: the built-in Strophe.NS table (strophe.js 5.0.0), every
-- `Strophe.addNamespace('K', <const expr>)`, a file-local const, then a const EXPORTED with one value,
-- harvested over the censused population (production only unless --all); anything else stays
-- unresolved with its expression.
-- @langs javascript
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local here = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tools/') or '.'
package.path = here .. '/lua/?.lua;' .. here .. '/lua/?/init.lua;' .. package.path
local stx = require 'cartograph.stx'

local dir, all, show, json_out
local i = 1
while arg[i] do
    local a = arg[i]
    if a == '--all' then all = true
    elseif a == '--stanzas' then show = true
    elseif a == '--json' then i = i + 1; json_out = arg[i]
    elseif not dir then dir = vim.fn.fnamemodify(vim.fn.expand(a), ':p'):gsub('/+$', '')
    else io.stderr:write('unknown argument ' .. a .. '\n'); os.exit(2) end
    i = i + 1
end
if not dir then io.stderr:write('usage: stxcensus.lua <dir> [--all] [--stanzas] [--json <out>]\n'); os.exit(2) end

-- the directory pass (namespace harvest, then templates) is stx.scan, shared with the wire merge
local scan = stx.scan(dir, { all = all })
local ns_files, ns = scan.ns_files, scan.ns

-- pass 2: the templates
local T = { files = 0, stx_files = 0, templates = 0, ok = 0, fragments = 0, nested = 0, bound = 0, stanzas = 0,
    unparsed = {}, per_file = {}, tops = {}, pairs = {}, via = {}, sites = {}, unresolved = {}, top_no_ns = {},
    stanza_rows = {}, escaped_attrs = {} }
local function inc(t, k, n) t[k] = (t[k] or 0) + (n or 1) end
local records = {}
for _, f in ipairs(scan.files) do
    local rel, recs = f.rel, f.recs
    T.files = T.files + 1
    if #recs > 0 then
        do
            T.stx_files = T.stx_files + 1
            local okn = 0
            for _, r in ipairs(recs) do
                T.templates = T.templates + 1
                if r.ok then okn = okn + 1 else T.unparsed[#T.unparsed + 1] = { file = rel, line = r.line, why = r.why } end
                if r.fragment then T.fragments = T.fragments + 1 end
                if r.parent then T.nested = T.nested + 1 end
                if r.bound_by then T.bound = T.bound + 1 end
                for _, h in ipairs(r.holes) do
                    local k = (h.site or ('unread:' .. tostring(h.pos))) .. (h.fill and (' / ' .. h.fill) or '')
                    inc(T.sites, k)
                    if h.site == 'attrs' and h.fill == 'text' then
                        T.escaped_attrs[#T.escaped_attrs + 1] = ('%s:%d  <%s ${%s}>'):format(rel, h.line, tostring(h.element), (h.expr:gsub('%s+', ' ')))
                    end
                end
            end
            T.ok = T.ok + okn
            T.per_file[#T.per_file + 1] = { file = rel, templates = #recs, ok = okn }
            local inv = stx.inventory(recs)
            for _, row in ipairs(inv) do
                T.stanzas = T.stanzas + 1
                row.file = rel
                T.stanza_rows[#T.stanza_rows + 1] = row
                local top = row.top or (row.ok and (row.fragment and '(fragment)' or '?') or '(unparsed)')
                inc(T.tops, top .. (row.type and (' type=' .. row.type) or ''))
                if row.top and stx.STANZAS[row.top] and not row.top_ns then
                    T.top_no_ns[#T.top_no_ns + 1] = ('%s:%d <%s>'):format(rel, row.line, row.top)
                end
                for _, e in ipairs(row.elements) do
                    inc(T.pairs, ('%s {%s}'):format(e.name, e.uri or ('?' .. (e.expr and (' ${' .. e.expr .. '}') or ''))))
                    inc(T.via, e.via)
                    if e.via == 'unresolved' then inc(T.unresolved, e.expr or '?') end
                end
            end
            records[rel] = { templates = recs, stanzas = inv }
        end
    end
end

local function sorted_counts(t, limit)
    local ks = {}
    for k, v in pairs(t) do ks[#ks + 1] = { k, v } end
    table.sort(ks, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
    local out = {}
    for j, kv in ipairs(ks) do
        if limit and j > limit then out[#out + 1] = ('  ... %d more'):format(#ks - limit); break end
        out[#out + 1] = ('  %5d  %s'):format(kv[2], kv[1])
    end
    return table.concat(out, '\n')
end

print(('stxcensus %s (%s)'):format(dir, all and 'all files' or 'production only'))
print(('  namespace tables: %d files harvested, %d addNamespace keys'):format(ns_files, vim.tbl_count(ns)))
print(('  files scanned %d, with stx %d; templates %d, parsed %d, unparsed %d'):format(T.files, T.stx_files, T.templates, T.ok, #T.unparsed))
print(('  nested in another template %d, bound by a const into another %d, fragments %d, top-level (stanza candidates) %d'):format(
    T.nested, T.bound, T.fragments, T.stanzas))
print('\nper file (templates / parsed):')
for _, f in ipairs(T.per_file) do print(('  %3d %3d  %s'):format(f.templates, f.ok, f.file)) end
if #T.unparsed > 0 then
    print('\nunparsed:')
    for _, u in ipairs(T.unparsed) do print(('  %s:%d  %s'):format(u.file, u.line, u.why)) end
end
print('\ntop-level templates by top element and type:')
print(sorted_counts(T.tops))
print(('\ntop iq/message/presence WITHOUT an xmlns (Stanza.toElement throws on these when built): %d'):format(#T.top_no_ns))
for _, s in ipairs(T.top_no_ns) do print('  ' .. s) end
print('\n(element, namespace) across top-level templates, fragments spliced in:')
print(sorted_counts(T.pairs))
print('\nnamespace provenance (element occurrences):')
print(sorted_counts(T.via))
print('\nunresolved namespace expressions:')
print(sorted_counts(T.unresolved))
print('\nholes by site / fill:')
print(sorted_counts(T.sites))
print(('\nTEXT spliced into an attribute list (Strophe escapes it: the stanza does not parse when non-empty): %d'):format(#T.escaped_attrs))
for _, s in ipairs(T.escaped_attrs) do print('  ' .. s) end

if show then
    print('\n── stanzas ──')
    for _, row in ipairs(T.stanza_rows) do
        print(('%s:%d  %s%s%s'):format(row.file, row.line, row.top or (row.ok and '(fragment)' or '(unparsed: ' .. tostring(row.why) .. ')'),
            row.type and (' type=' .. row.type) or '', row.unparsed_fragments and (' [unparsed fragments ' .. row.unparsed_fragments .. ']') or ''))
        for _, e in ipairs(row.elements) do
            print(('    %s%s  {%s} %s%s'):format(('  '):rep(e.depth), e.name, e.uri or ('? ' .. tostring(e.expr)), e.via, e.from ~= 'self' and (' <' .. e.from) or ''))
        end
    end
end

if json_out then
    local fd = assert(io.open(json_out, 'w'))
    fd:write(vim.json.encode({ dir = dir, all = all or false, totals = { files = T.files, stx_files = T.stx_files,
        templates = T.templates, ok = T.ok, stanzas = T.stanzas }, files = records }))
    fd:close()
    print('\nwrote ' .. json_out)
end
