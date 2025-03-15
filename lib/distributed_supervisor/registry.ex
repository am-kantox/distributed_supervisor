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
    scope = scope(name)

    {ref, pids} = :pg.monitor_scope(scope)
    Enum.each(pids, &Process.exit(&1, :restart))

    ring =
      opts
      |> Map.get(:nodes, [node() | Node.list()])
      |> then(&HashRing.add_nodes(HashRing.new(), &1))

    state =
      opts
      |> Map.put(:scope, scope)
      |> Map.put(:ref, ref)
      |> Map.put(:children, %{})
      |> Map.put(:ring, ring)

    {:ok, state}
  end

  @impl GenServer
  def handle_info({ref, :join, group, [pid]}, %{ref: ref} = state) do
    Logger.debug(
      "[🗒️] #{inspect(pid)} process joined group #{inspect(group)}, state: #{inspect(state)}"
    )

    {:noreply, put_in(state, [:children, group], pid)}
  end

  def handle_info({ref, :leave, group, pids}, %{ref: ref} = state) do
    Logger.debug(
      "[🗒️] #{inspect(pids)} processes left group #{inspect(group)}, state: #{inspect(state)}"
    )

    {:noreply, %{state | children: Map.delete(state.children, group)}}
  end

  @impl GenServer
  def handle_call({:node_for, key}, _from, %{ring: ring} = state),
    do: {:reply, HashRing.key_to_node(ring, key), state}

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
end
