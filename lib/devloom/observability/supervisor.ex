defmodule Devloom.Observability.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Application.fetch_env!(:devloom, :observability)

    children = [
      {TelemetryMetricsPrometheus.Core,
       name: Devloom.Observability.Prometheus,
       start_async: false,
       metrics: Devloom.Observability.Metrics.definitions()},
      {Bandit,
       plug: Devloom.Observability.MetricsPlug,
       ip: {0, 0, 0, 0},
       port: Keyword.fetch!(config, :port)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
