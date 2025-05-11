defmodule DistributedSupervisorTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for DistributedSupervisor single-node functionality.
  Multi-node scenarios are tested in `DistributedSupervisor.MultiNodeTest`.
  """

  # Add doctests for key public functions
  doctest DistributedSupervisor,
    import: true,
    only: [
      start_link: 1,
      start_child: 3,
      terminate_child: 2,
      whereis: 2,
      whois: 2,
      children: 1,
      cast: 3,
      send: 3
    ]

  alias DistributedSupervisor.Test.GenServer, as: MyGS

  # Create a unique supervisor name for each test to avoid conflicts
  setup do
    supervisor_name = :"DS#{System.unique_integer([:positive])}"
    {:ok, supervisor_name: supervisor_name}
  end

  describe "configuration and startup:" do
    test "requires name option to be specified" do
      assert_raise KeyError, fn ->
        DistributedSupervisor.start_link([])
      end
    end

    test "validates nodes configuration", %{supervisor_name: name} do
      # Valid configuration with local node
      {:ok, pid1} =
        DistributedSupervisor.start_link(
          name: name,
          nodes: [node()]
        )

      assert is_pid(pid1)

      # Empty node list is valid (uses all connected nodes)
      name2 = :"#{name}_2"

      {:ok, pid2} =
        DistributedSupervisor.start_link(
          name: name2,
          nodes: []
        )

      assert is_pid(pid2)
    end

    test "accepts cache_children? option", %{supervisor_name: name} do
      # With caching enabled (default)
      {:ok, pid1} =
        DistributedSupervisor.start_link(
          name: name,
          cache_children?: true
        )

      assert is_pid(pid1)

      # With caching disabled
      name2 = :"#{name}_2"

      {:ok, pid2} =
        DistributedSupervisor.start_link(
          name: name2,
          cache_children?: false
        )

      assert is_pid(pid2)
    end

    test "accepts monitor_nodes option", %{supervisor_name: name} do
      # With node monitoring
      {:ok, pid} =
        DistributedSupervisor.start_link(
          name: name,
          monitor_nodes: true
        )

      assert is_pid(pid)
    end

    test "accepts listeners option", %{supervisor_name: name} do
      # With listener
      {:ok, pid} =
        DistributedSupervisor.start_link(
          name: name,
          listeners: DistributedSupervisor.Test.Listener
        )

      assert is_pid(pid)
    end
  end

  describe "child process management:" do
    test "start_child with basic operation", %{supervisor_name: name} do
      start_supervised!({DistributedSupervisor, name: name})

      # Start a child with explicit name
      assert {:ok, pid, MyGS_1} = DistributedSupervisor.start_child(name, {MyGS, name: MyGS_1})
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Should appear in children
      children = DistributedSupervisor.children(name)
      assert Enum.count(children) == 1
    end

    test "start_child with automatically generated name", %{supervisor_name: name} do
      start_supervised!({DistributedSupervisor, name: name})

      # Start without explicitly specifying a name
      assert {:ok, pid, child_name} = DistributedSupervisor.start_child(name, MyGS)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Generated name should be a reference
      assert is_reference(child_name)
    end

    test "start_child with various module forms", %{supervisor_name: name} do
      start_supervised!({DistributedSupervisor, name: name})

      # Start with just a module atom
      assert {:ok, pid1, _} = DistributedSupervisor.start_child(name, MyGS)
      assert is_pid(pid1)

      # Start with module and options tuple
      assert {:ok, pid2, _} = DistributedSupervisor.start_child(name, {MyGS, []})
      assert is_pid(pid2)

      # Start with child spec
      child_spec = %{
        id: :test_child,
        start: {MyGS, :start_link, name: TestChild}
      }

      assert {:ok, pid3, TestChild} = DistributedSupervisor.start_child(name, child_spec)
      assert is_pid(pid3)
    end

    test "duplicate child names are rejected", %{supervisor_name: name} do
      start_supervised!({DistributedSupervisor, name: name})

      # Start first child
      assert {:ok, pid, :duplicate_test} =
               DistributedSupervisor.start_child(name, {MyGS, name: :duplicate_test})

      # Attempt to start child with same name should fail
      assert {:error, {:already_started, ^pid}} =
               DistributedSupervisor.start_child(name, {MyGS, name: :duplicate_test})
    end

    test "terminate_child removes the child process", %{supervisor_name: name} do
      start_supervised!({DistributedSupervisor, name: name})

      # Start a child
      {:ok, pid, child_name} = DistributedSupervisor.start_child(name, {MyGS, name: ChildName5})

      # Terminate the child
      assert :ok = DistributedSupervisor.terminate_child(name, pid)
      Process.sleep(50)

      # Child should no longer exist
      assert :undefined == DistributedSupervisor.whereis(name, child_name)
    end

    test "allows child shutdown when `restart: :transient` is passed", %{supervisor_name: name} do
      start_supervised!({DistributedSupervisor, name: name, cache_children?: true})

      # Start a transient child
      assert {:ok, _pid, child_name} =
               DistributedSupervisor.start_child(
                 name,
                 {MyGS, name: ChildName4, restart: :transient}
               )

      # Verify it exists
      assert %{^child_name => _} = DistributedSupervisor.children(name)

      # Signal normal shutdown
      assert :ok == DistributedSupervisor.cast(name, child_name, :shutdown)
      Process.sleep(100)

      # Should be removed since it terminated normally with :transient restart policy
      assert :undefined == DistributedSupervisor.whereis(name, child_name)
    end

    test "permanent process is restarted after abnormal termination", %{supervisor_name: name} do
      start_supervised!({DistributedSupervisor, name: name})

      # Start a permanent child (default)
      assert {:ok, pid, child_name} =
               DistributedSupervisor.start_child(name, {MyGS, name: ChildName3})

      # Kill it abnormally
      Process.exit(pid, :kill)
      Process.sleep(100)

      # Should be restarted
      new_pid = DistributedSupervisor.whereis(name, child_name)
      assert is_pid(new_pid)
      assert new_pid != pid
      assert Process.alive?(new_pid)
    end

    test "temporary process is not restarted after termination", %{supervisor_name: name} do
      start_supervised!({DistributedSupervisor, name: name})

      # Start a temporary child
      assert {:ok, pid, child_name} =
               DistributedSupervisor.start_child(
                 name,
                 {MyGS, name: ChildName1, restart: :temporary}
               )

      # Kill it abnormally
      Process.exit(pid, :kill)
      Process.sleep(100)

      # Should not be restarted
      assert :undefined == DistributedSupervisor.whereis(name, child_name)
    end
  end

  describe "process lookup and communication:" do
    setup %{supervisor_name: name} do
      # Start supervisor with children for this test group
      start_supervised!({DistributedSupervisor, name: name})

      # Start some test processes
      {:ok, pid1, child1} = DistributedSupervisor.start_child(name, {MyGS, name: :child1})
      {:ok, pid2, child2} = DistributedSupervisor.start_child(name, {MyGS, name: :child2})

      {:ok, %{child1: child1, pid1: pid1, child2: child2, pid2: pid2}}
    end

    test "whereis returns correct pid", %{supervisor_name: name, child1: child1, pid1: pid1} do
      assert ^pid1 = DistributedSupervisor.whereis(name, child1)
    end

    test "children returns all processes", %{
      supervisor_name: name,
      child1: child1,
      child2: child2
    } do
      children = DistributedSupervisor.children(name)
      assert map_size(children) == 2
      assert Map.has_key?(children, child1)
      assert Map.has_key?(children, child2)
    end

    test "call sends synchronous message to child", %{supervisor_name: name, child1: child1} do
      # Call returns response from the child process
      assert match?({{_, _}, _}, DistributedSupervisor.call(name, child1, :state))
    end

    test "cast sends asynchronous message to child", %{supervisor_name: name, child1: child1} do
      # Cast returns :ok immediately
      assert :ok = DistributedSupervisor.cast(name, child1, :inc)
      Process.sleep(50)

      # Effect of cast should be visible in state
      assert match?({{_, _}, 1}, DistributedSupervisor.call(name, child1, :state))
    end

    test "send delivers message to child", %{supervisor_name: name, child1: child1} do
      # Send returns the message
      assert :test_message = DistributedSupervisor.send(name, child1, :test_message)
    end

    test "via_name returns correct via tuple", %{supervisor_name: name, child1: child1} do
      via = DistributedSupervisor.via_name(name, child1)
      assert match?({:via, DistributedSupervisor.Registry, {^name, ^child1}}, via)

      # Via tuple works with GenServer calls
      assert match?({{_, _}, _}, GenServer.call(via, :state))
    end
  end

  describe "utility functions:" do
    setup %{supervisor_name: name} do
      start_supervised!({DistributedSupervisor, name: name})
      :ok
    end

    test "node_for returns consistent node for the same key", %{supervisor_name: name} do
      key = "consistent_key"
      node1 = DistributedSupervisor.node_for(name, key)
      node2 = DistributedSupervisor.node_for(name, key)
      assert node1 == node2
      assert is_atom(node1)

      # Different keys can map to different nodes
      key2 = "different_key"
      node3 = DistributedSupervisor.node_for(name, key2)
      assert is_atom(node3)
    end

    test "mine? correctly identifies if current node owns a key", %{supervisor_name: name} do
      key = "test_key"
      assigned_node = DistributedSupervisor.node_for(name, key)
      expected_result = assigned_node == node()

      assert DistributedSupervisor.mine?(name, key) == expected_result
    end

    test "nodes returns list of nodes in the ring", %{supervisor_name: name} do
      nodes = DistributedSupervisor.nodes(name)

      assert is_list(nodes)
      assert length(nodes) >= 1
      assert Enum.member?(nodes, node())
      assert Enum.all?(nodes, &is_atom/1)
    end

    test "local_children returns processes on current node", %{supervisor_name: name} do
      # Start several children
      for i <- 1..5 do
        {:ok, _pid, _name} =
          DistributedSupervisor.start_child(
            name,
            {MyGS, name: :"worker_#{i}"}
          )
      end

      local_pids = DistributedSupervisor.local_children(name)

      assert is_list(local_pids)
      assert length(local_pids) > 0

      # All PIDs should be on the current node
      Enum.each(local_pids, fn pid ->
        assert node(pid) == node()
        assert is_pid(pid)
        assert Process.alive?(pid)
      end)
    end
  end

  describe "child specifications:" do
    setup %{supervisor_name: name} do
      start_supervised!({DistributedSupervisor, name: name})
      :ok
    end

    test "accepts standard child_spec map", %{supervisor_name: name} do
      child_spec = %{
        id: :test_child,
        start: {MyGS, :start_link, name: TestChild}
      }

      assert {:ok, pid, TestChild} = DistributedSupervisor.start_child(name, child_spec)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "accepts child_spec with all optional fields", %{supervisor_name: name} do
      child_spec = %{
        id: FullSpecChild,
        start: {MyGS, :start_link, name: FullSpecChild},
        restart: :transient,
        shutdown: 5000,
        type: :worker
      }

      assert {:ok, pid, FullSpecChild} = DistributedSupervisor.start_child(name, child_spec)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "converts module-with-args tuple to child spec", %{supervisor_name: name} do
      # {Module, args} format
      assert {:ok, pid, NamedChild} =
               DistributedSupervisor.start_child(name, {MyGS, name: NamedChild})

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "transforms child specs for internal use", %{supervisor_name: name} do
      # Start with minimal spec
      {:ok, pid, :transform_test} =
        DistributedSupervisor.start_child(
          name,
          {MyGS, name: :transform_test}
        )

      # Get transformed spec from children
      %{transform_test: {^pid, child_spec}} = DistributedSupervisor.children(name)

      # Verify transformed spec has all required fields and the via name
      assert is_map(child_spec)
      assert Map.has_key?(child_spec, :id)
      assert Map.has_key?(child_spec, :start)

      # Verify name is transformed to via tuple
      {_mod, _fun, args} = child_spec.start
      opts = List.first(args)
      assert Keyword.get(opts, :name) == DistributedSupervisor.via_name(name, :transform_test)
    end

    test "preserves restart strategy in child specs", %{supervisor_name: name} do
      # Start with explicit restart strategy
      {:ok, pid, RestartTest1} =
        DistributedSupervisor.start_child(
          name,
          {MyGS, name: RestartTest1, restart: :temporary}
        )

      # Kill process and verify it's not restarted (testing restart strategy was preserved)
      Process.exit(pid, :kill)
      Process.sleep(100)
      assert :undefined == DistributedSupervisor.whereis(name, RestartTest1)
    end

    test "handles invalid child specifications", %{supervisor_name: name} do
      # Missing required start field
      invalid_spec = %{
        id: :invalid_child
      }

      assert {:error, _} = DistributedSupervisor.start_child(name, invalid_spec)

      # Invalid module name
      assert {:error, _} = DistributedSupervisor.start_child(name, :not_a_valid_module)

      # Invalid start tuple format
      invalid_start_spec = %{
        id: :invalid_start,
        start: {:not_a_module, :not_a_function, []}
      }

      assert {:error, _} = DistributedSupervisor.start_child(name, invalid_start_spec)
    end

    test "properly handles name conflicts", %{supervisor_name: name} do
      # Start first process
      {:ok, pid1, :duplicate_name} =
        DistributedSupervisor.start_child(
          name,
          {MyGS, name: :duplicate_name}
        )

      # Try to start another with same name
      assert {:error, {:already_started, ^pid1}} =
               DistributedSupervisor.start_child(
                 name,
                 {MyGS, name: :duplicate_name}
               )
    end
  end
end
