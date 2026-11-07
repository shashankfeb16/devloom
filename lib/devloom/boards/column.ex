defmodule Devloom.Boards.Column do
  @moduledoc "A configurable workflow column with an immutable work item status key."
  use Ecto.Schema
  import Ecto.Changeset

  @colors [:neutral, :blue, :amber, :purple, :green, :rose]

  schema "board_columns" do
    field :key, :string
    field :title, :string
    field :description, :string, default: ""
    field :color, Ecto.Enum, values: @colors, default: :blue
    field :completed, :boolean, default: false
    field :position, :integer, default: 0
    field :lock_version, :integer, default: 1

    belongs_to :board, Devloom.Boards.Board

    timestamps(type: :utc_datetime)
  end

  def colors, do: @colors

  def changeset(column, attrs) do
    column
    |> cast(normalize_attrs(attrs), [:title, :description, :color, :completed])
    |> update_change(:title, &trim_text/1)
    |> update_change(:description, fn value -> trim_text(value) || "" end)
    |> validate_required([:title, :color, :completed])
    |> validate_length(:title, max: 40)
    |> validate_length(:description, max: 100)
    |> unique_constraint(:title,
      name: :board_columns_board_title_index,
      message: "a column with this name already exists"
    )
    |> foreign_key_constraint(:board_id)
  end

  defp trim_text(value) when is_binary(value), do: String.trim(value)
  defp trim_text(nil), do: nil

  defp normalize_attrs(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    case Map.fetch(attrs, "color") do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "", do: Map.put(attrs, "color", nil), else: attrs

      _ ->
        attrs
    end
  end
end
