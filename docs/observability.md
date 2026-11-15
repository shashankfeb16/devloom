# Local observability

This optional stack adds Prometheus metrics, Grafana dashboards, and Loki logs to
the existing local Docker development environment. Start here before adapting the
setup for a VPS. It does not change `compose.production.yaml` or deploy anything.

## Start

Start Docker Desktop, then run these commands from the repository directory:

```sh
docker compose -f compose.yaml -f compose.observability.yaml up --build -d --wait
```

The first run downloads the monitoring images. Existing PostgreSQL data stays in
the same `pgdata` volume. Open:

| Service | Address | Access |
| --- | --- | --- |
| Devloom | http://localhost:4000 | Existing app accounts |
| Grafana | http://localhost:3000 | `admin` / `devloom_local_grafana` |
| Prometheus | http://localhost:9090 | Local development UI |

Grafana opens the provisioned **Devloom · Local observability** dashboard.
`GRAFANA_PORT`, `PROMETHEUS_PORT`, `APP_PORT`, and `GRAFANA_ADMIN_PASSWORD` can be
overridden in `.env`; see `.env.example`. Grafana's initial admin password applies
when its data volume is first initialized. Changing the environment variable
later does not reset an existing account password; use Grafana's password settings.

Grafana and Prometheus bind to `127.0.0.1`. Loki and Alloy have no published ports.
Prometheus scrapes Phoenix on a separate internal `web:9568/metrics` listener;
`/metrics` is not added to the public application router.

## What the charts mean

- **Availability, traffic and errors:** scrape health, requests per second, HTTP
  5xx rates, and raised router exceptions. A missing URL is a 404; it is not an
  HTTP 5xx server failure.
- **Slow endpoints:** latency histograms with p50/p95/p99 estimates, grouped by
  HTTP method and route template. `/workspaces/123/board` and
  `/workspaces/456/board` share `/workspaces/:workspace_id/board`. Actual labels
  follow the Phoenix router's parameter names. No user IDs or query strings are
  used as metric labels. Unmatched paths share `unmatched`.
- **CPU and RAM:** cAdvisor measures the `web` and `db` containers. CPU shown as
  percent of one core can exceed 100% when several cores are used. Memory working
  set is container memory; BEAM memory is Erlang's own allocation and is a
  different measurement. On Docker Desktop, these are Linux container metrics,
  not the physical Mac's total CPU/RAM.
- **Database and LiveView:** query/connection-queue duration and LiveView
  mount/event duration help distinguish database delays from work inside a live
  connection. Browser-side rendering and network latency are outside these
  measurements.

HTTP timing wraps router dispatch: routing, Phoenix pipelines, database calls and
rendering are included. Static files, body parsing before the router, and the
lifetime of a WebSocket connection are excluded. LiveView callback metrics cover
server work after the socket connects. Parser failures before the router still
appear in normal Phoenix error logs but do not increment the router counters.

The initial slow-request threshold is **p95 above 500 ms**. Treat this as a local
starting point; set an actual target from expected behavior and measured traffic.
Percentiles are bucket estimates over recent requests, and a quiet endpoint may
show no data. Allow at least 30–60 seconds for the first scrapes and a few minutes
of traffic for useful rate/percentile charts. LiveView charts appear after using
the application through a browser.

## Find warning and error logs

The overlay enables one JSON line per Logger event, including escaped multiline
stacktraces and request IDs. Grafana Alloy collects the current project's `web`
container stdout/stderr and sends it to Loki. Normal startup/build output can
remain plain text and is retained too. Log ingestion is scoped to this Compose
project; unrelated local Docker apps are excluded.

Use the dashboard's log-level filter or **Explore → Loki**:

```logql
{app="devloom", service="web"}
```

Warnings and severe events:

```logql
{app="devloom", service="web", level=~"warning|error|critical|alert|emergency"}
```

Find all JSON log entries for a request ID copied from a failure:

```logql
{app="devloom", service="web"} | json | request_id="YOUR_REQUEST_ID"
```

