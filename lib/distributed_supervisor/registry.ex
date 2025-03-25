defmodule DistributedSupervisor.Registry do
  @moduledoc false

  import Kernel, except: [send: 2]

  require Logger

  use GenServer

  @type scope :: DistributedSupervisor.name()
  @type group :: DistributedSupervisor.id()

  def register_name({registry, key}, pid) do
    with :ok <- :pg.join(scope(registry), key, pid), do: :yes
  end

  def unregister_name({registry, key}) do
    case pid(registry, key) do
      pid when is_pid(pid) -> with :not_joined <- :pg.leave(scope(registry), key, pid), do: :ok
      :restarting -> unregister_name({registry, key})
      _ -> :ok
    end
  end

  def whereis_name({registry, key}), do: pid(registry, key)

  def send({registry, key}, msg) do
    case pid(registry, key) do
      pid when is_pid(pid) ->
        Kernel.send(pid, msg)

      :restarting ->
        send({registry, key}, msg)

      _ ->
        :erlang.error(:badarg, [{registry, key}, msg])
    end
  end

  #############################################################################

  def start_link(opts) do
    opts = Map.new(opts)
    name = Map.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, {name, opts},
      name: DistributedSupervisor.registry_name(name)
    )
  end

  @impl GenServer
  def init({name, opts}) do
    opts = NimbleOptions.validate!(opts, DistributedSupervisor.schema())

    scope = scope(name)
    {ref, _pids} = :pg.monitor_scope(scope)

    opts |> Map.fetch!(:monitor_nodes) |> do_monitor_nodes()

    nodes = Map.fetch!(opts, :nodes)

    ring =
      nodes
      |> case do
        [] -> [node() | Node.list()]
        nodes -> Enum.filter(nodes, &(true == Node.connect(&1)))
      end
      |> then(&HashRing.add_nodes(HashRing.new(), &1))

    cache_children? = Map.fetch!(opts, :cache_children?)
    # https://www.erlang.org/docs/25/man/net_kernel#monitor_nodes-1

    listeners =
      opts |> Map.fetch!(:listeners) |> List.wrap() |> Enum.filter(&Code.ensure_loaded?/1)

    state = %{
      name: name,
      scope: scope,
      listeners: listeners,
      nodes: nodes,
      ref: ref,
      children: if(cache_children?, do: %{}),
      ring: ring
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:nodeup, node, info}, %{ring: ring} = state) do
    Logger.debug("[🗒️] #{inspect(node)} node joined the cluster #{inspect(state.name)}")
    maybe_notify_listeners(:nodeup, state.listeners, state.name, {ring, node}, info)
    {:noreply, %{state | ring: HashRing.add_node(ring, node)}}
  end

  def handle_info({:nodedown, node, info}, %{ring: ring} = state) do
    Logger.debug("[🗒️] #{inspect(node)} node left the cluster #{inspect(state.name)}")
    ring = HashRing.remove_node(ring, node)
    maybe_notify_listeners(:nodedown, state.listeners, state.name, {ring, node}, info)
    {:noreply, %{state | ring: ring}}
  end

  def handle_info({ref, :join, group, [pid]}, %{ref: ref} = state) do
    Logger.debug("[🗒️] #{inspect(pid)} process joined group #{inspect(group)}")
    maybe_notify_listeners(:join, state.listeners, state.name, group, pid)

    state =
      with %{children: %{}} <- state, do: put_in(state, [:children, group], pid)

    {:noreply, state}
  end

  def handle_info({ref, :leave, group, pids}, %{ref: ref} = state) do
    Logger.debug("[🗒️] #{inspect(pids)} processes left group #{inspect(group)}")
    maybe_notify_listeners(:leave, state.listeners, state.name, group, pids)

    state =
      with %{children: %{}} <- state, do: %{state | children: Map.delete(state.children, group)}

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:node_for, key}, _from, %{ring: ring} = state),
    do: {:reply, HashRing.key_to_node(ring, key), state}

  @impl GenServer
  def handle_call({:add_nodes, nodes}, _from, %{ring: ring} = state) do
    nodes = List.wrap(nodes)
    all_nodes = with [_ | _] = old_nodes <- state.nodes, do: Enum.uniq(nodes ++ old_nodes)
    {:reply, %{state | nodes: all_nodes, ring: HashRing.add_nodes(ring, nodes)}}
  end

  #############################################################################

  defdelegate scope(registry), to: DistributedSupervisor

  @spec pid(scope(), group()) :: pid() | :undefined | :restarting | :unsupported
  defp pid(registry, key), do: pid({registry, key})

  @spec pid({scope(), group()}) :: pid() | :undefined | :restarting | :unsupported
  defp pid({registry, key}) do
    registry
    |> scope()
    |> :pg.get_members(key)
    |> case do
      [] ->
        :undefined

      [pid] ->
        if :rpc.block_call(node(pid), Process, :alive?, [pid]), do: pid, else: :restarting

      [_ | _] ->
        :unsupported
    end
  end

  def maybe_notify_listeners(_, [], _, _, _), do: :ok

  def maybe_notify_listeners(join_or_leave, listeners, name, id, pid)
      when join_or_leave in [:join, :leave] do
    name
    |> DistributedSupervisor.notifier_name()
    |> GenServer.cast({join_or_leave, listeners, name, id, pid})
  end

  def maybe_notify_listeners(up_or_down, listeners, name, {ring, node}, info)
      when up_or_down in [:nodeup, :nodedown] do
    name
    |> DistributedSupervisor.notifier_name()
    |> GenServer.cast({up_or_down, listeners, name, {ring, node}, info})
  end

  defp do_monitor_nodes(false), do: :ok
  defp do_monitor_nodes(true), do: do_monitor_nodes(:all)
  defp do_monitor_nodes(kind), do: :net_kernel.monitor_nodes(true, node_type: kind)
end
