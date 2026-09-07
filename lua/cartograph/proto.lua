-- The protobuf/gRPC contract adapter: a `.proto` file is a DECLARED
-- CROSS-SERVICE CONTRACT, so it joins the graph the way django's URL routes and
-- symfony's yaml routes do — a session POST-PASS that mints nodes into an
-- already-extracted graph, re-derived per open/refresh, never persisted (nodes
-- marked `pb`). CART-0824.
--
-- ★★★ WHY AN ADAPTER AND NOT A SPEC OR A PROVIDER, decided against the tree
-- rather than by preference:
--   · A SECOND PROVIDER IS DISQUALIFIED BY init.lua:410-435. The token provider
--     (forth/postscript) is ONE ROOT, ONE PROVIDER: a MIXED root opens through
--     tree-sitter and the dialect files are EXCLUDED with a warning, because
--     "the two providers make different promises about calls". Every root that
--     matters here is mixed — microservices-demo is go + python + java + js
--     BESIDE its protos — so a provider-shaped reader would be excluded from
--     exactly the graphs the contract has to appear in.
--   · A TREE-SITTER SPEC costs a `proto.so` parser this machine does not have,
--     and claiming a new extension is an EXTRACTION-BEHAVIOUR change: cache
--     VERSION bump plus a gate re-save across 37 corpora. All to run a pipeline
--     that is empty for a declarative IDL — a .proto file has no calls, no
--     control flow and no data flow. It buys nothing and costs the whole gate.
--   · THE ADAPTER FAMILY IS ALREADY THE HOUSE ANSWER FOR A DECLARED CONTRACT:
--     routes (django/symfony), handlers (ansible), tables (sql/dblink).
-- ⚠ THE SPEC BECOMES RIGHT if .proto files should ever be FIRST-CLASS PERSISTED
-- MODULES — browsable, foldable, cached — rather than a contract overlay. This
-- does not foreclose that: the node ids are SITE-ANCHORED in the house format
-- (`file::name@line`), so they survive the migration unchanged.
--
-- ★★ WHAT IS A NODE, AND WHAT DELIBERATELY IS NOT. `validate.NODE_KINDS` is
-- module / function / method / var / region / external — there is no `type`, and
-- a java CLASS is not a node either: it is the qualifier on its methods' names.
-- So this follows java exactly rather than inventing a shape:
--     a .proto FILE   -> a `module` node (as ansible's yaml and symfony's twig do)
--     an `rpc`        -> a `method` node named `Service::Rpc`
--     a `service`     -> NOT a node; it is the qualifier, like a java class
--     a `message`/`enum` -> NOT a node; they are TYPES, and java's are not nodes
--                        either. The request/response type names ride on the rpc
--                        node as fields, which is what a join keys on.
-- ⚠ AND NOTHING HERE MINTS `kind = 'var'`, which is the point. kb
-- `synthetic-var-node-families` records that the four existing adapters all mint
-- vars and that atlas.lua:265 excludes only two of the six families, so django
-- routes and ansible handlers are counted as program variables and classified on
-- the WRITE AXIS (landing on `const`, inflating the dead-state lint's
-- population). A contract declaration is not a variable; minting it as one would
-- be joining a known wart.
--
-- HONESTY POSTURE:
--   · the reader REFUSES LOUDLY AND COUNTS. `stats.refused` plus a capped sample
--     of sites is part of the attach report, because a declarative reader that
--     silently skips what it does not understand reports a clean contract. (The
--     hrldistill lesson: its first cut refused 48 of 168 VISIBLY, and that
--     visibility is the only reason the gap was ever found.)
--   · VENDORED COPIES ARE NOT DEDUPLICATED HERE. microservices-demo carries
--     `demo.proto` three times inside src/ plus a fourth CartService in
--     `Cart.proto`, and each copy is a real declaration at a real site. The
--     per-site node is the fact; aggregating by qualified name is the JOIN's
--     job (CART-0821), and doing it here would destroy the evidence that the
--     copies exist.

local M = {}
local transport = require 'cartograph.transport'

