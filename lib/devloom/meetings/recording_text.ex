defmodule Devloom.Meetings.RecordingText do
  @moduledoc "Queues and persists transcripts and summaries of saved recordings."
  import Ecto.Query

  alias Devloom.Accounts.Scope
  alias Devloom.Meetings.{OpenRouter, Recording, RecordingAudio, RecordingTextJob}
  alias Devloom.Workspaces.Workspace
  alias Devloom.{Repo, Workspaces}

  def configured?(:summary), do: OpenRouter.configured?()
  def configured?(:transcript), do: configured?(:summary) and RecordingAudio.configured?()

  def subscribe(%Scope{workspace: %Workspace{id: id}}),
    do: Phoenix.PubSub.subscribe(Devloom.PubSub, topic(id))

  @doc "Loads text jobs for a recording already fetched through workspace access."
  def for_recording(%Recording{id: id}) do
    Repo.all(from j in RecordingTextJob, where: j.recording_id == ^id)
    |> Map.new(&{&1.kind, &1})
  end

  def request(%Scope{workspace: %Workspace{id: workspace_id}} = scope, id, kind)
      when kind in [:transcript, :summary] do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, {recording, changed}} <-
           Repo.transaction(fn ->
             # Serialize requests with membership changes and recording deletion.
             Repo.one(from w in Workspace, where: w.id == ^workspace_id, lock: "FOR UPDATE") ||
               Repo.rollback(:not_found)

             unless Workspaces.authorized_scope?(scope), do: Repo.rollback(:not_found)

             recording =
               Repo.one(
                 from r in Recording,
                   where: r.id == ^id and r.workspace_id == ^workspace_id and r.status == :ready,
                   lock: "FOR UPDATE"
               ) || Repo.rollback(:not_found)

             {recording, enqueue(recording, kind)}
           end) do
      if changed, do: notify(recording), else: :ok
    else
      :error -> {:error, :not_found}
      error -> error
    end
  end

  def request(_scope, _id, _kind), do: {:error, :not_found}

  defp enqueue(recording, kind) do
    job =
      Repo.one(
        from j in RecordingTextJob,
          where: j.recording_id == ^recording.id and j.kind == ^kind,
          lock: "FOR UPDATE"
      )

    if is_nil(job) or job.status == :failed do
      unless configured?(kind), do: Repo.rollback(:disabled)
      if kind == :summary, do: enqueue(recording, :transcript)

      (job || %RecordingTextJob{recording_id: recording.id, kind: kind})
      |> Ecto.Changeset.change(status: :queued, error: nil)
      |> Repo.insert_or_update!()
    end
  end

  @doc false
  def claim do
    source_finished =
      from t in RecordingTextJob,
        where:
          t.recording_id == parent_as(:job).recording_id and t.kind == :transcript and
            t.status in [:ready, :failed]

    {:ok, claimed} =
      Repo.transaction(fn ->
        case Repo.one(
               from j in RecordingTextJob,
                 as: :job,
                 where:
                   j.status == :queued and j.recording_id in subquery(active_recording_ids()),
                 where: j.kind == :transcript or exists(source_finished),
                 order_by: [asc: j.updated_at, asc: j.id],
                 limit: 1,
                 lock: "FOR UPDATE SKIP LOCKED"
             ) do
          nil ->
            nil

          job ->
            job
            |> Ecto.Changeset.change(status: :running, run_id: Ecto.UUID.generate())
            |> Repo.update!()
        end
      end)

    # Load outside the job lock because deleting the recording cascades to its jobs.
    if claimed do
      case Repo.get(Recording, claimed.recording_id) do
        %Recording{workspace_id: id} = recording when not is_nil(id) ->
          notify(recording)
          {claimed, recording}

        _ ->
          nil
      end
    end
  end

  @doc false
  def process(%RecordingTextJob{kind: :transcript} = job, recording, directory) do
    RecordingAudio.transcribe(recording, directory, fn -> Repo.exists?(running_job(job)) end)
  end

  def process(%RecordingTextJob{kind: :summary} = job, _recording, _directory) do
    if Repo.exists?(running_job(job)) do
      case Repo.get_by(RecordingTextJob, recording_id: job.recording_id, kind: :transcript) do
        %RecordingTextJob{status: :ready, result: %{"text" => text}} -> OpenRouter.summarize(text)
        _ -> {:error, :transcript_failed}
      end
    else
      {:error, :recording_unavailable}
    end
  end

  @doc false
  def renew(job) do
    {count, _} = Repo.update_all(running_job(job), set: [updated_at: now()])
    count == 1
  end

  @doc false
  def finish(job, recording, result) do
    fields =
      case result do
        {:ok, data} -> [status: :ready, result: data, error: nil]
        {:error, reason} -> [status: :failed, result: nil, error: Atom.to_string(reason)]
      end

    case Repo.update_all(running_job(job), set: [updated_at: now(), run_id: nil] ++ fields) do
      {1, _} -> notify(recording)
      {0, _} -> :ok
    end
  end

  @doc false
  def expire_stale(cutoff) do
    expired =
      from j in RecordingTextJob,
        where: j.status == :running and j.updated_at < ^cutoff,
        where: j.recording_id in subquery(active_recording_ids()),
        select: j.recording_id

    {_count, recording_ids} =
      Repo.update_all(expired,
        set: [status: :failed, error: "interrupted", run_id: nil, updated_at: now()]
      )

    for recording <- Repo.all(from r in Recording, where: r.id in ^recording_ids) do
      notify(recording)
    end

    :ok
  end

  defp running_job(job) do
    from j in RecordingTextJob,
      where: j.id == ^job.id and j.status == :running and j.run_id == ^job.run_id,
      where: j.recording_id in subquery(active_recording_ids())
  end

  defp active_recording_ids do
    from r in Recording,
      where: r.status == :ready and not is_nil(r.workspace_id),
      select: r.id
  end

  defp now, do: DateTime.utc_now(:second)

  defp notify(%Recording{workspace_id: workspace_id, id: id}) do
    Phoenix.PubSub.broadcast(Devloom.PubSub, topic(workspace_id), {:recording_text_changed, id})
  end

  defp topic(id), do: "workspace:#{id}:recording-text"
end
