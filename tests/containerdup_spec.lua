-- CART-1091: two query files on the runtimepath can inject the same container text twice (a stale nvim-treesitter
-- master queries/ dir beside main's site/queries did exactly that to every svelte <script>). Extraction must mint each
-- script definition ONCE, however many times the injection fires.

local ts = require 'cartograph.providers.treesitter'

test('containers: a region injected twice by overlapping query files is extracted once', function ()
    if not (parser_available('svelte') and parser_available('javascript')) then
        skip 'no svelte/javascript parser'
    end
    -- an EXTRA svelte injection query that re-injects every <script> body as javascript, appended via ;extends
    local qdir = vim.fn.tempname()
    vim.fn.mkdir(qdir .. '/queries/svelte', 'p')
    local fd = assert(io.open(qdir .. '/queries/svelte/injections.scm', 'w'))
    fd:write(';extends\n((script_element (raw_text) @injection.content) (#set! injection.language "javascript"))\n')
    fd:close()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    fd = assert(io.open(root .. '/Board.svelte', 'w'))
    fd:write('<script>\n  function bump() { return 1 }\n</script>\n<button onclick={bump}>bump</button>\n')
    fd:close()
    vim.opt.rtp:append(qdir)
    local ok_x, data = pcall(ts.extract, root)
    vim.opt.rtp:remove(qdir)
    vim.fn.delete(qdir, 'rf'); vim.fn.delete(root, 'rf')
    ok(ok_x, tostring(data))
    local bumps, reg = 0, false
    for _, n in ipairs(data.nodes) do if n.name == 'bump' then bumps = bumps + 1 end end
    for _, e in ipairs(data.edges) do
        if e.kind == 'reg' and e.from == 'Board.svelte' and tostring(e.to):find('bump', 1, true) then reg = true end
    end
    eq(1, bumps, 'one definition, not one per injection')
    ok(reg, 'and the handler registers against it')
end)
