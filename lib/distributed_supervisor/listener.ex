defmodule DistributedSupervisor.Listener do
  @moduledoc """
  The implementation of this behaviour might be passed
   to `DistributedSupervisor.start_link/1` to receive
    notifications about processes state.
  """

  @callback on_process_start(
              name :: DistributedSupervisor.name(),
              id :: DistributedSupervisor.id(),
              pid :: pid()
            ) :: :ok

  @callback on_process_stop(
              name :: DistributedSupervisor.name(),
              id :: DistributedSupervisor.id(),
              pids :: [pid()]
            ) :: :ok

  @callback on_node_up(
              name :: DistributedSupervisor.name(),
              node :: node(),
              info :: map() | keyword()
            ) :: :ok

  @callback on_node_down(
              name :: DistributedSupervisor.name(),
              node :: node(),
              info :: map() | keyword()
            ) :: :ok

  @optional_callbacks on_process_start: 3, on_process_stop: 3, on_node_up: 3, on_node_down: 3
end
