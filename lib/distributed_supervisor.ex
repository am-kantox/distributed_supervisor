defmodule DistributedSupervisor do
  @moduledoc """
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

  @doc """
  Starts the `DistributedSupervisor`.

  - required option
    - `name :: DistributedSupervisor.name()` the name of the supervisor to be used in lookups etc
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

  _See:_ `DynamicSupervisor.start_child/2`
  """
  @spec start_child(name(), Supervisor.child_spec() | {module(), term()}) ::
          DynamicSupervisor.on_start_child()
  def start_child(name, %{id: _, start: {mod, fun, opts}} = spec) do
    {opts, gs_opts, child_name} = patch_opts(name, opts)

    spec =
      spec
      |> Map.put(:start, {mod, fun, [opts]})
      |> Map.merge(gs_opts)

    me = node()

    launcher =
      case GenServer.call(registry_name(name), {:node_for, child_name}) do
        ^me -> &DynamicSupervisor.start_child(&1, spec)
        other -> &:rpc.block_call(other, DynamicSupervisor, :start_child, [&1, spec])
      end

    name
    |> dynamic_supervisor_name()
    |> launcher.()
    |> add_name_to_result(child_name)
  end

  def start_child(name, {mod, opts}) when is_atom(mod),
    do: start_child(name, %{id: Keyword.get(opts, name), start: {mod, :start_link, opts}})

  def start_child(name, mod) when is_atom(mod),
    do: start_child(name, {mod, []})

  @doc """
  Returns a map with registered names as keys and pids as values for the instance of the
    registry with a name `name`.
  """
  @spec children(name()) :: %{optional(term()) => pid()}
  def children(name) do
    name
    |> registry_name()
    |> :sys.get_state()
    |> Map.get(:children, {:error, :unknown_registry})
  end

  @doc """
  Returns a `t:pid()` for the instance of the registry with a name `name` by key.

  _See:_ `DistributedSupervisor.children/1`
  """
  @spec whereis(name(), id()) :: pid() | nil
  def whereis(name, child), do: DistributedSupervisor.Registry.whereis_name({name, child})

  @doc """
  A syntactic sugar for `GenServer.call/2` allowing to call a dynamically supervised
    `GenServer` by registry name and key.
  """
  @spec call(name(), id(), msg) :: result when msg: term(), result: term()
  def call(name, child, msg),
    do: name |> via_name(child) |> GenServer.call(msg)

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
  @spec registry_name(module()) :: module()
  def registry_name(name), do: Module.concat(name, Registry)

  @doc false
  @spec notifier_name(module()) :: module()
  def notifier_name(name), do: Module.concat(name, Notifier)

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
        {:ok, result} -> result
        :error -> make_ref()
      end

    {gs_opts, opts} =
      opts
      |> Keyword.put(:name, via_name(name, child_name))
      |> Keyword.put_new(:restart, :permanent)
      |> Keyword.split([:restart, :shutdown, :type, :modules, :significant])

    {opts, Map.new(gs_opts), child_name}
  end

  @spec add_name_to_result(DynamicSupervisor.on_start_child(), term()) ::
          DynamicSupervisor.on_start_child()
  defp add_name_to_result({:ok, pid}, child_name), do: {:ok, pid, child_name}
  defp add_name_to_result(result, _), do: result
end
