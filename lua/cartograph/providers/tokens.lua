-- The token provider: stack languages (Forth, PostScript) produce the
-- neutral schema WITHOUT tree-sitter. These languages cannot have a
-- faithful grammar even in principle — Forth's parsing words mutate the
-- syntax at runtime — but everything cartograph needs is token-level
-- convention: a definer table, literal-name mentions, load-order binding.
--
-- Honesty posture (v1):
--   · defs come from definer words only; a word conjured dynamically
--     (EXECUTE on a computed xt, PostScript cvx/exec) is simply absent —
--     an honest frontier, not a guess.
--   · conditional compilation ([IF]/[IFUNDEF]) is NOT evaluated: both
--     branches' defs exist, and Forth's own semantics (redefinition
--     shadows for subsequent uses) make nearest-preceding-def the
--     correct same-file binding either way.
--   · cross-file: unique def matches (~ inferred); several files
--     defining one name is a CANDIDATE SET — refused with the
--     candidates, never picked from.
--   · volume discipline (the at-ranges lesson): every token is a call
--     site here (1.7M tokens in openfirmware), so occurrences ride
--     DEDUPED edges with a capped-but-counted at list (e.atn = truth),
--     and unresolved/ambiguous mentions AGGREGATE per (file, name) —
--     capabilities.calls declares the shape.

local M = {}

local MAX_AT = 8 -- occurrences kept per edge; e.atn carries the full count

M.DIALECTS = {
    forth = {
        exts = { fs = true, ['4th'] = true, fth = true },
        ci = true, -- traditional Forth finds DUP and dup alike
        -- definer word -> kind of the word it defines (name = NEXT token)
        definers = {
            [':'] = 'function', code = 'function', defer = 'function',
            synonym = 'function', alias = 'function',
            variable = 'var', ['2variable'] = 'var', fvariable = 'var',
            cvariable = 'var', constant = 'var', ['2constant'] = 'var',
            fconstant = 'var', value = 'var', ['2value'] = 'var',
            fvalue = 'var', create = 'var', ['buffer:'] = 'var',
            user = 'var', vocabulary = 'var', ['field:'] = 'var',
        },
        enders = { [';'] = ':', ['end-code'] = 'code' },
        -- next token is a WORD REFERENCE, not a call
        tickers = { ["'"] = true, ["[']"] = true, postpone = true },
        -- next token is WRITTEN (value/defer stores)
        writers = { to = true, is = true },
        imports = { include = true, require = true, needs = true,
            fload = true },
        -- tokens that CONSUME the next token for parsing (skip both)
        eaters = { char = true, ['[char]'] = true },
    },
    postscript = {
        exts = { ps = true },
        ci = false,
        ps = true, -- structurally different: /name … def, brace procs
    },
}

M.ext_dialect = {}
for dname, d in pairs(M.DIALECTS) do
    for e in pairs(d.exts) do M.ext_dialect[e] = dname end
end

-- ── tokenizers ─────────────────────────────────────────────────────────
-- Both return { {t=, l=, c=}, ... } (0-based line, byte col). Comments
-- and string CONTENTS are dropped here; stack-effect comments are a v2
-- concern and will hang off the def site, not the token stream.

