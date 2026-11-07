defmodule Devloom.Boards.WorkItem do
  @moduledoc "A persisted, ordered work item belonging to one board."
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(backlog todo in_progress in_review done)
  @types [:feature, :task, :bug]
  @priorities [:low, :medium, :high, :urgent]

  schema "work_items" do
    field :title, :string
    field :description, :string, default: ""
    field :status, :string
    field :type, Ecto.Enum, values: @types, default: :task
    field :priority, Ecto.Enum, values: @priorities, default: :medium
    field :labels, {:array, :string}, default: []
    # A plain name until accounts and board memberships are introduced.
    field :assignee, :string
    field :estimate, :integer
    field :position, :integer, default: 0
    field :lock_version, :integer, default: 1

    belongs_to :board, Devloom.Boards.Board

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def types, do: @types
  def priorities, do: @priorities

  def changeset(work_item, attrs) do
    work_item
    |> cast(normalize_attrs(attrs), [
      :title,
      :description,
      :status,
      :type,
      :priority,
      :labels,
      :assignee,
      :estimate
    ])
    |> update_change(:title, &trim_text/1)
    |> update_change(:assignee, fn value ->
      case trim_text(value) do
        "" -> nil
        value -> value
      end
    end)
    |> validate_required([:title, :status, :type, :priority])
    |> validate_length(:title, max: 180)
    |> validate_length(:description, max: 10_000)
    |> validate_length(:assignee, max: 100)
    |> validate_length(:labels, max: 8)
    |> validate_change(:labels, fn :labels, labels ->
      if Enum.any?(labels, &(String.length(&1) > 32)) do
        [labels: "each label must be at most 32 characters"]
      else
        []
      end
    end)
    |> validate_number(:estimate, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> foreign_key_constraint(:board_id)
    |> foreign_key_constraint(:status,
      name: :work_items_column_fkey,
      message: "select an available column"
    )
  end

  defp normalize_attrs(attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> normalize_required_enums()

    attrs =
      case Map.fetch(attrs, "status") do
        {:ok, status} when is_atom(status) and not is_nil(status) ->
          Map.put(attrs, "status", Atom.to_string(status))

        _ ->
          attrs
      end

    case Map.fetch(attrs, "labels") do
      {:ok, nil} ->
        Map.put(attrs, "labels", [])

      {:ok, labels} when is_binary(labels) ->
        Map.put(attrs, "labels", normalize_labels(String.split(labels, ",")))

      {:ok, labels} when is_list(labels) ->
        if Enum.all?(labels, &is_binary/1) do
          Map.put(attrs, "labels", normalize_labels(labels))
        else
          attrs
        end

      _ ->
        attrs
    end
  end

  defp trim_text(value) when is_binary(value), do: String.trim(value)
  defp trim_text(nil), do: nil

  defp normalize_required_enums(attrs) do
    Enum.reduce(["status", "type", "priority"], attrs, fn field, attrs ->
      case Map.fetch(attrs, field) do
        {:ok, value} when is_binary(value) ->
          if String.trim(value) == "", do: Map.put(attrs, field, nil), else: attrs

        _ ->
          attrs
      end
    end)
  end

  defp normalize_labels(labels) do
    labels
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
