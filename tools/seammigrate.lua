-- seammigrate — the seam-guard's CONSTRUCTIVE twin. The guard (dogfood) says
-- "you read the wide index raw"; this ENUMERATES every such site plus the
-- mechanical rewrite (store.uses[x] -> band:callees(x)), so a migration is a
-- work-list, not a hunt. It would have driven the P2b sweep; record-fold's next
-- consumer moves are the same shape. The rewrite list is a SUPERSET of the
-- fence (it includes edge_inferred -> band:tier, the honesty-vector follow-up
-- the fence doesn't yet enforce), so a clean run still shows what's LEFT.
--
--   nvim --headless -u NONE -l tools/seammigrate.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

-- pattern (raw per-node read) -> the Band accessor it should become
local REWRITE = {
    { pat = 'store%.uses%[', to = 'band:callees(id)' },
    { pat = 'store%.usedby%[', to = 'band:callers(id)' },
    { pat = 'store%.calls_by_fn%[', to = 'band:sites(id)' },
    { pat = 'store%.calls_by_file%[', to = 'band:calls_of(file)' },
    { pat = 'store%.calls_by_prov%[', to = 'band:by_prov(prov)' },
    { pat = 'store%.var_uses%[', to = 'band:var_uses_detail(id)  (or var_uses for ids)' },
    { pat = 'store%.var_usedby%[', to = 'band:var_used_by_detail(id)' },
    { pat = 'store%.reg_by%[', to = 'band:registrants_detail(id)' },
    { pat = 'store%.imports_out%[', to = 'band:imports_out(id)' },
    { pat = 'store%.imports_in%[', to = 'band:imports_in(id)' },
    { pat = 'store%.registers%[', to = 'band:registered(id)' },
    { pat = 'store%.edge_tier%[', to = 'band:tier(from, to)' },
    { pat = 'store%.edge_inferred%[', to = "band:tier(from,to)=='inferred'  (honesty-vector follow-up)" },
    { pat = 'store%.occ%[', to = 'store.occurrences(from, to)' },
}
-- the accessors' HOME — reads here are the implementation, not violations
local OWNERS = { 'cartograph/band%.lua$', 'cartograph/store%.lua$' }

local function owned(path)
    for _, o in ipairs(OWNERS) do if path:match(o) then return true end end
    return false
end

-- walk lua/ (the engine)
local hits, files = {}, {}
local function scan(dir)
    for name, kind in vim.fs.dir(dir) do
        local p = dir .. '/' .. name
        if kind == 'directory' then scan(p)
        elseif name:match('%.lua$') then files[#files + 1] = p end
    end
end
scan(repo .. '/lua')

for _, path in ipairs(files) do
    local rel = path:gsub('.*/lua/', '')
    if not owned('cartograph/' .. rel) and not owned(rel) then
        local fh = io.open(path)
        if fh then
            local ln = 0
            for line in fh:lines() do
                ln = ln + 1
                local code = line:gsub('%-%-.*$', '') -- strip comments (as the lint does)
                for _, r in ipairs(REWRITE) do
                    if code:find(r.pat) then
                        hits[#hits + 1] = { file = rel, line = ln, to = r.to,
                            src = line:gsub('^%s+', ''):gsub('%s+$', '') }
                        break
                    end
                end
            end
            fh:close()
        end
    end
end

print(('seammigrate — %d raw wide-index read(s) to route through the Band'):format(#hits))
for _, h in ipairs(hits) do
    print(('  %s:%d'):format(h.file, h.line))
    print(('    %s'):format(h.src))
    print(('    → %s'):format(h.to))
end
if #hits == 0 then print('  (none — every consumer is on the Band seam)') end
