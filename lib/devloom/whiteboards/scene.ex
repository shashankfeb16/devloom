defmodule Devloom.Whiteboards.Scene do
  @moduledoc "Bounds and normalizes drawing data before it is persisted or broadcast."

  @types ~w(rectangle ellipse diamond line arrow freedraw text note)
  @max_bytes 2_000_000
  @styles %{
    "stroke" => "#1e293b",
    "fill" => "transparent",
    "strokeWidth" => 2,
    "opacity" => 100,
    "strokeStyle" => "solid",
    "roughness" => 1,
    "roundness" => true,
    "text" => "",
    "points" => []
  }
  @fields ~w(id type x y width height stroke fill strokeWidth opacity strokeStyle roughness roundness text points)

  def normalize(%{"elements" => elements} = scene) when is_list(elements) do
    with true <- length(elements) <= 1_000,
         {:ok, json} <- Jason.encode(scene),
         true <- byte_size(json) <= @max_bytes,
         {:ok, normalized} <- normalize_elements(elements),
         true <- unique_ids?(normalized) do
      {:ok, %{"elements" => normalized}}
    else
      _ -> {:error, :invalid_scene}
    end
  end

  def normalize(_scene), do: {:error, :invalid_scene}

  defp normalize_elements(elements) do
    Enum.reduce_while(elements, {:ok, []}, fn element, {:ok, acc} ->
      case normalize_element(element) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp normalize_element(element) when is_map(element) do
    element = Map.merge(@styles, Map.take(element, @fields))

    if valid_id?(element["id"]) and element["type"] in @types and
         Enum.all?(~w(x y width height), &coordinate?(element[&1])) and
         dimensions?(element) and
         color?(element["stroke"]) and fill?(element["fill"]) and
         element["strokeWidth"] in [1, 2, 4] and opacity?(element["opacity"]) and
         element["strokeStyle"] in ~w(solid dashed dotted) and
         element["roughness"] in [0, 1, 2] and is_boolean(element["roundness"]) and
         text?(element["text"]) and points?(element["points"]) and
         (element["type"] != "freedraw" or element["points"] != []) do
      {:ok, element}
    else
      :error
    end
  end

  defp normalize_element(_element), do: :error

  defp dimensions?(%{"type" => type}) when type in ["line", "arrow"], do: true
  defp dimensions?(element), do: element["width"] >= 0 and element["height"] >= 0

  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..100 and String.valid?(id)

  defp text?(text),
    do:
      is_binary(text) and byte_size(text) <= 40_000 and String.valid?(text) and
        String.length(text) <= 10_000

  defp coordinate?(value), do: is_number(value) and value >= -1_000_000 and value <= 1_000_000
  defp opacity?(value), do: is_number(value) and value >= 0 and value <= 100
  defp fill?("transparent"), do: true
  defp fill?(color), do: color?(color)
  defp color?(color) when is_binary(color), do: Regex.match?(~r/\A#[0-9a-fA-F]{6}\z/, color)
  defp color?(_color), do: false

  defp points?(points) when is_list(points) do
    length(points) <= 10_000 and
      Enum.all?(points, fn
        [x, y] -> coordinate?(x) and coordinate?(y)
        _ -> false
      end)
  end

  defp points?(_points), do: false

  defp unique_ids?(elements) do
    ids = Enum.map(elements, & &1["id"])
    length(Enum.uniq(ids)) == length(ids)
  end
end
