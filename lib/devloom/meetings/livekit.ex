defmodule Devloom.Meetings.LiveKit do
  @moduledoc false

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

  defp request(method, body, grant) do
    options = [
      url:
        String.trim_trailing(config()[:api_url], "/") <> "/twirp/livekit.RoomService/" <> method,
      auth: {:bearer, sign(%{video: grant}, 60)},
      json: body,
      retry: false,
      redirect: false,
      receive_timeout: 2_500,
      connect_options: [timeout: 2_000]
    ]

    case Req.post(Keyword.merge(options, config()[:request_options] || [])) do
      {:ok, %{status: 200, body: response}} when is_map(response) -> {:ok, response}
      {:ok, %{status: 404, body: %{"code" => "not_found"}}} -> {:error, :not_found}
      _ -> {:error, :unavailable}
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
