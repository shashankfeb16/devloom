defmodule Devloom.Observability.Metrics do
  @moduledoc """
  Prometheus metrics with bounded labels and base units (seconds and bytes).

  LiveDashboard continues to use `DevloomWeb.Telemetry.metrics/0` separately.
  """

  import Telemetry.Metrics

  @buckets [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]

  def definitions do
    [
      distribution("devloom.http.request.duration.seconds",
        event_name: [:devloom, :http, :request, :stop],
        measurement: :duration,
        tags: [:method, :route, :status],
        unit: {:native, :second},
        reporter_options: [buckets: @buckets]
      ),
      counter("devloom.http.requests.total",
        event_name: [:devloom, :http, :request, :stop],
        measurement: :duration,
        tags: [:method, :route, :status]
      ),
      counter("devloom.http.exceptions.total",
        event_name: [:devloom, :http, :request, :exception],
        measurement: :duration,
        tags: [:method, :route]
      ),
      distribution("devloom.repo.query.duration.seconds",
        event_name: [:devloom, :repo, :query],
        measurement: :total_time,
        unit: {:native, :second},
        reporter_options: [buckets: @buckets]
      ),
      distribution("devloom.repo.queue.duration.seconds",
        event_name: [:devloom, :repo, :query],
        measurement: :queue_time,
        unit: {:native, :second},
        reporter_options: [buckets: @buckets]
      ),
      last_value("devloom.vm.memory.bytes",
        event_name: [:vm, :memory],
        measurement: :total,
        unit: :byte
      ),
      last_value("devloom.vm.run.queue",
        event_name: [:vm, :total_run_queue_lengths],
        measurement: :total
      ),
      last_value("devloom.vm.process.count",
        event_name: [:vm, :system_counts],
        measurement: :process_count
      ),
      live_view_duration(:mount),
      live_view_duration(:handle_event)
    ]
  end

  defp live_view_duration(operation) do
    name = if operation == :handle_event, do: "event", else: "mount"

    distribution("devloom.live.view.#{name}.duration.seconds",
      event_name: [:phoenix, :live_view, operation, :stop],
      measurement: :duration,
      tags: [:view],
      tag_values: fn %{socket: socket} -> %{view: inspect(socket.view)} end,
      unit: {:native, :second},
      reporter_options: [buckets: @buckets]
    )
  end
end
