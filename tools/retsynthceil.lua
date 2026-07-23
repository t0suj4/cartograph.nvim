-- retsynthceil — the RETURN-TYPE SYNTHESIS ceiling probe (VM work, [[cartograph-local-type-
-- inference]] / [[cartograph-consumer-federation]]). Before building new extraction to INFER a
-- fn's return type from its body (to close the census's ret-absent gap + feed resolve_returns),
-- MEASURE the ceiling: of return statements, how many name a SYNTHESIZABLE type — a constructor
-- (Foo.new / new Foo / Foo{} / Foo.init) → nominal T, or a call → transitive (chain) — vs
-- void/primitive/literal (NO type to synthesize). Prior work found dynamic-lang constructor
-- inference exhausted; this quantifies what's actually left, per lang, before any build.
--
--   nvim --headless -u NONE -l tools/retsynthceil.lua <corpus>

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local ts = require 'cartograph.providers.treesitter'

local name = arg[1]
if not name then print('usage: retsynthceil <corpus>'); os.exit(2) end
local data = bench.extract(name)

-- classify a returned-expression string
local function classify(expr)
    expr = expr:gsub('^%s+', ''):gsub('%s+$', '')
    if expr == '' then return 'void' end
    -- constructor → a nominal type we could synthesize
    if expr:match('^new%s+%u[%w_.]*') then return 'ctor' end                   -- js/java: new Foo
    if expr:match('^@?%u[%w_]*%s*{') then return 'ctor' end                    -- zig: Foo{...}
    if expr:match('^%u[%w_.]*[.:]new%f[^%w_]') then return 'ctor' end           -- ruby/lua: Foo.new / Foo:new
    if expr:match('^%u[%w_.]*[.:]init%f[^%w_]') then return 'ctor' end          -- zig/lua: Foo.init
    if expr:match('^setmetatable%f[^%w_]') then return 'ctor' end               -- lua OOP (already smtclasses)
    -- self / receiver → self-type (resolvable to the enclosing type)
    if expr:match('^self%f[^%w_]') or expr:match('^@') then return 'self' end
    -- a call → transitive (needs the callee's ret; the chain rounds)
    if expr:match('^[%w_][%w_.:]*%s*%(') then return 'call' end
    -- a bare Capitalized identifier → maybe a type/const (weak)
    if expr:match('^%u[%w_]*$') then return 'const' end
    return 'other' -- literal / primitive / local / expression → no nominal type
end

-- per-lang tally over return-ish nodes inside function/method bodies
local L = {}
local function lang(l) local r = L[l]; if not r then r = { n = 0 }; L[l] = r end; return r end

local files = {}
for _, n in ipairs(data.nodes or {}) do if n.file then files[n.file] = true end end
local root = data.root or ''
for f in pairs(files) do
    local path = f:match('^/') and f or (root .. '/' .. f)
    local fd = io.open(path, 'r')
    if fd then
        local src = fd:read('*a'); fd:close()
        local clang = ts.lang_of(f)
        local okp, parser = pcall(vim.treesitter.get_string_parser, src, clang)
        if okp and parser then
            local tree = (parser:parse() or {})[1]
            if tree then
                local r = lang(clang)
                local function walk(node)
                    local t = node:type()
                    if t:find('return', 1, true) then
                        -- the returned expression = the node text after `return`
                        local txt = vim.treesitter.get_node_text(node, src)
                        txt = txt:gsub('^%s*return%s*', ''):gsub('^%s*', '')
                        local first = txt:match('^[^\n;]*') or ''
                        r.n = r.n + 1
                        local c = classify(first)
                        r[c] = (r[c] or 0) + 1
                    end
                    for ch in node:iter_children() do walk(ch) end
                end
                walk(tree:root())
            end
        end
    end
end

local ls = {}; for l in pairs(L) do ls[#ls + 1] = l end
table.sort(ls, function (a, b) return L[a].n > L[b].n end)
local function pc(x, d) return d > 0 and 100 * x / d or 0 end
print(('retsynthceil %s'):format(name))
for _, l in ipairs(ls) do
    local r = L[l]
    if r.n >= 30 then
        local synth = (r.ctor or 0) + (r.self or 0)
        print(('  %-10s %6d returns · SYNTH-nominal %.1f%% (ctor %.0f%% + self %.0f%%) · transitive-call %.1f%% · const %.1f%% · none/prim %.1f%%')
            :format(l, r.n, pc(synth, r.n), pc(r.ctor or 0, r.n), pc(r.self or 0, r.n),
                pc(r.call or 0, r.n), pc(r.const or 0, r.n), pc((r.other or 0) + (r.void or 0), r.n)))
    end
end
vim.cmd('qall!')
