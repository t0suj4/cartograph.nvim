-- rubyowner — SIZE the owner-precision opportunity for ruby-rails minting
-- ([[cartograph-stdlib-profile]] follow-up: owner-precise canonical paths). Today
-- minted nodes are name-only (`ruby-rails::each`). This measures where owner info
-- can come from: (a) the profile's own types owner→member map (free, but many
-- methods are multi-owner) vs (b) receiver typing (recv/self-in-model).
--
--   nvim --headless -u NONE -l tools/rubyowner.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
assert(pcall(vim.treesitter.language.add, 'ruby'), 'no ruby parser')
local ts = require 'cartograph.providers.treesitter'
local prof = require('cartograph.spec.profile').load('ruby-rails')

-- reverse map: member → set of profile owners (from types); Kernel frees not in
-- types are the implicit-Kernel owner
local owners_of = {}
for owner, t in pairs(prof.types or {}) do
    for m in pairs(t.members or {}) do
        owners_of[m] = owners_of[m] or {}
        owners_of[m][owner] = true
    end
end
local function owner_count(m)
    local n = 0; for _ in pairs(owners_of[m] or {}) do n = n + 1 end; return n
end

local root = vim.fn.expand('~/git/discourse')
if vim.fn.filereadable(root .. '/config/application.rb') ~= 1 then print('no discourse'); return end
local files = {}
for _, sub in ipairs({ 'app/models', 'app/controllers' }) do
    for _, f in ipairs(vim.fn.globpath(root .. '/' .. sub, '*.rb', false, true)) do
        files[#files + 1] = f:sub(#root + 2)
    end
end
local fileset = {}; for _, f in ipairs(files) do fileset[f] = true end
local data = ts.extract(root, { files = files, fileset = fileset, packs = { 'rails' } })

-- which classes are ActiveRecord models? (reach ApplicationRecord/ActiveRecord::Base
-- through the ruby ancestor edges) — the self-in-model receiver-typing opportunity
local AR = { ApplicationRecord = true, ['ActiveRecord::Base'] = true }
local parent = {}
for _, e in ipairs(data.ruby_anc or {}) do
    if e.mode == 'inst' then parent[e.c] = parent[e.c] or {}; parent[e.c][#parent[e.c] + 1] = e.p end
end
local is_model_cache = {}
local function is_model(cls)
    if is_model_cache[cls] ~= nil then return is_model_cache[cls] end
    local seen, frontier = { [cls] = true }, { cls }
    for _ = 1, 12 do
        local nf = {}
        for _, cur in ipairs(frontier) do
            if AR[cur] then is_model_cache[cls] = true; return true end
            for _, p in ipairs(parent[cur] or {}) do if not seen[p] then seen[p] = true; nf[#nf + 1] = p end end
        end
        if #nf == 0 then break end; frontier = nf
    end
    is_model_cache[cls] = false; return false
end
-- enclosing class of a caller fn id like `app/models/x.rb::User#method@10`
local function enclosing_class(fnid)
    local cls = fnid and fnid:match('::([%w_:]+)[#.]')
    return cls
end

local uniq, ambig, freeonly = 0, 0, 0
local bare, localrecv = 0, 0
local self_in_model = 0        -- bare call inside a model instance method
local ambig_resolvable = 0     -- ambiguous method BUT self-in-model → owner determinable
local total = 0
for _, c in ipairs(data.calls or {}) do
    if c.to and tostring(c.to):sub(1, 12) == 'ruby-rails::' then
        total = total + 1
        local m = c.callee
        local oc = owner_count(m)
        if oc == 0 then freeonly = freeonly + 1
        elseif oc == 1 then uniq = uniq + 1
        else ambig = ambig + 1 end
        if c.recv then localrecv = localrecv + 1 else
            bare = bare + 1
            local cls = enclosing_class(c.fn)
            if cls and is_model(cls) then
                self_in_model = self_in_model + 1
                if oc > 1 then ambig_resolvable = ambig_resolvable + 1 end
            end
        end
    end
end

print(('rubyowner — discourse app/models+controllers, %d files'):format(#files))
print(('  minted (ruby-rails::) calls: %d'):format(total))
print('  owner-set from profile.types:')
print(('    unique-owner (precise for FREE): %d (%.1f%%)'):format(uniq, 100 * uniq / math.max(1, total)))
print(('    multi-owner (ambiguous):          %d (%.1f%%)'):format(ambig, 100 * ambig / math.max(1, total)))
print(('    free-only / Kernel (no types owner): %d (%.1f%%)'):format(freeonly, 100 * freeonly / math.max(1, total)))
print('  receiver shape:')
print(('    bare / implicit-self: %d   local-recv: %d'):format(bare, localrecv))
print(('    bare calls inside an AR MODEL (self-typed owner available): %d'):format(self_in_model))
print(('    ...of which are AMBIGUOUS methods self-typing would disambiguate: %d'):format(ambig_resolvable))