local function forth_tokens(src)
    local out, l = {}, 0
    local incomment = false -- an unclosed ( … comment spans lines
    for line in (src .. '\n'):gmatch('(.-)\n') do
        local c = 1
        if incomment then
            local close = line:find(')', 1, true)
            if close then
                incomment = false
                c = close + 1
            else
                c = #line + 1
            end
        end
        while true do
            local s, e = line:find('%S+', c)
            if not s then break end
            local t = line:sub(s, e)
            -- \ comments to EOL — and so do gforth's \G doc comments
            if t == '\\' or t:lower() == '\\g' then break end
            if t == '(' or t == '.(' then
                local close = line:find(')', e + 1, true)
                if not close then
                    incomment = true
                    break
                end
                c = close + 1
            elseif #t > 1 and t:sub(-1) == '"' then
                -- s" ." c" abort" s\" …: string runs to the next "
                local close = line:find('"', e + 1, true)
                out[#out + 1] = { t = t, l = l, c = s - 1 }
                if not close then break end
                c = close + 1
            else
                out[#out + 1] = { t = t, l = l, c = s - 1 }
                c = e + 1
            end
        end
        l = l + 1
    end
    return out
end

local function ps_tokens(src)
    local out, l = {}, 0
    local instr, depth = false, 0 -- (…) strings NEST in PostScript
    for line in (src .. '\n'):gmatch('(.-)\n') do
        local i, len = 1, #line
        while i <= len do
            local ch = line:sub(i, i)
            if instr then
                if ch == '(' then depth = depth + 1
                elseif ch == ')' then
                    depth = depth - 1
                    if depth == 0 then instr = false end
                elseif ch == '\\' then i = i + 1 end
                i = i + 1
            elseif ch == '%' then
                break -- comment to EOL (incl. %% DSC lines)
            elseif ch == '(' then
                instr, depth = true, 1
                i = i + 1
            elseif ch == '<' and line:sub(i + 1, i + 1) ~= '<' then
                local close = line:find('>', i + 1, true) -- hex string
                i = close and close + 1 or len + 1
            elseif ch:match('%s') then
                i = i + 1
            elseif ch == '{' or ch == '}' or ch == '[' or ch == ']' then
                out[#out + 1] = { t = ch, l = l, c = i - 1 }
                i = i + 1
            elseif line:sub(i, i + 1) == '<<' or line:sub(i, i + 1) == '>>' then
                out[#out + 1] = { t = line:sub(i, i + 1), l = l, c = i - 1 }
                i = i + 2
            else
                -- a name runs to the next delimiter; /name keeps its slash
                local j = ch == '/' and i + 1 or i
                local k = j
                while k <= len
                    and not line:sub(k, k):match('[%s%(%)<>{}%[%]/%%]') do
                    k = k + 1
                end
                if k > j then
                    out[#out + 1] = { t = line:sub(i, k - 1), l = l, c = i - 1 }
                    i = k
                else
                    i = i + 1 -- lone delimiter-ish char: skip
                end
            end
        end
        l = l + 1
    end
    return out
end

-- ── extraction ─────────────────────────────────────────────────────────

local function is_forth_number(t)
    return t:match('^%-?%d[%d%.,]*$') or t:match('^%$%-?%x+$')
        or t:match('^#%-?%d+$') or t:match('^%%[01]+$')
        or t:match("^'.'$")
end

local function is_ps_number(t)
    return t:match('^%-?[%d%.]+$') or t:match('^%-?%d+%.%d*[eE]') ~= nil
        or t:match('^%d+#%x+$')
end

function M.extract(root, opts)
    local uv = vim.uv or vim.loop
    local data = { schema = 1, root = root, provider = 'tokens',
        capabilities = { calls = 'aggregated' },
        nodes = {}, edges = {}, calls = {}, stamps = {} }
    local nodes, edges, calls = data.nodes, data.edges, data.calls
    local abs = (opts and opts.abs) or function (f) return root .. '/' .. f end

    -- file discovery (or an explicit list, mirroring ts.extract)
    local files = opts and opts.files
    if not files then
        files = {}
        local function scan(dir, rel)
            local fs = uv.fs_scandir(dir)
            while fs do
                local name, ty = uv.fs_scandir_next(fs)
                if not name then break end
                if name:sub(1, 1) ~= '.' then
                    local r = rel and (rel .. '/' .. name) or name
                    if ty == 'directory' then
                        scan(dir .. '/' .. name, r)
                    else
                        local ext = name:match('%.([^%.]+)$')
                        if ext and M.ext_dialect[ext:lower()] then
                            files[#files + 1] = r
                        end
                    end
                end
            end
        end
        scan(root)
        table.sort(files)
    end

    local fileset = {}
    for _, f in ipairs(files) do fileset[f] = true end

    -- per-file: defs (in token order), mentions, imports
    local roster = {}       -- key -> { def node, ... } in discovery order
    local perfile = {}      -- file -> { defs = {..}, mentions = {..} }

    local function add_def(file, name, kind, l, c, el, dialect)
        local id = ('%s::%s@%d'):format(file, name, l)
        local node = { id = id, name = name, kind = kind, file = file,
            order = l, range = { start = { line = l, char = c },
                ['end'] = { line = el or l, char = 0 } } }
        nodes[#nodes + 1] = node
        local key = dialect.ci and name:lower() or name
        roster[key] = roster[key] or {}
        table.insert(roster[key], node)
        table.insert(perfile[file].defs, node)
        return node
    end

    for _, file in ipairs(files) do
        local fd = io.open(abs(file), 'r')
        local src = fd and fd:read('a')
        if fd then fd:close() end
        perfile[file] = { defs = {}, mentions = {}, imports = {} }
        nodes[#nodes + 1] = { id = file, name = file, kind = 'module',
            file = file, order = -1,
            range = { start = { line = 0, char = 0 },
                ['end'] = { line = 0, char = 0 } } }
        local st = uv.fs_stat(abs(file))
        if st then
            data.stamps[file] = ('%d:%d:%d')
                :format(st.mtime.sec, st.mtime.nsec or 0, st.size)
        end
        if src then
            local ext = file:match('%.([^%.]+)$')
            local dname = M.ext_dialect[ext and ext:lower() or '']
            local dialect = M.DIALECTS[dname]
            local pf = perfile[file]
            pf.dialect = dialect
            if dialect.ps then
                -- ── PostScript: /name {…} def | /name … def ──
                local toks = ps_tokens(src)
                local i, ndef = 1, nil
                local opendefs = {} -- named procs by token span
                while i <= #toks do
                    local tk = toks[i]
                    local t = tk.t
                    if t:sub(1, 1) == '/' and #t > 1 then
                        local nm = t:sub(2)
                        -- find the matching def for this literal
                        local j, d2 = i + 1, 0
                        local isproc = toks[i + 1] and toks[i + 1].t == '{'
                        while j <= #toks do
                            local u = toks[j].t
                            if u == '{' then d2 = d2 + 1
                            elseif u == '}' then d2 = d2 - 1
                            elseif d2 == 0 and u == 'def' then break
                            elseif d2 == 0 and u:sub(1, 1) == '/' and #u > 1 then
                                j = nil; break -- next literal first: no def
                            end
                            j = j + 1
                        end
                        if j and j <= #toks then
                            local node = add_def(file, nm,
                                isproc and 'function' or 'var',
                                tk.l, tk.c, toks[j].l, dialect)
                            if isproc then
                                opendefs[#opendefs + 1] =
                                    { node = node, s = i + 1, e = j,
                                        locals = {} }
                            end
                            ndef = j -- mentions between i and j belong here
                            _ = ndef
                        end
                    end
                    i = i + 1
                end
                -- locals: /x … def INSIDE a proc body binds locally —
                -- suppress those names within that proc (boundness lite)
                for _, od in ipairs(opendefs) do
                    for k = od.s, od.e do
                        local u = toks[k].t
                        if u:sub(1, 1) == '/' and #u > 1 then
                            od.locals[u:sub(2)] = true
                        end
                    end
                end
                -- mentions: bare names, attributed to the innermost
                -- enclosing named proc (token-span containment)
                for k, tk2 in ipairs(toks) do
                    local t2 = tk2.t
                    if t2:sub(1, 1) ~= '/' and t2 ~= '{' and t2 ~= '}'
                        and t2 ~= '[' and t2 ~= ']' and t2 ~= '<<'
                        and t2 ~= '>>' and not is_ps_number(t2) then
                        local from, best
                        for _, od in ipairs(opendefs) do
                            if k > od.s and k < od.e
                                and (not best or od.s > best.s) then
                                best = od
                            end
                        end
                        if best and best.locals[t2] then goto skip end
                        from = best and best.node
                        pf.mentions[#pf.mentions + 1] =
                            { name = t2, l = tk2.l, c = tk2.c,
                                from = from and from.id }
                        ::skip::
                    end
                end
            else
                -- ── Forth: definer tables + a colon-def range stack ──
                local toks = forth_tokens(src)
                local open -- the current : … ; definition
                local i = 1
                while i <= #toks do
                    local tk = toks[i]
                    local key = tk.t:lower()
                    local kind = dialect.definers[key]
                    if kind and toks[i + 1] then
                        local nm = toks[i + 1].t
                        local node = add_def(file, nm, kind, toks[i + 1].l,
                            toks[i + 1].c, nil, dialect)
                        if dialect.enders[';'] and (key == ':' or key == 'code') then
                            if open then open.node.range['end'].line = tk.l end
                            open = { node = node, opener = key }
                        end
                        if key == 'synonym' or key == 'alias' then
                            -- SYNONYM new old: old is a mention
                            if toks[i + 2] then
                                pf.mentions[#pf.mentions + 1] =
                                    { name = toks[i + 2].t, l = toks[i + 2].l,
                                        c = toks[i + 2].c, from = node.id }
                                i = i + 1
                            end
                        end
                        i = i + 2
                    elseif dialect.enders[key] then
                        if open then
                            open.node.range['end'].line = tk.l
                            open = nil
                        end
                        i = i + 1
                    elseif dialect.imports[key] and toks[i + 1] then
                        pf.imports[#pf.imports + 1] = toks[i + 1].t
                        i = i + 2
                    elseif dialect.eaters[key] and toks[i + 1] then
                        i = i + 2 -- char X / [char] X: X is data
                    elseif dialect.tickers[key] and toks[i + 1] then
                        local nx = toks[i + 1]
                        pf.mentions[#pf.mentions + 1] =
                            { name = nx.t, l = nx.l, c = nx.c,
                                from = open and open.node.id }
                        i = i + 2
                    elseif dialect.writers[key] and toks[i + 1] then
                        local nx = toks[i + 1]
                        pf.mentions[#pf.mentions + 1] =
                            { name = nx.t, l = nx.l, c = nx.c,
                                from = open and open.node.id, write = true }
                        i = i + 2
                    else
                        -- punctuation IS identity in Forth (+! @ , are
                        -- words) — only numbers and string openers skip
                        if not is_forth_number(tk.t)
                            and tk.t:sub(-1) ~= '"' then
                            pf.mentions[#pf.mentions + 1] =
                                { name = tk.t, l = tk.l, c = tk.c,
                                    from = open and open.node.id }
                        end
                        i = i + 1
                    end
                end
                if open then
                    open.node.range['end'].line =
                        toks[#toks] and toks[#toks].l or 0
                end
            end
        end
    end

    -- ── imports (Forth include/require/fload) ──
    local impEdge = {}
    for file, pf in pairs(perfile) do
        for _, path in ipairs(pf.imports or {}) do
            local dir = file:match('^(.*)/[^/]*$')
            local cand = dir and (dir .. '/' .. path) or path
            -- normalize ./ and ../
            local parts = {}
            for seg in cand:gmatch('[^/]+') do
                if seg == '..' then parts[#parts] = nil
                elseif seg ~= '.' then parts[#parts + 1] = seg end
            end
            cand = table.concat(parts, '/')
            local target = fileset[cand] and cand
                or fileset[path] and path or nil
            if target and target ~= file then
                local k = file .. '\31' .. target
                if not impEdge[k] then
                    impEdge[k] = true
                    edges[#edges + 1] =
                        { from = file, to = target, kind = 'import' }
                end
            end
        end
    end

    -- ── resolution: literal names against the roster ──
    -- same-file nearest-preceding def = Forth's actual redefinition
    -- semantics (matched); same-file following def = forward use (~);
    -- unique elsewhere = ~ ; several files = a candidate set, refused.
    local refEdge, regEdge = {}, {}
    local unres, ambig = {}, {} -- (file:name) aggregation
    local function emit(from, node, m, inferred, file)
        local kind = node.kind == 'var' and 'use' or 'ref'
        local src_id = from or file
        local ek = src_id .. '\31' .. node.id .. '\31' .. kind
        local reg = not from
        local book = reg and regEdge or refEdge
        local e = book[ek]
        if not e then
            e = { from = src_id, to = node.id,
                kind = reg and 'reg' or kind, at = {}, atn = 0,
                inferred = inferred or nil,
                self = (src_id == node.id) or nil }
            book[ek] = e
            edges[#edges + 1] = e
        end
        if not inferred then e.inferred = nil end
        e.atn = e.atn + 1
        if e.atn <= MAX_AT then
            e.at[#e.at + 1] = { start = { line = m.l, char = m.c },
                ['end'] = { line = m.l, char = m.c + #m.name } }
        end
    end
    for _, file in ipairs(files) do
        local pf = perfile[file]
        local dialect = pf.dialect
        for _, m in ipairs(pf.mentions) do
            local key = (dialect and dialect.ci) and m.name:lower() or m.name
            local cands = roster[key]
            if cands then
                -- same-file: nearest def at-or-before the mention line
                local same, fwd
                for _, n in ipairs(cands) do
                    if n.file == file then
                        if n.order <= m.l then
                            if not same or n.order > same.order then
                                same = n
                            end
                        elseif not fwd or n.order < fwd.order then
                            fwd = n
                        end
                    end
                end
                if same and same.id ~= m.from then
                    emit(m.from, same, m, false, file)
                elseif fwd and fwd.id ~= m.from then
                    emit(m.from, fwd, m, true, file)
                else
                    -- cross-file: count DEFINING FILES, not defs — one
                    -- file redefining a word is a chain, not ambiguity
                    local byfile, nfiles, last = {}, 0, nil
                    for _, n in ipairs(cands) do
                        if not byfile[n.file] then
                            byfile[n.file] = true
                            nfiles = nfiles + 1
                        end
                        last = n
                    end
                    if same then
                        -- only candidate was the mention's own def site
                    elseif nfiles == 1 then
                        emit(m.from, last, m, true, file)
                    else
                        local ak = file .. '\31' .. key
                        local a = ambig[ak]
                        if not a then
                            a = { file = file, callee = m.name, n = 0,
                                line = m.l,
                                refused = { rule = 'ambiguous',
                                    cands = cands } }
                            ambig[ak] = a
                            calls[#calls + 1] = a
                        end
                        a.n = a.n + 1
                    end
                end
            else
                -- not in the corpus at all: stdlib/primitive/external —
                -- outside the graph, aggregated per (file, name)
                local uk = file .. '\31' .. key
                local u = unres[uk]
                if not u then
                    u = { file = file, callee = m.name, n = 0, line = m.l }
                    unres[uk] = u
                    calls[#calls + 1] = u
                end
                u.n = u.n + 1
            end
        end
    end

    return data
end

return M
