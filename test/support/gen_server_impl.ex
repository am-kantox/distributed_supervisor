defmodule DistributedSupervisor.Test.GenServer do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, 0, opts)
  end

  @impl true
  def init(0), do: {:ok, 0}

  @impl true
  def handle_call(:state, from, state), do: {:reply, {from, state}, state}

  @impl true
  def handle_cast(:inc, state), do: {:noreply, state + 1}
  def handle_cast(:raise, _state), do: raise("boom")
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
end
