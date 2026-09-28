-- jsbreaks — WHAT BREAKS IF THIS LUA IS TRANSLITERATED TO JAVASCRIPT? (the census before any emitter; the banked
-- transliteration arc, [[cartograph-transliteration-arc]], aimed at JS instead of C)
--
--   nvim --headless -u NONE -l tools/jsbreaks.lua <dir> [--files N] [--show CLASS]
--
-- Every site is found by a TREE-SITTER QUERY over every .lua file (declarative — no walker, and every byte of every
-- file is covered, nested and anonymous functions included). Each site lands in a BREAK CLASS, and each class carries
-- whether an ALWAYS-FAITHFUL template exists — faithful for EVERY runtime type, never "right if the inferred type is
-- right" (~10% of inferred types are fabricated: in a code generator that is a miscompile):
--   TEMPLATE   a faithful JS template exists (truthiness, floored %, bit.*, numeric for, ...)
--   PARTIAL    faithful for a derivable subset (a Lua pattern without %b/%f compiles to a RegExp; goto that is the
--              `continue` idiom), refused for the rest
--   NONE       no faithful template (load/loadstring, __gc, yield across a call boundary, ...)
--   DECISION   the answer depends on a REPRESENTATION choice nobody has made (strings as bytes or UTF-16; tables as
--              objects, Maps or arrays) — the census counts the sites so the choice can be made with numbers
--   HOST       an API of the host (vim.*, io.*, os.*): a template per member is DECLARED DATA, or it refuses by name
-- The library table NAMES come from the running Lua (`string`, `_G`), never a list typed here.
-- ★ CONTROLS: every run prints known-nonzero counters (function calls, function definitions) beside the classes, so a
-- uniform zero reads as a broken query, not a clean tree.
local dir = vim.fn.fnamemodify(assert(arg[1], 'usage: jsbreaks.lua <dir> [--show CLASS]'), ':p'):gsub('/$', '')
local show
for i = 2, #arg do if arg[i] == '--show' then show = arg[i + 1] end end
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))

-- derived vocabularies
local STRING_FNS = {}
for k, v in pairs(string) do if type(v) == 'function' then STRING_FNS[k] = true end end
local BASE = {}
for k, v in pairs(_G) do if type(v) == 'function' then BASE[k] = true end end
-- byte-offset string operations: their result or arguments are BYTE positions or byte counts
local OFFSET = { sub = true, find = true, byte = true, len = true, match = true, gmatch = true, gsub = true }

