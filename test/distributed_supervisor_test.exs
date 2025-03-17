defmodule DistributedSupervisorTest do
  use ExUnit.Case
  doctest DistributedSupervisor

  alias DistributedSupervisor.Test.GenServer, as: MyGS

  test "works on the single node" do
    start_supervised!(
      {DistributedSupervisor, name: DS1, listeners: DistributedSupervisor.Test.Listener}
    )

    assert {:ok, _pid, MyGS_1} = DistributedSupervisor.start_child(DS1, {MyGS, name: MyGS_1})
    assert [{_, _, _, _}] = DistributedSupervisor.children(DS1)
    assert :ok == DistributedSupervisor.cast(DS1, MyGS_1, :inc)
    assert :ok == DistributedSupervisor.cast(DS1, MyGS_1, :inc)
    assert :ok == DistributedSupervisor.cast(DS1, MyGS_1, :inc)
    pid = self()
    assert {{^pid, [:alias | ref]}, 3} = DistributedSupervisor.call(DS1, MyGS_1, :state)
    assert is_reference(ref)
  end

  test "allows child shutdown when `restart: :transient` is passed" do
    start_supervised!(
      {DistributedSupervisor,
       name: DS2, listeners: DistributedSupervisor.Test.Listener, cache_children?: true}
    )

    assert {:ok, _pid, MyGS_2} =
             DistributedSupervisor.start_child(DS2, {MyGS, name: MyGS_2, restart: :transient})

    assert %{MyGS_2 => _} = DistributedSupervisor.children(DS2)
    assert :ok == DistributedSupervisor.cast(DS2, MyGS_2, :shutdown)
    Process.sleep(100)
    assert %{} == DistributedSupervisor.children(DS2)
    refute DS2 |> DistributedSupervisor.whereis(MyGS2) |> GenServer.whereis()
  end
end
