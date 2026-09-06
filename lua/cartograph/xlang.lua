-- Cross-language linking (pure post-pass over a neutral-schema graph).
-- Engine boundaries dispatch by STRING KEY: JS calls chrome.send('x') and
-- the C++ handler registered under "x" runs; C exports a scheme-callable
-- with scm_c_define_gsubr("name", ...); lua_register binds a Lua global to
-- a C function. The key is the edge — this pass finds export calls, resolves
-- their handler, and links every import site to it, across languages.
--
-- Confidence: these edges are string-key matched — the same mechanism the
-- engine itself dispatches by — so they are NOT marked `~`. They carry
-- xlang = true. Handlers that don't resolve stay honest frontiers.

local M = {}

local callrec = require 'cartograph.callrec' -- used by verb_matches below (def'd
                                             -- before the module's other requires)

--- A binding declares one boundary. `export` names the registering verb and
--- which (logical) arg is the key; `import` either names the sending verb
--- (chrome.send) or `any_call = true` (the exported key becomes a callable
--- name in the other language, as with gsubr/lua_register).
M.default_bindings = {
    -- chromium WebUI (fire-and-forget + request/response)
    { export = { verb = 'RegisterMessageCallback', name = 1 },
      import = { verb = { 'chrome.send', 'sendWithPromise' }, name = 1 } },
    -- guile: C function exported under a scheme name
    { export = { verb = 'scm_c_define_gsubr', name = 1 },
      import = { any_call = true } },
    -- lua C API
    { export = { verb = 'lua_register', name = 2 },
      import = { any_call = true } },
    -- wordpress hooks: handlers register by NAME STRING (or Class::method);
    -- one hook fans out to many handlers
    { export = { verb = { 'add_action', 'add_filter' }, name = 1, fn = 2 },
      import = { verb = { 'do_action', 'do_action_ref_array',
          'apply_filters', 'apply_filters_ref_array' }, name = 1 } },
}

--- ★★ CALL INDEX FOR `verb_matches`, and it is the SAME DEFECT SHAPE as the one
--- CART-0785 found in greenspun: `link` scanned EVERY call once (twice, with an
--- import side) PER BINDING, so the pass was B x calls. Measured on our own tree,
--- 65674 calls, one arm per binding count:
---     bindings   0     1     2     4     8    16    24
---     link ms  14.8  55.7  73.0 147.4 251.9 531.2 830.9
--- 14.8 ms of setup and ~34 ms per binding, dead straight. The binding count is
--- not fixed either — discovery proposes one per registry it finds, so a
--- registry-rich tree pays twice: more bindings AND more calls.
---
--- WITH THE INDEX, arms interleaved, median of 5, output byte-identical on all 8:
---     corpus     calls    B     link OLD -> NEW
---     bnw          1185  12       1.5 ->    1.8 ms   (0.8x — see below)
---     ruby         8818   5      11.5 ->   11.4 ms   (1.0x)
---     grocy       15004   5      20.5 ->   15.6 ms   (1.3x)
---     factorio    21082   6     101.8 ->   29.8 ms   (3.4x)
---     desynced    21041  11     250.5 ->   29.8 ms   (8.4x)
---     self        65695  24     574.9 ->   48.8 ms  (11.8x)
---     ghost      130645  23     903.9 ->  169.5 ms   (5.3x)
---     zig        131619   4     189.1 ->  109.3 ms   (1.7x)
--- ★ bnw is 0.3 ms SLOWER and that is the honest shape of an index: 1185 calls
--- over 12 bindings is too little scanning to pay for one pass of string work.
--- It is 0.3 ms, and the tree it is measured on is a toy.
--- Together with the greenspun memo this takes `refresh.files` after a one-file
--- edit from 4.24 s to 1.78 s — 2.46 s off every edit an agent makes.
---
--- ★ THE INDEX IS EXACT, NOT A PREFILTER, and that is the claim to check.
--- `verb_matches` is true iff callee == verb, OR full == verb, OR full ENDS WITH
--- '.' .. verb. So a call is keyed under its callee, its full name, and every
--- DOT-SUFFIX of its full name — `window.chrome.send` under `chrome.send` and
--- `send`. Those three cases are the whole of `verb_matches`, so the index can
--- neither miss nor invent; `verb_matches` is still applied to each candidate,
--- which makes a bug here cost time rather than answers.
--- ⚠ ORDER IS PART OF THE OUTPUT. Handlers accumulate into `exports[key]` lists
--- and sites append to an edge's `at`, both in CALL ORDER, so candidate lists are
--- built and merged ASCENDING BY CALL INDEX. A set-union that lost the order
--- would produce a graph that is equal in content and different on disk.
local function verb_index(data)
    local by = {}
    local function put(k, i)
        if not k or k == '' then return end
        local l = by[k]
        if not l then l = {}; by[k] = l end
        if l[#l] ~= i then l[#l + 1] = i end
    end
    for i, c in ipairs(data.calls or {}) do
        put(c.callee, i)
        local f = c.full
        if f then
            put(f, i)
            local p = f:find('.', 1, true)
            while p do put(f:sub(p + 1), i); p = f:find('.', p + 1, true) end
        end
    end
    return by
end

--- Call indices a verb spec could match, ascending. `verb` is a name or a list.
--- Returns nil when the spec is unusable (empty/absent), meaning "scan them all"
--- — a refusal to narrow, never a silent empty result.
local function verb_candidates(idx, verb)
    if type(verb) ~= 'table' then
        if not verb or verb == '' then return nil end
        return idx[verb] or {}
    end
    if #verb == 0 then return nil end
    if #verb == 1 then return verb[1] ~= '' and (idx[verb[1]] or {}) or nil end
    local seen, out = {}, {}
    for _, v in ipairs(verb) do
        if not v or v == '' then return nil end
        for _, i in ipairs(idx[v] or {}) do
            if not seen[i] then seen[i] = true; out[#out + 1] = i end
        end
    end
    table.sort(out)
    return out
end

--- Iterate `calls` over a candidate index list, yielding (call index, call) just
--- as `callrec.each` does. `cand == nil` means the narrowing declined, so this
--- falls back to the full scan rather than to nothing.
local function each_candidate(calls, cand)
    if not cand then return ipairs(calls) end
    local k = 0
    return function ()
        k = k + 1
        local ci = cand[k]
        if ci then return ci, calls[ci] end
    end
end

local function verb_matches(c, verb)
    if type(verb) == 'table' then
        for _, v in ipairs(verb) do
            if verb_matches(c, v) then return true end
        end
        return false
    end
    return callrec.callee(c) == verb or callrec.full(c) == verb
        or (callrec.full(c) and c.full:sub(-#verb - 1) == '.' .. verb)
end

local argv = require 'cartograph.argv'

local function logical_arg(c, i)
    local j = i + (callrec.method(c) and 1 or 0)
    return j <= argv.n(c) and argv.str(c, j) or nil
end

--- The call's own source text, bounded by its paren balance — scanning
--- past the statement picks up the next definition as a phantom.
function M.call_text(root, c, lines)
    if not lines then
        local fd = io.open(root .. '/' .. callrec.file(c), 'r')
        if not fd then return '' end
        lines = vim.split(fd:read('a'), '\n', { plain = true })
        fd:close()
    end
    local text, depth, opened = '', 0, false
    for l = callrec.line(c) + 1, math.min(callrec.line(c) + 12, #lines) do
        local chunk = lines[l]
        text = text .. chunk .. '\n'
        for ch in chunk:gmatch('[()]') do
            if ch == '(' then
                depth = depth + 1
                opened = true
            else
                depth = depth - 1
            end
        end
        if opened and depth <= 0 then break end
    end
    return text
end

--- Resolve the handler of an export call: a resolved function argv first,
--- then a textual scan of the call's source for a qualified/plain function
--- name (the &Class::Method inside base::BindRepeating spans lines).
local function find_handler(c, root, exact, export)
    if export.fn then
        local a = argv.at(c, export.fn + (callrec.method(c) and 1 or 0))
        if a then
            if a.k == 'func' and a.to then return a.to end
            local name = a.k == 'lit' and a.v or a.k == 'local' and a.name
                or a.k == 'callable' and a.name
            if name and exact[name] and #exact[name] == 1 then
                return exact[name][1].id
            end
            -- an inline closure or unresolvable callable: don't fall through
            -- to the textual scan, it would grab neighbouring names
            if a.k ~= 'expr' then return nil end
        end
    end
    for i = 1, argv.n(c) do
        local a = argv.at(c, i)
        if a.k == 'func' and a.to then return a.to end
    end
    for i = 1, argv.n(c) do
        local a = argv.at(c, i)
        if (a.k == 'local' or a.k == 'callable') and a.name and exact[a.name]
            and #exact[a.name] == 1 then
            return exact[a.name][1].id
        end
    end
    local text = M.call_text(root, c)
    -- array callables ([$obj, 'method'] / array($obj, 'method')) name the
    -- METHOD; qualified and &-references name the function
    for _, pat in ipairs({ '&([%w_]+::[%w_]+)', '([%w_]+::[%w_]+)',
        [=[%[[^%]]-,%s*['"]([%w_]+)['"]%s*%]]=],
        [=[array%s*%([^%)]-,%s*['"]([%w_]+)['"]]=],
        '&([%w_]+)' }) do
        for name in text:gmatch(pat) do
            local hit = exact[name]
            if hit and #hit == 1 then return hit[1].id end
        end
    end
    return nil
end

--- The bindings actually in force for a graph: config (or defaults) plus
--- discovered registries (config.discover), deduped by export verb.
--- The ACTIVE PROFILE's registry idioms, as export-only bindings (CART-0226).
---
--- User design: "I think the profiles should supply certain templates to turn
--- suggestions into lints." greenspun GUESSES a registry from call sites; a declared
--- API export KNOWS the shape from its signatures, so the environment can state its
--- own idioms and a discovered one that matches is correct platform usage rather than
--- an ad-hoc reimplementation. tools/factoriodistill derives them (7 on lua-factorio:
--- add_command, add_interface, on_event, on_init, on_load, on_configuration_changed,
--- on_nth_tick) and the hand profile republishes them.
---
--- EXPORT-ONLY, DELIBERATELY. Most of these are ENGINE-DISPATCHED: nothing in mod code
--- imports `script.on_event`, the game does. `M.default_bindings` entries all pair an
--- export with an importer because they describe language BOUNDARIES; a platform idiom
--- often has no second side, and inventing one would fabricate links.
--- WHERE THAT LEAVES THE GRAPH: link() skips a binding with no import side (see there),
--- so this changes no edges today. The registration→handler ref that `script.on_event(
--- id, handler)` implies is a REAL edge we do not yet have, and claiming it is a
--- deliberate separate step — it moves the open graph, so it needs a cache VERSION bump
--- and a gate re-save rather than riding along here.
local function profile_bindings(data)
    local name = data and data.profile
    if not name then return {} end
    local ok, pm = pcall(require, 'cartograph.spec.profile')
    local prof = ok and pm.load(name) or nil
    local out = {}
    for _, t in ipairs((prof or {}).templates or {}) do
        out[#out + 1] = { export = { verb = t.verb, name = t.key or 1 },
            -- provenance: which profile declared it, and what kind of idiom it is, so a
            -- consumer can say "this IS the platform's registry" rather than just
            -- suppressing a finding silently
            template = t, profile = name }
    end
    return out
end

--- Every binding in effect: the built-in language BOUNDARIES, the active profile's own
--- IDIOMS, the user's additions, and finally whatever discovery proposes.
---
--- THE COMBINING RULE IS UNION WITH FIRST-DECLARED-WINS, stated because two functions
--- deciding this differently is how the shape/profile stamping gap happened
--- (CART-0218). Order matters only for the discovery guard below: a verb already
--- declared by ANY tier is not proposed again.
---
--- `cfg.bindings` NOW COMPOSES instead of replacing, which is what its own
--- documentation always said — config.lua:44-48 reads "nil = the defaults … Add your
--- own", while the code was `cfg.bindings or M.default_bindings`, so declaring one
--- binding silently dropped chromium WebUI, guile gsubr, lua_register and wordpress
--- hooks. Same dispose-vs-extend confusion the packs axis got right by declaring it.
--- Set `cfg.bindings_only = true` for the old replace-everything behaviour.
function M.effective_bindings(data)
    local cfg = require('cartograph.config')
    local bindings = {}
    if not cfg.bindings_only then
        vim.list_extend(bindings, M.default_bindings)
        vim.list_extend(bindings, profile_bindings(data))
    end
    vim.list_extend(bindings, cfg.bindings or {})
    if cfg.discover ~= false then
        local have = {}
        for _, b in ipairs(bindings) do
            for _, v in ipairs(type(b.export.verb) == 'table'
                and b.export.verb or { b.export.verb }) do
                have[v] = true
            end
        end
        for _, b in ipairs(require('cartograph.greenspun').registries(data)) do
            if not have[b.export.verb] then bindings[#bindings + 1] = b end
        end
    end
    return bindings
end

--- Link a graph's cross-language boundaries in place.
---@param data table  neutral-schema graph (mutated)
---@param bindings table?  defaults to config.bindings or M.default_bindings
---@return { links:integer, exports:integer, unresolved:integer }
function M.link(data, bindings)
    bindings = bindings or require('cartograph.config').bindings
        or M.default_bindings
    local coop = require 'cartograph.coop' -- tick() yields under coop.run; else no-op
    local exact, tails = {}, {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'function' or n.kind == 'method' then
            exact[n.name] = exact[n.name] or {}
            table.insert(exact[n.name], n)
            local tail = n.name:match('([%w_]+)$')
            if tail and tail ~= n.name then
                tails[tail] = tails[tail] or {}
                table.insert(tails[tail], n)
            end
        end
    end
    -- a unique tail resolves too (Worker::work findable as 'work')
    for tail, list in pairs(tails) do
        if #list == 1 and not exact[tail] then exact[tail] = list end
    end
    local refEdge = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' then refEdge[e.from .. '\31' .. e.to] = e end
    end
    local function addref(from, to, at)
        local k = from .. '\31' .. to
        local e = refEdge[k]
        if not e then
            e = { from = from, to = to, kind = 'ref', at = {}, xlang = true }
            refEdge[k] = e
            data.edges[#data.edges + 1] = e
        end
        e.inferred = nil -- the key match outranks a name hypothesis
        if at then e.at[#e.at + 1] = at end
    end
    -- precise site range: the key literal on the call line, when findable
    local line_cache = {}
    local function key_range(c, key)
        if line_cache[callrec.file(c)] == nil then
            local fd = io.open(data.root .. '/' .. callrec.file(c), 'r')
            line_cache[callrec.file(c)] = fd and vim.split(fd:read('a'), '\n', { plain = true }) or false
            if fd then fd:close() end
        end
        local lines = line_cache[callrec.file(c)]
        for l = callrec.line(c), math.min(callrec.line(c) + 3, lines and #lines - 1 or callrec.line(c)) do
            local text = lines and lines[l + 1] or ''
            local s, e = text:find(key, 1, true)
            if s then
                return { start = { line = l, char = s - 1 },
                    ['end'] = { line = l, char = e } }
            end
        end
        return { start = { line = callrec.line(c), char = 0 },
            ['end'] = { line = callrec.line(c), char = 0 } }
    end

    local stats = { links = 0, exports = 0, unresolved = 0, pinned = 0 }
    -- human declarations outrank everything: a pin names the target of a
    -- dynamic call site the analysis cannot see. Durable pins anchor by
    -- (file, enclosing fn NAME, callee text) — the refs discipline, no
    -- line numbers, so they survive edits. { file, line, to } is the
    -- legacy shape. A pin that attaches to nothing complains loudly:
    -- a silently-inert declaration is worse than none.
    for _, pin in ipairs(require('cartograph.config').pins or {}) do
        local target = exact[pin.to]
        if target and #target > 1 and pin.to_file then
            -- a target-qualified pin (from a refusal): the name is
            -- ambiguous by construction, so the file disambiguates
            local one
            for _, t in ipairs(target) do
                if t.file == pin.to_file then one = one and false or t end
            end
            target = one or nil
        else
            target = target and #target == 1 and target[1]
        end
        local hit = 0
        if target then
            local fnids -- ids of the pin's enclosing function, by name
            if pin.fn then
                fnids = {}
                for _, n in ipairs(data.nodes) do
                    if n.file == pin.file and n.name == pin.fn
                        and (n.kind == 'function' or n.kind == 'method') then
                        fnids[n.id] = true
                    end
                end
            end
            for _, c in callrec.each(data) do
                local match
                if pin.callee then
                    match = callrec.file(c) == pin.file and callrec.callee(c) == pin.callee
                        and (fnids and (callrec.fn(c) and fnids[callrec.fn(c)] or false)
                            or (not fnids and not callrec.fn(c))) -- fn-less = top level
                else -- legacy line anchor
                    match = callrec.file(c) == pin.file and callrec.line(c) == pin.line - 1
                end
                if match then
                    callrec.set(c, 'to', target.id)
                    callrec.set(c, 'dynamic', nil)
                    if callrec.fn(c) then addref(callrec.fn(c), target.id,
                        key_range(c, pin.to)) end
                    hit = hit + 1
                    stats.pinned = stats.pinned + 1
                end
            end
        end
        if hit == 0 then
            vim.notify(('cartograph: pin -> %s did not attach: %s'):format(
                tostring(pin.to),
                not target
                    and ('no unique function named %q in the graph')
                        :format(tostring(pin.to))
                    or pin.callee
                    and ('no call of %s%s in %s'):format(pin.callee,
                        pin.fn and (' inside ' .. pin.fn) or ' at top level',
                        pin.file)
                    or ('%s:%d moved? re-pin from the trace')
                        :format(pin.file, pin.line or 0)),
                vim.log.levels.WARN)
        end
    end
    -- built on first use, not up front: a binding set with no import side does
    -- no scanning, and paying for an index nobody reads is the mistake the
    -- greenspun memo's placement already cost a measurement over.
    local vidx
    local function idx()
        if not vidx then vidx = verb_index(data) end
        return vidx
    end
    for _, b in ipairs(bindings) do
        coop.tick()
        -- A BINDING WITH NO IMPORT SIDE IS A DECLARATION, NOT A LINK (CART-0226): a
        -- profile's registry idiom is usually engine-dispatched, so there is no
        -- importer in the corpus to link to. Skipping it here is also what stops
        -- `b.import.verb` below from indexing nil — greenspun.audit already guards the
        -- same way (`if b.import and …`), so the two agree about what a one-sided
        -- binding means.
        if b.import and (b.import.verb or b.import.any_call) then
        local exports = {}
        local allcalls = data.calls or {}
        for ci, c in each_candidate(allcalls, verb_candidates(idx(), b.export.verb)) do
            if ci % 8192 == 0 then coop.tick() end
            if verb_matches(c, b.export.verb) then
                local key = logical_arg(c, b.export.name)
                if key and key ~= '' then
                    local h = find_handler(c, data.root, exact, b.export)
                    if h then
                        exports[key] = exports[key] or {}
                        table.insert(exports[key], h)
                        stats.exports = stats.exports + 1
                        -- the registration itself references the handler
                        if callrec.fn(c) then addref(callrec.fn(c), h, key_range(c, key)) end
                    else
                        stats.unresolved = stats.unresolved + 1
                    end
                end
            end
        end
        if next(exports) then
            -- the import side is either a named verb (index by that) or
            -- `any_call`, where the EXPORTED KEYS are themselves the callable
            -- names — so the candidates are the calls whose callee is one of the
            -- keys, which is the same index read with a different key set.
            local icand
            if b.import.verb then
                icand = verb_candidates(idx(), b.import.verb)
            else
                local ks = {}
                for k in pairs(exports) do ks[#ks + 1] = k end
                icand = verb_candidates(idx(), ks)
            end
            -- ★ WHICH importer verb matched, when the key position is per-verb.
            -- `import.names` (CART-0788) gives each importer its own argument
            -- position, because they genuinely differ — one shared position read
            -- the wrong argument for every importer that disagreed, and those
            -- simply never linked. Falls back to `name` for the declared
            -- bindings, which are hand-written with one position for the set.
            local names = b.import.names
            local function key_pos(c)
                if not names then return b.import.name or 1 end
                for _, v in ipairs(b.import.verb) do
                    if verb_matches(c, v) then return names[v] or b.import.name or 1 end
                end
                return b.import.name or 1
            end
            for ci, c in each_candidate(allcalls, icand) do
                if ci % 8192 == 0 then coop.tick() end
                local hs, key
                if b.import.verb and verb_matches(c, b.import.verb) then
                    key = logical_arg(c, key_pos(c))
                    hs = key and key ~= '' and exports[key]
                elseif b.import.any_call and not callrec.to(c) and exports[callrec.callee(c)] then
                    key = callrec.callee(c)
                    hs = exports[key]
                end
                if hs then
                    -- a single handler is a descend target; a fan-out keeps
                    -- c.to empty (edges carry it, callers views show sites)
                    if #hs == 1 then c.to = callrec.to(c) or hs[1] end
                    if callrec.fn(c) then
                        for _, h in ipairs(hs) do
                            addref(callrec.fn(c), h, key_range(c, key))
                        end
                    end
                    stats.links = stats.links + 1
                end
            end
        end
        end
    end
    return stats
end

return M
