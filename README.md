# DistributedSupervisor

[![Hex.pm](https://img.shields.io/hexpm/v/distributed_supervisor.svg)](https://hex.pm/packages/distributed_supervisor)
[![Hex.pm](https://img.shields.io/hexpm/dt/distributed_supervisor.svg)](https://hex.pm/packages/distributed_supervisor)
[![Hex.pm](https://img.shields.io/hexpm/l/distributed_supervisor.svg)](https://github.com/am-kantox/distributed_supervisor/blob/master/LICENSE)

## Overview

`DistributedSupervisor` is a specialized dynamic supervisor designed to work transparently in distributed Erlang/Elixir environments. It extends the functionality of Elixir's built-in `DynamicSupervisor` by adding:

- Automatic process distribution across connected Erlang nodes
- Process redistribution when nodes join or leave the cluster
- Per-process node selection/assignment capabilities
- Fault tolerance with automatic recovery across nodes
- Notification system for process lifecycle events

This makes it ideal for building resilient, distributed applications where processes need to be balanced across a cluster with minimal manual intervention.

## Installation

Add `distributed_supervisor` to your mix.exs dependencies:

```elixir
def deps do
  [
    {:distributed_supervisor, "~> 0.5"}
  ]
end
```

After adding the dependency, run:

```bash
mix deps.get
```

## Basic Usage

### Starting a DistributedSupervisor

```elixir
# Start the supervisor with a required name
{:ok, pid} = DistributedSupervisor.start_link(name: MyApp.DistSup)

# Start a child process (will be automatically assigned to a node)
{:ok, child_pid, child_name} = DistributedSupervisor.start_child(MyApp.DistSup, MyWorker)

# Interact with the child process
DistributedSupervisor.call(MyApp.DistSup, child_name, :get_state)
DistributedSupervisor.cast(MyApp.DistSup, child_name, {:set_value, 42})

# Get information about current children
children = DistributedSupervisor.children(MyApp.DistSup)

# Find a specific child's PID
child_pid = DistributedSupervisor.whereis(MyApp.DistSup, child_name)

# Terminate a child
:ok = DistributedSupervisor.terminate_child(MyApp.DistSup, child_pid)
```

### Using with Named Processes

```elixir
# Start a process with an explicit name
{:ok, pid, MyWorker} = DistributedSupervisor.start_child(
  MyApp.DistSup, 
  {MyWorker, name: MyWorker}
)

# The name can later be used for calls and casts
DistributedSupervisor.call(MyApp.DistSup, MyWorker, :some_call)
```

## Configuration Options

The `DistributedSupervisor` accepts the following configuration options:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:name` | `atom()` | **Required** | Unique name for this distributed supervisor instance |
| `:cache_children?` | `boolean()` | `true` | Whether to cache children information for faster lookups |
| `:nodes` | `[node()]` | `[]` (all connected nodes) | Specific nodes to distribute processes across |
| `:monitor_nodes` | `boolean() \| :cluster` | `false` | Whether to monitor node connections/disconnections |
| `:listeners` | `module() \| [module()]` | `[]` | Module(s) implementing the `DistributedSupervisor.Listener` behaviour |

Example configuration in a supervision tree:

```elixir
children = [
  {DistributedSupervisor, 
   name: MyApp.DistSup,
   cache_children?: true,
   monitor_nodes: true,
   nodes: [:node1@host, :node2@host],
   listeners: MyApp.ProcessListener
  }
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Advanced Usage

### Node Selection

By default, processes are distributed across nodes using a consistent hashing algorithm, but you can specify a node explicitly:

```elixir
# Start a child on a specific node
DistributedSupervisor.start_child(MyApp.DistSup, MyWorker, :"node1@host")
```

### Custom Process Restart Behavior

You can configure processes with different restart strategies:

```elixir
# Start a transient process (won't be restarted on normal termination)
DistributedSupervisor.start_child(
  MyApp.DistSup,
  {MyWorker, restart: :transient, shutdown: 5000}
)
```

### Notification Listeners

Implement the `DistributedSupervisor.Listener` behaviour to receive callbacks for process lifecycle events:

```elixir
defmodule MyApp.ProcessListener do
  @behaviour DistributedSupervisor.Listener

  # Called when a node joins the cluster
  def handle_node_up(node, state) do
    IO.puts("Node #{node} joined the cluster")
    {:ok, state}
  end

  # Called when a node leaves the cluster
  def handle_node_down(node, state) do
    IO.puts("Node #{node} left the cluster")
    {:ok, state}
  end

  # Add other callback implementations...
end
```

### Working with Distributed Environments

For a complete multi-node setup with process distribution:

```elixir
# On each node in your cluster
Node.connect(:"other_node@host")

# Start DistributedSupervisor with the same name on each node
{:ok, _} = DistributedSupervisor.start_link(
  name: MyApp.DistSup,
  monitor_nodes: true
)

# Start processes from any node - they'll be distributed across the cluster
Enum.each(1..100, fn i ->
  DistributedSupervisor.start_child(
    MyApp.DistSup,
    {MyWorker, [id: i, name: :"worker_#{i}"]}
  )
end)

# Query any node to see all processes in the cluster
DistributedSupervisor.children(MyApp.DistSup)
```

## Troubleshooting

### Common Issues

1. **Processes not distributed across expected nodes**
   - Ensure all nodes are connected with `Node.list/0`
   - Check that the nodes specified in config are online
   - Verify process names are unique

2. **Process communication failures**
   - Ensure consistent Erlang cookie across all nodes
   - Check network connectivity between nodes
   - Verify your firewall allows Erlang distribution ports

3. **Children disappearing from registry**
   - Check if `cache_children?: true` is set
   - Look for process crashes in logs
   - Ensure your `GenServer` initialization is stable

### Debugging Tools

Use these functions to debug distribution issues:

```elixir
# Check which nodes are in the ring
DistributedSupervisor.nodes(MyApp.DistSup)

# Check which node a particular process key would be assigned to
node = DistributedSupervisor.node_for(MyApp.DistSup, :some_key)

# Check if the current node owns a particular key
is_mine = DistributedSupervisor.mine?(MyApp.DistSup, :some_key)
```

## Development

### Local Testing

1. Clone the repository
2. Install dependencies:
   ```bash
   mix deps.get
   ```
3. Run tests:
   ```bash
   mix test
   ```

### Running Distributed Tests

1. Start multiple named nodes:
   ```bash
   iex --name node1@127.0.0.1 -S mix
   iex --name node2@127.0.0.1 -S mix
   ```
2. Connect nodes in each shell:
   ```elixir
   Node.connect(:"node2@127.0.0.1")
   ```

### Code Quality

Maintain code quality with:
```bash
mix quality      # Format, credo and dialyzer
mix quality.ci   # CI quality checks
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass: `mix test`
5. Ensure code quality: `mix quality`
6. Submit a pull request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## [Documentation](https://hexdocs.pm/distributed_supervisor)

For detailed API documentation, visit the [HexDocs page](https://hexdocs.pm/distributed_supervisor).
