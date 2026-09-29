-- cartograph.luajs.boundary — WHERE DOES LuaJIT's C STOP BEING TRANSLITERABLE FOR THE PACK? (CART-1211 leaf 4)
--
-- The pack holds Lua values as JS values; LuaJIT's C holds them as the VM's own GC objects. A C function is at the
-- BOUNDARY when its own body reads a GC object's fields, casts to one, walks over one or holds one by value — cjs
-- (exact heap mode, `opts.opaque` = the GC types) refuses exactly those uses as kind 'boundary', naming the type.
-- Every other refusal is a cjs GAP (a construct cjs does not carry yet). The rest is CLEAN, and a function whose
-- whole call closure is clean is a TRANSLITERATION CANDIDATE — the work order for the pack's hand-written code.
--
-- Nothing is listed by hand: the GC types are the structs holding the fields of LuaJIT's own `#define GCHeader`
-- (lj_obj.h), plus any struct/union holding one BY VALUE (GCobj, global_State); the C is the build's own preprocessing
-- (its make's flags); the amalgamation unit (a .c that includes .c files) is left out, as it redefines everything.
local M = {}

local C = require 'cartograph.cjs'

local function readfile(p) local fd = io.open(p, 'rb'); if not fd then return nil end local s = fd:read('a'); fd:close(); return s end

--- every compilation unit of `src`, preprocessed as the build does (cflags from its make), attributes defined away
--- (tree-sitter's C grammar cannot parse one before `=`) -> { {text, name} }, { skipped names }
function M.preprocess(src, cflags)
    local out, skipped = {}, {}
    for _, path in ipairs(vim.fn.globpath(src, '*.c', false, true)) do
        local name = vim.fn.fnamemodify(path, ':t')
        local raw = readfile(path) or ''
        if raw:find('#include%s+"[%w_]+%.c"') then
            skipped[#skipped + 1] = name .. ' (an amalgamation: it includes .c units)'
        else
            local cmd = { 'gcc', '-E', '-P', '-D__attribute__(x)=' }
            vim.list_extend(cmd, cflags or {})
            vim.list_extend(cmd, { '-I' .. src, path })
            local r = vim.system(cmd, { text = true }):wait()
            if r.code == 0 then out[#out + 1] = { text = r.stdout, name = name }
            else skipped[#skipped + 1] = name .. ' (does not preprocess)' end
        end
    end
    return out, skipped
end

--- the GC object types: structs holding every field of `#define GCHeader` (read from src/lj_obj.h), then — to a fixed
--- point — any struct/union holding one of them BY VALUE -> { [tag] = true }, the header's field names
function M.gc_types(sources, src)
    local hdr = readfile(src .. '/lj_obj.h') or ''
    local body = hdr:match('#define%s+GCHeader%s+([^\n]+)')
    if not body then return nil, 'no `#define GCHeader` in lj_obj.h' end
    local fields = {}
    for seg in body:gmatch('[^;]+') do local f = seg:match('([%a_][%w_]*)%s*$'); if f then fields[#fields + 1] = f end end
    local unit
    for _, s in ipairs(sources) do if s.name == 'lj_obj.c' then unit = s end end
    unit = unit or sources[1]
    local tree = vim.treesitter.get_string_parser(unit.text, 'c'):parse()[1]
    local q = vim.treesitter.query.parse('c', [[
        [(struct_specifier name: (type_identifier) @n body: (field_declaration_list) @b)
         (union_specifier name: (type_identifier) @n body: (field_declaration_list) @b)] ]])
    local defs = {} -- tag -> { field name set, member type names by value }
    local nm
    for id, node in q:iter_captures(tree:root(), unit.text, 0, -1) do
        if q.captures[id] == 'n' then nm = vim.treesitter.get_node_text(node, unit.text)
        else
            local d = { names = {}, by_value = {} }
            for fd in node:iter_children() do
                if fd:type() == 'field_declaration' then
                    local ty = fd:field('type')[1]
                    for _, dec in ipairs(fd:field('declarator')) do
                        if dec:type() == 'field_identifier' then
                            d.names[vim.treesitter.get_node_text(dec, unit.text)] = true
                            if ty then d.by_value[#d.by_value + 1] = (vim.treesitter.get_node_text(ty, unit.text):gsub('^%a+%s+', '')) end
                        end
                    end
                end
            end
            defs[nm] = d
        end
    end
    local gc = {}
    for tag, d in pairs(defs) do
        local all = true
        for _, f in ipairs(fields) do if not d.names[f] then all = false end end
        if all then gc[tag] = true end
    end
    local grew = true
    while grew do
        grew = false
        for tag, d in pairs(defs) do
            if not gc[tag] then
                for _, t in ipairs(d.by_value) do if gc[t] then gc[tag] = true; grew = true; break end end
            end
        end
    end
    return gc, fields
end

--- the VM ASSEMBLY the C calls, read from vm_x64.dasc (no C body exists): its templates, one line each, backed by
--- lua/cartograph/luajs/fpu.js (tests/luajs_spec.lua holds their oracles). Shared by the strscan recipe and the probe.
M.VM_ASM = {
    lj_vm_num2int_check = '$num2int_check($1)',
}

--- the heap LAYOUT of every non-GC struct/union lj_obj.h defines (TValue, SBuf, Node, MRef, …), from the COMPILER
--- (cartograph.cjs.compiler_layout) -> { [typedef name] = layout }, { names that did not lay out }
function M.layouts(sources, src, cflags, gc)
    local unit
    for _, s in ipairs(sources) do if s.name == 'lj_obj.c' then unit = s end end
    unit = unit or sources[1]
    local tree = vim.treesitter.get_string_parser(unit.text, 'c'):parse()[1]
    local q = vim.treesitter.query.parse('c', '(type_definition type: [(union_specifier body: (_)) (struct_specifier body: (_))] declarator: (type_identifier) @n)')
    local heap, failed = {}, {}
    for _, node in q:iter_captures(tree:root(), unit.text, 0, -1) do
        local nm = vim.treesitter.get_node_text(node, unit.text)
        if not gc[nm] and not heap[nm] then
            local l = C.compiler_layout({ src = unit.text, type = nm, header = 'lj_obj.h', include = src, cflags = cflags })
            if l then heap[nm] = l else failed[#failed + 1] = nm end
        end
    end
    table.sort(failed)
    return heap, failed
end

--- every `sizeof(<type>)` any unit asks, answered by the compiler through lj_obj.h (a type it does not define is
--- skipped: its sizeof stays a named gap) -> { [type text] = bytes }
function M.sizes(sources, src, cflags)
    local q = vim.treesitter.query.parse('c', '(sizeof_expression type: (type_descriptor) @t)')
    local seen, types = {}, {}
    for _, s in ipairs(sources) do
        local tree = vim.treesitter.get_string_parser(s.text, 'c'):parse()[1]
        for _, node in q:iter_captures(tree:root(), s.text, 0, -1) do
            local ty = vim.trim(vim.treesitter.get_node_text(node, s.text))
            if not seen[ty] then seen[ty] = true; types[#types + 1] = ty end
        end
    end
    table.sort(types)
    return C.compiler_sizes({ types = types, header = 'lj_obj.h', include = src, cflags = cflags }) or {}
end

--- the probe: one exact-heap emit over every unit from `roots`, the GC types opaque, refusals attributed to their
--- function. opts: { sources, roots, gc, heap_types, sizes, templates } -> {
---   functions = { [name] = { own = 'clean'|'boundary'|'gap', refusals = { [kind] = n }, why = { first whys },
---                            calls = { callee names }, dirty_via = the boundary/gap function its closure reaches } },
---   order = { names } }
function M.probe(opts)
    local _, refusals, info = C.emit(opts.sources, { exact = true, roots = opts.roots, opaque = opts.gc,
        heap = { types = opts.heap_types or {} }, sizes = opts.sizes, templates = opts.templates })
    local F = {}
    for _, name in ipairs(info.functions) do F[name] = { own = 'clean', refusals = {}, why = {}, calls = (info.calls or {})[name] or {}, lines = (info.lines or {})[name] or 0 } end
    for _, r in ipairs(refusals) do
        local f = r.fn and F[r.fn]
        if f then
            f.refusals[r.kind] = (f.refusals[r.kind] or 0) + 1
            if r.kind == 'boundary' then f.own = 'boundary' elseif f.own == 'clean' then f.own = 'gap' end
            if #f.why < 4 and not vim.tbl_contains(f.why, r.why) then f.why[#f.why + 1] = r.why end
        end
    end
    -- the CLOSURE: a function is dirty when it, or anything it calls, is not clean — `dirty_via` names the first
    -- non-clean function reached (to a fixed point: call cycles)
    local changed = true
    for name, f in pairs(F) do if f.own ~= 'clean' then f.dirty_via = name; f.dirty = true end end
    while changed do
        changed = false
        for _, name in ipairs(info.functions) do
            local f = F[name]
            if not f.dirty then
                for _, c in ipairs(f.calls) do
                    local g = F[c]
                    if g and g.dirty then f.dirty = true; f.dirty_via = g.dirty_via; changed = true; break end
                end
            end
        end
    end
    return { functions = F, order = info.functions, refusals = #refusals }
end

--- the functions that NEVER RETURN — the VM's error raisers (lj_err_msg, lj_err_argt, …): every macro whose
--- definition says `noreturn` (lj_def.h: LJ_NORET, and LJ_FUNC_NORET through it), then every declaration using one,
--- read from the tree's headers and units -> { [name] = true }. A primitive's COMPUTATION is its closure short of
--- these: the raise path (message formatting included) is the VM's, reached by nearly every function
function M.noreturn(src)
    local files = vim.fn.globpath(src, '*.h', false, true)
    vim.list_extend(files, vim.fn.globpath(src, '*.c', false, true))
    local texts = {}
    for _, p in ipairs(files) do texts[#texts + 1] = readfile(p) or '' end
    local all = table.concat(texts, '\n')
    -- (declarations are read with every #define line removed: a definition itself is no declaration)
    local decls = ('\n' .. all):gsub('\n[ \t]*#[^\n]*', '\n')
    local macros, grew = {}, true
    for m, def in all:gmatch('#define%s+([%w_]+)%s+([^\n]*)') do if def:find('noreturn', 1, true) then macros[m] = true end end
    while grew do
        grew = false
        for m, def in all:gmatch('#define%s+([%w_]+)%s+([^\n]*)') do
            if not macros[m] then
                for id in def:gmatch('[%a_][%w_]*') do if macros[id] then macros[m] = true; grew = true; break end end
            end
        end
    end
    local out = {}
    for m in pairs(macros) do
        for decl in decls:gmatch('%f[%w_]' .. m .. '%f[^%w_]([^;{#]-)%(') do
            local name = decl:match('([%a_][%w_]*)%s*$')
            if name then out[name] = true end
        end
    end
    return out
end

--- the C functions a GENERATED companion emits: every top-level `function NAME(` of the module (its adapter's own
--- entry points too — they name no LuaJIT function, so they never match) -> { [name] = module }
function M.generated(files)
    local out = {}
    for mod, path in pairs(files) do
        local text = readfile(path) or ''
        if text:sub(1, 400):find('GENERATED', 1, true) then
            for nm in ('\n' .. text):gmatch('\nfunction ([%w_$]+)%(') do out[nm] = out[nm] or mod end
        end
    end
    return out
end

--- a registered function's place against the boundary. `gen` = M.generated; `ubiq` = cores too common to decide a
--- kind (reached by most rows: the error and formatting machinery) -> {
---   own = its own status, via = the non-clean function its closure reaches first,
---   covered = generated functions in its closure, cores = its MAXIMAL clean cores not generated (a clean function
---   whose caller in the closure is not clean, or the root itself) — the transliteration work it still holds,
---   kind = 'transliterated' (covered, no core left) | 'partial' | 'hand-written' (cores, none covered) |
---          'boundary' (nothing below the boundary to transliterate) }
function M.classify(P, root, gen, ubiq, noret)
    local F = P.functions
    if not F[root] then return nil end
    local cl = M.closure(P, root, noret)
    local covered, below = {}, {}
    for f in pairs(cl) do if gen[f] then covered[#covered + 1] = f; for g in pairs(M.closure(P, f, noret)) do below[g] = true end end end
    local callers = {}
    for f in pairs(cl) do for _, c in ipairs(F[f].calls) do callers[c] = callers[c] or {}; callers[c][f] = true end end
    local cores = {}
    for f in pairs(cl) do
        if not F[f].dirty and not below[f] and not (ubiq and ubiq[f]) then
            local maximal = f == root
            for c in pairs(callers[f] or {}) do if F[c].dirty then maximal = true end end
            if maximal then cores[#cores + 1] = f end
        end
    end
    table.sort(covered); table.sort(cores)
    -- each core's WEIGHT: the source lines of its (clean) closure — a two-line accessor is not work, a scanner is
    local weight = {}
    for _, c in ipairs(cores) do
        local w = 0
        for g in pairs(M.closure(P, c, noret)) do w = w + (F[g].lines or 0) end
        weight[c] = w
    end
    local kind = #covered > 0 and (#cores == 0 and 'transliterated' or 'partial') or (#cores > 0 and 'hand-written' or 'boundary')
    return { own = F[root].own, via = F[root].dirty_via, covered = covered, cores = cores, weight = weight, kind = kind }
end

--- a function's call closure within the probe, not descending into `stop` (M.noreturn) -> set of names
function M.closure(P, root, stop)
    local seen, queue = {}, { root }
    while #queue > 0 do
        local n = table.remove(queue)
        if not seen[n] and P.functions[n] and not (stop and stop[n] and n ~= root) then
            seen[n] = true
            for _, c in ipairs(P.functions[n].calls) do queue[#queue + 1] = c end
        end
    end
    return seen
end

return M
