-- sink-concat (taint rung 0): an unsanitized param string-concatenated into
-- a query-shaped sink fires `~`; scalar-typed / cast-sanitized / non-sink
-- egress do NOT. Mirrors grocy's StockService divergent-sibling pattern
-- (the ground-truth vuln fixed in c415e2f).

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local sinkflow = require 'cartograph.sinkflow'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'php')
end

local function write(root, rel, text)
    local dir = root .. '/' .. (rel:match('^(.*)/[^/]*$') or '')
    vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(root .. '/' .. rel, 'w'))
    fd:write(text)
    fd:close()
end

test('sink-concat: divergent siblings — vuln fires, sanitized peers do not', function ()
    if not ready() then skip 'no php parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    write(root, 'R.php', table.concat({
        '<?php',
        'class R {',
        '  public function vuln($productId) {',                       -- UNTYPED → fires
        "    $where = 'product_id = ' . $productId;",
        '    return $this->db->where($where);',
        '  }',
        '  public function safe(int $productId) {',                   -- int hint → sanitized
        "    $where = 'product_id = ' . $productId;",
        '    return $this->db->where($where);',
        '  }',
        '  public function castSafe($productId) {',                   -- inline cast → sanitized
        "    $where = 'product_id = ' . (int)$productId;",
        '    return $this->db->where($where);',
        '  }',
        '  public function notASink($msg) {',                         -- not a query sink
        "    $line = 'user said ' . $msg;",
        '    return $this->logger->info($line);',
        '  }',
        '}',
    }, '\n'))
    store.ingest(ts.extract(root))
    local fs = sinkflow.findings(store)
    eq(1, #fs, 'only the untyped vuln fires')
    ok(fs[1].message:find('productId', 1, true), 'names the tainted param')
    ok(fs[1].message:find('peer', 1, true), 'annotates the sanitizing sibling')
    ok(fs[1].file:find('R.php', 1, true))
end)

test('sink-concat: parameterization sanitizes; a lone raw offender needs a peer', function ()
    if not ready() then skip 'no php parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    write(root, 'L.php', table.concat({
        '<?php',
        'class L {',
        '  public function safe(int $id) {',                          -- typed peer for `query`/id
        "    $q = 'id = ' . $id;",
        '    return $this->db->query($q);',
        '  }',
        '  public function paramd($id) {',                            -- param-wrapped = safe channel
        "    $q = 'id = ' . $this->db->param($id);",                  -- would fire but for the wrapper
        '    return $this->db->query($q);',
        '  }',
        '  public function lone($name) {',                            -- raw, but NO sanitized peer
        "    $q = 'name = ' . $name;",
        '    return $this->db->query($q);',
        '  }',
        '}',
    }, '\n'))
    store.ingest(ts.extract(root))
    local fs = sinkflow.findings(store)
    eq(0, #fs, 'param() wrapping suppresses paramd; lone raw has no divergent peer (rung 2)')
end)
