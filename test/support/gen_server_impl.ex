defmodule DistributedSupervisor.Test.GenServer do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, 0, opts)
  end

  @impl true
  def init(0), do: {:ok, tap(0, &Process.put(:foo, &1))}

  @impl true
  def handle_call(:state, from, state), do: {:reply, {from, state}, state}

  @impl true
  def handle_cast(:inc, state), do: {:noreply, state + 1}
  def handle_cast(:raise, _state), do: raise("boom")
  def handle_cast(:shutdown, state), do: {:stop, :normal, state}
end

defmodule DistributedSupervisor.Test.Listener do
  @moduledoc false

  require Logger

  @behaviour DistributedSupervisor.Listener

  @impl true
  def on_process_start(name, id, pid) do
    Logger.info("✓ starting: " <> inspect(name: name, id: id, pid: pid))
  end

  @impl true
  def on_process_stop(name, id, pid) do
    Logger.warning("✗ stopping: " <> inspect(name: name, id: id, pid: pid))
  end

  @impl true
  def on_node_up(name, node, info) do
    Logger.info("✓ node up: " <> inspect(name: name, node: node, info: info))
  end

  @impl true
  def on_node_down(name, node, info) do
    Logger.info("✗ node down: " <> inspect(name: name, node: node, info: info))
  end

  @impl true
  def on_node_terminate(name, node, reason, statuses) do
    Logger.info(
      "✗ node terminating: " <>
        inspect(name: name, node: node, reason: reason, statuses: statuses)
    )
  end
end
