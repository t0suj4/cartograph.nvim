-- CART-1008: a name is written where it is DEFINED, so it belongs to its defining file's entry in the mention index.
-- The index records IDENTIFIER occurrences; a definition named by a PROPERTY KEY — an object-literal key (`getJSON:
-- function …` inside jQuery.extend({ … })), a class method, a go method (`func (r *T) Name()`, a field_identifier) — is
-- no identifier node, and `mentions` / lint's "name occurs elsewhere" read "0 files" about a name printed on the
-- defining line. Measured, definitions in NO file's entry: jquery/src 108 -> 44 of 392, hugo 876 -> 337 of 8129, ours
-- 264 -> 258 — every one left is the index's documented rule (1-2 characters, the language's stdlib vocabulary).

local ts    = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local agent = require 'cartograph.agent'

local function tree(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local function entry(data, file, name) return (data.names[file] or ''):find('\31' .. name .. '\31', 1, true) ~= nil end

test('mention index: a definition named by an object-literal key, a class method or a go method is in its file\'s entry (CART-1008)', function ()
    local files = {
        -- minimised from jquery/src/ajax.js:847 and attributes/prop.js
        ['ajax.js'] = 'jQuery.extend({\n  getJSON: function (url, data, callback) { return url; },\n  getScript: function (url) { return url; }\n});\n'
            .. 'class Loader { fetchAll() { return 1; } }\n',
    }
    if parser_available('go') then
        files['t.go'] = 'package m\n\ntype Site struct{}\n\nfunc (s *Site) RenderPages() int {\n\tcount := 1\n\treturn count\n}\n'
    end
    if not parser_available('javascript') then skip 'no javascript parser' end
    local root = tree(files)
    local data = ts.extract(root); data.root = root
    for _, n in ipairs { 'getJSON', 'getScript', 'fetchAll' } do ok(entry(data, 'ajax.js', n), n .. ' in ajax.js\'s entry') end
    if files['t.go'] then ok(entry(data, 't.go', 'RenderPages'), 'a go method name') end
    -- the rule is the index's own: a 1-2 character name and a stdlib one stay out
    store.ingest(data)
    local a = agent.answer(store, 'mentions', { name = 'getJSON' })
    eq(true, a.ok)
    eq('ajax.js', a.result[1] and a.result[1].file, 'the verb names the defining file — it read "0 files": ' .. vim.inspect(a.result))
    vim.fn.delete(root, 'rf')
end)

test('mention index: only the index\'s rule — a short or stdlib name, a bracket string, a key that defines nothing stay out (CART-1008)', function ()
    if not parser_available('javascript') then skip 'no javascript parser' end
    local root = tree({ ['h.js'] = 'var hooks = {\n  get: function (e) { return e; },\n  go: function () {},\n  "x/y": function () {},\n  kind: "plain"\n};\n' })
    local data = ts.extract(root); data.root = root
    eq(false, entry(data, 'h.js', 'go'), 'two characters')
    local sp = ts.spec.javascript
    if sp.stdlib_names and sp.stdlib_names.get then eq(false, entry(data, 'h.js', 'get'), 'the stdlib vocabulary') end
    eq(false, entry(data, 'h.js', 'x/y'), 'no identifier shape')
    eq(false, entry(data, 'h.js', 'kind'), 'a key that defines nothing is not a mention')
    vim.fn.delete(root, 'rf')
end)

test('mention index: a refresh of the file keeps its definitions in its entry; a language that indexes nothing gains no entry (CART-1008)', function ()
    if not parser_available('javascript') then skip 'no javascript parser' end
    local files = { ['a.js'] = 'var api = { loadAll: function () { return 1; } };\n' }
    local erl = parser_available('erlang')
    if erl then files['m.erl'] = '-module(m).\n-export([start_link/0]).\nstart_link() -> ok.\n' end
    local root = tree(files)
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    ok(entry(store.data, 'a.js', 'loadAll'))
    if erl then eq(nil, store.data.names['m.erl'], 'erlang mentions are off by decision (CART-0845): no entry is invented') end
    vim.uv.sleep(1100)
    local fd = assert(io.open(root .. '/a.js', 'w')); fd:write('var api = { loadAll: function () { return 2; }, saveAll: function () {} };\n'); fd:close()
    require('cartograph.refresh').file('a.js')
    ok(entry(store.data, 'a.js', 'loadAll') and entry(store.data, 'a.js', 'saveAll'), 'the refreshed entry: ' .. tostring(store.data.names['a.js']))
    vim.fn.delete(root, 'rf')
end)

test('mention index: graph_info reports, per language, the definitions the index skips and by which rule (CART-1008)', function ()
    if not parser_available('javascript') then skip 'no javascript parser' end
    local root = tree({ ['h.js'] = 'var hooks = {\n  go: function () {},\n  "x/y": function () {},\n  get: function (e) { return e; },\n  loadAll: function () { return 1; }\n};\nfunction ab() {}\n' })
    local data = ts.extract(root); data.root = root
    local cov = agent.mention_coverage(data)
    local sp = ts.spec.javascript
    if sp.stdlib_names and sp.stdlib_names.get then ok(cov.javascript.stdlib >= 1, 'get: the stdlib vocabulary — ' .. vim.inspect(cov.javascript)) end
    local r = cov.javascript
    ok(r and r.defs >= 3, vim.inspect(cov))
    eq(0, r.unexplained, 'every skip is one of the index\'s rules')
    ok(r.short >= 2, 'go and ab: under 3 characters — ' .. vim.inspect(r))
    eq(r.skipped, r.short + r.stdlib + r.shape + r.off + r.unexplained, 'the rules partition the skips')
    store.ingest(data)
    local a = agent.answer(store, 'graph_info', {})
    local note
    for _, n in ipairs(a.notes or {}) do if n.kind == 'mention-index-coverage' then note = n end end
    ok(note, 'graph_info carries the coverage note')
    ok(note.why:find('javascript %d+ of %d+'), note.why)
    eq(r.skipped, note.evidence.by_lang.javascript.skipped)
    -- a definition the index lost by NO rule is counted apart: that is a bug in the index, not a rule
    data.names['h.js'] = data.names['h.js']:gsub('\31loadAll\31', '\31')
    eq(1, agent.mention_coverage(data).javascript.unexplained)
    vim.fn.delete(root, 'rf')
end)

test('mention index: a language whose mentions are off has no entry — its definitions count as OFF, not unexplained (CART-1008)', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local root = tree({ ['m.erl'] = '-module(m).\n-export([start_link/0]).\nstart_link() -> ok.\n' })
    local data = ts.extract(root); data.root = root
    local r = agent.mention_coverage(data).erlang
    ok(r and r.off >= 1 and r.unexplained == 0, vim.inspect(r))
    vim.fn.delete(root, 'rf')
end)

test('mention index: a bracket-string member has no identifier tail — counted as SHAPE (CART-1008)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['l.lua'] = "local M = { handlers = {} }\nM.handlers['textDocument/hover'] = function () return 1 end\nfunction M.loadAll() return 2 end\nreturn M\n" })
    local data = ts.extract(root); data.root = root
    local r = agent.mention_coverage(data).lua
    ok(r and r.shape >= 1, vim.inspect(r))
    eq(0, r.unexplained)
    vim.fn.delete(root, 'rf')
end)

test('mention index: a file the identifier pass gave no entry — a java record with no body — gets one for its definitions (CART-1008)', function ()
    if not parser_available('java') then skip 'no java parser' end
    -- minimised from elasticsearch libs user-agent-api Details.java: 7 definitions in no file's entry
    local root = tree({ ['Details.java'] = 'package p;\npublic record Details(String name, String version, String deviceType) {}\n' })
    local data = ts.extract(root); data.root = root
    ok(data.names['Details.java'], 'an entry exists')
    ok(entry(data, 'Details.java', 'deviceType'), 'the accessor\'s name: ' .. tostring(data.names['Details.java']))
    eq(0, agent.mention_coverage(data).java.unexplained)
    -- an indexed language's file with NO entry is no rule's doing: unexplained, never `off`
    data.names['Details.java'] = nil
    local r = agent.mention_coverage(data).java
    ok(r.unexplained >= 1 and r.off == 0, vim.inspect(r))
    vim.fn.delete(root, 'rf')
end)

test('mention index: a REFRESH of a file with no function body updates its entry (CART-1008)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['Details.java'] = 'package p;\npublic record Details(String name) {}\n' })
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    vim.uv.sleep(1100)
    local fd = assert(io.open(root .. '/Details.java', 'w')); fd:write('package p;\npublic record Details(String name, String deviceType) {}\n'); fd:close()
    require('cartograph.refresh').file('Details.java')
    ok(entry(store.data, 'Details.java', 'deviceType'), 'the refreshed entry: ' .. tostring(store.data.names['Details.java']))
    vim.fn.delete(root, 'rf')
end)

test('mention index: a file whose every name is short or stdlib has no entry, and that is the rules\' doing — not unexplained (CART-1008)', function ()
    if not parser_available('go') then skip 'no go parser' end
    local sp = ts.spec.go
    if not (sp.stdlib_names and sp.stdlib_names.Close and sp.stdlib_names.Add) then skip 'go vocabulary without Close / Add' end
    -- minimised from hugo common/types/closer.go
    local root = tree({ ['closer.go'] = 'package types\n\ntype Closers struct{}\n\nfunc (cs *Closers) Add(c int) {}\n\nfunc (cs *Closers) Close() error {\n\treturn nil\n}\n' })
    local data = ts.extract(root); data.root = root
    local r = agent.mention_coverage(data).go
    ok(r and r.stdlib >= 2 and r.unexplained == 0 and r.off == 0, vim.inspect(r))
    vim.fn.delete(root, 'rf')
end)
