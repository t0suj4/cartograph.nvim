-- The protobuf/gRPC contract adapter (CART-0824): a `.proto` file is a DECLARED
-- cross-service contract and joins the graph as a session post-pass, the way
-- django/symfony routes do. These fixtures are the shapes a line-pattern reader
-- gets wrong SILENTLY, which is why the reader is a token scanner.

local proto = require 'cartograph.proto'

local FULL = [[
// a line comment with a "quote and a /* not-a-block
/* a block comment
   spanning lines, with rpc Fake(A) returns (B); inside it */
syntax = "proto3";

package acme.v1;

// ⚠ THE `//` IN THIS STRING IS NOT A COMMENT. A line reader that strips from
// the first `//` truncates the option and then resynchronises mid-declaration.
option go_package = "github.com/acme/v1;acmev1";

option (acme.custom) = {
  note: "a brace body at top level"
  nested { deeper: true }
};

import "other/thing.proto";
import public "pub.proto";

message Outer {
  string a = 1;
  message Inner {          // nested: the qualified name is Outer.Inner
    int32 b = 1;
  }
  enum Flavour { PLAIN = 0; SALTED = 1; }
}

message Empty {}

service Widgets {
  // a MULTI-LINE rpc declaration, and a `;` terminator rather than `{}`
  rpc Make(
      MakeRequest
  ) returns (
      MakeResponse
  );
  rpc Watch(WatchRequest) returns (stream Event) {}
  rpc Upload(stream Chunk) returns (Ack) {}
  rpc Both(stream Chunk) returns (stream Event) {
    option deadline = 5;
  }
  option (acme.svc_opt) = { retries: 3 };
}
]]

