-- apifetch — OFFER to obtain an environment's own API description, and distil it
-- into a version-keyed profile artifact.
--
-- WHY: a profile for one version can only say "the target lacks this name", which may
-- be a fact about the artifact. With two versions present, portability reports a
-- status CHANGE — `game.entity_prototypes` was in 1.1 and is gone in 2.0 — which is
-- evidence about the environments and survives both artifacts being incomplete the
-- same way. Hand-authoring the old version is not the answer; the vendor publishes it.
--
-- NETWORK IS NEVER IMPLICIT, and that is the whole design of this file:
--   (no args)      report what is DECLARED and what is already LOCAL. No request.
--   --check        contact the index to list available versions. Announced first.
--   <version>      resolve, fetch, distil. Announced first.
-- Extraction, every verb and every report stay offline. A declaration is an OFFER,
-- not a trigger — which is why the URL is spec data (spec/ecosystem/*.lua
-- `api_source`) rather than a literal at a call site.
--
--   nvim --headless -u NONE -l tools/apifetch.lua                  -- what is offered
--   nvim --headless -u NONE -l tools/apifetch.lua --check           -- what exists
--   nvim --headless -u NONE -l tools/apifetch.lua 1.1               -- resolve + fetch
--   nvim --headless -u NONE -l tools/apifetch.lua 1.1.110           -- exact version
--   ... --eco lua-factorio                                          -- pick ecosystem

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/apifetch%.lua$')
package.path = here .. '/../lua/?.lua;' .. here .. '/../lua/?/init.lua;' .. package.path

local args, want, eco_name, check = { ... }, nil, nil, false
do
    local a = (#args > 0) and args or (_G.arg or {})
    local i = 1
    while a[i] do
        if a[i] == '--check' then check = true
        elseif a[i] == '--eco' then i = i + 1; eco_name = a[i]
        elseif not a[i]:match('^%-%-') then want = a[i] end
        i = i + 1
    end
end

local ecomod = require 'cartograph.spec.ecosystem'
-- VERSION ORDER comes from versionfloor, which already owns "compare over dotted
-- numeric parts". Comparing version strings LEXICALLY is wrong and quietly so: this
-- first reported 1.1 -> 1.1.99 and 2.0 -> 2.0.9, because '9' > '1' beats 110 and 77.
local newer_than = function (a, b) -- a strictly newer than b
    return require('cartograph.versionfloor').older(b, a)
end
local profmod = require 'cartograph.spec.profile'
local PROFDIR = here .. '/../lua/cartograph/spec/profile'

--- Every ecosystem that declares an api source — derived, so a newly declared one is
--- offered with no edit here.
local function offers()
    local out = {}
    for _, n in ipairs(ecomod.names()) do
        local e = ecomod.load(n)
        if e and e.api_source and e.api_source.url then
            out[#out + 1] = { name = n, eco = e, src = e.api_source }
        end
    end
    return out
end

--- The artifact suffix for a version: dots stripped, so the module name stays a legal
--- Lua path. `1.1` -> `11`, `1.1.110` -> `11` (a profile is per MINOR: patch releases
--- do not change the documented surface enough to warrant separate artifacts, and the
--- distilled file records the exact version it came from).
local function suffix_of(version)
    local maj, min = version:match('^(%d+)%.(%d+)')
    if not maj then return nil end
    return maj .. min
end

local function artifact_name(src, version)
    local sfx = suffix_of(version)
    return sfx and src.artifact:format(sfx) or nil
end

--- Present locally? Asked of the profile loader, so this reports what cartograph
--- would actually load rather than what happens to be on disk.
local function local_state(src, version)
    local name = artifact_name(src, version)
    if not name then return nil, 'unparseable version' end
    return {
        artifact = name,
        present = profmod.stamp_of(name) ~= nil,
        stamp = profmod.stamp_of(name),
    }
end

local function say(s) io.write(s .. '\n') end

-- ── the OFFER: no network ────────────────────────────────────────────────────
local list = offers()
if #list == 0 then
    say('apifetch: no ecosystem declares an api_source')
    return
end

if not check and not want then
    say('=== apifetch — what is OFFERED (no request made) ===')
    for _, o in ipairs(list) do
        if not eco_name or eco_name == o.name then
            say(('  %s'):format(o.name))
            say(('    index      %s'):format(o.src.index or '(none declared)'))
            say(('    url        %s'):format(o.src.url))
            if o.src.aliases and #o.src.aliases > 0 then
                say(('    aliases    %s'):format(table.concat(o.src.aliases, ' ')))
            end
            -- what is already distilled, from the profile dir
            local have = {}
            -- the artifact pattern must be ESCAPED before use: `-` is magic in a Lua
            -- pattern (a lazy quantifier), so a raw `lua-factorio-api-(%d+)` matches
            -- nothing and this reported "none distilled yet" with two on disk
            local prefix = o.src.artifact:format(''):gsub('(%W)', '%%%1')
            local it = vim.uv.fs_scandir(PROFDIR)
            while it do
                local n = vim.uv.fs_scandir_next(it)
                if not n then break end
                local base = n:match('^(.+)%.mpack$')
                if base and base:match('^' .. prefix .. '%d+$') then
                    have[#have + 1] = base
                end
            end
            table.sort(have)
            say(('    local      %s'):format(#have > 0 and table.concat(have, ' ')
                or '(none distilled yet)'))
        end
    end
    say('')
    say('  --check            ask the index which versions exist  (CONTACTS the host)')
    say('  <version>          resolve, fetch and distil            (CONTACTS the host)')
    say('  Nothing above contacted anything. Extraction and every verb stay offline.')
    return
end

-- ── from here on a request IS made, and is announced ─────────────────────────
local function fetch(url)
    say(('  GET %s'):format(url))
    local res = vim.system({ 'curl', '-sS', '-m', '60', '-L', url },
        { text = true }):wait()
    if res.code ~= 0 then return nil, (res.stderr or 'curl failed'):gsub('%s+$', '') end
    if not res.stdout or res.stdout == '' then return nil, 'empty response' end
    return res.stdout
end

for _, o in ipairs(list) do
    if not eco_name or eco_name == o.name then
        say(('=== %s ==='):format(o.name))
        if check then
            if not o.src.index then
                say('  no index declared — a version cannot be discovered, only named')
            else
                local body, err = fetch(o.src.index)
                if not body then say('  FAILED: ' .. tostring(err)) else
                    local per = {}
                    for v in body:gmatch(o.src.version_href) do
                        local mm = v:match('^(%d+%.%d+)')
                        if mm and (not per[mm] or newer_than(v, per[mm])) then
                            per[mm] = v
                        end
                    end
                    local keys = {}
                    for k in pairs(per) do keys[#keys + 1] = k end
                    table.sort(keys, function (a, b)
                        local a1, a2 = a:match('(%d+)%.(%d+)')
                        local b1, b2 = b:match('(%d+)%.(%d+)')
                        if tonumber(a1) ~= tonumber(b1) then return tonumber(a1) < tonumber(b1) end
                        return tonumber(a2) < tonumber(b2)
                    end)
                    say(('  %d minor version(s) published; newest patch per minor:')
                        :format(#keys))
                    for _, k in ipairs(keys) do
                        local st = local_state(o.src, k)
                        say(('    %-6s -> %-10s  %s'):format(k, per[k],
                            st and st.present and ('have ' .. st.artifact) or '—'))
                    end
                    say('  a BARE MINOR is not addressable: fetch the resolved patch')
                end
            end
        end
        if want then
            local version = want
            if not version:match('^%d+%.%d+%.%d+$') then
                -- a declared minor (or an alias): resolve it against the index
                if version:match('^%d+%.%d+$') then
                    if not o.src.index then
                        say('  cannot resolve a minor without an index'); return
                    end
                    local body, err = fetch(o.src.index)
                    if not body then say('  FAILED: ' .. tostring(err)); return end
                    local best
                    for v in body:gmatch(o.src.version_href) do
                        if v:match('^' .. version:gsub('%.', '%%.') .. '%.')
                            and (not best or newer_than(v, best)) then best = v end
                    end
                    if not best then
                        say(('  %s is not published'):format(version)); return
                    end
                    say(('  resolved %s -> %s'):format(version, best))
                    version = best
                end
            end
            local body, err = fetch(o.src.url:format(version))
            if not body then say('  FAILED: ' .. tostring(err)); return end
            local okj, decoded = pcall(vim.json.decode, body)
            if not okj or type(decoded) ~= 'table' then
                say('  the response is not JSON — refusing to distil it'); return
            end
            local real = decoded.application_version or version
            say(('  got %s (api_version %s, stage %s, %d classes)'):format(
                tostring(real), tostring(decoded.api_version),
                tostring(decoded.stage), #(decoded.classes or {})))
            local tmp = vim.fn.tempname() .. '.runtime-api.json'
            local fd = assert(io.open(tmp, 'w')); fd:write(body); fd:close()
            local sfx = suffix_of(real)
            if not sfx then say('  cannot derive an artifact suffix'); return end
            say(('  distilling -> %s'):format(o.src.artifact:format(sfx)))
            -- the DECLARED distiller, not a literal: the ecosystem says which tool
            -- turns its API description into an artifact, and specaudit reported this
            -- field UNREAD until it was actually consulted
            local dist = o.src.distiller
            if not dist then say('  no distiller declared'); return end
            local d = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l',
                here .. '/../' .. dist, tmp, sfx }, { text = true }):wait()
            -- gsub returns (string, count): io.write would print the count too
            io.write(((d.stdout or ''):gsub('^', '    ')))
            if d.code ~= 0 then say('  distiller FAILED: ' .. tostring(d.stderr)) end
            vim.fn.delete(tmp)
        end
    end
end
