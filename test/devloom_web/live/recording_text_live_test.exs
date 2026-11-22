defmodule DevloomWeb.RecordingTextLiveTest do
  use DevloomWeb.ConnCase, async: false

  import Devloom.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Devloom.Accounts.Scope
  alias Devloom.Meetings.{OpenRouter, Recording, RecordingStorage}
  alias Devloom.Meetings.{RecordingText, RecordingTextJob, RecordingTextWorker}
  alias Devloom.{Repo, Workspaces}

  setup %{conn: conn} do
    configure(OpenRouter, api_key: "local-test-key")

    configure(RecordingStorage,
      bucket: "meeting-recordings",
      region: "us-east-1",
      endpoint: "https://storage.example.com",
      access_key_id: "test-storage-key",
      secret_access_key: "test-storage-secret"
    )

    Req.Test.set_req_test_to_shared()
    context = setup_workspace(conn)

    recording =
      Repo.insert!(%Recording{
        workspace_id: context.workspace.id,
        meeting_id: Ecto.UUID.generate(),
        status: :ready
      })

    Map.merge(context, %{
      recording: recording,
      path: "/workspaces/#{context.workspace.id}/recordings/#{recording.id}"
    })
  end

  @tag :tmp_dir
  @tag timeout: :timer.minutes(1)
  @tag skip: if(System.find_executable("ffmpeg"), do: false, else: "requires FFmpeg")
  test "a member can generate a saved summary and seekable transcript from a recording", %{
    scope: owner,
    recording: recording,
    path: path,
    tmp_dir: tmp_dir
  } do
    member = invite_member(owner)
    video = sample_video(tmp_dir)
    id = recording.id

    Req.Test.expect(RecordingStorage, fn request ->
      assert request.method == "GET"
      assert request.request_path == "/meeting-recordings/#{Recording.object_key(recording)}"
      assert ["AWS4-HMAC-SHA256 " <> _] = get_req_header(request, "authorization")
      send_resp(request, 200, video)
    end)

    expect_transcription("Launch on Friday.", 0)
    expect_transcription("I will update the checklist.", 1)
    expect_summary("Launch on Friday.\n\nI will update the checklist.")

    {:ok, viewer, _} = live(member, path)
    assert has_element?(viewer, "#generate-recording-transcript")
    viewer |> element("#generate-recording-summary") |> render_click()
    render_click(viewer, "generate_recording_text", %{kind: "summary"})

    assert %{
             transcript: %{status: :queued},
             summary: %{status: :queued}
           } = RecordingText.for_recording(recording)

    assert has_element?(viewer, "#recording-summary-status")
    refute has_element?(viewer, "#generate-recording-summary")
    :ok = RecordingText.subscribe(owner)
    start_supervised!(RecordingTextWorker)

    for _ <- 1..4, do: assert_receive({:recording_text_changed, ^id}, 12_000)

    assert %{
             transcript: %{
               status: :ready,
               result: %{"part_count" => 2, "segments" => [first, second]}
             },
             summary: %{status: :ready}
           } = RecordingText.for_recording(recording)

    assert first["start_ms"] == 1_250
    assert second["start_ms"] > 900_000
    assert second["speaker"] == 2
    assert has_element?(viewer, "#recording-summary-result")
    assert has_element?(viewer, "#recording-transcript-line-0 [data-recording-seek='1.25']")
    assert has_element?(viewer, "#recording-transcript-line-1 [data-recording-seek]")

    {:ok, reopened, _} = live(member, path)
    assert has_element?(reopened, "#recording-summary-result")
    assert has_element?(reopened, "#recording-transcript-line-0")
    render_click(reopened, "generate_recording_text", %{kind: "summary"})
    assert Req.Test.verify!(RecordingStorage)
    assert Req.Test.verify!(OpenRouter)
  end

  test "a failed or interrupted summary can be retried using the saved transcript", %{
    conn: conn,
    scope: owner,
    recording: recording,
    path: path
  } do
    outsider = setup_workspace(build_conn())
    assert {:error, :not_found} = RecordingText.request(outsider.scope, recording.id, :summary)

    transcript =
      Repo.insert!(%RecordingTextJob{
        recording_id: recording.id,
        kind: :transcript,
        status: :ready,
        result: %{"text" => "Launch on Friday.", "part_count" => 1, "segments" => []}
      })

    library_path = "/workspaces/#{owner.workspace.id}/recordings"
    player_id = "#recording-player-#{recording.id}"
    {:ok, viewer, _} = live(conn, path)
    {:ok, observer, _} = live(invite_member(owner), path)

    assert has_element?(viewer, player_id <> "[phx-mounted]")
    viewer |> element("#generate-recording-summary") |> render_click()
    assert {job, ^recording} = RecordingText.claim()
    assert job.kind == :summary

    Req.Test.expect(OpenRouter, &send_resp(&1, 429, "Rate limited"))
    assert {:error, :provider_busy} = result = RecordingText.process(job, recording, nil)
    :ok = RecordingText.finish(job, recording, result)

    assert_patch(viewer, library_path)
    refute has_element?(viewer, player_id)
    assert has_element?(viewer, "#flash-error", "OpenRouter is busy")
    assert has_element?(observer, player_id)
    assert has_element?(observer, "#generate-recording-summary", "Retry summary")

    viewer |> element("#play-recording-#{recording.id}") |> render_click()
    assert_patch(viewer, path)
    assert has_element?(viewer, "#generate-recording-summary", "Retry summary")

    viewer |> element("#generate-recording-summary") |> render_click()
    assert {running, ^recording} = RecordingText.claim()
    :ok = RecordingText.expire_stale(DateTime.add(running.updated_at, 1))
    :ok = RecordingText.finish(running, recording, {:ok, %{"overview" => "Stale result"}})

    assert %{summary: %{status: :failed, error: "interrupted"}} =
             RecordingText.for_recording(recording)

    assert :ok = RecordingText.request(owner, recording.id, :summary)
    assert {retry, ^recording} = RecordingText.claim()
    refute retry.run_id == running.run_id
    :ok = RecordingText.finish(running, recording, {:ok, %{"overview" => "Stale result"}})
    expect_summary(transcript.result["text"])

    assert {:ok, _} = result = RecordingText.process(retry, recording, nil)
    :ok = RecordingText.finish(retry, recording, result)

    assert %{transcript: ^transcript, summary: %{status: :ready}} =
             RecordingText.for_recording(recording)

    assert Req.Test.verify!(OpenRouter)
  end

  defp expect_transcription(text, speaker) do
    Req.Test.expect(OpenRouter, fn request ->
      assert request.path_info == ["api", "v1", "audio", "transcriptions"]
      assert get_req_header(request, "authorization") == ["Bearer local-test-key"]

      assert %{
               "model" => "elevenlabs/scribe-v2",
               "input_audio" => %{"data" => encoded_audio, "format" => "mp3"},
               "response_format" => "verbose_json",
               "timestamp_granularities" => ["word"],
               "provider" => %{"options" => %{"elevenlabs" => %{"diarize" => true}}}
             } = request.body_params

      assert {:ok, audio} = Base.decode64(encoded_audio)
      assert byte_size(audio) > 0

      Req.Test.json(request, %{
        "text" => text,
        "words" => [%{"word" => text, "start" => 1.25, "end" => 1.8, "speaker" => speaker}]
      })
    end)
  end

  defp expect_summary(transcript) do
    Req.Test.expect(OpenRouter, fn request ->
      assert request.path_info == ["api", "v1", "chat", "completions"]
      assert get_req_header(request, "authorization") == ["Bearer local-test-key"]
      assert %{"messages" => [_, %{"content" => ^transcript}]} = request.body_params

      result = %{
        "overview" => "The team planned Friday’s launch.",
        "key_points" => ["Launch readiness"],
        "decisions" => ["Launch on Friday"],
        "action_items" => ["Update the checklist"]
      }

      Req.Test.json(request, %{
        "choices" => [
          %{"finish_reason" => "stop", "message" => %{"content" => Jason.encode!(result)}}
        ]
      })
    end)
  end

  defp sample_video(directory) do
    path = Path.join(directory, "meeting.mp4")

    args =
      ~w(-hide_banner -loglevel error -y -f lavfi -i color=blue:s=16x16:r=1
         -f lavfi -i anullsrc=r=16000:cl=mono
         -t 903 -c:v mpeg4 -c:a aac -threads 1) ++ [path]

    assert {_, 0} = System.cmd("ffmpeg", args, stderr_to_stdout: true)
    File.read!(path)
  end

  defp invite_member(owner) do
    user = user_fixture()
    {:ok, _invite, token} = Workspaces.create_invitation(owner, %{email: user.email})
    {:ok, _workspace} = Workspaces.accept_invitation(Scope.for_user(user), token)
    log_in_user(build_conn(), user)
  end

  defp configure(module, options) do
    previous = Application.get_env(:devloom, module)

    Application.put_env(
      :devloom,
      module,
      options ++ [request_options: [plug: {Req.Test, module}]]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:devloom, module, previous),
        else: Application.delete_env(:devloom, module)
    end)
  end
end
