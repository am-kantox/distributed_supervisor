# DistributedSupervisor

## Purpose

`DistributedSupervisor` is exactly what its name says. It’s a `DynamicSupervisor` working
transparently in a distributed environment.

### Example

```elixir
iex|🌢|n1@am|1> DistributedSupervisor.start_link(name: DS)
{:ok, #PID<0.307.0>}
iex|🌢|n1@am|2> DistributedSupervisor.start_child(DS, {MyGenServer, name: MGS})
{:ok, #PID<0.311.0>, MGS}
iex|🌢|n1@am|3> DistributedSupervisor.children(DS)
%{MGS => #PID<0.311.0>}
```

## Installation

```elixir
def deps do
  [
    {:distributed_supervisor, "~> 0.1"}
  ]
end
```

## [Documentation](https://hexdocs.pm/distributed_supervisor).

