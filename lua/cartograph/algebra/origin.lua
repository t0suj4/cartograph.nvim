-- cartograph.algebra.origin — WHERE THE VENDORED ALGEBRA CAME FROM (CART-0912).
--
-- ★★★ THE VENDORED COPY IS NOT A SECOND AUTHORITY, BECAUSE IT IS STAMPED.
-- The standing objection to vendoring is CART-0746's — A COPIED WALKER IS A
-- COPIED BUG — and `tools/algebradrive.lua` states it as a rule: "a copied
-- algebra would be a second authority that drifts". That objection is about
-- SILENT drift. A copy that records its origin, and a fence that reads the
-- record, cannot drift silently: `tools/vendordrift.lua` reports three states
-- and two of them are findings.
--
-- ★★ THE THREE STATES, AND WHY DIVERGENCE IS NOT AN ERROR. The end goal is that
-- this code is CARTOGRAPH'S OWN (user, 2026-09-13), so a deliberate local edit
-- is the plan, not a fault. What must never happen is not knowing which of the
-- two moved:
--
--     IDENTICAL       the copy still equals the recorded origin content
--     DIVERGED        WE edited the copy — expected once adaptation starts
--     ORIGIN MOVED    the DONOR changed under a stamp that says otherwise
--
-- ⚠ THE DONOR'S ABSENCE IS NOT A FAILURE. This machine has the prototype; a
-- clone of cartograph need not. A missing donor makes the drift check
-- UNAVAILABLE, which is its own answer — never "identical" and never a failure,
-- the same absence/unavailable split the transport layer already draws.
--
-- ★ AND THIS IS THE PROVENANCE SLOT THE ABSORB VERB NEEDS ANYWAY. Any future
-- donor gets a record of this shape; the licence design requires that origin
-- ride WITH the code and survive substitution, and a field that is not written
-- at vendor time cannot be recovered by re-deriving it later.

return {
    -- the donor, as it was when this copy was taken
    donor_repo   = '~/tools/templates',
    donor_file   = 'algebra.lua',
    donor_rev    = 'c07bdd40a0a288a71506c07e48dff5ff91055765',
    donor_clean  = true,     -- the donor working tree had no uncommitted changes
    vendored_at  = '2026-09-13',
    vendored_by  = 'CART-0912',

    -- sha256 of the bytes as vendored. `vendordrift` compares BOTH sides
    -- against this, which is what separates "we edited it" from "it moved".
    sha256       = '350ce5c23a564a341685cd5e88a7ec55ade06481f86ca69dd9db3b5ed156ff6f',
    lines        = 6001,

    -- ⚠ ONE LINE OF THE DONOR DOES NOT PORT, AND IT IS DELIBERATELY LEFT IN.
    -- `core.lua:5999` reads
    --     if os.getenv('DERIVE') then require('derive').apply_to(M, ...) end
    -- `derive.lua` is a PROTOTYPE-DEVELOPMENT affordance (re-derive the
    -- operators from the four-arrow basis to check the basis still spans them).
    -- It is env-gated and dead with DERIVE unset, and vendoring it would put a
    -- bare top-level module name `derive` on our package.path. Left verbatim so
    -- the copy stays byte-comparable; if we ever want that check it belongs in
    -- `tools/`, not here.
    unported     = { 'core.lua:5999 — optional `require("derive")`, env-gated on DERIVE' },
}
