-- The HASKELL language spec (L0 grammar binding + L1 name model)
-- extracted from the engine ([[cartograph-spec-layering]] P1). Pure motion.

-- @langs haskell — a spec IS one grammar's mapping, so every node type here is
-- haskell's by construction.

local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text
local inext = tsutil.inext

return {
        exts = { 'hs' },
        functions = [=[
            (function name: (variable) @name) @def
            (bind name: (variable) @name) @def
        ]=],
        -- application is a nested spine; the innermost apply holds the head
        calls = [=[ (apply function: (variable) @name) @call ]=],
        vars = nil,
        params_field = 'patterns',
        body_field = nil, -- df comes from the custom hook below
        fn_types = { ['function'] = true, bind = true },
        mention_types = { variable = true },
        -- where-clause binds are a function's INTERIOR (df rows), not nodes:
        -- indexing `e`/`go`/`args` by name would link every pattern variable
        toplevel_only = true,
        merge_equations = true, -- step 0 = ...; step x = ... is ONE function
        cbarg_within = { instance_declarations = true }, -- typeclass dispatch
        block_container = 'declarations',
        block_skip = { signature = true, pragma = true },
        is_method = function () return false end,
        entry_names = { main = true },
        import_query = [=[ (import module: (module) @path) ]=],
        resolve_import = function (mod, files)
            -- source roots differ (compiler/, libraries/x/src/) and the
            -- extraction root may sit INSIDE the module hierarchy: match
            -- path suffixes in either direction, unique-or-refuse
            local suffix, hit = mod:gsub('%.', '/') .. '.hs', nil
            for f in pairs(files) do
                local m = f == suffix
                    or f:sub(-#suffix - 1) == '/' .. suffix
                    or suffix:sub(-#f - 1) == '/' .. f
                if m then
                    if hit then return nil end
                    hit = f
                end
            end
            return hit
        end,
        -- df-lite from the equation body + where clause: each where-bind is
        -- a "statement" (def = its name), the match expression leads
        dataflow = function (def, spec, src)
            local stmts = {}
            local function names(n, out, seen)
                if n:type() == 'variable' then
                    local t = node_text(n, src)
                    if not seen[t] then seen[t] = true out[#out + 1] = t end
                    return
                end
                for _, c in inext, n, -1 do
                    if c:named() then names(c, out, seen) end
                end
            end
            local m = def:field('match')[1]
            if m then
                local use = {}
                names(m, use, {})
                stmts[#stmts + 1] = { l = m:range() + 1, def = {}, use = use, dep = {} }
            end
            local lb = def:field('binds')[1]
            if lb then
                for _, d in inext, lb, -1 do
                    if d:named() and (d:type() == 'bind' or d:type() == 'function') then
                        local namen = d:field('name')[1]
                        local use = {}
                        names(d, use, {})
                        stmts[#stmts + 1] = { l = d:range() + 1,
                            def = namen and { node_text(namen, src) } or {},
                            use = use, dep = {} }
                    end
                end
            end
            if #stmts == 0 then return nil end
            table.sort(stmts, function (a, b) return a.l < b.l end)
            return { inputs = {}, stmts = stmts }
        end,
}
