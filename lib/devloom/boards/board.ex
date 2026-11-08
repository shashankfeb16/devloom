defmodule Devloom.Boards.Board do
  @moduledoc "A Kanban board, which is the boundary for work items and live updates."
  use Ecto.Schema

  schema "boards" do
    field :name, :string
    field :slug, :string
    belongs_to :workspace, Devloom.Workspaces.Workspace
    field :authorized_user_id, :integer, virtual: true

    has_many :work_items, Devloom.Boards.WorkItem
    has_many :columns, Devloom.Boards.Column

    timestamps(type: :utc_datetime)
  end
end
