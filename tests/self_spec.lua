-- The self provider: the running instance as a multi-root corpus.
-- Roster comes from the runtimepath (deterministic here — run.sh puts the
-- checkout on rtp); resolution across roots is exercised with temp fixtures.

local function has_parser(lang)
    return pcall(vim.treesitter.language.add or vim.treesitter.language.require_language, lang)
end

test('self: runtimepath is the loaded-root roster; VIMRUNTIME held lazy', function ()
    local selfp = require 'cartograph.providers.self'
    local kept, vr = selfp.roots()
    ok(vr ~= '', 'VIMRUNTIME is known')
    ok(#kept >= 1, 'at least one loaded root')
    local norm = function (p) return (vim.fn.fnamemodify(p, ':p')):gsub('/+$', '') end
    local cwd, found = norm(vim.fn.getcwd()), false
    for _, r in ipairs(kept) do
        ok(r.label and r.dir, 'each kept root has a label + dir')
        ok(r.dir ~= vr and r.dir:sub(1, #vr + 1) ~= vr .. '/',
            'no kept root lives inside $VIMRUNTIME (that is the lazy node)')
        if norm(r.dir) == cwd then found = true end
    end
    ok(found, 'the cartograph checkout (on rtp) is a kept root')
end)

test('self: multi-root corpus — labelled keys resolve, refs cross roots', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local ts    = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local dirA  = vim.fn.tempname(); vim.fn.mkdir(dirA, 'p')
    local dirB  = vim.fn.tempname(); vim.fn.mkdir(dirB, 'p')
    local function put(dir, f, t)
        local fd = assert(io.open(dir .. '/' .. f, 'w')); fd:write(t); fd:close()
    end
    -- B defines a uniquely-named global; A calls it — the only way that link
    -- resolves is if both roots share ONE corpus (cross-root name match).
    put(dirB, 'lib.lua', 'function uniquehelper(x)\n  return x + 1\nend\n')
    put(dirA, 'app.lua', 'local function run()\n  return uniquehelper(41)\nend\nreturn run\n')

    local roots = { plugA = dirA, plugB = dirB }
    local files = { 'plugA/app.lua', 'plugB/lib.lua' }
    local function abs(file)
        local label, rest = file:match('^([^/]+)/(.*)$')
        return roots[label] .. '/' .. rest
    end
    local data = ts.extract('self://loaded', { files = files, abs = abs })
    data.roots = roots

    local byfile = {}
    for _, n in ipairs(data.nodes) do byfile[n.file] = true end
    ok(byfile['plugA/app.lua'] and byfile['plugB/lib.lua'],
        'nodes carry plugin-labelled file keys')

    store.data = data
    eq(dirB .. '/lib.lua', store.abs('plugB/lib.lua'),
        'abspath resolves a labelled key through the roots map')

    -- the call in A settled onto B's function (cross-root, one corpus)
    local crossed = false
    for _, c in ipairs(data.calls) do
        if c.callee == 'uniquehelper' and c.to and c.to:match('^plugB/') then
            crossed = true
        end
    end
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.from:match('^plugA/') and e.to:match('^plugB/') then
            crossed = true
        end
    end
    ok(crossed, 'a call in plugA resolves to plugB — cross-root resolution')

    vim.fn.delete(dirA, 'rf'); vim.fn.delete(dirB, 'rf')
end)
