defmodule Devloom.Observability.RequestMetrics do
  @moduledoc """
  Measures router dispatch, including pipelines, database work and rendering.

  Static files, WebSocket traffic and parsing before the router are excluded.
  LiveView callback metrics cover work performed after a WebSocket connects.
  Route templates and a fixed method allowlist keep labels bounded; request
  paths, IDs, query strings, params and bodies are never included in these events.
  """
  @behaviour Plug
  require Logger

  @methods ~w(GET HEAD POST PUT PATCH DELETE OPTIONS CONNECT TRACE)

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :router)

  @impl true
  def call(conn, router) do
    if Application.get_env(:devloom, :observability, [])[:enabled] do
      instrument(conn, router)
    else
      router.call(conn, router.init([]))
    end
  end

  defp instrument(conn, router) do
    metadata = %{method: method(conn.method), route: route(router, conn)}
    started_at = System.monotonic_time()

    result =
      try do
        router.call(conn, router.init([]))
      catch
        kind, reason ->
          stacktrace = __STACKTRACE__
          status = exception_status(kind, reason)
          record(started_at, Map.put(metadata, :status, status), :exception)
          :erlang.raise(kind, reason, stacktrace)
      end

    record(started_at, Map.put(metadata, :status, result.status || 500), :stop)
    result
  end

  defp record(started_at, metadata, outcome) do
    duration = System.monotonic_time() - started_at
    measurements = %{duration: duration}

    # A failure produces one completed request and one exception, without
    # combining overlapping Phoenix endpoint/router telemetry events.
    :telemetry.execute([:devloom, :http, :request, :stop], measurements, metadata)

    if outcome == :exception do
      :telemetry.execute([:devloom, :http, :request, :exception], measurements, metadata)
    end

    level =
      cond do
        metadata.status >= 500 -> :error
        metadata.status >= 400 -> :warning
        true -> :info
      end

    Logger.log(level, "HTTP request #{if outcome == :exception, do: "failed", else: "completed"}",
      method: metadata.method,
      route: metadata.route,
      status: metadata.status,
      duration_ms: System.convert_time_unit(duration, :native, :microsecond) / 1_000
    )
  end

  defp method(value) when value in @methods, do: value
  defp method(_value), do: "OTHER"

  defp route(router, conn) do
    case Phoenix.Router.route_info(router, conn.method, conn.request_path, conn.host) do
      %{route: template} -> template
      _ -> "unmatched"
    end
  rescue
    _ -> "unmatched"
  end

  defp exception_status(:error, %Plug.Conn.WrapperError{kind: kind, reason: reason}) do
    exception_status(kind, reason)
  end

  defp exception_status(:error, reason), do: Plug.Exception.status(reason)
  defp exception_status(_kind, _reason), do: 500
end
