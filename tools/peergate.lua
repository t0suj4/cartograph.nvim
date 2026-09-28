-- peergate — CART-1160 step 9c's acceptance on a REAL tree: peer-project FEDERATION against the MERGED graph. The
-- root is extracted once as ONE graph and xlang links it (the in-graph oracle: every cross-language ref edge a
-- binding makes); then the exporter and importer subtrees are extracted as SEPARATE bands, mounted, and the linkage
-- is derived over the namespace. Rows (caller fn -> handler), band ids re-rooted to the root: MATCH / MISS / EXTRA.
--
--   nvim --headless -u NONE -l tools/peergate.lua <root> <exporter subdir> <importer subdir> <verb>:<arg>:<handler pattern>[:ident]
--   e.g. luanti: tools/peergate.lua ~/git/luanti src builtin API_FCT:1:l_%s:ident
-- Reads the tree only; writes nothing.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local ts = require 'cartograph.providers.treesitter'
local X = require 'cartograph.xlang'
local F = require 'cartograph.federation'
local NS = require 'cartograph.namespace'
local root = vim.fn.fnamemodify(assert(arg[1], 'usage: <root> <exporter> <importer> <binding>'), ':p'):gsub('/$', '')
local exp, imp, spec = assert(arg[2]), assert(arg[3]), assert(arg[4])
local verb, argn, handler, ident = spec:match('^([^:]+):(%d+):([^:]+):?(%a*)$')
local B = { { export = { verb = verb, name = tonumber(argn), handler = handler, ident = ident == 'ident' or nil }, import = { any_call = true } } }

local t0 = vim.uv.hrtime()
local merged = ts.extract(root, { profile = false })
local st = X.link(merged, B)
local lang_of = function (f) return ts.parse_lang(f) end
local oracle = {}
for _, e in ipairs(merged.edges) do
    if e.kind == 'ref' and e.xlang then
        local ff, tf = e.from:match('^(.-)::'), e.to:match('^(.-)::')
        -- the CROSS-BAND links only: a caller under the importer subtree, a handler under the exporter subtree
        if ff and tf and ff:sub(1, #imp + 1) == imp .. '/' and tf:sub(1, #exp + 1) == exp .. '/' then oracle[e.from .. '\31' .. e.to] = true end
    end
end
local t1 = vim.uv.hrtime()
local E = ts.extract(root .. '/' .. exp, { profile = false })
local I = ts.extract(root .. '/' .. imp, { profile = false })
local ns = NS.mount(NS.mount(NS.empty(), E.root, E, { bindings = B }), I.root, I, { share = { E.root } })
local L = F.linkage(ns)
local fed = {}
for _, r in ipairs(L.rows) do fed[imp .. '/' .. r.from .. '\31' .. exp .. '/' .. r.to] = true end
local t2 = vim.uv.hrtime()
local match, miss, extra, ex_m, ex_e = 0, 0, 0, {}, {}
for k in pairs(oracle) do if fed[k] then match = match + 1 else miss = miss + 1; if #ex_m < 6 then ex_m[#ex_m + 1] = k:gsub('\31', ' -> ') end end end
for k in pairs(fed) do if not oracle[k] then extra = extra + 1; if #ex_e < 6 then ex_e[#ex_e + 1] = k:gsub('\31', ' -> ') end end end
io.write(('%s: merged graph %d registrations (%d keys), %d cross-band xlang edge(s); federated %d row(s), %d miss(es) in the linkage\n')
    :format(root, st.exports, vim.tbl_count(st.keys or {}), vim.tbl_count(oracle), vim.tbl_count(fed), #L.misses))
io.write(('MATCH %d · MISS %d · EXTRA %d   (merged %.1f s, federated %.1f s)\n'):format(match, miss, extra, (t1 - t0) / 1e9, (t2 - t1) / 1e9))
for _, x in ipairs(ex_m) do io.write('  MISS  ', x, '\n') end
for _, x in ipairs(ex_e) do io.write('  EXTRA ', x, '\n') end
os.exit((miss == 0 and extra == 0 and match > 0) and 0 or 1)
