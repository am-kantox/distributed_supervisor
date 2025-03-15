defmodule DistributedSupervisor.Notifier do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, nil, opts)

  @impl GenServer
  def init(nil), do: {:ok, %{}}

  @impl GenServer
  def handle_cast({:join, listeners, name, id, pid}, state) do
    Enum.each(listeners, fn mod_pattern ->
      {listener, callback?, notify?} =
        case mod_pattern do
          {mod, pattern} ->
            {source, pattern} = {inspect(id), inspect(pattern)}

            {mod, function_exported?(mod, :on_process_start, 3),
             String.starts_with?(source, pattern)}

          mod ->
            {mod, function_exported?(mod, :on_process_start, 3), true}
        end

      maybe_notify_join(callback?, notify?, listener, name, id, pid)
    end)

    {:noreply, state}
  end

  def handle_cast({:leave, listeners, name, id, pid}, state) do
    Enum.each(listeners, fn mod_pattern ->
      {listener, callback?, notify?} =
        case mod_pattern do
          {mod, pattern} ->
            {source, pattern} = {inspect(id), inspect(pattern)}

            {mod, function_exported?(mod, :on_process_stop, 3),
             String.starts_with?(source, pattern)}

          mod ->
            {mod, function_exported?(mod, :on_process_stop, 3), true}
        end

      maybe_notify_leave(callback?, notify?, listener, name, id, pid)
    end)

    {:noreply, state}
  end

  defp maybe_notify_join(true, true, listener, name, id, pid),
    do: listener.on_process_start(name, id, pid)

  defp maybe_notify_join(_, _, _, _, _, _), do: :ok

  defp maybe_notify_leave(true, true, listener, name, id, pid),
    do: listener.on_process_stop(name, id, pid)

  defp maybe_notify_leave(_, _, _, _, _, _), do: :ok
end
