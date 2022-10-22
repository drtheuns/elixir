defmodule ExUnit.Server do
  @moduledoc false
  @name __MODULE__
  @timeout :infinity

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  def add_async_module(name, async_type \\ :per_module)
  # async: true is an alias for async: :per_module
  def add_async_module(name, true), do: add_async_module(name, :per_module)

  def add_async_module(name, async_type) when async_type in [:per_module, :per_test],
    do: add({name, async_type}, :async)

  def add_sync_module(name), do: add(name, :sync)

  def add_running_test(ref, pid), do: add({ref, pid}, :running)

  defp add(name, type) do
    case GenServer.call(@name, {:add, name, type}, @timeout) do
      :ok ->
        :ok

      :already_running ->
        raise "cannot add #{type} case named #{inspect(name)} to test suite after the suite starts running"
    end
  end

  def modules_loaded do
    GenServer.call(@name, :modules_loaded, @timeout)
  end

  def take_async_modules(count) do
    GenServer.call(@name, {:take_async_modules, count}, @timeout)
  end

  def take_sync_modules() do
    GenServer.call(@name, :take_sync_modules, @timeout)
  end

  def take_running_tests(count) do
    GenServer.call(@name, {:take_running_tests, count}, @timeout)
  end

  ## Callbacks

  def init(:ok) do
    state = %{
      loaded: System.monotonic_time(),
      waiting: nil,
      async_modules: [],
      sync_modules: [],
      running_tests: []
    }

    {:ok, state}
  end

  def handle_call({:take_running_tests, count}, _from, state) do
    {reply, tests} =
      case Enum.split(state.running_tests, count) do
        {[], tests} -> {nil, tests}
        reply -> reply
      end

    {:reply, reply, %{state | running_tests: tests}}
  end

  # Called on demand until we are signaled all modules are loaded.
  def handle_call({:take_async_modules, count}, from, %{waiting: nil} = state) do
    {:noreply, take_modules(%{state | waiting: {from, count}})}
  end

  # Called once after all async modules have been sent and reverts the state.
  def handle_call(:take_sync_modules, _from, state) do
    %{waiting: nil, loaded: :done, async_modules: []} = state
    {:reply, state.sync_modules, %{state | sync_modules: [], loaded: System.monotonic_time()}}
  end

  def handle_call(:modules_loaded, _from, %{loaded: :done} = state) do
    {:reply, 0, state}
  end

  def handle_call(:modules_loaded, _from, %{loaded: loaded} = state) when is_integer(loaded) do
    diff = System.convert_time_unit(System.monotonic_time() - loaded, :native, :microsecond)
    {:reply, diff, take_modules(%{state | loaded: :done})}
  end

  def handle_call({:add, {_, _} = name_and_type, :async}, _from, %{loaded: loaded} = state)
      when is_integer(loaded) do
    state = update_in(state.async_modules, &[name_and_type | &1])
    {:reply, :ok, take_modules(state)}
  end

  def handle_call({:add, name, :sync}, _from, %{loaded: loaded} = state)
      when is_integer(loaded) do
    state = update_in(state.sync_modules, &[name | &1])
    {:reply, :ok, state}
  end

  def handle_call({:add, {_, _} = ref_and_pid, :running}, _from, state) do
    state = update_in(state.running_tests, &[ref_and_pid | &1])
    {:reply, :ok, state}
  end

  def handle_call({:add, _name, _type}, _from, state),
    do: {:reply, :already_running, state}

  defp take_modules(%{waiting: nil} = state) do
    state
  end

  defp take_modules(%{waiting: {from, _count}, async_modules: [], loaded: :done} = state) do
    GenServer.reply(from, nil)
    %{state | waiting: nil}
  end

  defp take_modules(%{async_modules: []} = state) do
    state
  end

  defp take_modules(%{waiting: {from, count}, async_modules: modules} = state) do
    {reply, modules} = Enum.split(modules, count)
    GenServer.reply(from, reply)
    %{state | async_modules: modules, waiting: nil}
  end
end
