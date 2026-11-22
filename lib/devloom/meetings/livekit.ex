defmodule Devloom.Meetings.LiveKit do
  @moduledoc false

  @transcriber "devloom-transcriber"

  def configured? do
    Enum.all?([:url, :api_url, :api_key, :api_secret], fn key ->
      value = config()[key]
      is_binary(value) and value != ""
    end)
  end

  def join_credentials(room, user, identity) do
    grant = %{
      room: room,
      roomJoin: true,
      canSubscribe: true,
      canPublish: true,
      canPublishData: false,
      canPublishSources: ["camera", "microphone", "screen_share", "screen_share_audio"]
    }

    %{
      url: config()[:url],
      token: sign(%{sub: identity, name: user.name, video: grant}, 60)
    }
  end

  def transcriber_token(room) do
    grant = %{
      room: room,
      roomJoin: true,
      canSubscribe: true,
      canPublish: false,
      canPublishData: true
    }

    sign(%{sub: @transcriber, kind: "agent", video: grant}, 60)
  end

  def transcriber?(%{"identity" => @transcriber, "kind" => kind}), do: kind in ["AGENT", 4]
  def transcriber?(_participant), do: false

  def create_room(room) do
    request("CreateRoom", %{name: room, empty_timeout: 120, departure_timeout: 45}, %{
      roomCreate: true
    })
  end

  def delete_room(room), do: request("DeleteRoom", %{room: room}, %{roomCreate: true})

  def list_rooms(names) do
    with {:ok, response} <- request("ListRooms", %{names: names}, %{roomList: true}) do
      {:ok, Map.get(response, "rooms", [])}
    end
  end

  def list_participants(room) do
    with {:ok, response} <-
           request("ListParticipants", %{room: room}, %{roomAdmin: true, room: room}) do
      {:ok, Map.get(response, "participants", [])}
    end
  end

  def remove_participant(room, identity) do
    request("RemoveParticipant", %{room: room, identity: identity}, %{roomAdmin: true, room: room})
  end

  def start_recording(room, path) do
    egress_request(
      "StartEgress",
      %{
        room_name: room,
        template: %{layout: "speaker"},
        outputs: [%{file: %{filepath: path, file_type: "MP4", disable_manifest: true}}],
        storage: %{s3: Devloom.Meetings.RecordingStorage.egress_upload()}
      },
      7_000
    )
    |> normalize_job()
  end

  def stop_recording(id), do: egress_request("StopEgress", %{egress_id: id}) |> normalize_job()

  def recording_info(room, id, path) do
    filter = if id, do: %{egress_id: id}, else: %{room_name: room}

    with {:ok, response} <- egress_request("ListEgress", filter) do
      response
      |> Map.get("items", [])
      |> Enum.find(fn job ->
        if id do
          (job["egress_id"] || job["egressId"]) == id
        else
          outputs = get_in(job, ["egress", "outputs"]) || []
          Enum.any?(outputs, &(get_in(&1, ["file", "filepath"]) == path))
        end
      end)
      |> case do
        nil -> {:error, :not_found}
        job -> normalize_job({:ok, job})
      end
    end
  end

  defp normalize_job({:ok, job}) do
    {:ok,
     %{
       id: job["egress_id"] || job["egressId"],
       status: egress_status(Map.get(job, "status", "EGRESS_STARTING")),
       files: job["file_results"] || job["fileResults"] || []
     }}
  end

  defp normalize_job(error), do: error

  defp egress_status(value) when value in ["EGRESS_STARTING", 0], do: :starting
  defp egress_status(value) when value in ["EGRESS_ACTIVE", 1], do: :recording
  defp egress_status(value) when value in ["EGRESS_ENDING", 2], do: :processing

  defp egress_status(value) when value in ["EGRESS_COMPLETE", "EGRESS_LIMIT_REACHED", 3, 6],
    do: :complete

  defp egress_status(value) when value in ["EGRESS_FAILED", "EGRESS_ABORTED", 4, 5], do: :failed
  defp egress_status(_value), do: :unknown

  defp egress_request(method, body, timeout \\ 2_500),
    do: request(method, body, %{roomRecord: true}, "Egress", timeout)

  defp request(method, body, grant, service \\ "RoomService", timeout \\ 2_500) do
    options = [
      url:
        String.trim_trailing(config()[:api_url], "/") <> "/twirp/livekit.#{service}/" <> method,
      auth: {:bearer, sign(%{video: grant}, 60)},
      json: body,
      retry: false,
      redirect: false,
      receive_timeout: timeout,
      connect_options: [timeout: 2_000]
    ]

    case Req.post(Keyword.merge(options, config()[:request_options] || [])) do
      {:ok, %{status: 200, body: response}} when is_map(response) ->
        {:ok, response}

      {:ok, %{status: 404, body: %{"code" => "not_found"}}} ->
        {:error, :not_found}

      {:ok, %{status: status}} when service == "Egress" and status in [400, 401, 403, 412] ->
        {:error, :rejected}

      _ ->
        {:error, :unavailable}
    end
  end

  defp sign(claims, ttl) do
    now = System.system_time(:second)
    header = encode(%{alg: "HS256", typ: "JWT"})
    payload = encode(Map.merge(claims, %{iss: config()[:api_key], nbf: now - 5, exp: now + ttl}))
    message = header <> "." <> payload
    signature = :crypto.mac(:hmac, :sha256, config()[:api_secret], message)
    message <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp encode(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)
  defp config, do: Application.get_env(:devloom, __MODULE__, [])
end
