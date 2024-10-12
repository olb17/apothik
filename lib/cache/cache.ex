defmodule Apothik.Cache do
  use GenServer

  # Interface
  def get(k), do: GenServer.call(__MODULE__, {:get, k})

  def put(k, v), do: GenServer.call(__MODULE__, {:put, k, v})

  def delete(k), do: GenServer.call(__MODULE__, {:delete, k})

  def stats(), do: GenServer.call(__MODULE__, :stats)

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  # Implementation
  @impl true
  def init(_args) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:get, k}, _from, state) do
    {:reply, Map.get(state, k), state}
  end

  def handle_call({:put, k, v}, _from, state) do
    new_state = Map.put(state, k, v)
    {:reply, :ok, new_state}
  end

  def handle_call({:delete, k}, _from, state) do
    new_state = Map.delete(state, k)
    {:reply, :ok, new_state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, map_size(state), state}
  end
end