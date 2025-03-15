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

  @optional_callbacks on_process_start: 3, on_process_stop: 3
end
