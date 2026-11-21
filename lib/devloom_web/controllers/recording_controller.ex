defmodule DevloomWeb.RecordingController do
  use DevloomWeb, :controller

  alias Devloom.Meetings.{Recordings, RecordingStorage}
  alias Devloom.Workspaces

  def show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    with {:ok, scope} <- Workspaces.fetch_scope(conn.assigns.current_scope, workspace_id),
         {:ok, %{status: :ready} = recording} <- Recordings.fetch(scope, id) do
      if RecordingStorage.configured?() do
        redirect(conn,
          external: RecordingStorage.playback_url(recording, conn.params["download"] == "1")
        )
      else
        send_resp(conn, 503, "Recording storage is unavailable.")
      end
    else
      _ -> send_resp(conn, 404, "Recording not found.")
    end
  end
end
