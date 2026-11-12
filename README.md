# ExCpn

Coloured Petri Net action models for Elixir. Parses, encodes, validates, and
runs nets written in the `.cpn.tcl` format: typed places, transitions with
`in`/`out` arcs, four-target guards (`local`, `shell`, `http`, `retry`),
priorities, and labels.

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

Topology is implicit: a transition whose `out` names a place that another
transition's `in` names is how the two connect. Tokens are maps; `init` with
`{}` seeds an empty token. `$var(field)` in a `local` guard reads
`token["field"]`.

## Semantics

`ExCpn.Marking` is pure. A marking is `%{place => [token]}`. `enabled/3`
returns transitions with a satisfying binding, highest priority first; within
a priority, source order rotated to start after the last fired transition so
self-loops cannot starve siblings. `fire/4` consumes one bound token per
in-place and produces out tokens, which a host action may override.

`local` guards are evaluated by `ExCpn.Expr`. `shell`, `http`, and `retry`
guards are delegated to the host through the `:guard` option and are disabled
when no evaluator is given.

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

A transition with a bound action runs it in a monitored process and fires
only on success; the action may return `{:ok, produced}` to supply the out
tokens. Failures and crashes count against `max_retries`; a transition over
budget is retired, and any transition guarded by `retry <that-name>` becomes
enabled, so the net models its own failure handling. Unbound transitions
move tokens as their arcs say. A `:journal` callback receives every
`{:fired, ...}` and `{:failed, ...}` event.

## Installation

```elixir
{:ex_cpn, github: "imsmith/ex_cpn"}
```

## License

AGPL-3.0-only.