local counts, files_of, sites = {}, {}, {}
local function hit(class, key, rel, row)
    local k = class .. '\t' .. key
    counts[k] = (counts[k] or 0) + 1
    files_of[k] = files_of[k] or {}
    files_of[k][rel] = true
    if show and (class == show or key == show) then sites[#sites + 1] = ('%s:%d  %s'):format(rel, row + 1, key) end
end

local Q = vim.treesitter.query.parse('lua', [[
  (function_call) @call
  (function_definition) @fndef
  (function_declaration) @fndecl
  (function_declaration name: (method_index_expression)) @methoddecl
  (function_call name: (method_index_expression method: (identifier) @m) arguments: (arguments) @margs)
  (function_call name: (dot_index_expression table: (identifier) @lib field: (identifier) @libfn) arguments: (arguments) @largs)
  (function_call name: (identifier) @gfn)
  (dot_index_expression table: (identifier) @vimroot field: (identifier) @vimm (#eq? @vimroot "vim"))
  (dot_index_expression table: (dot_index_expression table: (identifier) @v2 field: (identifier) @vm2 (#eq? @v2 "vim")) field: (identifier) @vf2)
  (unary_expression) @un
  (binary_expression) @bin
  (field name: (identifier) @fkey)
  (bracket_index_expression field: (_) @bkey)
  (goto_statement (identifier) @goto)
  (label_statement) @label
  (repeat_statement) @repeat
  (vararg_expression) @vararg
  (string) @str
  (comment) @comment
  (for_statement clause: (for_generic_clause)) @forin
  (for_statement clause: (for_numeric_clause)) @fornum
]])

local function text(node, src) return vim.treesitter.get_node_text(node, src) end
local function first_arg(args) for c in args:iter_children() do if c:named() and c:type() ~= 'comment' then return c end end end
local function nth_arg(args, n)
    local i = 0
    for c in args:iter_children() do
        if c:named() and c:type() ~= 'comment' then i = i + 1; if i == n then return c end end
    end
end
--- classify a Lua pattern literal: plain text, a RegExp-translatable pattern, or one using %b / %f (no RegExp form)
local function pattern_class(node, src)
    if not node or node:type() ~= 'string' then return 'dynamic pattern (not a literal)' end
    local s = text(node, src)
    if s:find('%%[bf]') then return 'uses %b or %f (no RegExp equivalent)' end
    if s:find('[%^%$%(%)%%%.%[%]%*%+%-%?]') then return 'magic (translatable to RegExp)' end
    return 'plain (no magic characters)'
end

--- is this `goto` the continue idiom: its label is the LAST statement of the innermost loop body enclosing it?
local function continue_idiom(g, src)
    local label = text(g, src)
    local n = g:parent()
    while n do
        local t = n:type()
        if t == 'while_statement' or t == 'for_statement' or t == 'repeat_statement' then
            local body
            for c, f in n:iter_children() do if f == 'body' then body = c end end
            if not body then return false end
            local last
            for c in body:iter_children() do if c:named() and c:type() ~= 'comment' then last = c end end
            return last and last:type() == 'label_statement' and text(last, src):match('::%s*' .. label .. '%s*::') ~= nil
        end
        if t == 'function_definition' or t == 'function_declaration' then return false end
        n = n:parent()
    end
    return false
end

local files = vim.fs.find(function (name) return name:match('%.lua$') end, { path = dir, type = 'file', limit = math.huge })
table.sort(files)
local nfiles, nbytes, nonascii_files = 0, 0, 0
for _, path in ipairs(files) do
    local fd = io.open(path); local src = fd:read('a'); fd:close()
    local rel = path:sub(#dir + 2)
    nfiles, nbytes = nfiles + 1, nbytes + #src
    if src:find('[\128-\255]') then nonascii_files = nonascii_files + 1 end
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
    local tree = ok and parser:parse()[1]
    if not tree then hit('NONE', 'file does not parse', rel, 0) else
    for id, node in Q:iter_captures(tree:root(), src, 0, -1) do
        local cap, row = Q.captures[id], (node:range())
        if cap == 'call' then hit('CONTROL', 'function calls', rel, row)
        elseif cap == 'fndef' or cap == 'fndecl' then hit('CONTROL', 'function definitions', rel, row)
        elseif cap == 'methoddecl' then hit('TEMPLATE', 'method declaration a:b() (implicit self)', rel, row)
        elseif cap == 'm' then
            local m = text(node, src)
            if STRING_FNS[m] then
                hit(OFFSET[m] and 'DECISION' or 'TEMPLATE', ('string method :%s()%s'):format(m, OFFSET[m] and ' — BYTE offsets/counts' or ''), rel, row)
            end
        elseif cap == 'margs' then
            local call = node:parent()
            local mname
            for c, f in call:iter_children() do if f == 'name' then for cc, ff in c:iter_children() do if ff == 'method' then mname = text(cc, src) end end end end
            if mname == 'find' or mname == 'match' or mname == 'gmatch' or mname == 'gsub' then
                local plain = mname == 'find' and nth_arg(node, 3) and text(nth_arg(node, 3), src) == 'true'
                local pc = plain and 'plain=true' or pattern_class(first_arg(node), src)
                hit(pc:find('%%b') and 'NONE' or 'PARTIAL', 'Lua pattern, ' .. pc, rel, row)
            end
        elseif cap == 'libfn' then
            local call = node:parent():parent()
            local lib
            for c, f in node:parent():iter_children() do if f == 'table' then lib = text(c, src) end end
            local fn = text(node, src)
            if lib == 'string' and (fn == 'find' or fn == 'match' or fn == 'gmatch' or fn == 'gsub') then
                local args
                for c, f in call:iter_children() do if f == 'arguments' then args = c end end
                local pc = pattern_class(args and nth_arg(args, 2), src)
                hit(pc:find('%%b') and 'NONE' or 'PARTIAL', 'Lua pattern, ' .. pc, rel, row)
            end
            if lib == 'string' then
                hit(OFFSET[fn] and 'DECISION' or 'TEMPLATE', ('string.%s%s'):format(fn, OFFSET[fn] and ' — BYTE offsets/counts' or ''), rel, row)
            elseif lib == 'coroutine' then hit('PARTIAL', 'coroutine.' .. fn .. ' (a generator; yield across a call boundary refuses)', rel, row)
            elseif lib == 'bit' then hit('TEMPLATE', 'bit.* (JS 32-bit bitwise ops)', rel, row)
            elseif lib == 'table' or lib == 'math' then hit('TEMPLATE', lib .. '.' .. fn, rel, row)
            elseif lib == 'io' or lib == 'os' or lib == 'debug' or lib == 'package' or lib == 'jit' or lib == 'ffi' then
                hit('HOST', lib .. '.' .. fn, rel, row)
            end
        elseif cap == 'gfn' then
            local g = text(node, src)
            if BASE[g] then
                if g == 'load' or g == 'loadstring' or g == 'dofile' or g == 'loadfile' or g == 'setfenv' or g == 'getfenv' then
                    hit('NONE', g .. '() — evaluates Lua source / environments', rel, row)
                elseif g == 'setmetatable' or g == 'getmetatable' or g == 'rawget' or g == 'rawset' or g == 'rawequal' or g == 'rawlen' then
                    hit('PARTIAL', g .. '() — metatables (prototype / Proxy)', rel, row)
                elseif g == 'select' or g == 'unpack' then hit('TEMPLATE', g .. '() (rest / spread)', rel, row)
                elseif g == 'pairs' or g == 'next' then hit('DECISION', g .. '() — iteration over a table representation', rel, row)
                elseif g == 'collectgarbage' then hit('NONE', 'collectgarbage() — the GC is not observable in JS', rel, row)
                elseif g == 'tostring' then hit('PARTIAL', 'tostring() — number formatting %.14g, table addresses', rel, row)
                else hit('TEMPLATE', g .. '()', rel, row) end
            end
        elseif cap == 'vimm' then
            hit('HOST', 'vim.' .. text(node, src), rel, row)
        elseif cap == 'vf2' then
            local m
            for c, f in node:parent():iter_children() do if f == 'table' then for cc, ff in c:iter_children() do if ff == 'field' then m = text(cc, src) end end end end
            hit('HOST.member', ('vim.%s.%s'):format(tostring(m), text(node, src)), rel, row)
        elseif cap == 'un' then
            local op = text(node, src):match('^%s*([#%-]?)') or ''
            if text(node, src):match('^%s*not[%s(]') then hit('TEMPLATE', 'not (truthiness: only nil/false are falsy)', rel, row)
            elseif op == '#' then hit('DECISION', '# length (string BYTES, or a table border)', rel, row) end
        elseif cap == 'bin' then
            local op
            for c, f in node:iter_children() do if not c:named() then op = text(c, src) end end
            if op == 'and' or op == 'or' then hit('TEMPLATE', op .. ' (value-returning, truthiness)', rel, row)
            elseif op == '%' then hit('TEMPLATE', '% (floored modulo)', rel, row)
            elseif op == '..' then hit('PARTIAL', '.. concat (number formatting %.14g)', rel, row)
            elseif op == '~=' then hit('TEMPLATE', '~= (!==)', rel, row)
            elseif op == '^' then hit('TEMPLATE', '^ (Math.pow)', rel, row) end
        elseif cap == 'fkey' then
            local k = text(node, src)
            if k == '__mode' then hit('DECISION', '__mode (weak table: WeakMap / WeakRef)', rel, row)
            elseif k == '__gc' then hit('NONE', '__gc (finalizer)', rel, row)
            elseif k:match('^__') then hit('PARTIAL', 'field named ' .. k .. ' (a metamethod if the table becomes a metatable)', rel, row) end
        elseif cap == 'bkey' then
            local t = node:type()
            hit('DECISION', t == 'string' and 't["literal"] (object key)' or t == 'number' and 't[number] (array index, 1-based)'
                or 't[expr] (key of unknown type: object / Map / array)', rel, row)
        elseif cap == 'goto' then
            if continue_idiom(node, src) then hit('PARTIAL', 'goto — the `continue` idiom (label ends the loop body)', rel, row)
            else hit('NONE', 'goto — general (no JS form)', rel, row) end
        elseif cap == 'label' then hit('CONTROL', 'labels', rel, row)
        elseif cap == 'repeat' then hit('TEMPLATE', 'repeat ... until (the condition sees the body\'s locals)', rel, row)
        elseif cap == 'str' then
            if text(node, src):find('[\128-\255]') then hit('DECISION', 'string LITERAL holding non-ASCII bytes (bytes vs UTF-16 differ on it)', rel, row) end
        elseif cap == 'comment' then
            if text(node, src):find('[\128-\255]') then hit('CONTROL', 'comments holding non-ASCII bytes (no effect on a translation)', rel, row) end
        elseif cap == 'vararg' then hit('TEMPLATE', '... (rest parameters)', rel, row)
        elseif cap == 'forin' then hit('TEMPLATE', 'generic for (iterator triple)', rel, row)
        elseif cap == 'fornum' then hit('TEMPLATE', 'numeric for (bounds evaluated once)', rel, row)
        end
    end
    end
end

-- report: per class, the keys by site count, with the files they occur in
local ORDER = { 'CONTROL', 'NONE', 'DECISION', 'PARTIAL', 'HOST', 'HOST.member', 'TEMPLATE' }
local per = {}
for k, n in pairs(counts) do
    local class, key = k:match('^([^\t]+)\t(.*)$')
    per[class] = per[class] or {}
    local nf = 0
    for _ in pairs(files_of[k]) do nf = nf + 1 end
    per[class][#per[class] + 1] = { key = key, n = n, files = nf }
end
io.write(('jsbreaks over %s: %d .lua file(s), %d bytes, %d with non-ASCII bytes\n'):format(dir, nfiles, nbytes, nonascii_files))
for _, class in ipairs(ORDER) do
    local rows = per[class] or {}
    table.sort(rows, function (a, b) if a.n ~= b.n then return a.n > b.n end return a.key < b.key end)
    local total, distinct = 0, #rows
    for _, r in ipairs(rows) do total = total + r.n end
    io.write(('\n%s — %d site(s), %d distinct\n'):format(class, total, distinct))
    local limit = (class == 'HOST.member') and 25 or 40
    for i = 1, math.min(limit, #rows) do io.write(('  %7d  %4d file(s)  %s\n'):format(rows[i].n, rows[i].files, rows[i].key)) end
    if #rows > limit then io.write(('  … %d more\n'):format(#rows - limit)) end
end
-- the files free of every NONE / DECISION / HOST site: the leaf-ward candidates for a first execution
local blocked = {}
for k in pairs(counts) do
    local class = k:match('^([^\t]+)')
    if class == 'NONE' or class == 'DECISION' or class == 'HOST' or class == 'HOST.member' then
        for f in pairs(files_of[k]) do blocked[f] = true end
    end
end
local free = {}
for _, path in ipairs(files) do local rel = path:sub(#dir + 2); if not blocked[rel] then free[#free + 1] = rel end end
io.write(('\nfiles with no NONE / DECISION / HOST site: %d of %d%s\n'):format(#free, nfiles, #free > 0 and (': ' .. table.concat(free, ' ', 1, math.min(#free, 30))) or ''))
if show then io.write('\nsites of ', show, ':\n'); for _, s in ipairs(sites) do io.write('  ', s, '\n') end end
