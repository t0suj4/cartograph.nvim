-- cartograph.luajs.packmap — WHICH C FUNCTION DOES EACH PACK PRIMITIVE RE-IMPLEMENT? (CART-1211 leaf 2)
--
-- The luajs pack (lua/cartograph/luajs/pack.js) re-implements LuaJIT's runtime in JavaScript; every bug CART-1206's
-- generator found lived in a HAND-WRITTEN re-implementation of a C function that is on disk. This map pairs them, and
-- every pairing is DERIVED from both sides' own text — never a hand list:
--   REGISTRATIONS  LuaJIT's library, read from lib_*.c exactly as its build tool reads it (host/buildvm_lib.c:
--                  LJLIB_MODULE_/CF/ASM/ASM_/LUA/PUSH/SET/NOREG/NOREGUV, the `#if LJ_52/LJ_HASJIT/LJ_HASFFI/LJ_HASBUFFER`
--                  gates) — the configuration read from the ORACLE, the module's run-time name from its LJ_LIB_REG
--   THE ORACLE     the library the running LuaJIT (nvim's — the differential's reference) actually has: a second,
--                  independent reading of the same set, joined against the registrations
--   C BODIES       cartograph's own C extraction (providers.treesitter) of the PREPROCESSED sources — raw LuaJIT C is
--                  macro-defined (`LJLIB_CF(string_format)` becomes `lj_cf_string_format` only after cpp), so the host
--                  compiler expands it first; only lines from the source tree are kept (linemarkers)
--   THE PACK       enumerated at RUN TIME through the pack's own accessor (its `pairs`, which sees the hidden side maps)
--                  under node; each entry's evidence is its source text plus the pack definitions it reaches
-- JOINS, each an evidence kind on the row: `lib` (the qualified name), `mm` (a metamethod name the pack text uses ↔ the
-- C functions whose bodies use MM_<name>), `msg` (a LuaJIT message the pack raises — lj_errmsg.h's ERRDEF text, its
-- longest fixed fragment >= 10 characters — ↔ the C functions that use LJ_ERR_<name>), `cite` (an lj_* name the pack's
-- own text cites that exists in the C graph).
local M = {}

local function readfile(p) local fd = io.open(p, 'rb'); if not fd then return nil end local s = fd:read('a'); fd:close(); return s end

