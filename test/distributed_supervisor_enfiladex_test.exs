defmodule DistributedSupervisor.Enfiladex.Test do
  use ExUnit.Case, async: true

  use Enfiladex.Suite

  @moduletag :enfiladex

  alias DistributedSupervisor.Test.GenServer, as: GS

  setup do
    # start_supervised!(
    #   {DistributedSupervisor,
    #    [
    #      name: DS,
    #      listeners: DistributedSupervisor.Test.Listener,
    #      cache_children?: true,
    #      monitor_nodes: true
    #    ]}
    # )

    %{}
  end

  test "start, stop", _ctx do
    count = 3
    peers = Enfiladex.start_peers(count)

    try do
      Enfiladex.block_call_everywhere(DistributedSupervisor, :start_link, [
        [
          name: DS,
          listeners: DistributedSupervisor.Test.Listener,
          cache_children?: true,
          monitor_nodes: true
        ]
      ])

      DistributedSupervisor.start_child(DS, {GS, name: GS})
      DistributedSupervisor.start_child(DS, {GS, []})

      %{GS => _} = children = DistributedSupervisor.children(DS)
      assert map_size(children) == 2
      assert match?([GS, ref] when is_reference(ref), Map.keys(children))
    after
      Enfiladex.stop_peers(peers)
    end
  end
end
