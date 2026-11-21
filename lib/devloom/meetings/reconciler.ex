defmodule Devloom.Meetings.Reconciler do
  @moduledoc false
  use GenServer

  alias Devloom.Meetings

  @interval :timer.seconds(10)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def membership_changed(workspace_id),
    do: GenServer.cast(__MODULE__, {:membership_changed, workspace_id})

  @impl true
  def init(nil) do
    if Meetings.configured?() do
      schedule()
      {:ok, nil}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:reconcile, state) do
    Meetings.reconcile()
    schedule()
    {:noreply, state}
  end

  @impl true
  def handle_cast({:membership_changed, id}, state) do
    Meetings.reconcile(id)
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :reconcile, @interval)
end
