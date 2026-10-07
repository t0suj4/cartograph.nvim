-- THE MIX BATTERY (CART-1537): the gates every mix / saturate / algebra-derivation change of 2026-10-07 was run through
-- by hand, as one declared experiment. The variant is the WORKING TREE, the baseline HEAD — run it before a commit:
--   nvim --headless -u NONE -l tools/toolbelt.lua run experiment - decl=@tools/experiments/mix-battery.lua
-- Instruments run as their own processes with their cwd in each tree; a relative instrument file is the variant's (both
-- sides run the same instrument). ~40 min on this machine.
-- (derive-accept HOLDS since 2026-10-07 — 34 agree, 0 differ, 0 no sample, 0 refused — so each of its gates is the
-- claim itself; before resolve specialized they were no-regression: compare = '(%d+ agree, …)', better = { 'up', … })
return {
    name = 'mix-battery',
    baseline = 'HEAD',
    instruments = {
        { name = 'mix + algebra specs', kind = 'specs', specs = { 'mix_spec', 'mixgaps_spec', 'mixalg_spec', 'compiledverb_spec',
            'saturate_spec', 'mixproj_spec', 'algebra_spec', 'algebradonor_spec', 'kvterm_spec', 'fnpeer_spec' } },
        { name = 'derive-accept plain', kind = 'tactic', tactic = 'derive-accept', expect = 'holds' },
        { name = 'derive-accept through', kind = 'tactic', tactic = 'derive-accept', params = { through = 1 }, expect = 'holds' },
        { name = 'derive-accept + the derived client', kind = 'tactic', tactic = 'derive-accept', params = { fuzz = 120 }, expect = 'holds' },
        { name = 'compiled matchers equal A.match', kind = 'check', file = 'tools/experiments/instruments/cmreg.lua', pattern = '0 refused;.*, 0 differ;' },
        { name = "mix's sets unchanged (row join)", kind = 'join', file = 'tools/experiments/instruments/lowersets.lua' },
        { name = 'compile time (33 matchers)', kind = 'ab', file = 'tools/experiments/instruments/cmreg.lua', extract = 'compile ([%d.]+) s', runs = 5, bound = 1.10 },
        { name = 'lowering time (derivations)', kind = 'ab', file = 'tools/experiments/instruments/lowertime.lua', extract = 'derivations%(%d+%) ([%d.]+) ms', runs = 5, bound = 1.15 },
    },
}
