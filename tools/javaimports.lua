-- javaimports — the java import resolver JOINED against the files' own package declarations (CART-0675).
--
--   nvim --headless -u NONE -l tools/javaimports.lua <repo>… [--show N]
--
-- A repo is a path or a name under ~/git; the population is `git ls-files '*.java'`.
-- OURS: `spec.java.resolve_import(fqn, files, from, root)` — a LAYOUT rule (the path spells the package).
-- THE ORACLE: each file's `package x.y;` declaration plus its basename, read from the CONTENT, so
-- the two sides share no evidence: a file whose directory does not spell its package (a generated
-- stub, a misplaced test) is exactly where they can disagree.
-- Per single-type import (static and on-demand imports are skipped and counted):
--   agree      both name the same file
--   ambiguous  the oracle has 2+ files for the FQN — ours must refuse (sound-first) or name one
--              that the importer's MODULE CAN SEE; reported by what ours did
--   missed     the oracle has exactly one file, ours refused
--   wrong      ours named a file whose declared FQN is not the import
--   external   neither side has it (JDK, a dependency jar) — the counter that must stay large
--   nested     `import a.b.Outer.Inner`: no file, but a.b.Outer is declared in the tree (neither side
--              resolves a member class today; counted apart so it does not pass as external)
-- ★ The oracle is a regex over the first `package` line; a file without one is in the default
-- package. It does not know which module can SEE which (that is the POM layer's job).
-- ⚠ ONE SHARED INPUT, SAID: ours is handed the importer's source root (`spec.import_context`, which
-- the provider reads from the tree) computed here from the oracle's own declaration. It only picks
-- among duplicates; the oracle never uses it, and it never makes a resolution out of nothing.
-- ⚠ WHY NOT cartograph.oraclejoin: that frame judges one value per INPUT FILE, and the unit here is
-- the import SITE with a third class — AMBIGUOUS, where refusing is the right answer and naming the
-- importer's own copy is too. A per-file first difference would bury 665 sound refusals among
-- real misses.

local REPO = (debug.getinfo(1, 'S').source:match('@(.*)/tools/[^/]+$')) or '.'
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path
local J = require 'cartograph.oraclejoin'
local java = require 'cartograph.spec.java'

local repos, show = {}, 3
local i = 1
while i <= #arg do
    if arg[i] == '--show' then show = tonumber(arg[i + 1]); i = i + 1 else repos[#repos + 1] = arg[i] end
    i = i + 1
end

local function slurp(p)
    local f = io.open(p, 'rb'); if not f then return nil end
    local s = f:read('*a'); f:close(); return s
end

for _, repo in ipairs(repos) do
    local dir = repo:find('/', 1, true) and vim.fn.expand(repo) or vim.fn.expand('~/git/' .. repo)
    local files, list = {}, {}
    for _, f in ipairs(J.ls_files(dir)) do
        if f:match('%.java$') then files[f] = true; list[#list + 1] = f end
    end
    local t0 = vim.uv.hrtime()
    local fqn_files, decl, imports, ctx = {}, {}, {}, {}
    local n_static, n_star, unread = 0, 0, 0
    for _, f in ipairs(list) do
        local src = slurp(dir .. '/' .. f)
        if not src then unread = unread + 1 else
            -- strip comments so a commented-out package/import line is not read
            local s = src:gsub('/%*.-%*/', ''):gsub('//[^\n]*', '')
            local pkg = s:match('%f[%w]package%s+([%w_.%s]-)%s*;')
            pkg = pkg and pkg:gsub('%s', '') or ''
            local fq = (pkg ~= '' and pkg .. '.' or '') .. f:match('([^/]+)%.java$')
            decl[f] = fq
            -- the importer's context as the provider builds it (spec.import_context), from the same declaration
            local tail = fq:gsub('%.', '/') .. '.java'
            ctx[f] = f == tail and { srcroot = '' } or f:sub(-#tail - 1) == '/' .. tail and { srcroot = f:sub(1, #f - #tail) } or {}
            local l = fqn_files[fq] or {}; l[#l + 1] = f; fqn_files[fq] = l
            local im = {}
            -- ⚠ ONE capture, parsed after: an optional `(s?t?a?t?i?c?)` group eats the `i` of `io.quarkus`
            for body in s:gmatch('%f[%w]import%s+([%w_.*%s]-)%s*;') do
                body = body:gsub('%s+', ' ')
                if body:match('^static ') then n_static = n_static + 1
                elseif body:find('*', 1, true) then n_star = n_star + 1
                else
                    local path = body:gsub(' ', '')
                    if path ~= '' then im[#im + 1] = path end
                end
            end
            imports[f] = im
        end
    end
    local c = { agree = 0, ambiguous_refused = 0, ambiguous_named = 0, missed = 0, wrong = 0, external = 0, nested = 0 }
    local ex = { missed = {}, wrong = {}, ambiguous_named = {}, ambiguous_refused = {} }
    local total = 0
    for _, f in ipairs(list) do
        for _, fq in ipairs(imports[f] or {}) do
            total = total + 1
            local ours = java.resolve_import(fq, files, f, dir, ctx[f])
            local truth = fqn_files[fq]
            local k
            if truth and #truth > 1 then
                k = ours and 'ambiguous_named' or 'ambiguous_refused'
                if ours and decl[ours] ~= fq then k = 'wrong' end
                -- a named duplicate must be the importer's OWN copy, not merely a copy
                local tail = fq:gsub('%.', '/') .. '.java'
                if k == 'ambiguous_named' and ours:sub(1, #ours - #tail) ~= ctx[f].srcroot then k = 'wrong' end
            elseif truth then
                k = (ours == truth[1]) and 'agree' or ours and 'wrong' or 'missed'
            else
                k = ours and 'wrong' or 'external'
                if k == 'external' then -- a member class: `import a.b.Outer.Inner` lives in Outer.java
                    local outer = fq:match('^(.*)%.[^.]+$')
                    while outer do
                        if fqn_files[outer] then k = 'nested'; break end
                        outer = outer:match('^(.*)%.[^.]+$')
                    end
                end
            end
            c[k] = c[k] + 1
            if ex[k] and #ex[k] < show then ex[k][#ex[k] + 1] = { f, fq, ours or '-', truth and table.concat(truth, ' ') or '-' } end
        end
    end
    local amb = 0
    for _, l in pairs(fqn_files) do if #l > 1 then amb = amb + 1 end end
    print(('%s: %d java file(s), %d unread; %d single-type import(s) (+%d static, +%d on-demand skipped); %d FQN(s) declared in 2+ files  (%.1fs)')
        :format(repo, #list, unread, total, n_static, n_star, amb, (vim.uv.hrtime() - t0) / 1e9))
    print(('  agree %d  missed %d  wrong %d  ambiguous: refused %d, named %d  external %d  (member class of an in-tree class %d)')
        :format(c.agree, c.missed, c.wrong, c.ambiguous_refused, c.ambiguous_named, c.external, c.nested))
    for _, k in ipairs({ 'missed', 'wrong', 'ambiguous_named', 'ambiguous_refused' }) do
        for _, e in ipairs(ex[k]) do print('    ' .. k, e[1], e[2], '->', e[3], '| truth', e[4]) end
    end
end