test('proto: the hard shapes a line reader gets wrong', function ()
    local r = assert(proto.parse(FULL))
    eq('acme.v1', r.package)
    eq(0, r.refused)
    -- the string holding `//` survived as one option, and the balanced
    -- `option ... = { … }` body did not swallow the declarations after it
    eq(2, #r.imports)
    eq('other/thing.proto', r.imports[1])
    eq('pub.proto', r.imports[2])
    -- nested type names are QUALIFIED, and a nested enum is an enum
    local msgs = {}
    for _, m in ipairs(r.messages) do msgs[#msgs + 1] = m.name end
    table.sort(msgs)
    eq('Empty Outer Outer.Inner', table.concat(msgs, ' '))
    eq(1, #r.enums)
    eq('Outer.Flavour', r.enums[1].name)
    -- one service, four rpcs, INCLUDING the one that wraps across five lines
    eq(1, #r.services)
    eq('Widgets', r.services[1].name)
    local rpcs = r.services[1].rpcs
    eq(4, #rpcs)
    eq('Make', rpcs[1].name)
    eq('MakeRequest', rpcs[1].req)
    eq('MakeResponse', rpcs[1].resp)
    -- streaming is a property of each SIDE, and the four cases are distinct
    eq(nil, rpcs[1].stream_in); eq(nil, rpcs[1].stream_out)
    eq(nil, rpcs[2].stream_in); eq(true, rpcs[2].stream_out)
    eq(true, rpcs[3].stream_in); eq(nil, rpcs[3].stream_out)
    eq(true, rpcs[4].stream_in); eq(true, rpcs[4].stream_out)
    -- and the rpc whose body carries an `option` still closed correctly, or
    -- the service's trailing option would have been read as a declaration
    eq('Both', rpcs[4].name)
end)

-- ★★ THE GUARD, AND IT IS THE POINT OF THE READER. A declarative reader that
-- skips what it does not understand reports a contract that is merely SMALLER,
-- and nothing distinguishes that from a contract that is genuinely small. The
-- hrldistill lesson: its first cut refused 48 of 168 VISIBLY, and the
-- visibility is the only reason the gap was ever found. So the refusal counter
-- is load-bearing and gets its own test.
test('proto: an unrecognised declaration is COUNTED and SAMPLED, never skipped', function ()
    local r = assert(proto.parse([[
syntax = "proto3";
package p;
grommet Widget { }
service S {
  rpc Ok(A) returns (B);
  frobnicate Thing;
  rpc AlsoOk(C) returns (D);
}
]]))
    ok(r.refused > 0, 'the unknown declarations are refused, not skipped')
    eq(1, #r.services)
    -- ★ AND IT RESYNCHRONISES: the rpcs on either side of the junk are both read
    eq(2, #r.services[1].rpcs)
    eq('Ok', r.services[1].rpcs[1].name)
    eq('AlsoOk', r.services[1].rpcs[2].name)
    -- the sample carries a LINE and the offending token, so the refusal is a
    -- place a reader can open rather than a number
    ok(table.concat(r.refusals, ' '):find('grommet'), table.concat(r.refusals, ' '))
end)

test('proto: an unterminated comment or string is a REASON, not a crash', function ()
    local a, why = proto.parse('syntax = "proto3";\n/* never closed\n')
    eq(nil, a)
    ok(why:find('comment'), why)
    local b, why2 = proto.parse('option x = "never closed\n;\n')
    eq(nil, b)
    ok(why2:find('string'), why2)
end)

-- ── the ATTACH half ────────────────────────────────────────────────────────

local function tmproot(files)
    local dir = vim.fn.tempname()
    for rel, src in pairs(files) do
        local sub = rel:match('^(.*)/[^/]+$')
        if sub then vim.fn.mkdir(dir .. '/' .. sub, 'p') else vim.fn.mkdir(dir, 'p') end
        local fd = assert(io.open(dir .. '/' .. rel, 'w'))
        fd:write(src); fd:close()
    end
    return dir
end

local SVC = [[
syntax = "proto3";
package shop;
service Cart {
  rpc AddItem(AddItemRequest) returns (Empty) {}
}
message AddItemRequest { string id = 1; }
message Empty {}
]]

test('proto: attach mints a module per file and a SITE-ANCHORED method per rpc', function ()
    local root = tmproot({ ['a/demo.proto'] = SVC, ['b/demo.proto'] = SVC })
    local data = { root = root, nodes = {}, edges = {} }
    local s = proto.attach(data)
    eq(2, s.files)
    eq(2, s.services)
    eq(2, s.rpcs)
    -- ★★ THE VENDORED COPY IS NOT DEDUPLICATED HERE. Two real declarations at
    -- two real sites; aggregating by qualified name is the JOIN's job, and
    -- doing it in the front end would destroy the evidence the copies exist.
    eq(1, s.qnames)
    eq(2, s.by_qname['shop.Cart/AddItem'])
    local mods, rpcs = {}, {}
    for _, n in ipairs(data.nodes) do
        if n.pb == 'file' then mods[#mods + 1] = n.id
        elseif n.pb == 'rpc' then rpcs[#rpcs + 1] = n end
    end
    eq(2, #mods); eq(2, #rpcs)
    table.sort(rpcs, function (x, y) return x.id < y.id end)
    -- the house id format, `file::name@line` — so the ids differ per SITE and a
    -- future migration to a real spec keeps them
    eq('a/demo.proto::Cart::AddItem@3', rpcs[1].id)
    eq('b/demo.proto::Cart::AddItem@3', rpcs[2].id)
    eq('method', rpcs[1].kind)
    eq('shop.Cart/AddItem', rpcs[1].qname)
    eq('AddItemRequest', rpcs[1].req)
    -- ⚠ AND NOTHING IS A `var`. kb `synthetic-var-node-families`: the four
    -- existing adapters mint kind='var' and atlas.lua's census counts them on
    -- the WRITE AXIS, so django routes land on `const`. A contract declaration
    -- is not a variable.
    for _, n in ipairs(data.nodes) do ok(n.kind ~= 'var', n.id .. ' is a var') end
end)

test('proto: an import resolves inside the root and stays a frontier outside it', function ()
    local root = tmproot({
        ['x/base.proto'] = 'syntax = "proto3";\npackage shop;\nmessage B {}\n',
        ['x/use.proto'] = 'syntax = "proto3";\npackage shop;\n'
            .. 'import "x/base.proto";\nimport "google/protobuf/any.proto";\n',
    })
    local data = { root = root, nodes = {}, edges = {} }
    local s = proto.attach(data)
    eq(2, s.imports) -- both are COUNTED
    local imps = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'import' then imps[#imps + 1] = e.from .. ' -> ' .. e.to end
    end
    -- ...and only the one that lands inside the root becomes an EDGE. The other
    -- points out of the tree and gets no fabricated target.
    eq(1, #imps)
    eq('x/use.proto -> x/base.proto', imps[1])
end)

test('proto: attach is idempotent under refresh and leaves foreign nodes alone', function ()
    local root = tmproot({ ['a/demo.proto'] = SVC })
    local data = { root = root,
        nodes = { { id = 'keep.go', name = 'keep.go', kind = 'module', file = 'keep.go' } },
        edges = { { from = 'keep.go', to = 'keep.go', kind = 'import' } } }
    local s1 = proto.attach(data)
    local n1, e1 = #data.nodes, #data.edges
    local s2 = proto.attach(data)
    eq(s1.rpcs, s2.rpcs)
    eq(n1, #data.nodes)
    eq(e1, #data.edges)
    -- the foreign node and its edge survived both passes
    local kept = false
    for _, n in ipairs(data.nodes) do if n.id == 'keep.go' then kept = true end end
    ok(kept, 'a non-proto node must not be stripped by the adapter')
    eq(1, #data.edges)
end)

test('proto: a root with no .proto files attaches nothing and says so', function ()
    local root = tmproot({ ['a/thing.go'] = 'package main\n' })
    local data = { root = root, nodes = {}, edges = {} }
    local s = proto.attach(data)
    eq(0, s.files)
    eq(nil, data.proto)
    eq(nil, proto.summary(s))
end)

test('proto: the scan honours the WALK\'s exclusion set, not a private copy', function ()
    local ts = require 'cartograph.providers.treesitter'
    ok(ts.EXCLUDE_DIRS and ts.EXCLUDE_DIRS.node_modules,
        'the walk exports its exclusion set so the rule has one home')
    local root = tmproot({
        ['keep/a.proto'] = SVC,
        ['node_modules/dep/b.proto'] = SVC,
        ['.hidden/c.proto'] = SVC,
    })
    local found = proto.find(root)
    eq(1, #found)
    eq('keep/a.proto', found[1])
end)

-- ── THE JOIN: A DECLARED EXPORT SIDE (CART-0825) ───────────────────────────
-- Every other xlang binding finds its export by scanning for a REGISTERING
-- VERB, because in those boundaries the registration is a call. A gRPC service
-- is the other shape: the contract is DECLARED in a .proto file, so the export
-- exists as a NODE before any code runs and there is no call to find. This is
-- the third rung of [[cartograph-registration-relation]]'s one relation, and
-- the XMPP macro join wants the same extension.

test('proto: an rpc node carries the WIRE PATH, which is the join identity', function ()
    local r = assert(proto.parse(
        'syntax = "proto3";\npackage hipstershop;\n'
        .. 'service CartService { rpc AddItem(A) returns (B) {} }\n'))
    eq('hipstershop', r.package)
    local root = tmproot({ ['p/demo.proto'] =
        'syntax = "proto3";\npackage hipstershop;\n'
        .. 'service CartService { rpc AddItem(A) returns (B) {} }\n' })
    local data = { root = root, nodes = {}, edges = {} }
    proto.attach(data)
    local rpc
    for _, n in ipairs(data.nodes) do if n.pb == 'rpc' then rpc = n end end
    -- ★ the leading `/` is part of the gRPC method path per the spec, not a
    -- formatting choice — and it is exactly what both generated stubs write
    eq('hipstershop.CartService/AddItem', rpc.qname)
    eq('/hipstershop.CartService/AddItem', rpc.wire)
end)

test('xlang: a DECLARED export links a wire-path literal to its contract', function ()
    local xlang = require 'cartograph.xlang'
    local root = tmproot({ ['p/demo.proto'] =
        'syntax = "proto3";\npackage shop;\n'
        .. 'service Cart { rpc AddItem(A) returns (B) {} rpc Lonely(C) returns (D) {} }\n' })
    local data = { root = root, nodes = {
        { id = 'stub.py', name = 'stub.py', kind = 'module', file = 'stub.py' },
        { id = 'stub.py::Stub.__init__@1', name = 'Stub.__init__', kind = 'method',
            file = 'stub.py' },
    }, edges = {}, calls = {
        { fn = 'stub.py::Stub.__init__@1', callee = 'unary_unary', file = 'stub.py',
            line = 1, argn = 1,
            argv = { { k = 'lit', v = '/shop.Cart/AddItem' } },
            args = { '/shop.Cart/AddItem' } },
        -- ⚠ A NEAR MISS THAT MUST NOT LINK: the right method NAME under the
        -- wrong service. Joining on `AddItem` would take it; joining on the
        -- wire path refuses it, which is the whole reason the key is the path.
        { fn = 'stub.py::Stub.__init__@1', callee = 'unary_unary', file = 'stub.py',
            line = 2, argn = 1,
            argv = { { k = 'lit', v = '/other.Cart/AddItem' } },
            args = { '/other.Cart/AddItem' } },
    } }
    proto.attach(data)
    xlang.link(data)
    local wire_of, hits = {}, {}
    for _, n in ipairs(data.nodes) do if n.pb == 'rpc' then wire_of[n.id] = n.wire end end
    for _, e in ipairs(data.edges) do
        if e.xlang and wire_of[e.to] then hits[wire_of[e.to]] = (hits[wire_of[e.to]] or 0) + 1 end
    end
    eq(1, hits['/shop.Cart/AddItem'])
    -- the second rpc is declared and nothing names it: an honest empty, and it
    -- must stay empty rather than collecting the near-miss above
    eq(nil, hits['/shop.Cart/Lonely'])
    eq(nil, hits['/other.Cart/AddItem'])
end)

-- ── THE DEPLOYMENT LAYER (CART-0830) ───────────────────────────────────────
-- A kubernetes manifest is a THIRD declared artefact beside the source and the
-- contract, and it carries the one thing a runtime observation cannot get
-- anywhere else: the map from a running service's name back to its code.

local k8s = require 'cartograph.k8s'

local MANIFEST = [[
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  labels:
    app: frontend
spec:
  template:
    spec:
      serviceAccountName: frontend
      containers:
      - name: server
        image: gcr.io/example/frontend:v1.2
        ports:
        - containerPort: 8080
        env:
        - name: PORT
          value: "8080"
        - name: CART_SERVICE_ADDR
          value: "cartservice:7070"
        - name: GHOST_SERVICE_ADDR
          value: "ghostservice:9999"
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
spec:
  ports:
  - port: 80
]]

local CART = [[
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cartservice
spec:
  template:
    spec:
      containers:
      - name: server
        image: cartservice
]]

test('k8s: a manifest yields services, ports and the declared peer topology', function ()
    local root = tmproot({
        ['k/frontend.yaml'] = MANIFEST,
        ['k/cartservice.yaml'] = CART,
        ['skaffold.yaml'] = 'apiVersion: skaffold/v4beta1\nbuild:\n  artifacts:\n'
            .. '  - image: frontend\n    context: src/frontend\n'
            .. '  - image: cartservice\n    context: src/cartservice/src\n',
    })
    local data = { root = root, nodes = {}, edges = {} }
    local s = k8s.attach(data)
    eq(2, s.files)
    eq(3, s.docs) -- two Deployments and a Service
    -- ★ THE IMAGE -> SOURCE JOIN IS SKAFFOLD'S DECLARED CONTEXT, and the fixture
    -- carries the case a name match gets wrong: cartservice lives in
    -- `src/cartservice/src`, not `src/cartservice`.
    eq('src/frontend', k8s.dir_of(data, 'frontend'))
    eq('src/cartservice/src', k8s.dir_of(data, 'cartservice'))
    -- ⚠ AND THE REGISTRY PREFIX MUST NOT DEFEAT IT. `gcr.io/example/frontend:v1.2`
    -- and skaffold's bare `frontend` are the same artifact; keying on the full
    -- string mapped one service of fifteen on the real corpus.
    local declared = 0
    for _, e in ipairs(data.edges) do if e.k8 == 'declares' then declared = declared + 1 end end
    eq(1, declared) -- frontend -> cartservice, and NOT frontend -> ghostservice
    -- ★★ THE ONE-SIDED EDGE IS THE POINT, not an omission: `GHOST_SERVICE_ADDR`
    -- names a service this deployment does not contain. That is the k8s design's
    -- A4 bipartite shape, and it is REPORTED rather than resolved into a
    -- fabricated target — an overlay or an operator may still supply it.
    eq(1, #s.dangling)
    ok(s.dangling[1]:find('ghostservice'), s.dangling[1])
end)

test('k8s: a TEMPLATED document is refused and counted, never half-read', function ()
    local root = tmproot({
        ['helm/templates/x.yaml'] = 'apiVersion: apps/v1\nkind: Deployment\n'
            .. 'metadata:\n  name: {{ .Values.name }}\nspec:\n  replicas: {{ .Values.n }}\n',
        ['k/ok.yaml'] = CART,
    })
    local data = { root = root, nodes = {}, edges = {} }
    local s = k8s.attach(data)
    -- the plain manifest is read...
    eq(1, s.files)
    eq(1, s.services)
    -- ...and the helm template is REFUSED, with a reason. A reader that took its
    -- literal `{{ .Values.name }}` as a service name would invent a workload.
    ok(s.refused >= 1, 'the templated document is refused')
    ok(table.concat(s.refusals, ' '):find('templated'), table.concat(s.refusals, ' '))
end)

test('k8s: the same service in two variants is two declarations, not one', function ()
    -- ⚠ A repo routinely declares one system several times (raw manifests, a
    -- release bundle, kustomize overlays). Keying services by NAME alone merged
    -- them on the real corpus and currencyservice came back with three copies of
    -- its port, as though it listened three times.
    local root = tmproot({ ['base/c.yaml'] = CART, ['release/c.yaml'] = CART })
    local data = { root = root, nodes = {}, edges = {} }
    local s = k8s.attach(data)
    eq(2, s.services)
    local variants = {}
    for _, sv in pairs(s.services_map) do variants[sv.variant] = true end
    ok(variants['base'] and variants['release'], 'one declaration per variant')
end)

test('k8s: attach is idempotent and mints no node kind the schema lacks', function ()
    local validate = require 'cartograph.validate'
    local root = tmproot({ ['k/c.yaml'] = CART })
    local data = { root = root, nodes = {}, edges = {} }
    local s1 = k8s.attach(data)
    local n1, e1 = #data.nodes, #data.edges
    local s2 = k8s.attach(data)
    eq(s1.services, s2.services)
    eq(n1, #data.nodes); eq(e1, #data.edges)
    -- ★ THE PRE-`instance`-KIND CUT: the design proposes instance/workload/
    -- listener/principal and none is in NODE_KINDS. Minting one here would
    -- pre-empt CART-0140's schema decision.
    for _, n in ipairs(data.nodes) do
        ok(validate.NODE_KINDS[n.kind], n.kind .. ' is not a declared node kind')
    end
end)