Elixir uses `warning`, `error`, `critical`, `alert`, and `emergency`; it has no
`fatal` Logger level. Use `Logger.critical/1` (or alert/emergency as appropriate)
for the severity you would call fatal. Exceptions and OTP crash reports emitted
by Logger retain their formatted report/stacktrace in the `message` field.
Supervision can recover a crashed process, so an error log does not necessarily
mean the whole application is down.

Request completion logs include method, normalized route, response status,
duration, and the request ID set by Phoenix. HTTP 4xx completions are warnings;
5xx completions are errors. Application code can add useful context with the
existing Logger API:

```elixir
require Logger
Logger.warning("External service responded slowly")
Logger.error("Background operation failed")
```

The JSON formatter exports an allowlist of request metadata, rather than all
process metadata. Existing Phoenix parameter filtering still applies. Messages
and exception reports can contain whatever application code logs; avoid writing
passwords, session tokens, or full request bodies into messages. Only severity
and fixed service labels are indexed in Loki; request IDs stay in the JSON.

## Check the setup

```sh
docker compose -f compose.yaml -f compose.observability.yaml ps
curl --fail http://localhost:4000/health
curl --fail http://localhost:3000/api/health
curl --fail http://localhost:9090/-/ready
```

Use the app normally to generate traffic. A safe missing URL produces a warning
without modifying data:

```sh
curl -o /dev/null -s -w '%{http_code}\n' http://localhost:4000/observability-missing-page
```

Look for the `unmatched`/404 request and its warning log. In Prometheus, check
**Status → Target health** for `devloom`; query `up{job="devloom"}` (expected 1),
`devloom_http_requests_total`, and
`container_memory_working_set_bytes{app="devloom",service="web"}`. Container
metrics arrive through Alloy's embedded cAdvisor and remote write, so they do not
appear as a separate Prometheus scrape target.

If a panel stays empty, check the actual data and collector logs:

```sh
docker compose -f compose.yaml -f compose.observability.yaml logs --tail=100 web alloy prometheus loki grafana
docker compose -f compose.yaml -f compose.observability.yaml exec web curl --fail http://localhost:9568/metrics
```

If the Docker context uses a different socket path or Docker Desktop blocks the
Linux cgroup mounts, the resource collector needs platform-specific adjustments.
Alloy requires Docker socket access and privileged Linux cgroup mounts for this
local collector. A read-only socket mount still gives powerful Docker API access;
keep this overlay local and review collector privileges for a VPS deployment.

## Alert rules and storage

Prometheus loads local rules for missing application metrics, elevated server
errors, and slow routes. View pending/firing rules in Prometheus's **Alerts**
page. These are visual monitoring rules; email/Slack/paging delivery is not
configured. The slow/error rules need sustained traffic before firing.

Prometheus retains up to seven days or 2 GB of metrics, whichever limit is
reached first. Loki's filesystem storage has seven-day retention with asynchronous
compaction/deletion; this is not a hard disk-space limit. Grafana settings and
Alloy read positions also persist in named Docker volumes. Web container log
files rotate at 10 MB with three files. Monitor disk usage during long sessions.

Use both Compose files consistently while this stack is running:

```sh
# Restart Phoenix after config or startup changes.
docker compose -f compose.yaml -f compose.observability.yaml restart web

# Stop the app and monitoring without deleting stored data.
docker compose -f compose.yaml -f compose.observability.yaml down

# Return to the original app-only setup after stopping the overlay.
docker compose up -d --wait
```

Avoid `down -v` unless you intend to erase named volumes, including PostgreSQL.

## Later, on a VPS

Keep the app instrumentation and adapt the infrastructure after choosing the
server. Add Linux host metrics if you need whole-server CPU, memory and disk,
choose storage/retention and resource budgets, restrict metrics/log endpoints to
private networks, and configure authenticated Grafana access and notification
delivery. This local overlay is not a production deployment configuration.

Implementation references: [TelemetryMetricsPrometheus.Core](https://hexdocs.pm/telemetry_metrics_prometheus_core/TelemetryMetricsPrometheus.Core.html),
[Alloy Docker logs](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.docker/),
[Alloy cAdvisor](https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.exporter.cadvisor/),
and [Elixir Logger](https://hexdocs.pm/logger/Logger.html).
