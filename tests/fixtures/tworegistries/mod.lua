-- TWO registries in one tree, which the single-registry `listener` fixture
-- cannot reach — and E>=2 is what the discovery memo (CART-0785) is about: the
-- per-verb key cache is shared across the import search, so an entry attributed
-- to the wrong verb makes each registry claim the other's importer.
--
-- ★ THE TWO REGISTRIES ARE DELIBERATELY UNALIKE ON EVERY AXIS THE MEMO CACHES:
--   · disjoint key sets      (on_* vs build/clean/test) — a shared key TABLE shows
--   · different key POSITION on the import side (fire_hook's is 2nd, run_cmd's is
--     1st) — a shared POSITION list shows
-- A first cut had both at position 1, and a break that crossed the two verbs'
-- positions passed it while the OLD one-registry fixture caught the same break.
-- Same-shaped registries do not test a cache keyed by shape.

local hooks = require 'hooks'
local cmds = require 'cmds'

hooks.add_hook("on_save", function () end)
hooks.add_hook("on_load", function () end)
hooks.add_hook("on_quit", function () end)

cmds.define_cmd("build", function () end)
cmds.define_cmd("clean", function () end)
cmds.define_cmd("test", function () end)

-- importers: each fires only its OWN registry's keys, at its own position
hooks.fire_hook(ctx, "on_save")
hooks.fire_hook(ctx, "on_load")
hooks.fire_hook(ctx, "on_quit")

cmds.run_cmd("build")
cmds.run_cmd("clean")
cmds.run_cmd("test")
