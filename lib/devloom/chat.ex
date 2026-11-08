defmodule Devloom.Chat do
  @moduledoc """
  Persistent team conversation scoped to a board.

  Display names are guest-provided labels, not verified account identities.
  A future membership layer must resolve an authorized board before calling
  this context. Client references make retries safe without duplicating posts.
  """
  import Ecto.Query

  alias Devloom.Boards.Board
  alias Devloom.Chat.Message
  alias Devloom.Repo

  @default_limit 50
  @maximum_limit 200
  @maximum_id 9_223_372_036_854_775_807

  def subscribe(%Board{id: id}) do
    Phoenix.PubSub.subscribe(Devloom.PubSub, topic(id))
  end

  def change_message(attrs \\ %{}), do: Message.changeset(%Message{}, attrs)

  @doc """
  Returns a bounded page in chronological order (ascending message ID).

  Without a cursor, returns the newest page. `before_id` returns the nearest
  older page; `after_id` returns the first newer page for gap-free catch-up.
  `limit` defaults to 50 and is capped at 200. Invalid or simultaneous cursors
  return an empty page. Cursors may be positive integer IDs or decimal strings;
  `after_id: 0` starts catch-up from the beginning of the conversation.
  """
  def list_messages(%Board{id: board_id}, opts \\ []) do
    query = from message in Message, where: message.board_id == ^board_id
    limit = page_limit(Keyword.get(opts, :limit, @default_limit))

    case {cursor(Keyword.get(opts, :before_id)), after_cursor(Keyword.get(opts, :after_id))} do
      {:none, :none} ->
        newest_page(query, limit)

      {{:ok, id}, :none} ->
        query |> where([message], message.id < ^id) |> newest_page(limit)

      {:none, {:ok, id}} ->
        query
        |> where([message], message.id > ^id)
        |> order_by([message], asc: message.id)
        |> limit(^limit)
        |> Repo.all()

      _ ->
        []
    end
  end

  @doc "Creates a message and publishes it after its insert transaction commits."
  def create_message(%Board{} = board, attrs) do
    changeset = Message.changeset(%Message{board_id: board.id}, attrs)

    if changeset.valid? do
      result =
        Repo.transaction(fn ->
          # Allocate IDs only after acquiring this lock, so ID order also
          # reflects commit order and an after_id cursor cannot miss a post.
          Repo.one(from persisted in Board, where: persisted.id == ^board.id, lock: "FOR UPDATE") ||
            Repo.rollback(:not_found)

          client_ref = Ecto.Changeset.get_field(changeset, :client_ref)

          case Repo.get_by(Message, board_id: board.id, client_ref: client_ref) do
            %Message{} = message ->
              {message, false}

            nil ->
              case Repo.insert(changeset) do
                {:ok, message} -> {message, true}
                {:error, changeset} -> Repo.rollback(changeset)
              end
          end
        end)

      case result do
        {:ok, {message, true}} ->
          Phoenix.PubSub.broadcast(Devloom.PubSub, topic(board.id), {:message_created, message})
          {:ok, message}

        {:ok, {message, false}} ->
          {:ok, message}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  defp newest_page(query, limit) do
    query
    |> order_by([message], desc: message.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp cursor(nil), do: :none
  defp cursor(id) when is_integer(id) and id > 0 and id <= @maximum_id, do: {:ok, id}

  defp cursor(id) when is_binary(id) and byte_size(id) <= 19 do
    case Integer.parse(id) do
      {value, ""} when value > 0 and value <= @maximum_id -> {:ok, value}
      _ -> :error
    end
  end

  defp cursor(_), do: :error

  defp after_cursor(id) when id in [0, "0"], do: {:ok, 0}
  defp after_cursor(id), do: cursor(id)

  defp page_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @maximum_limit)
  defp page_limit(_), do: @default_limit

  defp topic(id), do: "boards:#{id}:chat"
end
