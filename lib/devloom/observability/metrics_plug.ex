defmodule Devloom.Observability.MetricsPlug do
  @moduledoc """
  Serves only metrics on the dedicated internal listener, without app routes.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "GET", request_path: "/metrics"} = conn, _opts) do
    body = TelemetryMetricsPrometheus.Core.scrape(Devloom.Observability.Prometheus)

    conn
    |> put_resp_header("content-type", "text/plain; version=0.0.4; charset=utf-8")
    |> send_resp(200, body)
  end

  def call(conn, _opts), do: send_resp(conn, 404, "Not found\n")
end
