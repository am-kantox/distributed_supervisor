defmodule DistributedSupervisor.Registry do
  @moduledoc false

  import Kernel, except: [send: 2]

  require Logger

  use GenServer

  @type scope :: DistributedSupervisor.name()
  @type group :: DistributedSupervisor.id()

  def register_name({registry, key}, pid) do
    with [] <- :pg.get_members(scope(registry), key),
         :ok <- :pg.join(scope(registry), key, pid),
         do: :yes,
         else: (_ -> :no)
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

  def handle_info({:node_terminate, node, reason, statuses}, %{ring: ring} = state) do
    Logger.debug(
      "[🗒️] #{inspect(node)} node (#{Enum.count(statuses)} processes) is terminated with reason #{inspect(reason)}"
    )

    maybe_notify_listeners(
      :node_terminate,
      state.listeners,
      state.name,
      {ring, node},
      {reason, statuses}
    )

    {:noreply, state}
  end

  def handle_info({ref, :join, group, [pid]}, %{ref: ref} = state) do
    Logger.debug("[🗒️] #{inspect(pid)} process joined group #{inspect(group)}")
    maybe_notify_listeners(:join, state.listeners, state.name, group, pid)
    winner = fix_group(state.name, state.scope, group, state.ring)

    {initial_call, name, process_state} =
      case :sys.get_status(winner) do
        {:status, ^winner, {:module, :gen_server},
         [start_info, :running, _leader, _, process_info]} ->
          initial_call = Keyword.get(start_info, :"$initial_call")
          name = get_in(process_info, [:header, Access.elem(1), Access.elem(1)])

          state =
            process_info
            |> Keyword.split([:data])
            |> elem(0)
            |> Enum.flat_map(&elem(&1, 1))
            |> Enum.filter(&match?({~c"State", _}, &1))
            |> Enum.map(&elem(&1, 1))
            |> List.first()

          {initial_call, name, state}

        _ ->
          {nil, nil, nil}
      end

    state =
      with %{children: %{}} <- state do
        put_in(state, [:children, Access.key(group, %{}), winner], %{
          initial_call: initial_call,
          name: name,
          state: process_state
        })
      end

    {:noreply, state}
  end

  def handle_info({ref, :leave, group, [pid]}, %{ref: ref} = state) do
    Logger.debug("[🗒️] #{inspect(pid)} process left group #{inspect(group)}")
    maybe_notify_listeners(:leave, state.listeners, state.name, group, pid)

    state =
      with %{children: %{}} <- state do
        with true <- pid |> node() |> Node.connect() |> Kernel.!(),
             [%{name: name, state: _process_state, initial_call: {module, :init, initial_state}}] <-
               get_in(state, [:children, group, pid]) do
          DistributedSupervisor.start_child(
            state.name,
            {GenServer, [module, initial_state, [name: name]]}
          )
        end

        Map.update!(state, :children, fn %{^group => pids} = children ->
          case Map.delete(pids, pid) do
            map when map == %{} -> Map.delete(children, group)
            map -> Map.put(children, group, map)
          end
        end)
      end

    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:state, _from, state), do: {:reply, state, state}

  @impl GenServer
  def handle_call(:nodes, _from, state), do: {:reply, HashRing.nodes(state.ring), state}

  @impl GenServer
  def handle_call({:node_for, key}, _from, %{ring: ring} = state),
    do: {:reply, HashRing.key_to_node(ring, key), state}

  @impl GenServer
  def handle_call({:add_nodes, nodes}, _from, %{ring: ring} = state),
    do: {:reply, %{state | ring: HashRing.add_nodes(ring, List.wrap(nodes))}}

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

  def maybe_notify_listeners(up_down_terminate, listeners, name, {ring, node}, info)
      when up_down_terminate in [:nodeup, :nodedown, :node_terminate] do
    name
    |> DistributedSupervisor.notifier_name()
    |> GenServer.cast({up_down_terminate, listeners, name, {ring, node}, info})
  end

  defp do_monitor_nodes(false), do: :ok
  defp do_monitor_nodes(true), do: do_monitor_nodes(:all)
  defp do_monitor_nodes(kind), do: :net_kernel.monitor_nodes(true, node_type: kind)

  defp fix_group(name, scope, group, ring) when is_atom(group) do
    winner_node = HashRing.key_to_node(ring, group)

    case :pg.get_members(scope, group) do
      [winner] ->
        winner

      [winner, loser] when node(winner) == winner_node ->
        fix_loser(name, group, winner, loser)

      [loser, winner] when node(winner) == winner_node ->
        fix_loser(name, group, winner, loser)
    end
  end

  defp fix_group(_name, scope, group, _ring), do: scope |> :pg.get_members(group) |> hd()

  defp fix_loser(name, group, winner, loser) do
    Logger.warning(
      "[🗒️] Shutting the named process ‹" <>
        inspect(group) <> "› down at ‹" <> inspect(node(loser)) <> "›"
    )

    DistributedSupervisor.terminate_child(name, loser)
    winner
  end
end