-- ── THE SCANNER ────────────────────────────────────────────────────────────
-- A token stream, because the grammar needs it: an rpc declaration may wrap
-- across lines, `option (x) = { ... }` carries a brace body, and a `//` inside a
-- string literal is not a comment. A line-pattern reader gets each of those
-- wrong, and gets them wrong SILENTLY.

local PUNCT = { ['{'] = true, ['}'] = true, ['('] = true, [')'] = true,
    ['='] = true, [';'] = true, [','] = true, ['<'] = true, ['>'] = true,
    ['['] = true, [']'] = true }

--- Tokenize proto source. Returns a list of { v = text, k = 'id'|'str'|'p', line }
--- (0-based lines, the house convention), or nil + reason.
function M.lex(src)
    local toks, i, n, line = {}, 1, #src, 0
    while i <= n do
        local c = src:sub(i, i)
        if c == '\n' then line = line + 1; i = i + 1
        elseif c == ' ' or c == '\t' or c == '\r' then i = i + 1
        elseif c == '/' and src:sub(i + 1, i + 1) == '/' then
            local nl = src:find('\n', i, true)
            i = nl or (n + 1)
        elseif c == '/' and src:sub(i + 1, i + 1) == '*' then
            local e = src:find('*/', i + 2, true)
            if not e then return nil, 'unterminated block comment' end
            for _ in src:sub(i, e):gmatch('\n') do line = line + 1 end
            i = e + 2
        elseif c == '"' or c == "'" then
            -- a string, and its contents are NOT scanned: `option go_package =
            -- "github.com/.../x"` holds a `//` that is not a comment
            local j, q = i + 1, c
            while j <= n do
                local d = src:sub(j, j)
                if d == '\\' then j = j + 2
                elseif d == q then break
                elseif d == '\n' then return nil, 'unterminated string' end
                j = j + 1
            end
            if j > n then return nil, 'unterminated string' end
            toks[#toks + 1] = { v = src:sub(i + 1, j - 1), k = 'str', line = line }
            i = j + 1
        elseif PUNCT[c] then
            toks[#toks + 1] = { v = c, k = 'p', line = line }
            i = i + 1
        else
            -- an identifier, a dotted/qualified name, or a number
            local s, e = src:find('^[%w_%.%-%+]+', i)
            if not s then
                -- an unknown byte: skip it rather than loop forever, and let the
                -- parser's refusal counter be the thing that reports the damage
                i = i + 1
            else
                toks[#toks + 1] = { v = src:sub(s, e), k = 'id', line = line }
                i = e + 1
            end
        end
    end
    return toks
end

-- ── THE PARSER ─────────────────────────────────────────────────────────────

--- Read one .proto source. Returns
---   { package, imports = {path...}, services = { {name, line,
---       rpcs = { {name, line, req, resp, stream_in, stream_out} } } },
---     messages = {qualified names}, enums = {...}, refused = N,
---     refusals = { 'line:token' ... } }
--- ★ EVERY UNRECOGNISED DECLARATION IS COUNTED, and the first few are sampled.
--- The one thing a reader for a declarative language must never do is skip
--- quietly: a contract it half-read reports as a contract that is half-empty.
function M.parse(src)
    local toks, lerr = M.lex(src)
    if not toks then return nil, lerr end
    local p, N = 1, #toks
    local out = { imports = {}, services = {}, messages = {}, enums = {},
        refused = 0, refusals = {} }
    local function peek(k) local t = toks[p + (k or 0)]; return t end
    local function tv(k) local t = peek(k); return t and t.v end
    local function refuse(t)
        out.refused = out.refused + 1
        if #out.refusals < 8 then
            out.refusals[#out.refusals + 1] =
                ('%d:%s'):format((t and t.line or 0) + 1, t and t.v or '?')
        end
    end
    -- skip a balanced { } block starting at the next `{`; returns false if
    -- there is none (an unbalanced file, which is a refusal, not a crash)
    local function skip_block()
        while p <= N and tv() ~= '{' and tv() ~= ';' do p = p + 1 end
        if tv() == ';' then p = p + 1; return true end
        if tv() ~= '{' then return false end
        local depth = 0
        while p <= N do
            local v = tv()
            if v == '{' then depth = depth + 1
            elseif v == '}' then depth = depth - 1
                if depth == 0 then p = p + 1; return true end end
            p = p + 1
        end
        return false
    end
    local function skip_to_semi()
        -- an `option (x) = { ... };` body is balanced, so a naive scan to `;`
        -- would stop inside it
        while p <= N do
            local v = tv()
            if v == ';' then p = p + 1; return true end
            if v == '{' then if not skip_block() then return false end
            else p = p + 1 end
        end
        return false
    end

    -- an rpc: `rpc Name ( [stream] Type ) returns ( [stream] Type ) ( {…} | ; )`
    local function rpc(svc)
        local kw = peek()
        p = p + 1 -- 'rpc'
        local nm = peek()
        if not nm or nm.k ~= 'id' then refuse(kw); return nil end
        p = p + 1
        local function arg()
            if tv() ~= '(' then return nil end
            p = p + 1
            local stream = false
            if tv() == 'stream' then stream = true; p = p + 1 end
            local ty = peek()
            if not ty or ty.k ~= 'id' then return nil end
            p = p + 1
            if tv() ~= ')' then return nil end
            p = p + 1
            return ty.v, stream
        end
        local req, sin = arg()
        if not req then refuse(kw); return nil end
        if tv() ~= 'returns' then refuse(kw); return nil end
        p = p + 1
        local resp, sout = arg()
        if not resp then refuse(kw); return nil end
        if not skip_block() then refuse(kw); return nil end
        return { name = nm.v, line = nm.line, req = req, resp = resp,
            stream_in = sin or nil, stream_out = sout or nil, service = svc }
    end

    local function service()
        p = p + 1 -- 'service'
        local nm = peek()
        if not nm or nm.k ~= 'id' or tv(1) ~= '{' then refuse(nm); return end
        p = p + 2
        local svc = { name = nm.v, line = nm.line, rpcs = {} }
        while p <= N and tv() ~= '}' do
            local v = tv()
            if v == 'rpc' then
                local r = rpc(svc.name)
                if r then svc.rpcs[#svc.rpcs + 1] = r end
            elseif v == 'option' then
                if not skip_to_semi() then break end
            elseif v == ';' then p = p + 1
            else refuse(peek()); p = p + 1 end
        end
        p = p + 1 -- '}'
        out.services[#out.services + 1] = svc
    end

    -- a message/enum body, recursed only to collect QUALIFIED nested names —
    -- fields are deliberately not read (descendable-data is a separate arc)
    local function typedecl(kw, prefix)
        p = p + 1
        local nm = peek()
        if not nm or nm.k ~= 'id' then refuse(nm); return end
        p = p + 1
        local q = prefix and (prefix .. '.' .. nm.v) or nm.v
        local bucket = kw == 'enum' and out.enums or out.messages
        bucket[#bucket + 1] = { name = q, line = nm.line }
        if tv() == ';' then p = p + 1; return end -- a forward declaration
        if tv() ~= '{' then refuse(nm); return end
        p = p + 1
        local depth = 1
        while p <= N and depth > 0 do
            local v = tv()
            if v == 'message' or v == 'enum' then
                typedecl(v, q)
            elseif v == '{' then depth = depth + 1; p = p + 1
            elseif v == '}' then depth = depth - 1; p = p + 1
            else p = p + 1 end
        end
    end

    while p <= N do
        local v = tv()
        if v == 'syntax' or v == 'option' or v == 'edition' then
            if not skip_to_semi() then refuse(peek()); break end
        elseif v == 'package' then
            p = p + 1
            local nm = peek()
            if nm and nm.k == 'id' then out.package = nm.v else refuse(nm) end
            if not skip_to_semi() then break end
        elseif v == 'import' then
            p = p + 1
            if tv() == 'public' or tv() == 'weak' then p = p + 1 end
            local s = peek()
            if s and s.k == 'str' then out.imports[#out.imports + 1] = s.v
            else refuse(s) end
            if not skip_to_semi() then break end
        elseif v == 'service' then service()
        elseif v == 'message' or v == 'enum' then typedecl(v, nil)
        elseif v == 'extend' then
            p = p + 1
            if not skip_block() then break end
        elseif v == ';' then p = p + 1
        else refuse(peek()); p = p + 1 end
    end
    return out
end

-- ── ENUMERATION ────────────────────────────────────────────────────────────
-- ⚠ `.proto` is claimed by no spec, so these files are NOT in the extraction
-- walk's output and this has to find them itself. It is the FOURTH such scan
-- (ansible.lua:166, symfony, django), and each of the other three hardcodes its
-- own directory-exclusion list — ansible's is `molecule / node_modules / .git /
-- collections`, which is neither the walk's EXCLUDE_DIRS nor anyone else's.
-- This one reads the WALK's set (`ts.EXCLUDE_DIRS`) so the rule has one home,
-- and reads directories through the transport rather than fs_scandir so a
-- non-disk substrate behaves. Unifying the four scans is CART-0817's, not this
-- ticket's.
function M.find(root, tp)
    tp = tp or transport
    local ts = require 'cartograph.providers.treesitter'
    local ex = ts.EXCLUDE_DIRS or {}
    local out = {}
    local function rec(rel)
        for name, t in tp.dir(rel == '' and root or (root .. '/' .. rel)) do
            if name:sub(1, 1) ~= '.' then
                local r = rel == '' and name or (rel .. '/' .. name)
                if t == 'directory' then
                    if not ex[name:lower()] then rec(r) end
                elseif name:match('%.proto$') then
                    out[#out + 1] = r
                end
            end
        end
    end
    rec('')
    table.sort(out) -- an artifact field: order is output (CART-0790)
    return out
end

-- ── ATTACH ─────────────────────────────────────────────────────────────────

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function at(line)
    return { start = { line = line, char = 0 }, ['end'] = { line = line, char = 0 } }
end

--- Mint the contract into `data`. Idempotent under refresh: a previous
--- attachment is stripped first, the way symfony/django do.
--- Returns stats (never nil), and sets `data.proto` to them.
function M.attach(data, opts)
    local stats = { files = 0, services = 0, rpcs = 0, messages = 0, enums = 0,
        imports = 0, refused = 0, refusals = {}, unreadable = {},
        by_qname = {}, qnames = 0 }
    if not data or not data.root then data.proto = nil; return stats end

    -- strip a previous attachment (idempotent under refresh)
    local pbids, nodes = {}, {}
    for _, n in ipairs(data.nodes or {}) do
        if n.pb then pbids[n.id] = true else nodes[#nodes + 1] = n end
    end
    if next(pbids) then
        local edges = {}
        for _, e in ipairs(data.edges or {}) do
            if not (e.pb or pbids[e.from] or pbids[e.to]) then edges[#edges + 1] = e end
        end
        data.nodes, data.edges = nodes, edges
    end

    local files = (opts and opts.files) or M.find(data.root, opts and opts.transport)
    if #files == 0 then data.proto = nil; return stats end
    data.nodes = data.nodes or {}
    data.edges = data.edges or {}

    -- file -> its module node id, so an `import` can become an edge when the
    -- target is inside this root (and stay a disclosed frontier when it is not)
    local have = {}
    for _, f in ipairs(files) do have[f] = true end

    local parsed = {}
    for _, rel in ipairs(files) do
        local src = (opts and opts.transport or transport).read
            and select(1, (opts and opts.transport or transport).read(data.root .. '/' .. rel))
        if type(src) ~= 'string' then
            local fd = io.open(data.root .. '/' .. rel, 'r')
            src = fd and fd:read('a') or nil
            if fd then fd:close() end
        end
        if type(src) ~= 'string' then
            stats.unreadable[#stats.unreadable + 1] = rel
        else
            local r, perr = M.parse(src)
            if not r then
                stats.unreadable[#stats.unreadable + 1] = rel .. ' (' .. tostring(perr) .. ')'
            else
                parsed[rel] = r
                stats.files = stats.files + 1
                stats.refused = stats.refused + r.refused
                for _, s in ipairs(r.refusals) do
                    if #stats.refusals < 12 then
                        stats.refusals[#stats.refusals + 1] = rel .. ':' .. s
                    end
                end
            end
        end
    end

    for _, rel in ipairs(files) do
        local r = parsed[rel]
        if r then
            -- the FILE is a module node, as ansible's yaml and symfony's twig are
            data.nodes[#data.nodes + 1] = { id = rel, name = rel, kind = 'module',
                file = rel, range = R0, order = 0, pb = 'file',
                pkg = r.package }
            for _, imp in ipairs(r.imports) do
                stats.imports = stats.imports + 1
                -- an import RESOLVES only inside this root; one that points out
                -- of it (`google/protobuf/timestamp.proto`) is a frontier and
                -- gets no edge rather than a fabricated one
                local tgt = have[imp] and imp
                    or (have[rel:gsub('[^/]+$', '') .. imp] and rel:gsub('[^/]+$', '') .. imp)
                if tgt then
                    data.edges[#data.edges + 1] =
                        { from = rel, to = tgt, kind = 'import', pb = true }
                end
            end
            stats.messages = stats.messages + #r.messages
            stats.enums = stats.enums + #r.enums
            for _, svc in ipairs(r.services) do
                stats.services = stats.services + 1
                for _, rp in ipairs(svc.rpcs) do
                    stats.rpcs = stats.rpcs + 1
                    -- ★ SITE-ANCHORED, house format `file::name@line`. The three
                    -- vendored copies of demo.proto each declare CartService, so
                    -- a name-keyed id would collide and silently last-win; the
                    -- per-site node is the fact, and aggregating by QUALIFIED
                    -- NAME is the join's job (CART-0821).
                    local name = svc.name .. '::' .. rp.name
                    local qname = (r.package and (r.package .. '.') or '')
                        .. svc.name .. '/' .. rp.name
                    -- ★★★ THE WIRE PATH IS THE IDENTITY, and it is a LITERAL in
                    -- the generated code on both sides: grpc-go emits
                    -- `CartService_AddItem_FullMethodName = "/hipstershop.
                    -- CartService/AddItem"` and grpc-python passes the same
                    -- string to `channel.unary_unary(...)`. So the join key is
                    -- not a NAME MATCH on `AddItem` — which is ambiguous across
                    -- nine services — but the exact string the runtime itself
                    -- dispatches on. Same lesson as the XMPP boundary, where
                    -- joining by macro NAME found 8 pairs and joining by URI
                    -- found 30, a different set. Carried as its own field
                    -- because the leading `/` is part of the gRPC spec's method
                    -- path, not a formatting choice this code gets to make.
                    local wire = '/' .. qname
                    data.nodes[#data.nodes + 1] = {
                        id = ('%s::%s@%d'):format(rel, name, rp.line),
                        name = name, kind = 'method', file = rel,
                        range = at(rp.line), order = rp.line,
                        pb = 'rpc', pkg = r.package, service = svc.name,
                        qname = qname, wire = wire, req = rp.req, resp = rp.resp,
                        stream_in = rp.stream_in, stream_out = rp.stream_out,
                    }
                    local q = stats.by_qname[qname]
                    if not q then q = 0; stats.qnames = stats.qnames + 1 end
                    stats.by_qname[qname] = q + 1
                end
            end
        end
    end
    data.proto = stats
    return stats
end

--- One report line per the house convention, so a caller need not format it.
function M.summary(s)
    if not s or s.files == 0 then return nil end
    local dup = 0
    for _, n in pairs(s.by_qname) do if n > 1 then dup = dup + 1 end end
    return ('proto: %d file(s) — %d service(s), %d rpc(s) at %d distinct'
        .. ' qualified name(s)%s, %d message(s), %d enum(s), %d import(s)%s%s')
        :format(s.files, s.services, s.rpcs, s.qnames,
            dup > 0 and (' (%d name(s) declared more than once — vendored copies)')
                :format(dup) or '',
            s.messages, s.enums, s.imports,
            s.refused > 0 and (' · %d REFUSED declaration(s): %s')
                :format(s.refused, table.concat(s.refusals, ' ')) or '',
            #s.unreadable > 0 and (' · %d unreadable: %s')
                :format(#s.unreadable, table.concat(s.unreadable, ' ')) or '')
end

return M
