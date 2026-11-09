defmodule Devloom.DirectMessages do
  @moduledoc """
  Private conversations between two current members of the same workspace.

  Each operation resolves the persisted conversation and both memberships.
  Workspace locks serialize writes with membership removal, and conversation
  locks keep message IDs in commit order. Direct message notifications never
  use team-chat or workspace-wide topics.
  """
  import Ecto.Query

  alias Devloom.Accounts.{Scope, User}
  alias Devloom.DirectMessages.{Conversation, Message}
  alias Devloom.Repo
  alias Devloom.Workspaces.{Membership, Workspace}

  @default_limit 50
  @maximum_limit 200
  @maximum_id 9_223_372_036_854_775_807

  @doc "Opens the one persisted conversation for this workspace and account pair."
  def open_conversation(
        %Scope{user: %User{id: user_id}, workspace: %Workspace{id: workspace_id}},
        peer_id
      ) do
    with {:ok, peer_id} <- cast_id(peer_id),
         false <- peer_id == user_id do
      Repo.transaction(fn ->
        lock_workspace!(workspace_id)
        ensure_members!(workspace_id, user_id, peer_id)
        [one, two] = Enum.sort([user_id, peer_id])

        Repo.get_by(Conversation,
          workspace_id: workspace_id,
          participant_one_id: one,
          participant_two_id: two
        ) ||
          Repo.insert!(%Conversation{
            workspace_id: workspace_id,
            participant_one_id: one,
            participant_two_id: two
          })
      end)
    else
      true -> {:error, :invalid_participant}
      _ -> {:error, :not_found}
    end
  end

  def open_conversation(_scope, _peer_id), do: {:error, :not_found}

  @doc "Returns the other participant only while both accounts remain workspace members."
  def get_peer(scope, conversation) do
    with {:ok, conversation} <- authorized_conversation(scope, conversation) do
      peer_id =
        if conversation.participant_one_id == scope.user.id,
          do: conversation.participant_two_id,
          else: conversation.participant_one_id

      Repo.get(User, peer_id)
    else
      _ -> nil
    end
  end

  def subscribe(scope, conversation) do
    with {:ok, conversation} <- authorized_conversation(scope, conversation) do
      Phoenix.PubSub.subscribe(Devloom.PubSub, topic(conversation))
    end
  end

  @doc "Stops a previously opened subscription; this does not grant conversation access."
  def unsubscribe(%Conversation{} = conversation) do
    Phoenix.PubSub.unsubscribe(Devloom.PubSub, topic(conversation))
  end

  def unsubscribe(_conversation), do: :ok

  @doc """
  Returns a bounded chronological page that only the two participants can read.

  The latest 50 messages are returned by default. `before_id` loads the nearest
  earlier page; `after_id` loads the first newer page. `after_id: 0` starts from
  the beginning. Limits are capped at 200. Invalid cursors return an empty page.
  """
  def list_messages(scope, conversation, opts \\ []) do
    with {:ok, conversation_query} <- authorized_query(scope, conversation) do
      query =
        from message in Message,
          join: conversation in subquery(conversation_query),
          on: message.conversation_id == conversation.id,
          select: message

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
    else
      _ -> []
    end
  end

  @doc "Creates an authenticated private message and publishes it after commit."
  def create_message(
        %Scope{user: %User{id: user_id}, workspace: %Workspace{id: workspace_id}} = scope,
        conversation,
        attrs
      ) do
    result =
      Repo.transaction(fn ->
        lock_workspace!(workspace_id)

        conversation =
          case authorized_query(scope, conversation) do
            {:ok, query} -> Repo.one(query |> lock("FOR UPDATE"))
            _ -> nil
          end || Repo.rollback(:not_found)

        user = Repo.get!(User, user_id)

        changeset =
          %Message{
            conversation_id: conversation.id,
            user_id: user.id,
            sender_name: user.name
          }
          |> Message.changeset(message_attrs(attrs))

        if !changeset.valid?, do: Repo.rollback(%{changeset | action: :insert})
        client_ref = Ecto.Changeset.get_field(changeset, :client_ref)

        case Repo.get_by(Message, conversation_id: conversation.id, client_ref: client_ref) do
          %Message{user_id: ^user_id} = message ->
            {conversation, message, false}

          %Message{} ->
            Repo.rollback(:invalid_client_ref)

          nil ->
            case Repo.insert(changeset) do
              {:ok, message} -> {conversation, message, true}
              {:error, changeset} -> Repo.rollback(changeset)
            end
        end
      end)

    case result do
      {:ok, {conversation, message, true}} ->
        Phoenix.PubSub.broadcast(
          Devloom.PubSub,
          topic(conversation),
          {:direct_message_created, conversation.id, message}
        )

        {:ok, message}

      {:ok, {_conversation, message, false}} ->
        {:ok, message}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def create_message(_scope, _conversation, _attrs), do: {:error, :not_found}

  defp authorized_conversation(scope, conversation) do
    with {:ok, query} <- authorized_query(scope, conversation),
         %Conversation{} = persisted <- Repo.one(query) do
      {:ok, persisted}
    else
      _ -> {:error, :not_found}
    end
  end

  defp authorized_query(
         %Scope{user: %User{id: user_id}, workspace: %Workspace{id: workspace_id}},
         conversation
       ) do
    with {:ok, id} <- conversation_id(conversation) do
      query =
        from conversation in Conversation,
          join: one in Membership,
          on:
            one.workspace_id == conversation.workspace_id and
              one.user_id == conversation.participant_one_id,
          join: two in Membership,
          on:
            two.workspace_id == conversation.workspace_id and
              two.user_id == conversation.participant_two_id,
          where: conversation.id == ^id and conversation.workspace_id == ^workspace_id,
          where:
            conversation.participant_one_id == ^user_id or
              conversation.participant_two_id == ^user_id,
          select: conversation

      {:ok, query}
    end
  end

  defp authorized_query(_scope, _conversation), do: {:error, :not_found}

  defp ensure_members!(workspace_id, one, two) do
    count =
      Repo.aggregate(
        from(membership in Membership,
          where: membership.workspace_id == ^workspace_id and membership.user_id in ^[one, two]
        ),
        :count
      )

    if count != 2, do: Repo.rollback(:not_found)
  end

  defp lock_workspace!(id) do
    Repo.one(from workspace in Workspace, where: workspace.id == ^id, lock: "FOR UPDATE") ||
      Repo.rollback(:not_found)
  end

  defp message_attrs(attrs) when is_map(attrs) do
    %{
      "body" => Map.get(attrs, "body", Map.get(attrs, :body)),
      "client_ref" => Map.get(attrs, "client_ref", Map.get(attrs, :client_ref))
    }
  end

  defp message_attrs(_attrs), do: %{}
  defp conversation_id(%Conversation{id: id}), do: cast_id(id)
  defp conversation_id(id), do: cast_id(id)

  defp newest_page(query, limit) do
    query
    |> order_by([message], desc: message.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp cast_id(id) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} when is_integer(id) and id > 0 and id <= @maximum_id -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp cursor(nil), do: :none

  defp cursor(id) do
    case cast_id(id) do
      {:ok, id} -> {:ok, id}
      _ -> :error
    end
  end

  defp after_cursor(id) when id in [0, "0"], do: {:ok, 0}
  defp after_cursor(id), do: cursor(id)
  defp page_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @maximum_limit)
  defp page_limit(_limit), do: @default_limit
  defp topic(conversation), do: "workspace:#{conversation.workspace_id}:direct:#{conversation.id}"
end