--- LuaJIT's library registrations -> { funcs = { {module, cname, name, kind, noreg, cfn, file, line} },
--- values = { {module, name, file, line} }, modules = { [mod] = { regname, file } } }. `config` gates the `#if` blocks.
function M.registrations(src, config)
    local out = { funcs = {}, values = {}, modules = {} }
    local libnames = {}
    for _, h in ipairs { 'lualib.h', 'luajit.h', 'lua.h' } do
        for name, val in (readfile(src .. '/' .. h) or ''):gmatch('#define%s+([%w_]+)%s+"([^"]*)"') do libnames[name] = val end
    end
    local files = vim.fn.globpath(src, 'lib_*.c', false, true)
    table.sort(files)
    for _, path in ipairs(files) do
        local file = vim.fn.fnamemodify(path, ':t')
        local lines = vim.split(readfile(path) or '', '\n', { plain = true })
        local mod, regfunc, i = nil, nil, 1
        while i <= #lines do
            local line = lines[i]
            local gate = line:match('^#if (LJ_[%w_]+)%s*$')
            if gate and config[gate] ~= nil and not config[gate] then
                -- buildvm: skip to the matching #endif / #else, counting nested #if
                local lvl = 1
                while i < #lines do
                    i = i + 1
                    local l = lines[i]
                    if l:match('^#en') or l:match('^#el') then lvl = lvl - 1; if lvl == 0 then break end
                    elseif l:match('^#if') then lvl = lvl + 1 end
                end
            else
                -- LJ_LIB_REG(L, <regname>, <mod>): the module's run-time name
                local rn, rm = line:match('LJ_LIB_REG%(L,%s*([^,]+),%s*([%w_]+)%)')
                if rn then
                    rn = vim.trim(rn)
                    out.modules[rm] = out.modules[rm] or { file = file }
                    -- (an if, not `rn == 'NULL' and false or …`: that idiom yields the fallback when the middle is false)
                    if rn == 'NULL' then out.modules[rm].regname = false
                    else out.modules[rm].regname = rn:match('^"(.*)"$') or libnames[rn] or rn end
                end
                local p = 1
                while true do
                    local s, e = line:find('LJLIB_', p, true)
                    if not s then break end
                    local rest = line:sub(e + 1)
                    local tag, arg = rest:match('^(MODULE_)([%w_]+)')
                    if not tag then tag, arg = rest:match('^(%u+_?)%(([^)]*)%)') end
                    if not tag then tag = rest:match('^(NOREGUV)') or rest:match('^(NOREG)') end
                    if tag == 'MODULE_' then
                        mod, regfunc = arg, nil
                        out.modules[mod] = out.modules[mod] or { file = file }
                    elseif tag == 'NOREG' or tag == 'NOREGUV' then regfunc = tag
                    elseif tag == 'CF' or tag == 'ASM' or tag == 'ASM_' or tag == 'LUA' then
                        -- libdef_name: the `<module>_` prefix is stripped from the registered name
                        local name = (mod and arg:sub(1, #mod + 1) == mod .. '_') and arg:sub(#mod + 2) or arg
                        out.funcs[#out.funcs + 1] = { module = mod, cname = arg, name = name, kind = tag,
                            noreg = regfunc ~= nil, cfn = tag == 'CF' and ('lj_cf_' .. arg) or tag == 'ASM' and ('lj_ffh_' .. arg) or nil,
                            file = file, line = i }
                        regfunc = nil
                    elseif tag == 'SET' then
                        out.values[#out.values + 1] = { module = mod, name = arg, file = file, line = i }
                    end
                    p = e + 1
                end
            end
            i = i + 1
        end
    end
    return out
end

--- the ORACLE's library, read from THIS process (nvim's LuaJIT is the differential's reference): the modules by
--- run-time name -> { [qualified name] = lua type }. A module registered with a NULL name is found as the loaded table
--- holding ALL its registered names, else it is a frontier (a method table: no global path)
function M.oracle_library(reg)
    local out, where = {}, {}
    local by_mod = {}
    for _, f in ipairs(reg.funcs) do if not f.noreg then by_mod[f.module] = by_mod[f.module] or {}; table.insert(by_mod[f.module], f.name) end end
    for mod, info in pairs(reg.modules) do
        local name = info.regname
        local t
        if name == '_G' then t = _G
        elseif name then t = package.loaded[name] or _G[name]
        else
            for lname, lt in pairs(package.loaded) do
                if type(lt) == 'table' and by_mod[mod] then
                    local all = true
                    for _, n in ipairs(by_mod[mod]) do if lt[n] == nil then all = false; break end end
                    if all then name, t = lname, lt; break end
                end
            end
        end
        where[mod] = name or false
        if type(t) == 'table' then
            for k, v in pairs(t) do
                if type(k) == 'string' then out[(name == '_G' and '' or (name .. '.')) .. k] = type(v) end
            end
        end
    end
    return out, where
end

--- preprocess every LuaJIT .c (the host compiler expands its macros), keeping only lines from `src` itself, into
--- `dir`; then cartograph's C extraction over it -> graph, { [function name] = { node, … } }
function M.c_graph(src, dir, cflags)
    vim.fn.mkdir(dir, 'p')
    local files = vim.fn.globpath(src, '*.c', false, true)
    local failed = {}
    for _, path in ipairs(files) do
        -- the BUILD's own flags (`cflags`, read from LuaJIT's `make -n`): lj_err.c refuses to preprocess without its
        -- -DLUAJIT_UNWIND_EXTERNAL ("Broken build system -- only use the provided Makefiles!")
        local cmd = { 'gcc', '-E' }
        vim.list_extend(cmd, cflags or {})
        vim.list_extend(cmd, { '-I' .. src, path })
        local r = vim.system(cmd, { text = true }):wait()
        if r.code ~= 0 then failed[#failed + 1] = vim.fn.fnamemodify(path, ':t') end
        if r.code == 0 then
            local keep, outl = false, {}
            for line in (r.stdout .. '\n'):gmatch('(.-)\n') do
                local f = line:match('^# %d+ "([^"]+)"')
                if f then keep = f:sub(1, #src) == src or not f:find('/')
                elseif keep then outl[#outl + 1] = line end
            end
            local fd = assert(io.open(dir .. '/' .. vim.fn.fnamemodify(path, ':t'), 'w'))
            fd:write(table.concat(outl, '\n')); fd:close()
        end
    end
    local g = require('cartograph.providers.treesitter').extract(dir)
    local byname = {}
    for _, n in ipairs(g.nodes) do
        if n.kind == 'function' and not n.decl and n.name then byname[n.name] = byname[n.name] or {}; table.insert(byname[n.name], n) end
    end
    return g, byname, failed
end

--- a function node's body text (its file range in the preprocessed dir)
local text_cache = {}
local function body_of(dir, n)
    local lines = text_cache[n.file]
    if not lines then
        lines = vim.split(readfile(dir .. '/' .. n.file) or '', '\n', { plain = true })
        text_cache[n.file] = lines
    end
    local s, e = n.range and n.range.start, n.range and n.range['end']
    if not (s and e) then return '' end
    local out = {}
    for i = (s.line or s[1] or 0) + 1, (e.line or e[1] or 0) + 1 do out[#out + 1] = lines[i] end
    return table.concat(out, '\n')
end
M.body_of = body_of

--- the C call closure of `roots` (function names): callees resolved to definitions in the SAME file first (every
--- preprocessed unit carries its own copies of the headers' static inlines), else the unique definition elsewhere ->
--- { names = set, files = set, ambiguous = n }
function M.c_closure(g, byname, roots)
    local callees = {} -- node id -> { callee names }
    for _, c in ipairs(g.calls or {}) do
        if c.fn and c.callee then callees[c.fn] = callees[c.fn] or {}; table.insert(callees[c.fn], c.callee) end
    end
    local seen, files, amb, queue = {}, {}, 0, {}
    for _, r in ipairs(roots) do for _, n in ipairs(byname[r] or {}) do queue[#queue + 1] = n end end
    while #queue > 0 do
        local n = table.remove(queue)
        if not seen[n.id] then
            seen[n.id] = true
            files[n.file] = true
            for _, cal in ipairs(callees[n.id] or {}) do
                local defs = byname[cal] or {}
                local pick
                for _, d in ipairs(defs) do if d.file == n.file then pick = d end end
                if not pick and #defs == 1 then pick = defs[1] end
                if not pick and #defs > 1 then amb = amb + 1 end
                if pick and not seen[pick.id] then queue[#queue + 1] = pick end
            end
        end
    end
    local names = {}
    for id in pairs(seen) do names[id:match('::([%w_]+)@') or id] = true end
    return { names = names, files = files, ambiguous = amb }
end

--- LuaJIT's messages (lj_errmsg.h ERRDEF) and metamethod names (lj_obj.h MMDEF) -> errs = { [NAME] = text }, mms = set
function M.vocabulary(src)
    local errs, mms = {}, {}
    -- an ERRDEF's text is string literals with LUA_QS / LUA_QL("x") spliced in ("calling " LUA_QS " on bad self"):
    -- rebuilt with each quote macro as a `%s` slot
    for name, args in (readfile(src .. '/lj_errmsg.h') or ''):gmatch('ERRDEF%(([%w_]+),([^\n]*)%)') do
        local parts = {}
        -- luaconf.h: LUA_QL(x) is "'" x "'", LUA_QS is LUA_QL("%s") — expanded as the compiler does
        local toks = {}
        local rest = args
        while #rest > 0 do
            local lit, r1 = rest:match('^%s*"([^"]*)"(.*)$')
            local ql, r2 = rest:match('^%s*LUA_QL%("([^"]*)"%)(.*)$')
            local qs, r3 = rest:match('^%s*(LUA_QS)(.*)$')
            if lit then toks[#toks + 1] = lit; rest = r1
            elseif ql then toks[#toks + 1] = "'" .. ql .. "'"; rest = r2
            elseif qs then toks[#toks + 1] = "'%s'"; rest = r3
            else break end
        end
        parts = toks
        errs[name] = table.concat(parts)
    end
    -- every MMDEF* macro, its WHOLE continued body (a backslash continues the line — MMDEF spans six lines; reading
    -- three lost concat, lt, le and the arithmetic metamethods)
    local obj = (readfile(src .. '/lj_obj.h') or ''):gsub('\\\n', ' ')
    for block in obj:gmatch('#define MMDEF[%w_]*%(_%)([^\n]*)') do
        for mm in block:gmatch('_%(([%w_]+)%)') do mms[mm] = true end
    end
    return errs, mms
end

--- the pack at run time under node: every entry of every module the oracle names, through the pack's own `pairs`,
--- with its function source; the pack's exported primitives -> { entries = { [qname] = {type, text} }, exports = {…} }
function M.pack_runtime(dir, modules)
    local js = [[
const P = require(process.argv[2] + '/$pack.js');
const mods = JSON.parse(process.argv[3]);
const G = P.$G, out = { entries: {}, exports: {}, missing_modules: [] };
const entries = t => { const r = []; const it = P.$all(G.pairs(t)); const f = it[0], s = it[1]; let k;
  for (;;) { const kv = P.$all(f(s, k)); if (kv[0] === undefined) break; k = kv[0]; r.push(kv); } return r; };
for (const [mod, name] of mods) {
  let t;
  if (name === '_G') t = G;
  else { t = P.$idx(G, name.split('.')[0]); for (const part of name.split('.').slice(1)) t = t === undefined ? t : P.$idx(t, part);
         if (t === undefined) try { t = P.$require(name); } catch (e) { t = undefined; } }
  if (t === undefined || P.$type(t) !== 'table') { out.missing_modules.push(name); continue; }
  for (const [k, v] of entries(t)) if (typeof k === 'string')
    out.entries[(name === '_G' ? '' : name + '.') + k] = { type: P.$type(v), text: typeof v === 'function' ? v.toString() : null };
}
for (const [k, v] of Object.entries(P)) if (typeof v === 'function') out.exports[k] = v.toString();
process.stdout.write(JSON.stringify(out));
]]
    local f = dir .. '/$packmap.js'
    local fd = assert(io.open(f, 'w')); fd:write(js); fd:close()
    local r = vim.system({ 'node', f, dir, vim.json.encode(modules) }, { text = true }):wait(120000)
    if r.code ~= 0 then return nil, r.stderr end
    return vim.json.decode(r.stdout)
end

--- the pack's top-level definitions (tree-sitter javascript): name -> text; and which bindings are GENERATED modules
--- (a `require('./$X.js')` whose X.js header says GENERATED) or HOST modules (a require of a non-relative name)
function M.pack_static(pack_path, companion_dir)
    local src = readfile(pack_path) or ''
    local dir = vim.fn.fnamemodify(pack_path, ':h')
    local tree = vim.treesitter.get_string_parser(src, 'javascript'):parse()[1]
    local defs, generated, host = {}, {}, {}
    local function tx(n) return vim.treesitter.get_node_text(n, src) end
    for n in tree:root():iter_children() do
        local t = n:type()
        if t == 'function_declaration' then
            local nm = n:field('name')[1]
            if nm then defs[tx(nm)] = tx(n) end
        elseif t == 'lexical_declaration' or t == 'variable_declaration' then
            for d in n:iter_children() do
                if d:type() == 'variable_declarator' then
                    local nm, val = d:field('name')[1], d:field('value')[1]
                    local vtext = val and tx(val) or ''
                    local names = {}
                    if nm and nm:type() == 'identifier' then names[1] = tx(nm)
                    elseif nm then for id in tx(nm):gmatch('[%w_$]+') do names[#names + 1] = id end end
                    for _, name in ipairs(names) do
                        defs[name] = tx(n)
                        local req = vtext:match("^require%('([^']+)'%)")
                        if req then
                            local rel = req:match('^%./%$([%w_]+)%.js$')
                            if rel then
                                -- the companion AS INSTALLED ($X.js beside the pack being mapped), else the source tree's
                                local head = (readfile((companion_dir or '') .. '/$' .. rel .. '.js') or readfile(dir .. '/' .. rel .. '.js') or ''):sub(1, 200)
                                if head:find('GENERATED', 1, true) then generated[name] = rel end
                            elseif not req:match('^%.') then host[name] = req end
                        end
                    end
                end
            end
        elseif t == 'expression_statement' then
            -- `G.x = …` / `STRING.x = …`: a definition of the member
            local s = tx(n)
            local lhs = s:match('^([%w_$%.]+)%s*=')
            if lhs then defs[lhs] = s end
        end
    end
    return { defs = defs, generated = generated, host = host, text = src }
end

--- the pack-side closure of a text: the top-level definitions it names, transitively -> list of texts, names set
local function pack_closure(static, text)
    local seen, texts, queue = {}, { text }, { text }
    while #queue > 0 do
        local t = table.remove(queue)
        for id in t:gmatch('[%a_$][%w_$]*') do
            if not seen[id] and static.defs[id] and #texts < 400 then
                seen[id] = true
                texts[#texts + 1] = static.defs[id]
                queue[#queue + 1] = static.defs[id]
            end
        end
    end
    return texts, seen
end

--- the implementation kind of a pack closure: transliterated (reaches a GENERATED module binding) · host (reaches a
--- host module or process/Buffer) · refused ($abort) · hand-written
local function kind_of(static, seen, texts)
    local all = table.concat(texts, '\n')
    local names = vim.tbl_keys(seen)
    table.sort(names) -- (the FIRST binding named is reported: a pairs() walk made it differ run to run)
    for _, name in ipairs(names) do if static.generated[name] then return 'transliterated', static.generated[name] end end
    if all:find('$abort(', 1, true) and #texts <= 3 then return 'refused' end
    for _, name in ipairs(names) do if static.host[name] then return 'host', static.host[name] end end
    if all:match('[^%w_]process%.') or all:find('Buffer.', 1, true) then return 'host', 'process/Buffer' end
    return 'hand-written'
end

--- the string literals of a JavaScript text (tree-sitter javascript's string_fragment nodes). A text that is no
--- program — an anonymous `function (f) {…}` from a function's toString — needs no rewrapping: measured, the
--- grammar's error recovery yields the same fragments (a parenthesized fallback was an equivalent mutant)
local js_cache = {}
function M.js_strings(text)
    if js_cache[text] then return js_cache[text] end
    local out = {}
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, 'javascript')
    if ok then
        local root = parser:parse()[1]:root()
        local q = vim.treesitter.query.parse('javascript', '(string_fragment) @f')
        for _, n in q:iter_captures(root, text, 0, -1) do out[#out + 1] = vim.treesitter.get_node_text(n, text) end
    end
    js_cache[text] = out
    return out
end

--- does message `text` (an ERRDEF, `%x` slots) ASSEMBLE from `lits` (a unit's string literals)?
---   a SLOT-FREE text (OPARITH "perform arithmetic on"): some literal holds it — LuaJIT composes it into another
---     message, and the pack writes the composed text in one literal ('attempt to perform arithmetic on a ')
---   a SLOTTED text: the literals COVER every fixed character (longest first; only slots, quotes, spaces left), the
---     text taken as it is or with its FIRST slot filled by one of LuaJIT's own slot-free texts (`fillers`) —
---     "attempt to %s a %s value" with OPCALL's "call" is what 'attempt to call a ' + t + ' value' says
--- At least 10 fixed characters must be covered (quote marks not counted), so "attempt to " never matches alone.
function M.assembles(text, lits, fillers)
    local function fixed(t) return #(t:gsub('%%[%w]', ''):gsub("'", '')) end
    local ls = {}
    for _, l in ipairs(lits) do if #l >= 3 then ls[#ls + 1] = l end end
    table.sort(ls, function (x, y) return #x > #y end)
    if not text:find('%%[%w]') then
        if fixed(text) < 10 then return false end
        for _, l in ipairs(ls) do if l:find(text, 1, true) then return true end end
    end
    local cands = { text }
    for _, f in ipairs(fillers or {}) do
        local s, e = text:find('%%[%w]')
        if s then cands[#cands + 1] = text:sub(1, s - 1) .. f .. text:sub(e + 1) end
    end
    for ci, cand in ipairs(cands) do
        if fixed(cand) >= 10 then
            local rem = cand
            for _, l in ipairs(ls) do
                local s, e = rem:find(l, 1, true)
                while s do rem = rem:sub(1, s - 1) .. '\1' .. rem:sub(e + 1); s, e = rem:find(l, 1, true) end
            end
            -- (the second value: the FILLER it was composed with — that filler's own message is then said too)
            if rem:gsub('%%[%w]', ''):gsub('\1', ''):gsub("[%s']", '') == '' then return true, ci > 1 and fillers[ci - 1] or nil end
        end
    end
    return false
end

--- MESSAGE-LEVEL compatibility of an ERRDEF `text` with one `new LuaError(<arg>)` (the arguments node `args` in
--- `src`): the arg's TEMPLATE is its literals in order with every non-literal operand a HOLE. LuaJIT nests its messages
--- ("bad argument #%d to '%s' (%s)" holds a whole "%s expected, got %s") and the pack puts holes where LuaJIT has
--- fixed text ("'for' " + what + " must be a number"), so either side's wildcards may absorb the other's text:
--- compatible when the pack template (holes as `X`) matches the ERRDEF's pattern (slots as `.-`), or the ERRDEF
--- text (slots as `X`) matches the pack's pattern (holes as `.-`) — and >= 10 fixed characters on the ERRDEF side
function M.compatible(text, args, src)
    if #(text:gsub('%%[%w]', ''):gsub("'", '')) < 10 then return false end
    -- flatten the argument into literal / hole pieces (a `+` chain; anything else is one hole)
    local pieces = {}
    local function flat(node)
        local t = node:type()
        if t == 'string' then
            local s = {}
            for c in node:iter_children() do if c:type() == 'string_fragment' or c:type() == 'escape_sequence' then s[#s + 1] = vim.treesitter.get_node_text(c, src) end end
            pieces[#pieces + 1] = { lit = table.concat(s) }
        elseif t == 'binary_expression' and vim.treesitter.get_node_text(node:child(1), src) == '+' then
            flat(node:named_child(0)); flat(node:named_child(1))
        elseif t == 'parenthesized_expression' then flat(node:named_child(0))
        else pieces[#pieces + 1] = { hole = true } end
    end
    local first = args:named_child(0)
    if not first then return false end
    flat(first)
    local packstr, packpat = {}, {}
    for _, p in ipairs(pieces) do
        packstr[#packstr + 1] = p.lit or 'X'
        packpat[#packpat + 1] = p.lit and vim.pesc(p.lit) or '.-'
    end
    local errpat = {}
    local rest = text
    while #rest > 0 do
        local s, e = rest:find('%%[%w]')
        if not s then errpat[#errpat + 1] = vim.pesc(rest); break end
        errpat[#errpat + 1] = vim.pesc(rest:sub(1, s - 1)) .. '.-'
        rest = rest:sub(e + 1)
    end
    local P = table.concat(packstr)
    if P:match('^' .. table.concat(errpat) .. '$') then return true end
    return (text:gsub('%%[%w]', 'X')):match('^' .. table.concat(packpat) .. '$') ~= nil
end

--- the joins of one pack closure's text against the C vocabulary -> { mm = {mm…}, msg = {ERR…}, cite = {lj_…} }
local function evidence(texts, errs, mms, byname)
    local all = table.concat(texts, '\n')
    local ev = { mm = {}, msg = {}, cite = {} }
    -- the string literals, as JAVASCRIPT's grammar reads them (a quote regex paired an apostrophe in a comment —
    -- "LuaJIT's" — with the next quote, and every literal after it was misread)
    local lits = {}
    for _, t in ipairs(texts) do for _, s in ipairs(M.js_strings(t)) do lits[#lits + 1] = s end end
    for _, s in ipairs(lits) do
        local mm = s:match('^__([%w_]+)$')
        if mm and mms[mm] then ev.mm[mm] = true end
    end
    local fillers = {}
    for _, t in pairs(errs) do if not t:find('%%[%w]') and #t <= 24 then fillers[#fillers + 1] = t end end
    table.sort(fillers)
    local by_text = {}
    for name, text in pairs(errs) do by_text[text] = name end
    for name, text in pairs(errs) do
        local yes, filler = M.assembles(text, lits, fillers)
        if yes then
            ev.msg[name] = true
            -- a message COMPOSED with a filler ("attempt to %s a %s value" + OPCALL's "call") says the filler's
            -- message too — measured: OPCALL/OPINDEX were reported unsaid, being under the 10-character floor alone
            if filler and by_text[filler] then ev.msg[by_text[filler]] = true end
        end
    end
    for id in all:gmatch('(lj_[%w_]+)') do if byname[id] then ev.cite[id] = true end end
    return ev
end

--- the MAP -> { rows, summary, frontiers, meta }. opts: { src (the oracle's LuaJIT src), pack_dir (install_pack'd),
--- pack_path (the pack.js to read statically), work (a scratch dir), config, rev }
function M.build(opts)
    local reg = M.registrations(opts.src, opts.config)
    local oracle, where = M.oracle_library(reg)
    local errs, mms = M.vocabulary(opts.src)
    local g, byname, pp_failed = M.c_graph(opts.src, opts.work .. '/pp', opts.cflags)
    -- the C functions using each MM_/LJ_ERR_ name (from their bodies)
    local mm_users, err_users = {}, {}
    for name, defs in pairs(byname) do
        for _, n in ipairs(defs) do
            local b = body_of(opts.work .. '/pp', n)
            for mm in b:gmatch('MM_([%w_]+)') do if mms[mm] then mm_users[mm] = mm_users[mm] or {}; mm_users[mm][name] = true end end
            for e in b:gmatch('LJ_ERR_([%w_]+)') do err_users[e] = err_users[e] or {}; err_users[e][name] = true end
        end
    end
    -- the INTERPRETER's C boundary: every `extern` the VM of this architecture calls (vm_<arch>.dasc) — the pack follows
    -- the interpreter, so a candidate the VM calls ranks first (the JIT recorder's and the FFI's copies of the same
    -- metamethod logic do not)
    local arch = ({ x86_64 = 'x64', aarch64 = 'arm64' })[vim.uv.os_uname().machine] or vim.uv.os_uname().machine
    local vm_extern = {}
    for name in (readfile(opts.src .. '/vm_' .. arch .. '.dasc') or ''):gmatch('extern%s+([%w_]+)') do vm_extern[name] = true end
    local mods = {}
    for mod, name in pairs(where) do if name then mods[#mods + 1] = { mod, name } end end
    table.sort(mods, function (a, b) return a[2] < b[2] end)
    local pack, why = M.pack_runtime(opts.pack_dir, mods)
    if not pack then return nil, 'the pack did not enumerate under node: ' .. tostring(why) end
    local static = M.pack_static(opts.pack_path, opts.pack_dir)
    local function sorted(set) local l = vim.tbl_keys(set); table.sort(l); return l end
    -- the C functions an evidence set names -> { [fn] = 'mm:x msg:Y cite' }; `via` marks evidence found only in the
    -- pack definitions a unit REACHES (its closure), not in its own text — ranked below direct evidence
    local function users(ev, via)
        local c = {}
        local p = via and '~' or ''
        -- (SORTED: the evidence string is part of the report, and a pairs() walk made it differ run to run)
        for _, mm in ipairs(sorted(ev.mm)) do for f in pairs(mm_users[mm] or {}) do c[f] = (c[f] or '') .. ' ' .. p .. 'mm:' .. mm end end
        for _, e in ipairs(sorted(ev.msg)) do for f in pairs(err_users[e] or {}) do c[f] = (c[f] or '') .. ' ' .. p .. 'msg:' .. e end end
        for _, f in ipairs(sorted(ev.cite)) do c[f] = (c[f] or '') .. ' ' .. p .. 'cite' end
        return c
    end
    --- direct evidence (the unit's own text) + via evidence (its closure minus its own text), merged
    local function matches(own, texts)
        local d = evidence({ own }, errs, mms, byname)
        local all = evidence(texts, errs, mms, byname)
        local v = { mm = {}, msg = {}, cite = {} }
        for k, set in pairs(all) do for x in pairs(set) do if not d[k][x] then v[k][x] = true end end end
        local c = users(d, false)
        for f, why in pairs(users(v, true)) do c[f] = (c[f] or '') .. why end
        for f in pairs(c) do if vm_extern[f] then c[f] = c[f] .. ' vm' end end
        return c, d, all
    end
    local rows, frontiers = {}, {}
    for _, f in ipairs(reg.funcs) do
        if not f.noreg then
            local rname = where[f.module]
            if rname == false or rname == nil then
                frontiers[#frontiers + 1] = ('%s.%s (%s: registered with no global name — a method table)'):format(f.module, f.name, f.file)
            else
                local q = (rname == '_G' and '' or (rname .. '.')) .. f.name
                local e = pack.entries[q]
                local row = { qname = q, lj_kind = f.kind, cfn = f.cfn, lj_file = f.file, oracle = oracle[q] ~= nil,
                    pack = e ~= nil }
                if e and e.text then
                    local texts, seen = pack_closure(static, e.text)
                    row.pack_kind, row.pack_via = kind_of(static, seen, texts)
                    local cm, ev = matches(e.text, texts)
                    row.evidence = { mm = sorted(ev.mm), msg = sorted(ev.msg), cite = sorted(ev.cite) }
                    row.c_matches = cm
                    row._pseen = seen
                elseif e then row.pack_kind = 'value' end
                if f.cfn and byname[f.cfn] then
                    local cl = M.c_closure(g, byname, { f.cfn })
                    row.c_closure = { size = vim.tbl_count(cl.names), files = sorted(cl.files), ambiguous = cl.ambiguous }
                    row._cset = cl.names
                end
                rows[#rows + 1] = row
            end
        end
    end
    -- the pack's PRIMITIVES (its exports): the same evidence joins
    local prims = {}
    for name, text in pairs(pack.exports) do
        local own = (static.defs[name] or '') .. '\n' .. text
        local texts, seen = pack_closure(static, own)
        local cm, ev, evall = matches(own, texts)
        local kind, via = kind_of(static, seen, texts)
        -- the primitive's C side: the closure of its DIRECT matches the VM calls (the interpreter's own handlers)
        local seeds = {}
        for f, why in pairs(cm) do
            -- a DIRECT evidence token (not `~` closure evidence, and not the `vm` tag itself)
            local direct = false
            for tok in why:gmatch('%S+') do if tok ~= 'vm' and tok:sub(1, 1) ~= '~' then direct = true end end
            if why:find(' vm', 1, true) and direct then seeds[#seeds + 1] = f end
        end
        table.sort(seeds)
        local cl = #seeds > 0 and M.c_closure(g, byname, seeds) or nil
        -- the messages the interpreter's handler (and what it calls) can raise that this unit NEVER assembles: a
        -- message drift at its source (LuaJIT names the variable — BADOPRT — where the pack says BADOPRV: CART-1207)
        local unassembled = {}
        if cl then
            for e, fns in pairs(err_users) do
                local reach = false
                for f in pairs(fns) do if cl.names[f] then reach = true; break end end
                if reach and not evall.msg[e] then unassembled[#unassembled + 1] = e end
            end
            table.sort(unassembled)
        end
        prims[#prims + 1] = { name = name, pack_kind = kind, pack_via = via,
            evidence = { mm = sorted(ev.mm), msg = sorted(ev.msg), cite = sorted(ev.cite) }, c_matches = cm,
            handlers = seeds, unassembled = unassembled, _pseen = seen, _cset = cl and cl.names or nil }
    end
    table.sort(prims, function (a, b) return a.name < b.name end)
    -- CO-OCCURRENCE (weak evidence, labelled as such): a pack HELPER no name or message links — `$numstr` — aligned with
    -- the C functions present in the C closure of EVERY unit whose pack closure uses it, and in NO unit's that does not
    local units = {}
    for _, r in ipairs(rows) do if r._pseen and r._cset then units[#units + 1] = r end end
    for _, p in ipairs(prims) do if p._pseen and p._cset then units[#units + 1] = p end end
    local uses = {}
    for _, u in ipairs(units) do for h in pairs(u._pseen) do uses[h] = (uses[h] or 0) + 1 end end
    -- SPECIFICITY: of the units whose C closure holds f, the share that use h — 1.0 is "in every unit using h, in no
    -- other" (strict); `$numstr` measured 0 strict candidates (lj_strfmt_num also sits in unrelated closures through
    -- generic formatting paths), so candidates are RANKED: in every unit using h, then by specificity
    local holders = {}
    for _, u in ipairs(units) do for f in pairs(u._cset) do holders[f] = (holders[f] or 0) + 1 end end
    local aligned = {}
    for h, n in pairs(uses) do
        if n >= 2 then
            local inter
            for _, u in ipairs(units) do
                if u._pseen[h] then
                    if not inter then inter = vim.deepcopy(u._cset)
                    else for f in pairs(inter) do if not u._cset[f] then inter[f] = nil end end end
                end
            end
            local cand = {}
            for f in pairs(inter or {}) do cand[#cand + 1] = { f = f, spec = n / holders[f] } end
            table.sort(cand, function (x, y) if x.spec ~= y.spec then return x.spec > y.spec end return x.f < y.f end)
            if cand[1] and cand[1].spec >= 0.5 then
                local top = {}
                for i = 1, math.min(3, #cand) do
                    if cand[i].spec >= 0.5 then top[#top + 1] = { f = cand[i].f, spec = math.floor(cand[i].spec * 100 + 0.5) / 100 } end
                end
                aligned[h] = { units = n, c = top }
            end
        end
    end
    -- UBIQUITOUS messages: raised somewhere in MOST primitives' handler closures (out of memory, stack overflow, …) —
    -- not specific to any one, so split out of each primitive's `unassembled` into one list
    local reach, np = {}, 0
    for _, p in ipairs(prims) do
        if p.handlers and #p.handlers > 0 then
            np = np + 1
            for _, e in ipairs(p.unassembled) do reach[e] = (reach[e] or 0) + 1 end
        end
    end
    local ubiquitous = {}
    for e, c in pairs(reach) do if c > np / 2 then ubiquitous[e] = true end end
    for _, p in ipairs(prims) do
        local keep = {}
        for _, e in ipairs(p.unassembled or {}) do if not ubiquitous[e] then keep[#keep + 1] = e end end
        p.unassembled = keep
    end
    for _, u in ipairs(units) do u._pseen, u._cset = nil, nil end
    for _, r in ipairs(rows) do r._pseen, r._cset = nil, nil end
    -- the pack's messages that are NO LuaJIT message (drift: CART-1207's class) — the SAME reader as the joins: each
    -- `new LuaError(<arg>)`'s literals (all of them, the parts it concatenates) must assemble some ERRDEF (with the
    -- fillers), else it is drift; reported as its literals joined by `…`
    local fillers = {}
    for _, t in pairs(errs) do if not t:find('%%[%w]') and #t <= 24 then fillers[#fillers + 1] = t end end
    table.sort(fillers)
    local drift = {}
    local lq = vim.treesitter.query.parse('javascript', '(new_expression constructor: (identifier) @c (#eq? @c "LuaError") arguments: (arguments) @a)')
    local fq = vim.treesitter.query.parse('javascript', '(string_fragment) @f')
    local ltree = vim.treesitter.get_string_parser(static.text, 'javascript'):parse()[1]
    for id, n in lq:iter_captures(ltree:root(), static.text, 0, -1) do
        if lq.captures[id] == 'a' then
            local parts = {}
            for _, f in fq:iter_captures(n, static.text, 0, -1) do parts[#parts + 1] = vim.treesitter.get_node_text(f, static.text) end
            local joined = table.concat(parts, '…')
            if #table.concat(parts) >= 10 then
                local known = false
                for _, text in pairs(errs) do
                    if M.assembles(text, parts, fillers) or M.compatible(text, n, static.text) then known = true; break end
                end
                if not known then drift[joined] = true end
            end
        end
    end
    local summary = { lj = 0, oracle = 0, pack = 0, missing = {}, extra = 0, by_kind = {}, lj_kinds = {} }
    for _, r in ipairs(rows) do
        summary.lj = summary.lj + 1
        if r.oracle then summary.oracle = summary.oracle + 1 end
        if r.pack then summary.pack = summary.pack + 1 else summary.missing[#summary.missing + 1] = r.qname end
        summary.lj_kinds[r.lj_kind] = (summary.lj_kinds[r.lj_kind] or 0) + 1
        if r.pack_kind then summary.by_kind[r.pack_kind] = (summary.by_kind[r.pack_kind] or 0) + 1 end
    end
    -- registrations the oracle lacks and oracle names no registration explains: the two readings disagree
    local regset = {}
    for _, r in ipairs(rows) do regset[r.qname] = true end
    local oracle_only = {}
    for q, ty in pairs(oracle) do if ty == 'function' and not regset[q] then oracle_only[#oracle_only + 1] = q end end
    table.sort(oracle_only)
    local not_in_oracle = {}
    for _, r in ipairs(rows) do if not r.oracle then not_in_oracle[#not_in_oracle + 1] = r.qname end end
    table.sort(summary.missing)
    return { rows = rows, prims = prims, summary = summary, frontiers = frontiers, oracle_only = oracle_only,
        not_in_oracle = not_in_oracle, missing_modules = pack.missing_modules, drift = sorted(drift), aligned = aligned, ubiquitous = sorted(ubiquitous),
        meta = { rev = opts.rev, config = opts.config, c_functions = vim.tbl_count(byname), modules = where,
            pp_failed = pp_failed, cflags = opts.cflags } }
end

return M
