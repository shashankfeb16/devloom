defmodule Devloom.Meetings.RecordingReconciler do
  @moduledoc false
  use GenServer

  alias Devloom.Meetings.{Recordings, RecordingStorage}

  @interval :timer.seconds(10)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    if RecordingStorage.configured?() do
      schedule()
      {:ok, nil}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:reconcile, state) do
    Recordings.reconcile()
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :reconcile, @interval)
end
