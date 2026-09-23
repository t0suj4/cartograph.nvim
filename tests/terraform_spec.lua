-- CART-1042: the declared cloud layer — Terraform read and evaluated WITHOUT running Terraform.
-- ★ MEASURED ON jenkins-infra: 39 of 40 DNS records in azure/digitalocean/fastly resolve to a
-- host, some through a module output three hops away and a count derived from a counted data
-- source; 18 of the 26 distinct hosts are written literally elsewhere in the org (a witness).

local TF = require 'cartograph.terraform'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'terraform') then skip('no terraform tree-sitter parser') end
end

local function repo(files)
    local root = vim.fn.tempname()
    for rel, body in pairs(files) do
        local p = root .. '/' .. rel
        vim.fn.mkdir(vim.fn.fnamemodify(p, ':h'), 'p')
        local fd = assert(io.open(p, 'w')); fd:write(body); fd:close()
    end
    return root
end

local FILES = {
    ['main.tf'] = [[
locals { zone = "example.org" }
variable "env" { default = "prod" }
module "dns" {
  source = "./modules/zone"
  zone   = "sub.${local.zone}"
}
resource "azurerm_dns_a_record" "www" {
  name      = "www"
  zone_name = module.dns.zone_name
  records   = [azurerm_public_ip.x.ip_address]
}
resource "azurerm_dns_a_record" "maybe" {
  count     = var.env != "" ? 1 : 0
  name      = "maybe-${count.index}"
  zone_name = local.zone
}
resource "azurerm_dns_a_record" "off" {
  count     = var.env == "" ? 1 : 0
  name      = "off"
  zone_name = local.zone
}
resource "azurerm_dns_cname_record" "computed" {
  name      = azurerm_public_ip.x.ip_address
  zone_name = local.zone
}
resource "azurerm_public_ip" "x" { name = "pip" }
resource "digitalocean_domain" "d" { name = "do.example.org" }
resource "digitalocean_record" "r" {
  domain = digitalocean_domain.d.id
  name   = lower("API")
  type   = "A"
}
resource "azurerm_dns_a_record" "keyed" {
  for_each  = toset(["a"])
  name      = each.key
  zone_name = local.zone
}
module "remote" { source = "hashicorp/thing" }
resource "azurerm_dns_a_record" "far" {
  name      = "far"
  zone_name = module.remote.zone
}
resource "azurerm_dns_a_record" "lb" {
  name      = "${azurerm_public_ip.x.ip_address}-lb"
  zone_name = local.zone
}
resource "azurerm_dns_a_record" "regexed" {
  name      = regex("^[a-z]+", "abc1")
  zone_name = local.zone
}
resource "azurerm_dns_a_record" "undecided" {
  count     = azurerm_public_ip.x.ip_address == "" ? 0 : 1
  name      = "u"
  zone_name = local.zone
}
resource "azurerm_dns_a_record" "alias1" {
  name      = "one"
  zone_name = local.zone
  records   = [azurerm_public_ip.x.ip_address]
}
resource "azurerm_dns_a_record" "alias2" {
  name      = "two"
  zone_name = local.zone
  records   = [azurerm_public_ip.x.ip_address]
}
locals {
  sites = { for s in ["a", "b"] : s => "${s}.web" }
}
resource "azurerm_dns_cname_record" "site" {
  for_each  = local.sites
  name      = each.value
  zone_name = local.zone
}
]],
    ['hosts.yaml'] = 'hosts:\n  - x\n  - y\n',
    ['more.tf'] = [[
locals {
  m    = { a = "1" }
  c1   = can(local.m["b"])
  c2   = can(local.m["a"])
  c3   = try(local.m["b"], "dflt")
  c4   = can(regex("x", "y"))
  hs   = yamldecode(file("${path.module}/hosts.yaml")).hosts
  out  = file("../outside.txt")
  prod = length(setproduct(["a", "b"], ["1", "2", "3"]))
}
resource "azurerm_dns_a_record" "fromyaml" {
  for_each  = toset(local.hs)
  name      = each.key
  zone_name = "example.org"
}
resource "azurerm_private_dns_zone" "pz" { name = "privatelink.example.net" }
resource "azurerm_private_dns_a_record" "byid" {
  name                = "svc"
  private_dns_zone_id = azurerm_private_dns_zone.pz.id
}
]],
    ['modules/zone/main.tf'] = [[
variable "zone" {}
resource "azurerm_dns_zone" "z" { name = var.zone }
output "zone_name" { value = azurerm_dns_zone.z.name }
]],
}

local function records()
    local data = { root = repo(FILES), nodes = {}, edges = {} }
    local s = TF.attach(data)
    local by = {}
    for _, r in ipairs(data.terraform.records) do by[r.address] = r end
    return by, s, data
end

test('terraform: ★ a host assembled through a MODULE OUTPUT bound per instance', function ()
    ready()
    local by = records()
    eq('sub.example.org', by['.:azurerm_dns_a_record.www'].host:match('^www%.(.*)$'))
    eq('www.sub.example.org', by['.:azurerm_dns_a_record.www'].host)
    eq('sub.example.org', by['./module.dns:azurerm_dns_zone.z'].host)
end)

test('terraform: a decidable COUNT is one record per index; a count of 0 declares none', function ()
    ready()
    local by = records()
    eq('maybe-0.example.org', by['.:azurerm_dns_a_record.maybe[0]'].host)
    for addr in pairs(by) do ok(not addr:find('azurerm_dns_a_record.off', 1, true), 'count = 0: ' .. addr) end
end)

test('terraform: a documented PROVIDER FACT resolves (digitalocean_domain.id is the name)', function ()
    ready()
    local by = records()
    eq('api.do.example.org', by['.:digitalocean_record.r'].host)
end)

