defmodule Devloom.Meetings.Transcripts do
  @moduledoc "Authorizes live transcription controls and calls the private worker."

  alias Devloom.Accounts.UserToken
  alias Devloom.Meetings.{LiveKit, Meeting, MediaTasks}
  alias Devloom.{Meetings, Repo}

  def configured? do
    LiveKit.configured?() and
      Enum.all?([:url, :secret], fn key ->
        value = config()[key]
        is_binary(value) and value != ""
      end)
  end

  def control(scope, meeting_id, session_token, action)
      when is_binary(session_token) and byte_size(session_token) == 32 and
             action in ["start", "stop"] do
    with true <- configured?() || {:error, :disabled},
         {:ok, {room, identity}} <-
           Meetings.with_control(scope, meeting_id, fn scope, meeting ->
             session = Repo.one(UserToken.active_token_query(session_token))

             unless session && session.user_id == scope.user.id do
               Repo.rollback(:forbidden)
             end

             {Meeting.room_name(meeting), "session-#{session.id}"}
           end) do
      MediaTasks
      |> Task.Supervisor.async_nolink(fn -> control_room(room, identity, action) end)
      |> Task.await(:infinity)
    end
  end

  def control(_scope, _meeting_id, _session_token, _action), do: {:error, :forbidden}

  defp control_room(room, identity, "start") do
    with {:ok, participants} <- LiveKit.list_participants(room),
         true <- Enum.any?(participants, &(&1["identity"] == identity)) || {:error, :not_in_call} do
      request(room, "start", %{token: LiveKit.transcriber_token(room)}, true)
    else
      {:error, :not_found} -> {:error, :no_meeting}
      error -> error
    end
  end

  defp control_room(room, _identity, "stop"), do: request(room, "stop", %{}, false)

  defp request(room, action, body, expected) do
    config = config()

    options = [
      url: String.trim_trailing(config[:url], "/") <> "/rooms/#{room}/#{action}",
      auth: {:bearer, config[:secret]},
      json: body,
      retry: false,
      redirect: false,
      receive_timeout: 7_500,
      connect_options: [timeout: 2_000]
    ]

    case Req.post(Keyword.merge(options, config[:request_options] || [])) do
      {:ok, %{status: 200, body: %{"active" => ^expected}}} -> :ok
      _ -> {:error, :unavailable}
    end
  end

  defp config, do: Application.get_env(:devloom, __MODULE__, [])
end
