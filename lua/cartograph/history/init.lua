-- cartograph.history — offline history archaeology.
--
-- A sibling tool to the live cockpit: it reads git history rather than the
-- current buffer, and produces reports rather than driving panes. It shares the
-- cockpit's graph extractor (one dump per commit, cached by sha) but nothing
-- else, so it stands on its own.
--
--   reconstruct.run{repo, from, to}  -> per-commit structural ledger
--   couplingmine.run{repo, from, to} -> temporal (change) coupling
--
-- ledger / coupling are the pure diff/counting cores the two drivers sit on.

return {
    reconstruct  = require 'cartograph.history.reconstruct',
    couplingmine = require 'cartograph.history.couplingmine',
    ledger       = require 'cartograph.history.ledger',
    coupling     = require 'cartograph.history.coupling',
}