test('terraform: ★★ what only Terraform knows is OPAQUE — a named hole, and the host a PARTIAL residual', function ()
    ready()
    local by = records()
    local c = by['.:azurerm_dns_cname_record.computed']
    eq(nil, c.host)
    eq('«.:azurerm_public_ip.x.ip_address».example.org', c.partial)
    -- a TEMPLATE interpolating an opaque keeps its literal parts around the named hole
    eq('«.:azurerm_public_ip.x.ip_address»-lb.example.org', by['.:azurerm_dns_a_record.lb'].partial)
    local f = by['.:azurerm_dns_a_record.far']
    eq(nil, f.host)
    ok(f.partial and f.partial:find('^far%.«') and f.partial:find('remote hashicorp/thing', 1, true), tostring(f.partial))
end)

test('terraform: what cannot even be NAMED stays UNKNOWN with its reason', function ()
    ready()
    local by = records()
    local r = by['.:azurerm_dns_a_record.regexed']
    eq(nil, r.host); eq(nil, r.partial); ok(r.unresolved:find('regex', 1, true), r.unresolved)
    local u = by['.:azurerm_dns_a_record.undecided']
    eq(nil, u.host); ok(u.unresolved:find('opaque', 1, true), u.unresolved)
end)

test('terraform: ★ for_each is instances per key; a for expression builds the collection', function ()
    ready()
    local by = records()
    eq('a.example.org', by['.:azurerm_dns_a_record.keyed["a"]'].host)
    eq('a.web.example.org', by['.:azurerm_dns_cname_record.site["a"]'].host)
    eq('b.web.example.org', by['.:azurerm_dns_cname_record.site["b"]'].host)
end)

test('terraform: ★★ two records pointing at ONE opaque target share an ENDPOINT — identity without a value', function ()
    ready()
    local _, s, data = records()
    local hosts = data.terraform.endpoints['«.:azurerm_public_ip.x.ip_address»']
    ok(hosts, 'the opaque target is an endpoint')
    table.sort(hosts)
    eq('one.example.org,two.example.org,www.sub.example.org', table.concat(hosts, ','))
    ok(s.shared >= 1, 'counted as shared')
end)

test('terraform: files are module nodes; a module call is a `use` edge to the child\'s files; re-attach is idempotent', function ()
    ready()
    local _, s, data = records()
    eq(3, s.files)
    local found = false
    for _, e in ipairs(data.edges) do
        if e.tf == 'module' and e.from == 'main.tf' and e.to == 'modules/zone/main.tf' then found = true end
    end
    ok(found, 'main.tf -> modules/zone/main.tf')
    local n, m = #data.nodes, #data.edges
    TF.attach(data)
    eq(n, #data.nodes); eq(m, #data.edges)
end)

test('terraform: the evaluator — operators with HCL precedence quirks, functions, conditionals', function ()
    ready()
    local blocks = TF.parse([[
locals {
  a = !var.off && (1 + 2 > 2)
  b = format("%s-%s", "x", replace("a.b", ".", "-"))
  c = join(",", concat(["p"], split(",", "q,r")))
  d = var.name != "" ? upper(var.name) : "none"
  e = trimsuffix(trimsuffix("host.zone.org", "zone.org"), ".")
}
variable "off" { default = false }
variable "name" { default = "n" }
]], 'x.tf')
    local mod = { dir = '', files = {}, resources = {}, data = {}, locals = {}, vars = {}, outputs = {}, calls = {}, order = {} }
    TF.add_blocks(mod, blocks)
    local inst = { mod = mod, inputs = {}, key = '.', memo = {}, busy = {}, models = {}, children = {}, scope = {} }
    local function ev(name) return TF.eval(mod.locals[name], inst) end
    eq(true, ev('a'))            -- `!var.off` binds the attribute INSIDE the negation
    eq('x-a-b', ev('b'))
    eq('p,q,r', ev('c'))
    eq('N', ev('d'))
    eq('host', ev('e'))
end)

test('terraform: can/try catch an ABSENT attribute or index — never a real unknown', function ()
    ready()
    local _, _, data = records()
    local root = data.terraform.roots[1]
    local function ev(n) return TF.eval(root.mod.locals[n], root) end
    eq(false, ev('c1')); eq(true, ev('c2')); eq('dflt', ev('c3'))
    ok(TF.is_unknown(ev('c4')), 'can() over an unimplemented function stays unknown')
    eq(6, ev('prod'))
end)

test('terraform: yamldecode(file("${path.module}/…")) reads the tree through cartograph\'s YAML reader; never outside it', function ()
    ready()
    local by, _, data = records()
    eq('x.example.org', by['.:azurerm_dns_a_record.fromyaml["x"]'].host)
    eq('y.example.org', by['.:azurerm_dns_a_record.fromyaml["y"]'].host)
    -- a real file OUTSIDE the root, so an escape would read it rather than fail for another reason
    local outside = vim.fn.fnamemodify(data.root, ':h') .. '/outside.txt'
    local fd = assert(io.open(outside, 'w')); fd:write('secret'); fd:close()
    local root = data.terraform.roots[1]
    root.memo = {}
    local v = TF.eval(root.mod.locals.out, root)
    os.remove(outside)
    eq(true, TF.is_unknown(v))
    eq('file outside the tree', v.unknown)
end)

test('terraform: ★ a zone passed as an ID resolves through the resource the ID BELONGS to (identity, not text)', function ()
    ready()
    local by = records()
    eq('svc.privatelink.example.net', by['.:azurerm_private_dns_a_record.byid'].host)
end)
