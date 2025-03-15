defmodule DistributedSupervisorTest do
  use ExUnit.Case
  doctest DistributedSupervisor

  alias DistributedSupervisor.Test.GenServer, as: MyGS

  test "works on the single node" do
    start_supervised!({DistributedSupervisor, name: DS1})
    assert {:ok, _pid, MyGS_1} = DistributedSupervisor.start_child(DS1, {MyGS, name: MyGS_1})
    assert :ok == DistributedSupervisor.cast(DS1, MyGS_1, :inc)
    assert :ok == DistributedSupervisor.cast(DS1, MyGS_1, :inc)
    assert :ok == DistributedSupervisor.cast(DS1, MyGS_1, :inc)
    pid = self()
    assert {{^pid, [:alias | ref]}, 3} = DistributedSupervisor.call(DS1, MyGS_1, :state)
    assert is_reference(ref)
  end
end
