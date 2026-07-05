# Example project configs

Cartograph's defaults are deliberately generic: they assume nothing about
your framework, your state machine, or your runtime. Everything
project-specific — lifecycle entry points, FSM adapters, live-oracle
queries, database links — is a few lines of `setup{}`, and these files
show complete, working shapes to copy from.

Each file is a self-contained `setup{}` call with commentary. Take the
blocks you need; nothing here is loaded automatically.

- **factorio.lua** — a Factorio mod: lifecycle entry points, an FSM
  adapter over a data-table state machine, and the live oracle dialing a
  running game through an MCP server. This is the maximal example: static
  graph, state browsing, and runtime-vs-model diffing.
- **wordpress.lua** — a classic PHP codebase: vendored-directory excludes,
  dispatch pins for the sites discovery can't see, and linking the code's
  SQL entities to a live database over MCP.

The rule of thumb: if a feature stands down with a "not configured"
message, the wiring it wants is in one of these files.
