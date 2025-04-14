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

  def handle_cast({:nodeup, [_ | _] = listeners, name, {ring, node}, info}, state) do
    Enum.each(listeners, fn listener ->
      {listener, _notify?} = parse_listener(listener, "")

      notify? =
        function_exported?(listener, :on_node_up, 3) and
          HashRing.key_to_node(ring, node) == node()

      maybe_notify_up(notify?, listener, name, node, info)
    end)

    {:noreply, state}
  end

  def handle_cast({:nodedown, [_ | _] = listeners, name, {ring, node}, info}, state) do
    Enum.each(listeners, fn listener ->
      {listener, _notify?} = parse_listener(listener, "")

      notify? =
        function_exported?(listener, :on_node_down, 3) and
          HashRing.key_to_node(ring, node) == node()

      maybe_notify_down(notify?, listener, name, node, info)
    end)

    {:noreply, state}
  end

  def handle_cast(
        {:node_terminate, [_ | _] = listeners, name, {_ring, node}, {reason, statuses}},
        state
      ) do
    Enum.each(listeners, fn listener ->
      {listener, _notify?} = parse_listener(listener, "")

      notify? =
        function_exported?(listener, :on_node_terminate, 4)

      maybe_notify_terminate(notify?, listener, name, node, reason, statuses)
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

  defp maybe_notify_up(true, listener, name, node, info),
    do: listener.on_node_up(name, node, info)

  defp maybe_notify_up(_, _, _, _, _), do: :ok

  defp maybe_notify_down(true, listener, name, node, info),
    do: listener.on_node_down(name, node, info)

  defp maybe_notify_down(_, _, _, _, _), do: :ok

  defp maybe_notify_terminate(true, listener, name, node, reason, statuses),
    do: listener.on_node_terminate(name, node, reason, statuses)

  defp maybe_notify_terminate(_, _, _, _, _, _), do: :ok
end
