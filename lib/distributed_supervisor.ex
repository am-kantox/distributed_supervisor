defmodule DistributedSupervisor do
  @moduledoc """
  `DistributedSupervisor` is exactly what its name says. It’s a `DynamicSupervisor` working
    transparently in a distributed environment.

  ### Example

  ```elixir
  iex|🌢|n1@am|1> DistributedSupervisor.start_link(name: DS, cache_children?: true)
  {:ok, #PID<0.307.0>}
  iex|🌢|n1@am|2> DistributedSupervisor.start_child(DS, {MyGenServer, name: MGS})
  {:ok, #PID<0.311.0>, MGS}
  iex|🌢|n1@am|3> DistributedSupervisor.children(DS)
  %{MGS => {#PID<0.311.0>, %{id: …}}}
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

  `child_spec` should be a valid child specification as detailed in the “Child specification”
    section of the documentation for `Supervisor` expressed as a `t:Supervisor.child_spec/0`
    or as a tuple `{module, start_link_arg}`.

  The child process will be started as defined in the child specification. The core
    difference from `DynamicSupervisor` is that the process must be named.
  The name might be any term, passed through `name:` option in a call to this function.
  If `name` option is not passed, it gets assigned randomly and returned in the third
    element of the tuple from `start_child/2`.

  This function accepts an optional third argument `node`. If it’s passed, the process
    will be started on that node; the node will be chosed according to a keyring otherwise.

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

  def start_child(name, {mod, opts}, node) when is_atom(mod),
    do: start_child(name, %{id: Keyword.get(opts, name), start: {mod, :start_link, opts}}, node)

  def start_child(name, mod, node) when is_atom(mod),
    do: start_child(name, {mod, []}, node)

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

  _See:_ `DynamicSupervisor.terminate_child/2`
  """
  @spec terminate_child(name(), pid()) :: :ok | {:error, :not_found}
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

  _See:_ `DistributedSupervisor.children/1`
  """
  @spec whereis(name(), id()) :: pid() | nil
  def whereis(name, child), do: DistributedSupervisor.Registry.whereis_name({name, child})

  @doc """
  A syntactic sugar for `GenServer.call/3` allowing to call a dynamically supervised
    `GenServer` by registry name and key.
  """
  @spec call(name(), id(), msg, timeout()) :: result when msg: term(), result: term()
  def call(name, child, msg, timeout \\ 5_000),
    do: name |> via_name(child) |> GenServer.call(msg, timeout)

  @doc """
  A syntactic sugar for `GenServer.cast/2` allowing to call a dynamically supervised
    `GenServer` by registry name and key.
  """
  @spec cast(name(), id(), msg) :: :ok when msg: term()
  def cast(name, child, msg),
    do: name |> via_name(child) |> GenServer.cast(msg)

  @doc """
  A syntactic sugar for `Kernel.send/2` allowing to send a message to
     a dynamically supervised `GenServer` identified by registry name and key.
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
