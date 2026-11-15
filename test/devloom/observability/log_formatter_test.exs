defmodule Devloom.Observability.LogFormatterTest do
  use ExUnit.Case, async: true

  alias Devloom.Observability.LogFormatter

  @timestamp {{2026, 11, 15}, {8, 30, 45, 123}}

  test "emits one JSON line with a UTC timestamp and queryable request metadata" do
    output =
      LogFormatter.format(:warning, ["request ", "failed\nwith stacktrace"], @timestamp,
        request_id: "req-123",
        method: "GET",
        route: "/workspaces/:id",
        status: 500,
        duration_ms: 731.4,
        params: %{"password" => "private"},
        cookie: "private",
        token: "private"
      )
      |> IO.iodata_to_binary()

    assert String.ends_with?(output, "\n")
    assert length(String.split(output, "\n", trim: true)) == 1

    assert Jason.decode!(output) == %{
             "timestamp" => "2026-11-15T08:30:45.123Z",
             "level" => "warning",
             "message" => "request failed\nwith stacktrace",
             "request_id" => "req-123",
             "method" => "GET",
             "route" => "/workspaces/:id",
             "status" => 500,
             "duration_ms" => 731.4
           }
  end

  test "preserves every OTP severity, including fatal-equivalent levels" do
    for level <- [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency] do
      line = LogFormatter.format(level, "message", @timestamp, [])
      assert Jason.decode!(IO.iodata_to_binary(line))["level"] == Atom.to_string(level)
    end
  end

  test "sanitizes malformed UTF-8 and unusual metadata without crashing Logger" do
    line =
      LogFormatter.format(:error, <<"stacktrace ", 255>>, @timestamp,
        request_id: self(),
        route: nil
      )

    decoded = Jason.decode!(IO.iodata_to_binary(line))
    assert String.valid?(decoded["message"])
    assert is_binary(decoded["request_id"])
    refute Map.has_key?(decoded, "route")
  end

  test "works through Logger.Formatter with a multiline OTP report" do
    {formatter, config} =
      Logger.Formatter.new(
        format: {LogFormatter, :format},
        metadata: [:request_id],
        colors: [enabled: false],
        utc_log: true
      )

    event = %{
      level: :error,
      msg: {:report, %{reason: "boom", stacktrace: "line 1\nline 2"}},
      meta: %{time: 1_700_000_000_000_000, request_id: "crash-123"}
    }

    output = formatter.format(event, config) |> IO.chardata_to_string()
    decoded = Jason.decode!(output)
    assert decoded["level"] == "error"
    assert decoded["request_id"] == "crash-123"
    assert decoded["message"] =~ "boom"
    assert decoded["message"] =~ "stacktrace"
    assert length(String.split(output, "\n", trim: true)) == 1
  end
end
