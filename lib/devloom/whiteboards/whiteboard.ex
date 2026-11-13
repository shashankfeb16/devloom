defmodule Devloom.Whiteboards.Whiteboard do
  @moduledoc "A workspace's shared, revisioned drawing canvas."
  use Ecto.Schema
  import Ecto.Changeset

  schema "whiteboards" do
    field :name, :string, default: "Team whiteboard"
    field :scene, :map, default: %{"elements" => []}
    field :revision, :integer, default: 1
    belongs_to :workspace, Devloom.Workspaces.Workspace

    timestamps(type: :utc_datetime)
  end

  def rename_changeset(whiteboard, name) do
    whiteboard
    |> cast(%{"name" => name}, [:name], empty_values: [])
    |> update_change(:name, fn
      name when is_binary(name) -> String.trim(name)
      name -> name
    end)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
  end
end
