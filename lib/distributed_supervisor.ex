defmodule DistributedSupervisor do
  @moduledoc """
  `DistributedSupervisor` is a specialized dynamic supervisor designed to work transparently
  in distributed Erlang/Elixir environments. It extends the functionality of Elixir's built-in
  `DynamicSupervisor` by providing automatic process distribution across connected nodes.

  ## Architecture and Process Distribution

  The supervisor leverages several components to achieve distributed process management:

  * `:pg` for distributed process groups and registry
  * `HashRing` (via `libring`) for consistent hash-based process distribution
  * Local `DynamicSupervisor` instances on each node
  * Internal process registry for child tracking

  When a child process is started through `DistributedSupervisor`:

  1. A target node is selected (using consistent hashing or explicit assignment)
  2. The process is started on the designated node via the local `DynamicSupervisor`
  3. Process information is registered in the internal registry
  4. Child processes can be monitored for failures and redistributed if needed

  ### Supervision Strategy

  `DistributedSupervisor` uses a one-for-one supervision strategy for child processes.
  Each child is supervised independently, and if a child process terminates, only that
  process is restarted according to its restart strategy (`:permanent`, `:transient`, or `:temporary`).

  In a distributed context:

  * When a node goes down, child processes can be restarted on other nodes (if `cache_children?` is enabled)
  * When a new node joins, it becomes available for process distribution
  * Process redistribution is handled automatically via a consistent hashing algorithm

  ## Basic Usage

  ### Starting a DistributedSupervisor

  ```elixir
  # Start a distributed supervisor with minimal configuration
  {:ok, pid} = DistributedSupervisor.start_link(name: MyApp.DistSup)

  # Start with more options
  {:ok, pid} = DistributedSupervisor.start_link(
    name: MyApp.DistSup,
    cache_children?: true,
    monitor_nodes: true
  )
  ```

  ### Starting Child Processes

  ```elixir
  # Start a child process (will be distributed automatically)
  {:ok, pid, ref} = DistributedSupervisor.start_child(MyApp.DistSup, MyWorker)

  # Start a child with a specific name
  {:ok, pid, MyWorker} = DistributedSupervisor.start_child(
    MyApp.DistSup,
    {MyWorker, name: MyWorker}
  )

  # Start a child on a specific node
  {:ok, pid, name} = DistributedSupervisor.start_child(
    MyApp.DistSup,
    MyWorker,
    :"node1@host"
  )
  ```

  ### Interacting with Children

  ```elixir
  # Call a specific child process
  result = DistributedSupervisor.call(MyApp.DistSup, MyWorker, :get_status)

  # Send a cast to a child process
  :ok = DistributedSupervisor.cast(MyApp.DistSup, MyWorker, {:update, value})

  # Send a direct message
  DistributedSupervisor.send(MyApp.DistSup, MyWorker, {:ping, self()})

  # Get information about all children
  children = DistributedSupervisor.children(MyApp.DistSup)
  # => %{worker_name => {pid, child_spec}, ...}

  # Find a specific child's PID
  pid = DistributedSupervisor.whereis(MyApp.DistSup, MyWorker)

  # Find a child's name from its PID
  name = DistributedSupervisor.whois(MyApp.DistSup, pid)

  # Terminate a child
  :ok = DistributedSupervisor.terminate_child(MyApp.DistSup, pid)
  ```

  ## Configuration Options

  The `DistributedSupervisor` accepts the following configuration options:

  ### Required Options

  * `:name` - The unique name for this distributed supervisor instance
    ```elixir
    DistributedSupervisor.start_link(name: MyApp.DistSup)
    ```

  ### Optional Configuration

  * `:cache_children?` (default: `true`) - Whether to cache children information

    When enabled, the supervisor maintains a cache of child processes, allowing them
    to be restarted on other nodes if their original node goes down. Disabling this
    option reduces memory usage but removes the ability to recover processes after node failures.

    ```elixir
    # Enable child caching (better fault tolerance)
    DistributedSupervisor.start_link(
      name: MyApp.DistSup,
      cache_children?: true
    )
    ```

  * `:nodes` (default: `[]`) - Specific nodes to distribute processes across

    By default, all connected nodes are used. Specifying a subset can improve
    performance and predictability.

    ```elixir
    # Use only specific nodes
    DistributedSupervisor.start_link(
      name: MyApp.DistSup,
      nodes: [:node1@host, :node2@host]
    )
    ```

  * `:monitor_nodes` (default: `false`) - Monitor node connections/disconnections

    When set to `true`, the hash ring will be automatically updated when nodes
    join or leave the cluster.

    ```elixir
    # Automatically adapt to cluster changes
    DistributedSupervisor.start_link(
      name: MyApp.DistSup,
      monitor_nodes: true
    )
    ```

  * `:listeners` (default: `[]`) - Modules implementing the `DistributedSupervisor.Listener` behaviour

    Listeners receive notifications about process and node lifecycle events.

    ```elixir
    # Single listener
    DistributedSupervisor.start_link(
      name: MyApp.DistSup,
      listeners: MyApp.ProcessListener
    )

    # Multiple listeners
    DistributedSupervisor.start_link(
      name: MyApp.DistSup,
      listeners: [MyApp.ProcessListener, MyApp.MetricsListener]
    )
    ```

  ## Advanced Features and Usage

  ### Process Distribution Control

  Check process distribution information:

  ```elixir
  # Get all nodes in the distribution ring
  nodes = DistributedSupervisor.nodes(MyApp.DistSup)

  # Determine which node would handle a specific key
  node = DistributedSupervisor.node_for(MyApp.DistSup, :some_key)

  # Check if current node owns a specific key
  is_mine = DistributedSupervisor.mine?(MyApp.DistSup, :some_key)
  ```

  ### Custom Process Names and Via Tuples

  Use custom names for processes and interact with them using standard GenServer functions:

  ```elixir
  # Get a via tuple for use with standard GenServer functions
  via = DistributedSupervisor.via_name(MyApp.DistSup, MyWorker)

  # Use with standard GenServer calls
  GenServer.call(via, :message)
  GenServer.cast(via, :message)
  ```

  ### Process Restart Strategies

  Configure how processes behave on termination:

  ```elixir
  # Permanent process (restarted for any reason)
  DistributedSupervisor.start_child(
    MyApp.DistSup,
    {MyWorker, name: :worker1, restart: :permanent}
  )

  # Transient process (restarted only on abnormal termination)
  DistributedSupervisor.start_child(
    MyApp.DistSup,
    {MyWorker, name: :worker2, restart: :transient}
  )

  # Temporary process (never restarted)
  DistributedSupervisor.start_child(
    MyApp.DistSup,
    {MyWorker, name: :worker3, restart: :temporary}
  )
  ```
  """
  use Supervisor

  @typedoc """
  The name of the instance of this distributed supervisor. 
  Unlike `t:GenServer.name/0`, it must be an atom.
  """
  @type name :: atom()

  @typedoc """
  The id of the child process within the instance of the distributed supervisor. 
  Might be whatever. If not passed explicitly to the `DistributedSupervisor.start_child/2`,
    the reference will be created automatically and returned as a third element
    of the `{:ok, pid, child_name}` success tuple.
  """
  @type id :: term()

  schema = [
    name: [
      required: true,
      type: :atom,
      doc:
        "The unique `ID` of this _DistributedSupervisor_, that will be used to address it, similar to `DynamicSupervisor.name()`"
    ],
    cache_children?: [
      required: false,
      type: :boolean,
      default: true,
      doc:
        "If `true`, `Registry` will cache children as a map of `%{name => %{pid() => initial_params}}`, " <>
          "setting this to `false` would block the functionañity of restarting a process on another node when any node goes down"
    ],
    nodes: [
      required: false,
      type: {:list, :atom},
      default: [],
      doc:
        "The hardcoded list of nodes to spread children across, if not passed, all connected nodes will be used"
    ],
    monitor_nodes: [
      required: false,
      type: :atom,
      default: false,
      doc:
        "If not false, the `HashRing` will be automatically updated when nodes are changed in the cluster"
    ],
    listeners: [
      required: false,
      default: [],
      type:
        {:or,
         [
           {:custom, NimbleOptionsEx, :behaviour, [DistributedSupervisor.Listener]},
           {:list, {:custom, NimbleOptionsEx, :behaviour, [DistributedSupervisor.Listener]}}
         ]},
      doc:
        "The implementation of `DistributedSupervisor.Listener` to receive notifications upon process restarts"
    ]
  ]

  @schema NimbleOptions.new!(schema)

  @doc false
  def schema, do: @schema

  @doc """
  Starts the `DistributedSupervisor`.

  ### Options to `DistributedSupervisor.start_link/1`

  #{NimbleOptions.docs(@schema)}

  ## Examples

      # Start with minimal required configuration (just the name)
      iex> {:ok, pid} = DistributedSupervisor.start_link(name: ExampleSup1)
      iex> is_pid(pid)
      true

      # Start with additional options
      iex> {:ok, pid} = DistributedSupervisor.start_link(
      ...>   name: ExampleSup2,
      ...>   cache_children?: true,
      ...>   monitor_nodes: true,
      ...>   nodes: [node()]
      ...> )
      iex> is_pid(pid)
      true
  """
  # @spec start_link(Supervisor.option() | Supervisor.init_option()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, {name, opts}, name: name)
  end

  @impl Supervisor
  @doc false
  def init({name, opts}) do
    children = [
      {__MODULE__.Guard, distributed_supervisor_id: name},
      {__MODULE__.Notifier, name: notifier_name(name)},
      %{
        id: __MODULE__.Supervisor,
        start:
          {Supervisor, :start_link,
           [
             [
               %{id: :pg, start: {__MODULE__, :start_pg, [name]}},
               %{
                 id: __MODULE__.Registry,
                 start: {__MODULE__.Registry, :start_link, [opts]}
               }
             ],
             [strategy: :rest_for_one]
           ]}
      },
      {DynamicSupervisor,
       name: dynamic_supervisor_name(name),
       strategy: :one_for_one,
       max_restarts: 100,
       max_seconds: 1}
    ]

    Supervisor.init(children, Keyword.put_new(opts, :strategy, :one_for_one))
  end

  @doc """
  Dynamically adds a child specification to supervisor and starts that child.

  `child_spec` should be a valid child specification as detailed in the "Child specification"
    section of the documentation for `Supervisor` expressed as a `t:Supervisor.child_spec/0`
    or as a tuple `{module, start_link_arg}`.

  The child process will be started as defined in the child specification. The core
    difference from `DynamicSupervisor` is that the process must be named.
  The name might be any term, passed through `name:` option in a call to this function.
  If `name` option is not passed, it gets assigned randomly and returned in the third
    element of the tuple from `start_child/2`.

  This function accepts an optional third argument `node`. If it's passed, the process
    will be started on that node; the node will be chosed according to a keyring otherwise.

  ## Examples

      # Start a simple child process with module only (auto-generated name)
      iex> {:ok, _sup} = DistributedSupervisor.start_link(name: ExampleSup3)
      iex> {:ok, pid, child_name} = DistributedSupervisor.start_child(ExampleSup3, DistributedSupervisor.Test.GenServer)
      iex> is_pid(pid) and is_reference(child_name)
      true

      # Start with tuple format and explicit name
      iex> {:ok, _sup} = DistributedSupervisor.start_link(name: ExampleSup4)
      iex> {:ok, pid, NamedWorker} = DistributedSupervisor.start_child(
      ...>   ExampleSup4,
      ...>   {DistributedSupervisor.Test.GenServer, name: NamedWorker}
      ...> )
      iex> is_pid(pid)
      true
      
      # Start with explicit child specification
      iex> {:ok, _sup} = DistributedSupervisor.start_link(name: ExampleSup5)
      iex> child_spec = %{
      ...>   id: :test_child,
      ...>   start: {DistributedSupervisor.Test.GenServer, :start_link, name: SpecWorker}
      ...> }
      iex> {:ok, pid, SpecWorker} = DistributedSupervisor.start_child(ExampleSup5, child_spec)
      iex> is_pid(pid)
      true

  _See:_ `DynamicSupervisor.start_child/2`
  """
  @spec start_child(name(), Supervisor.child_spec() | {module(), term()}, node() | nil) ::
          DynamicSupervisor.on_start_child()
  def start_child(name, spec, node \\ nil)

  def start_child(name, %{id: _, start: {mod, fun, opts}} = spec, node) do
    {opts, gs_opts, child_name} = patch_opts(name, opts)

    spec =
      spec
      |> Map.put(:start, {mod, fun, opts})
      |> Map.merge(gs_opts)

    name
    |> do_start_child(spec, node || node_for(name, child_name))
    |> add_name_to_result(child_name)
  end

  def start_child(name, {mod, opts}, node) when is_atom(mod) do
    start_child(
      name,
      %{id: Keyword.get(opts, :name), start: {mod, :start_link, opts}},
      node
    )
  end

  def start_child(name, mod, node) when is_atom(mod),
    do: start_child(name, {mod, []}, node)

  def start_child(name, spec, node) do
    require Logger
    Logger.warning("Cannot start child: " <> inspect(name: name, spec: spec, node: node))
    {:error, {:incorrect_spec, spec}}
  end

  @doc false
  def do_start_child(name, spec, node) do
    me = node()

    launcher =
      case node do
        {:error, {:invalid_ring, :no_nodes}} -> &DynamicSupervisor.start_child(&1, spec)
        ^me -> &DynamicSupervisor.start_child(&1, spec)
        other -> &:rpc.block_call(other, DynamicSupervisor, :start_child, [&1, spec])
      end

    name
    |> dynamic_supervisor_name()
    |> launcher.()
  end

  @doc """
  Terminates the given child identified by pid.

  If successful, this function returns `:ok`.
  If there is no process with the given PID, this function returns `{:error, :not_found}`.

  ## Examples

      # Start and then terminate a child process
      iex> {:ok, _sup} = DistributedSupervisor.start_link(name: ExampleSup6)
      iex> {:ok, pid, _} = DistributedSupervisor.start_child(ExampleSup6, DistributedSupervisor.Test.GenServer)
      iex> DistributedSupervisor.terminate_child(ExampleSup6, pid)
      :ok
      
      # Try to terminate a non-existent PID
      iex> {:ok, _sup} = DistributedSupervisor.start_link(name: ExampleSup7)
      iex> DistributedSupervisor.terminate_child(ExampleSup7, nil)
      {:error, :not_found}

  _See:_ `DynamicSupervisor.terminate_child/2`
  """
  @spec terminate_child(name(), pid() | nil) :: :ok | {:error, :not_found}
  def terminate_child(_name, nil), do: {:error, :not_found}

  def terminate_child(name, pid) do
    ds_name = dynamic_supervisor_name(name)
    me = node()

    case node(pid) do
      ^me -> DynamicSupervisor.terminate_child(ds_name, pid)
      other -> :rpc.block_call(other, DynamicSupervisor, :terminate_child, [ds_name, pid])
    end
  end

  @doc """
  Returns the list of nodes operated by a registered ring
  """
  def nodes(name) do
    case :persistent_term.get(name, nil) do
      %HashRing{} = ring -> HashRing.nodes(ring)
      nil -> name |> registry_name() |> GenServer.call(:nodes)
    end
  end

  @doc """
  Returns the node for the key given according to a `HashRing`
  """
  def node_for(name, key) do
    case :persistent_term.get(name, nil) do
      %HashRing{} = ring -> HashRing.key_to_node(ring, key)
      nil -> name |> registry_name() |> GenServer.call({:node_for, key})
    end
  end

  @doc """
  Returns `true` if called from a node assigned to this key, `false` otherwise
  """
  def mine?(name, key), do: node_for(name, key) == node()

  @doc """
  Returns a list of pids of local children
  """
  @spec local_children(name()) :: [pid()]
  def local_children(name),
    do: name |> which_children([node()]) |> List.wrap() |> Enum.map(&elem(&1, 1))

  @doc """
  Returns a map with registered names as keys and pids as values for the instance of the
    registry with a name `name`.

  ## Examples

      iex> {:ok, _sup} = DistributedSupervisor.start_link(name: ExampleSup8)
      iex> {:ok, _pid, :child1} = DistributedSupervisor.start_child(ExampleSup8, {DistributedSupervisor.Test.GenServer, name: :child1})
      iex> {:ok, _pid, :child2} = DistributedSupervisor.start_child(ExampleSup8, {DistributedSupervisor.Test.GenServer, name: :child2})
      iex> children = DistributedSupervisor.children(ExampleSup8)
      iex> is_map(children) and map_size(children) >= 2
      true
      iex> Map.has_key?(children, :child1) and Map.has_key?(children, :child2)
      true
  """
  @spec children(name()) ::
          %{optional(term()) => {pid(), Supervisor.child_spec()}}
          | [{:undefined, pid() | :restarting, :worker | :supervisor, [module()] | :dynamic}]
  def children(name) do
    name
    |> registry_name()
    |> GenServer.call(:state)
    |> case do
      %{children: children} when not is_nil(children) -> children
      %{ring: ring} -> which_children(name, HashRing.nodes(ring))
    end
  end

  @doc """
  Returns a `t:pid()` for the instance of the registry with a name `name` by key.

  ## Examples

      iex> {:ok, _sup} = DistributedSupervisor.start_link(name: ExampleSup9)
      iex> {:ok, pid1, :lookup_test} = DistributedSupervisor.start_child(ExampleSup9, {DistributedSupervisor.Test.GenServer, name: :lookup_test})
      iex> DistributedSupervisor.whereis(ExampleSup9, :lookup_test) == pid1
      true
      iex> DistributedSupervisor.whereis(ExampleSup9, :nonexistent_process)
      :undefined

  _See:_ `DistributedSupervisor.children/1`
  """
  @spec whereis(name(), id()) :: pid() | nil
  def whereis(name, child), do: DistributedSupervisor.Registry.whereis_name({name, child})

  @doc """
  Returns a registered name by a `t:pid()` given.

  ## Examples

      iex> {:ok, _sup} = DistributedSupervisor.start_link(name: ExampleSup10)
      iex> {:ok, pid, :whois_test} = DistributedSupervisor.start_child(ExampleSup10, {DistributedSupervisor.Test.GenServer, name: :whois_test})
      iex> DistributedSupervisor.whois(ExampleSup10, pid)
      :whois_test
      iex> non_existing_pid = :erlang.list_to_pid(~c"<0.999.0>")
      iex> DistributedSupervisor.whois(ExampleSup10, non_existing_pid)
      nil

  _See:_ `DistributedSupervisor.children/1`
  """
  @spec whois(name(), pid()) :: name() | nil
  def whois(name, pid), do: name |> DistributedSupervisor.children() |> do_whois(pid)

  defp do_whois(%{} = children, pid) do
    with {name, {^pid, _}} <- Enum.find(children, &match?({_, {^pid, _}}, &1)), do: name
  end

  defp do_whois(_, _), do: nil

  @doc """
  A syntactic sugar for `GenServer.call/3` allowing to call a dynamically supervised
    `GenServer` by registry name and key.

  ## Examples

      iex> {:ok, _sup} = DistributedSupervisor.start_link(name: ExampleSup11)
      iex> {:ok, _pid, :call_test} = DistributedSupervisor.start_child(ExampleSup11, {DistributedSupervisor.Test.GenServer, name: :call_test})
      iex> result = DistributedSupervisor.call(ExampleSup11, :call_test, :state)
      iex> match?({{_, _}, _}, result)
      true
  """
  @spec call(name(), id(), msg, timeout()) :: result when msg: term(), result: term()
  def call(name, child, msg, timeout \\ 5_000),
    do: name |> via_name(child) |> GenServer.call(msg, timeout)

  @doc """
  A syntactic sugar for `GenServer.cast/2` allowing to call a dynamically supervised
    `GenServer` by registry name and key.

  ## Examples

      iex> {:ok, _sup} = DistributedSupervisor.start_link(name: ExampleSup12)
      iex> {:ok, _pid, :cast_test} = DistributedSupervisor.start_child(ExampleSup12, {DistributedSupervisor.Test.GenServer, name: :cast_test})
      iex> DistributedSupervisor.cast(ExampleSup12, :cast_test, :inc)
      :ok
  """
  @spec cast(name(), id(), msg) :: :ok when msg: term()
  def cast(name, child, msg),
    do: name |> via_name(child) |> GenServer.cast(msg)

  @doc """
  A syntactic sugar for `Kernel.send/2` allowing to send a message to
  a dynamically supervised `GenServer` identified by registry name and key.

  Returns the message if the process exists, `nil` otherwise.

  ## Examples

      iex> {:ok, _sup} = DistributedSupervisor.start_link(name: ExampleSup13)
      iex> {:ok, _pid, :send_test} = DistributedSupervisor.start_child(ExampleSup13, {DistributedSupervisor.Test.GenServer, name: :send_test})
      iex> DistributedSupervisor.send(ExampleSup13, :send_test, :test_message)
      :test_message
      iex> DistributedSupervisor.send(ExampleSup13, :nonexistent, :test_message)
      :undefined
  """
  @spec send(name(), id(), msg) :: msg | nil when msg: term()
  def send(name, child, msg),
    do: with(pid when is_pid(pid) <- whereis(name, child), do: send(pid, msg))

  @doc """
  Returns a fully qualified name to use with a standard library functions,
    accepting `{:via, Registry, key}` as a `GenServer` name.
  """
  @spec via_name(name(), id()) :: {:via, module(), {name(), id()}}
  def via_name(name, id), do: {:via, DistributedSupervisor.Registry, {name, id}}

  #############################################################################

  @doc false
  @spec start_pg(module()) :: {:ok, pid()} | :ignore
  def start_pg(name) do
    with {:error, {:already_started, _pid}} <- name |> scope() |> :pg.start_link(), do: :ignore
  end

  @doc false
  @spec scope(module()) :: module()
  def scope(name), do: Module.concat(name, Scope)

  @doc false
  @spec dynamic_supervisor_name(module()) :: module()
  def dynamic_supervisor_name(name), do: Module.concat(name, DynamicSupervisor)

  @doc false
  def dynamic_supervisor_status(name),
    do: name |> dynamic_supervisor_name() |> GenServer.whereis() |> :sys.get_status()

  @doc false
  @spec registry_name(module()) :: module()
  def registry_name(name), do: Module.concat(name, Registry)

  @doc false
  @spec notifier_name(module()) :: module()
  def notifier_name(name), do: Module.concat(name, Notifier)

  @spec which_children(name(), [node()]) :: [
          {:undefined, pid() | :restarting, :worker | :supervisor, [module()] | :dynamic}
        ]
  defp which_children(name, nodes) do
    ds_name = dynamic_supervisor_name(name)
    me = node()

    Enum.flat_map(nodes, fn
      ^me -> DynamicSupervisor.which_children(ds_name)
      node -> :rpc.call(node, DynamicSupervisor, :which_children, [ds_name])
    end)
  end

  @spec patch_opts(module(), keyword()) ::
          {keyword(),
           %{
             optional(:restart) => Supervisor.restart(),
             optional(:shutdown) => Supervisor.shutdown(),
             optional(:type) => Supervisor.type(),
             optional(:modules) => [module()] | :dynamic,
             optional(:significant) => boolean()
           }, term()}
  defp patch_opts(name, opts) do
    child_name =
      case Keyword.fetch(opts, :name) do
        {:ok, {:via, DistributedSupervisor.Registry, {^name, result}}} -> result
        {:ok, result} -> result
        :error -> make_ref()
      end

    {gs_opts, opts} =
      if Keyword.keyword?(opts) do
        opts
        |> Keyword.put(:name, via_name(name, child_name))
        |> Keyword.put_new(:restart, :permanent)
        |> Keyword.split([:restart, :shutdown, :type, :modules, :significant])
        |> then(fn {gs_opts, opts} -> {Map.new(gs_opts), [opts]} end)
      else
        {%{restart: :permanent}, opts}
      end

    {opts, gs_opts, child_name}
  end

  @spec add_name_to_result(DynamicSupervisor.on_start_child(), term()) ::
          DynamicSupervisor.on_start_child()
  defp add_name_to_result({:ok, pid}, child_name), do: {:ok, pid, child_name}
  defp add_name_to_result(result, _), do: result
end
