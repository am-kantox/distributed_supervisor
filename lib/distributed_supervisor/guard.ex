defmodule DistributedSupervisor.Guard do
  @moduledoc false

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts), do: {:ok, Map.new(opts)}

  @impl GenServer
  def terminate(reason, %{distributed_supervisor_id: name}) do
    Logger.debug(
      "[🗒️] Distributed supervisor #{inspect(name)} at node #{inspect(node())} is terminating"
    )

    local_processes =
      name
      |> DistributedSupervisor.local_children()
      |> Enum.map(&:sys.get_status/1)

    self = node()
    remote_nodes = DistributedSupervisor.nodes(name) -- [self]

    Enum.each(remote_nodes, fn node ->
      send(
        {DistributedSupervisor.registry_name(name), node},
        {:node_terminate, self, reason, local_processes}
      )
    end)
  end
end
