defmodule Devloom.Observability.MetricsTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Devloom.Observability.{Metrics, MetricsPlug, RequestMetrics}

  @moduletag capture_log: true

  setup do
    previous = Application.fetch_env!(:devloom, :observability)
    Application.put_env(:devloom, :observability, enabled: true)
    on_exit(fn -> Application.put_env(:devloom, :observability, previous) end)

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: Devloom.Observability.Prometheus, start_async: false, metrics: Metrics.definitions()}
    )

    :ok
  end

  test "requests use one route template for different IDs and omit query strings" do
    for id <- ["first-private-id", "second-private-id"] do
      assert request("GET", "/probe/#{id}?token=secret").status == 200
    end

    body = scrape()
    tags = %{method: "GET", route: "/probe/:id", status: "200"}

    assert metric_value(body, "devloom_http_requests_total", tags) == 2
    assert metric_value(body, "devloom_http_request_duration_seconds_count", tags) == 2
    refute body =~ "first-private-id"
    refute body =~ "second-private-id"
    refute body =~ "secret"
    refute body =~ "token"
  end

  test "exceptions preserve the original error and count one failed request" do
    error = assert_raise Plug.Conn.WrapperError, fn -> request("GET", "/probe/boom") end
    assert %RuntimeError{message: "test request failure"} = error.reason

    body = scrape()
    tags = %{method: "GET", route: "/probe/:id", status: "500"}

    assert metric_value(body, "devloom_http_requests_total", tags) == 1
    assert metric_value(body, "devloom_http_request_duration_seconds_count", tags) == 1

    assert metric_value(body, "devloom_http_exceptions_total", %{
             method: "GET",
             route: "/probe/:id"
           }) == 1
  end

  test "unmatched routes and arbitrary HTTP methods produce bounded labels and preserve 404" do
    assert_raise Phoenix.Router.NoRouteError, fn -> request("GET", "/unknown/private-id") end

    assert_raise Phoenix.Router.NoRouteError, fn ->
      request("PRIVATE-METHOD", "/other/private-id")
    end

    body = scrape()

    assert metric_value(body, "devloom_http_requests_total", %{
             method: "GET",
             route: "unmatched",
             status: "404"
           }) == 1

    assert metric_value(body, "devloom_http_requests_total", %{
             method: "OTHER",
             route: "unmatched",
             status: "404"
           }) == 1

    refute body =~ "private-id"
    refute body =~ "PRIVATE-METHOD"
  end

  test "database timing uses seconds and VM memory uses bytes" do
    :telemetry.execute([:devloom, :repo, :query], %{
      total_time: System.convert_time_unit(250, :millisecond, :native),
      queue_time: System.convert_time_unit(10, :millisecond, :native)
    })

    :telemetry.execute([:vm, :memory], %{total: 123_456})
    body = scrape()

    assert metric_value(body, "devloom_repo_query_duration_seconds_sum", %{}) == 0.25
    assert metric_value(body, "devloom_repo_queue_duration_seconds_sum", %{}) == 0.01
    assert metric_value(body, "devloom_vm_memory_bytes", %{}) == 123_456
  end

  test "metrics-only listener serves Prometheus text and cannot dispatch application routes" do
    conn = conn(:get, "/metrics") |> MetricsPlug.call(MetricsPlug.init([]))
    assert conn.status == 200

    assert Plug.Conn.get_resp_header(conn, "content-type") == [
             "text/plain; version=0.0.4; charset=utf-8"
           ]

    assert (conn(:get, "/health") |> MetricsPlug.call([])).status == 404
    assert (conn(:post, "/metrics") |> MetricsPlug.call([])).status == 404
  end

  test "disabled instrumentation passes through without collecting requests" do
    Application.put_env(:devloom, :observability, enabled: false)
    assert request("GET", "/probe/first").status == 200
    refute scrape() =~ ~s(route="/probe/:id")
  end

  defp request(method, path) do
    conn(method, path)
    |> RequestMetrics.call(RequestMetrics.init(router: DevloomWeb.ObservabilityTestRouter))
  end

  defp scrape do
    conn(:get, "/metrics") |> MetricsPlug.call([]) |> Map.fetch!(:resp_body)
  end

  defp metric_value(body, name, tags) do
    line =
      body
      |> String.split("\n")
      |> Enum.find(fn line ->
        (String.starts_with?(line, name <> "{") or String.starts_with?(line, name <> " ")) and
          Enum.all?(tags, fn {key, value} -> String.contains?(line, ~s(#{key}="#{value}")) end)
      end)

    assert line, "missing #{name} #{inspect(tags)} in:\n#{body}"
    {value, _rest} = line |> String.split() |> List.last() |> Float.parse()
    value
  end
end
