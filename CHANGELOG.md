# Changelog

## v0.1.0 (2026-11-12)

Initial release.

- Parse and encode `cpn-spec 1.0` nets (`.cpn.tcl`): typed places, `init`
  tokens, transitions with `in`/`out` arcs, `local`/`shell`/`http`/`retry`
  guards, `priority`, `label`. No runtime dependencies.
- `ExCpn.Validator`: unknown places, duplicate names, bad guard targets,
  `retry` naming a missing transition, `local` guard syntax, unreferenced
  places.
- `ExCpn.Expr`: the Tcl `expr` subset used by `local` guards.
- `ExCpn.Marking`: pure token-game semantics with priority ordering and
  fair rotation so self-loops cannot starve siblings.
- `ExCpn.Instance`: `gen_statem` runner with host-bound actions under a
  `Task.Supervisor`, retry budgets feeding `retry` guards, and a journal
  callback.
