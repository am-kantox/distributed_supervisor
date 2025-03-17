defmodule DistributedSupervisor.Notifier do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, nil, opts)

  @impl GenServer
  def init(nil), do: {:ok, %{}}

  defguardp is_local(pid) when node(pid) == node()

  @impl GenServer
  def handle_cast({:join, [_ | _] = listeners, name, id, pid}, state) when is_local(pid) do
    Enum.each(listeners, fn listener ->
      {listener, notify?} = parse_listener(listener, id)
      notify? = notify? and function_exported?(listener, :on_process_start, 3)

      maybe_notify_join(notify?, listener, name, id, pid)
    end)

    {:noreply, state}
  end

  def handle_cast({:leave, [_ | _] = listeners, name, id, pid}, state) when is_local(pid) do
    Enum.each(listeners, fn listener ->
      {listener, notify?} = parse_listener(listener, id)
      notify? = notify? and function_exported?(listener, :on_process_stop, 3)

      maybe_notify_leave(notify?, listener, name, id, pid)
    end)

    {:noreply, state}
  end

  def handle_cast(_, state), do: {:noreply, state}

  defp parse_listener({listener, pattern}, id) do
    {source, pattern} = {inspect(id), inspect(pattern)}
    {listener, String.starts_with?(source, pattern)}
  end

  defp parse_listener(listener, _id), do: {listener, true}

  defp maybe_notify_join(true, listener, name, id, pid),
    do: listener.on_process_start(name, id, pid)

  defp maybe_notify_join(_, _, _, _, _), do: :ok

  defp maybe_notify_leave(true, listener, name, id, pid),
    do: listener.on_process_stop(name, id, pid)

  defp maybe_notify_leave(_, _, _, _, _), do: :ok
end
