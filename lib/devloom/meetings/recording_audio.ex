defmodule Devloom.Meetings.RecordingAudio do
  @moduledoc false

  alias Devloom.Meetings.{OpenRouter, RecordingStorage}

  @part_duration_seconds 900
  @line_duration_ms 20_000
  @pause_ms 2_000

  def configured?,
    do: RecordingStorage.configured?() and not is_nil(System.find_executable("ffmpeg"))

  def transcribe(recording, directory, active?) do
    with ffmpeg when is_binary(ffmpeg) <- System.find_executable("ffmpeg"),
         true <- RecordingStorage.configured?() and active?.(),
         :ok <- File.mkdir(directory) do
      try do
        video = Path.join(directory, "recording.mp4")

        with :ok <- File.chmod(directory, 0o700),
             :ok <- RecordingStorage.download(recording, video),
             {:ok, parts} <- extract_audio(ffmpeg, video, directory) do
          File.rm(video)
          transcribe_parts(parts, active?)
        end
      after
        File.rm_rf(directory)
      end
    else
      _ -> {:error, :recording_unavailable}
    end
  end

  defp extract_audio(ffmpeg, video, directory) do
    manifest = Path.join(directory, "parts.csv")

    args =
      ~w(-hide_banner -loglevel error -nostdin -xerror -timelimit 600 -protocol_whitelist file
         -f mov -i) ++
        [video] ++
        ~w(-map 0:a:0 -af aresample=16000:async=1:first_pts=0 -ac 1 -c:a libmp3lame -b:a 32k
           -f segment -reset_timestamps 1 -segment_time) ++
        [
          Integer.to_string(@part_duration_seconds),
          "-segment_list",
          manifest,
          Path.join(directory, "audio-%05d.mp3")
        ]

    case System.cmd(ffmpeg, args, stderr_to_stdout: true) do
      {_output, 0} ->
        read_parts(manifest, directory)

      {output, _status} ->
        if String.contains?(output, "matches no streams"),
          do: {:error, :no_audio},
          else: {:error, :audio_extraction_failed}
    end
  end

  defp read_parts(manifest, directory) do
    with {:ok, csv} <- File.read(manifest),
         [_ | _] = rows <- String.split(csv, "\n", trim: true) do
      parts =
        Enum.map(rows, fn row ->
          # The segment muxer writes each part's actual offset into the MP4 timeline.
          [filename, start_time, end_time] = String.split(row, ",")

          {Path.join(directory, filename), to_ms(String.to_float(start_time)),
           to_ms(String.to_float(end_time))}
        end)

      {:ok, parts}
    else
      _ -> {:error, :no_audio}
    end
  end

  defp transcribe_parts(parts, active?) do
    result =
      parts
      |> Enum.with_index(1)
      |> Enum.reduce_while({[], []}, fn {{path, from, to}, part}, {texts, segments} ->
        with true <- active?.() || {:error, :recording_unavailable},
             {:ok, %{"text" => text} = response} <- OpenRouter.transcribe(path),
             {:ok, lines} <- transcript_lines(response, from, to, part) do
          File.rm(path)
          {:cont, {[text | texts], [lines | segments]}}
        else
          error -> {:halt, error}
        end
      end)

    case result do
      {texts, segments} when is_list(texts) ->
        {:ok,
         %{
           "text" => texts |> Enum.reverse() |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n"),
           "segments" => segments |> Enum.reverse() |> List.flatten(),
           "part_count" => length(parts)
         }}

      error ->
        error
    end
  end

  defp transcript_lines(%{"text" => ""}, _from, _to, _part), do: {:ok, []}

  defp transcript_lines(%{"words" => words}, from, to, part) when is_list(words) do
    lines =
      words
      |> Enum.reduce([], fn
        %{"word" => text, "start" => start, "end" => stop} = word, lines
        when is_binary(text) and is_number(start) and is_number(stop) and start >= 0 and
               stop >= start ->
          case clean_text(text) do
            "" ->
              lines

            text ->
              start_ms = min(from + to_ms(start), to)
              end_ms = min(from + to_ms(stop), to)
              add_word(lines, text, start_ms, end_ms, speaker(word))
          end

        _, lines ->
          lines
      end)
      |> Enum.reverse()
      |> Enum.map(fn {start_ms, end_ms, speaker, words} ->
        %{
          "start_ms" => start_ms,
          "end_ms" => end_ms,
          "speaker" => speaker,
          "text" => words |> Enum.reverse() |> Enum.join(" "),
          "part" => part
        }
      end)

    if lines == [], do: {:error, :invalid_response}, else: {:ok, lines}
  end

  defp transcript_lines(_response, _from, _to, _part), do: {:error, :invalid_response}

  defp add_word([{line_start, last_end, speaker, words} | rest], text, start, stop, speaker)
       when start - last_end <= @pause_ms and stop - line_start <= @line_duration_ms,
       do: [{line_start, max(last_end, stop), speaker, [text | words]} | rest]

  defp add_word(lines, text, start, stop, speaker), do: [{start, stop, speaker, [text]} | lines]

  defp speaker(%{"speaker" => number}) when is_integer(number) and number >= 0, do: number + 1
  defp speaker(_word), do: nil

  defp clean_text(text), do: text |> String.replace(<<0>>, "") |> String.trim()
  defp to_ms(seconds), do: round(seconds * 1_000)
end
