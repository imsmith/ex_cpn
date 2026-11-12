# ExCpn

Coloured Petri Net action models for Elixir. Parses, encodes, validates, and
runs nets written in the `.cpn.tcl` format: typed places, transitions with
`in`/`out` arcs, four-target guards (`local`, `shell`, `http`, `retry`),
priorities, and labels. No runtime dependencies.

```elixir
{:ok, net} = ExCpn.parse_file("deploy.cpn.tcl")
{:ok, net} = ExCpn.validate(net)

marking = ExCpn.Marking.initial(net)
{marking, fired} = ExCpn.Marking.run(net, marking)

ExCpn.encode(net)
```

## Format

```tcl
cpn-spec 1.0

yang import avx-common

place queued  -type avx-common:request
place done    -type avx-common:request

init queued {}

transition handle {
  in    {queued req}
  guard {local {$req(age) < 300}}
  out   {done $req}
  priority 1
  label "Handle a request younger than five minutes"
}
```

| Statement | Meaning |
|---|---|
| `cpn-spec <version>` | Format version. Currently `1.0`. |
| `yang import <mod> ...` | YANG modules that `place -type` may reference. Accumulates. |
| `place <name> -type <mod>:<node>` | A typed place. `-type` is required. |
| `init <place> <dict>` | Seed token at t=0. `{}` is an empty token; `{k v k v}` is a map. |
| `transition <name> { ... }` | Sub-forms: `in`, `out`, `guard`, `priority`, `label`. |

Inside a transition, `in {place var} ...` binds one consumed token per place
to `var`; `out {place $var} ...` forwards a bound token, or a literal dict.
Topology is implicit: a transition whose `out` names a place that another
transition's `in` names is how the two connect. A transition with `out` but
no `in` is a source and mints an empty token each time it fires.

Guards take one `{target expression}` pair:

| Target | Expression | Evaluated by |
|---|---|---|
| `local` | Tcl `expr` subset over bound variables | `ExCpn.Expr`, inside the library |
| `shell` | Readiness predicate for a CLI | The host, through the `:guard` option |
| `http` | Readiness predicate for an HTTP request | The host, through the `:guard` option |
| `retry` | Name of another transition | `ExCpn.Instance`: true once that transition is over its retry budget |

`ExCpn.Expr` supports `$var`, `$var(field)`, numbers, `"strings"`, parentheses,
unary `!` and `-`, `* / %`, `+ -`, `< > <= >=`, `== != eq ne`, `&&`, `||`.
A missing variable is `nil`, and no comparison with `nil` holds.

## Semantics

`ExCpn.Marking` is pure. A marking is `%{place => [token]}`, each list a
multiset in arrival order. `enabled/3` returns transitions with a satisfying
binding, highest priority first; within a priority, source order rotated to
start after the last fired transition so a self-loop cannot starve its
siblings. `fire/4` consumes one bound token per in-place and produces out
tokens, which a host action may override. `run/4` fires to quiescence or a
firing cap.

Without a `:guard` evaluator, `shell` and `http` guards are disabled and their
transitions never fire.

## Running a net

`ExCpn.Instance` runs one net as a `gen_statem`. Lifecycle states are
`:running`, `:busy` (a host action is in flight), and `:quiescent`. The
marking is data, never a state.

```elixir
actions = %{
  "publish" => fn "publish", %{"h" => token} ->
    case Publisher.push(token) do
      :ok -> {:ok, %{"done" => Map.put(token, "published_at", now())}}
      {:error, why} -> {:error, why}
    end
  end
}

{:ok, pid} = ExCpn.Instance.start_link(net: net, actions: actions, max_retries: 3)
:ok = ExCpn.Instance.put_token(pid, "todo", %{"id" => 7})
marking = ExCpn.Instance.await_quiescent(pid)
```

A transition with a bound action runs it as a supervised task and fires
only on success; the action may return `{:ok, produced}` to supply the out
tokens. Failures and crashes count against `max_retries`; a transition over
budget is retired, and any transition guarded by `retry <that-name>` becomes
enabled, so the net models its own failure handling. Unbound transitions
move tokens as their arcs say. A `:journal` callback receives every
`{:fired, name, binding, marking}` and `{:failed, name, reason, count}`.
Stopping the instance stops its task supervisor, so no action outlives it.
Instances register under an atom `:name` or any `:via` tuple, such as a
`Registry` key.

## Not yet

Hierarchical nets, compensation, timed transitions, and telemetry events are
not in `cpn-spec 1.0` and not implemented. Each needs a spec decision first.

## Development

```sh
mix test
mix credo --strict
mix dialyzer
mix docs
```

## Installation

```elixir
{:ex_cpn, github: "imsmith/ex_cpn"}
```

## License

AGPL-3.0-only.
