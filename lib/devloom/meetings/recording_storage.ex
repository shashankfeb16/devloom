defmodule Devloom.Meetings.RecordingStorage do
  @moduledoc false

  alias Devloom.Meetings.Recording

  def configured? do
    Enum.all?([:bucket, :region, :access_key_id, :secret_access_key], fn key ->
      value = config()[key]
      is_binary(value) and value != ""
    end)
  end

  def egress_upload do
    config = config()

    %{
      bucket: config[:bucket],
      region: config[:region],
      access_key: config[:access_key_id],
      secret: config[:secret_access_key],
      endpoint: endpoint() || "",
      force_path_style: true
    }
  end

  def playback_url(recording, download?) do
    disposition =
      if download? do
        date = Calendar.strftime(recording.inserted_at, "%Y-%m-%d-%H%M-UTC")
        ~s(attachment; filename="devloom-meeting-#{date}.mp4")
      else
        "inline"
      end

    Req.Utils.aws_sigv4_url(
      signing_options() ++
        [
          datetime: DateTime.utc_now(),
          method: :get,
          url: object_url(recording),
          expires: 900,
          query: [
            {"response-cache-control", "private, no-store"},
            {"response-content-disposition", disposition},
            {"response-content-type", "video/mp4"}
          ]
        ]
    )
    |> URI.to_string()
  end

  def delete(recording) do
    case request(:delete, recording) do
      {:ok, %{status: status}} when status in [200, 204] -> :ok
      _ -> {:error, :unavailable}
    end
  end

  def size(recording) do
    case request(:head, recording) do
      {:ok, %{status: 200} = response} ->
        case Req.Response.get_header(response, "content-length") do
          [size] -> {:ok, String.to_integer(size)}
          _ -> {:error, :unavailable}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      _ ->
        {:error, :unavailable}
    end
  end

  def download(recording, path) do
    case request(:get, recording, into: File.stream!(path), receive_timeout: 30_000, raw: true) do
      {:ok, %{status: 200}} -> :ok
      _ -> {:error, :recording_unavailable}
    end
  end

  defp request(method, recording, overrides \\ []) do
    options = [
      method: method,
      url: object_url(recording),
      aws_sigv4: signing_options(),
      retry: false,
      redirect: false,
      receive_timeout: 2_500,
      connect_options: [timeout: 2_000]
    ]

    options
    |> Keyword.merge(overrides)
    |> Keyword.merge(config()[:request_options] || [])
    |> Req.request()
  end

  defp object_url(recording) do
    config = config()
    endpoint = endpoint() || "https://s3.#{config[:region]}.amazonaws.com"
    "#{String.trim_trailing(endpoint, "/")}/#{config[:bucket]}/#{Recording.object_key(recording)}"
  end

  defp signing_options do
    config = config()
    Keyword.take(config, [:region, :access_key_id, :secret_access_key]) ++ [service: :s3]
  end

  defp endpoint do
    case config()[:endpoint] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp config, do: Application.get_env(:devloom, __MODULE__, [])
end
