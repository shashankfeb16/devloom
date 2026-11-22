defmodule Devloom.Meetings.RecordingTextWorker do
  @moduledoc false
  use GenServer

  alias Devloom.Meetings.{MediaTasks, OpenRouter, RecordingText}

  @poll_interval :timer.seconds(3)
  @heartbeat_interval :timer.seconds(20)
  @lease_seconds 90
  @job_timeout :timer.minutes(45)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    if OpenRouter.configured?() do
      Process.send_after(self(), :poll, @poll_interval)
      {:ok, nil}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:poll, nil) do
    RecordingText.expire_stale(DateTime.add(DateTime.utc_now(), -@lease_seconds))

    case RecordingText.claim() do
      {job, recording} ->
        directory =
          if job.kind == :transcript do
            Path.join(System.tmp_dir!(), "devloom-recording-#{Ecto.UUID.generate()}")
          end

        task =
          Task.Supervisor.async_nolink(MediaTasks, fn ->
            RecordingText.process(job, recording, directory)
          end)

        {:noreply,
         %{
           task: task,
           heartbeat: schedule_heartbeat(task.ref),
           timeout: Process.send_after(self(), {:timeout, task.ref}, @job_timeout),
           job: job,
           recording: recording,
           directory: directory
         }}

      nil ->
        Process.send_after(self(), :poll, @poll_interval)
        {:noreply, nil}
    end
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish(state, result)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state),
    do: finish(state, {:error, :interrupted})

  def handle_info({:heartbeat, ref}, %{task: %Task{ref: ref} = task} = state) do
    if RecordingText.renew(state.job) do
      {:noreply, %{state | heartbeat: schedule_heartbeat(ref)}}
    else
      Task.shutdown(task, :brutal_kill)
      finish(state, {:error, :interrupted})
    end
  end

  def handle_info({:timeout, ref}, %{task: %Task{ref: ref} = task} = state) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> finish(state, result)
      _ -> finish(state, {:error, :interrupted})
    end
  end

  def handle_info({timer, _ref}, state) when timer in [:heartbeat, :timeout],
    do: {:noreply, state}

  defp finish(state, result) do
    Process.cancel_timer(state.heartbeat)
    Process.cancel_timer(state.timeout)
    if state.directory, do: File.rm_rf(state.directory)
    RecordingText.finish(state.job, state.recording, result)
    send(self(), :poll)
    {:noreply, nil}
  end

  defp schedule_heartbeat(ref),
    do: Process.send_after(self(), {:heartbeat, ref}, @heartbeat_interval)
end
