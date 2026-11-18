defmodule Devloom.Observability.LogFormatter do
  @moduledoc """
  Formats Logger events as one JSON line for Docker and Loki.

  Logger.Formatter handles OTP reports, stacktraces and truncation before calling
  this callback. Only explicitly allowed metadata is exported; request bodies,
  cookies and arbitrary process metadata are never added to the JSON envelope.
  """

  @metadata_keys [:request_id, :method, :route, :status, :duration_ms]

  def format(level, message, timestamp, metadata) do
    fields =
      metadata
      |> Keyword.take(@metadata_keys)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(fn {key, value} -> {key, json_value(value)} end)
      |> Map.merge(%{
        timestamp: timestamp_to_iso8601(timestamp),
        level: Atom.to_string(level),
        message: clean_text(message)
      })

    [Jason.encode_to_iodata!(fields), "\n"]
  end

  defp timestamp_to_iso8601({date, {hour, minute, second, millisecond}}) do
    {date, {hour, minute, second}}
    |> NaiveDateTime.from_erl!({millisecond * 1_000, 3})
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp json_value(value) when is_number(value) or is_boolean(value), do: value
  defp json_value(value) when is_binary(value), do: clean_text(value)
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value), do: inspect(value, limit: 20, printable_limit: 512)

  defp clean_text(value) do
    value
    |> Logger.Formatter.prune()
    |> IO.chardata_to_string()
  end
end
