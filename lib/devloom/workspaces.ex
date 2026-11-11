defmodule Devloom.Workspaces do
  @moduledoc "Workspace membership and owner-managed invitations."
  import Ecto.Query

  alias Devloom.Accounts.{Scope, User}
  alias Devloom.Boards
  alias Devloom.Repo
  alias Devloom.Workspaces.{Invitation, Membership, Workspace}

  @invitation_seconds 7 * 24 * 60 * 60

  def change_workspace(attrs \\ %{}), do: Workspace.changeset(%Workspace{}, attrs)
  def change_invitation(attrs \\ %{}), do: Invitation.changeset(%Invitation{}, attrs)
  def get_board!(scope), do: Boards.get_workspace_board!(scope)

  @doc "Registers an account and claims migrated work in one serialized transaction."
  def register_user_with_legacy_workspace(attrs) do
    Repo.transaction(fn ->
      # Lock before inserting an account: successful registration and the initial
      # workspace claim commit together, including when registrations overlap.
      Repo.one(from workspace in Workspace, where: workspace.legacy, lock: "FOR UPDATE")

      case Devloom.Accounts.register_user(attrs) do
        {:ok, user} ->
          case claim_legacy_workspace(user) do
            {:ok, _workspace} -> user
            {:error, reason} -> Repo.rollback(reason)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def list_workspaces(%Scope{user: %User{id: user_id}}) do
    rows =
      Repo.all(
        from workspace in Workspace,
          join: membership in Membership,
          on: membership.workspace_id == workspace.id,
          where: membership.user_id == ^user_id,
          order_by: [asc: workspace.inserted_at, asc: workspace.id],
          select: {workspace, membership.role}
      )

    ids = Enum.map(rows, fn {workspace, _role} -> workspace.id end)

    counts =
      Repo.all(
        from membership in Membership,
          where: membership.workspace_id in ^ids,
          group_by: membership.workspace_id,
          select: {membership.workspace_id, count(membership.id)}
      )
      |> Map.new()

    Enum.map(rows, fn {workspace, role} ->
      %{workspace | role: role, member_count: Map.get(counts, workspace.id, 0)}
    end)
  end

  def list_workspaces(_scope), do: []

  def create_workspace(%Scope{user: %User{id: user_id}}, attrs) do
    changeset =
      %Workspace{slug: "workspace-" <> Ecto.UUID.generate()}
      |> Workspace.changeset(attrs)

    Repo.transaction(fn ->
      workspace = insert_or_rollback(changeset)
      Repo.insert!(%Membership{workspace_id: workspace.id, user_id: user_id, role: :owner})
      Boards.create_workspace_board!(workspace)
      workspace
    end)
  end

  def create_workspace(_scope, _attrs), do: {:error, :forbidden}

  def fetch_scope(%Scope{user: %User{id: user_id}} = scope, id) do
    with {:ok, id} <- cast_id(id),
         {workspace, membership} <-
           Repo.one(
             from workspace in Workspace,
               join: membership in Membership,
               on: membership.workspace_id == workspace.id,
               where: workspace.id == ^id and membership.user_id == ^user_id,
               select: {workspace, membership}
           ) do
      {:ok, %{scope | workspace: workspace, membership: membership}}
    else
      _ -> {:error, :not_found}
    end
  end

  def fetch_scope(_scope, _id), do: {:error, :not_found}

  def authorized_scope?(%Scope{workspace: %Workspace{id: id}} = scope),
    do: match?({:ok, _}, fetch_scope(scope, id))

  def authorized_scope?(_scope), do: false

  def owner?(%Scope{workspace: %Workspace{id: id}} = scope) do
    case fetch_scope(scope, id) do
      {:ok, %Scope{membership: %Membership{role: :owner}}} -> true
      _ -> false
    end
  end

  def owner?(_scope), do: false

  @doc "Whether the account currently has workspace deletion privileges."
  def can_delete_workspace?(%Scope{workspace: %Workspace{id: id}} = scope) do
    case fetch_scope(scope, id) do
      {:ok, %Scope{membership: %Membership{role: role}}} when role in [:owner, :admin] -> true
      _ -> false
    end
  end

  def can_delete_workspace?(_scope), do: false

  @doc "Permanently deletes a workspace and its related records for a current owner or admin."
  def delete_workspace(%Scope{user: %User{}, workspace: %Workspace{id: id}} = scope) do
    result =
      Repo.transaction(fn ->
        workspace = lock_workspace!(id)

        case fetch_scope(scope, id) do
          {:ok, %Scope{membership: %Membership{role: role}}} when role in [:owner, :admin] ->
            # Database foreign keys cascade through boards, work items, team and
            # direct chats, invitations and memberships within this transaction.
            Repo.delete!(workspace)

          _ ->
            Repo.rollback(:forbidden)
        end
      end)

    broadcast_membership(result)
  end

  def delete_workspace(_scope), do: {:error, :forbidden}

  def subscribe(%Scope{workspace: %Workspace{id: id}} = scope) do
    if authorized_scope?(scope) do
      Phoenix.PubSub.subscribe(Devloom.PubSub, topic(id))
    else
      {:error, :forbidden}
    end
  end

  def subscribe(_scope), do: {:error, :forbidden}

  def list_members(%Scope{workspace: %Workspace{id: id}} = scope) do
    if authorized_scope?(scope) do
      Repo.all(
        from membership in Membership,
          where: membership.workspace_id == ^id,
          order_by: [asc: membership.inserted_at, asc: membership.id],
          preload: [:user]
      )
    else
      []
    end
  end

  def list_members(_scope), do: []

  def list_pending_invitations(%Scope{workspace: %Workspace{id: id}} = scope) do
    if owner?(scope) do
      now = now()

      Repo.all(
        from invitation in Invitation,
          where:
            invitation.workspace_id == ^id and is_nil(invitation.accepted_at) and
              is_nil(invitation.revoked_at) and invitation.expires_at > ^now,
          order_by: [desc: invitation.id],
          preload: [:workspace]
      )
    else
      []
    end
  end

  def list_pending_invitations(_scope), do: []

  def create_invitation(scope, attrs) do
    raw_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    result =
      owner_transaction(scope, fn workspace ->
        changeset =
          %Invitation{
            workspace_id: workspace.id,
            inviter_id: scope.user.id,
            token_hash: token_hash(raw_token),
            expires_at: DateTime.add(now(), @invitation_seconds, :second)
          }
          |> Invitation.changeset(attrs)

        if !changeset.valid?, do: Repo.rollback(%{changeset | action: :insert})
        email = Ecto.Changeset.get_field(changeset, :email)

        if Repo.exists?(
             from membership in Membership,
               join: user in User,
               on: user.id == membership.user_id,
               where: membership.workspace_id == ^workspace.id and user.email == ^email
           ),
           do: Repo.rollback(:already_member)

        Repo.update_all(
          from(invitation in Invitation,
            where:
              invitation.workspace_id == ^workspace.id and invitation.email == ^email and
                is_nil(invitation.accepted_at) and is_nil(invitation.revoked_at)
          ),
          set: [revoked_at: now(), updated_at: now()]
        )

        insert_or_rollback(changeset)
      end)

    case result do
      {:ok, invitation} -> {:ok, Repo.preload(invitation, :workspace), raw_token}
      error -> error
    end
  end

  def get_invitation(raw_token) do
    with {:ok, hash} <- validated_token_hash(raw_token),
         %Invitation{} = invitation <- Repo.one(active_invitation_query(hash)) do
      {:ok, Repo.preload(invitation, :workspace)}
    else
      _ -> {:error, :invalid_invitation}
    end
  end

  def accept_invitation(%Scope{user: %User{id: user_id}}, raw_token) do
    with {:ok, hash} <- validated_token_hash(raw_token),
         %Invitation{} = candidate <- Repo.one(active_invitation_query(hash)) do
      result =
        Repo.transaction(fn ->
          workspace = lock_workspace!(candidate.workspace_id)

          invitation =
            Repo.one(active_invitation_query(hash) |> lock("FOR UPDATE")) ||
              Repo.rollback(:invalid_invitation)

          user = Repo.get(User, user_id) || Repo.rollback(:forbidden)
          if user.email != invitation.email, do: Repo.rollback(:wrong_email)

          Repo.insert!(%Membership{workspace_id: workspace.id, user_id: user.id, role: :member},
            on_conflict: :nothing,
            conflict_target: [:workspace_id, :user_id]
          )

          invitation
          |> Ecto.Changeset.change(accepted_at: now(), accepted_by_id: user.id)
          |> Repo.update!()

          workspace
        end)

      broadcast_membership(result)
    else
      _ -> {:error, :invalid_invitation}
    end
  end

  def accept_invitation(_scope, _raw_token), do: {:error, :forbidden}

  def revoke_invitation(scope, id) do
    owner_transaction(scope, fn workspace ->
      with {:ok, id} <- cast_id(id),
           %Invitation{} = invitation <-
             Repo.get_by(Invitation, id: id, workspace_id: workspace.id),
           true <- is_nil(invitation.accepted_at) and is_nil(invitation.revoked_at) do
        invitation |> Ecto.Changeset.change(revoked_at: now()) |> Repo.update!()
      else
        _ -> Repo.rollback(:not_found)
      end
    end)
  end

  def remove_member(scope, id) do
    result =
      owner_transaction(scope, fn workspace ->
        with {:ok, id} <- cast_id(id),
             %Membership{} = membership <-
               Repo.get_by(Membership, id: id, workspace_id: workspace.id) do
          if membership.role == :owner, do: Repo.rollback(:owner_required)
          user = Repo.get!(User, membership.user_id)

          Repo.update_all(
            from(invitation in Invitation,
              where:
                invitation.workspace_id == ^workspace.id and invitation.email == ^user.email and
                  is_nil(invitation.accepted_at) and is_nil(invitation.revoked_at)
            ),
            set: [revoked_at: now(), updated_at: now()]
          )

          Repo.delete!(membership)
          workspace
        else
          _ -> Repo.rollback(:not_found)
        end
      end)

    broadcast_membership(result)
  end

  @doc "Claims the migrated shared workspace exactly once, for the first registered account."
  def claim_legacy_workspace(%User{id: user_id}) do
    Repo.transaction(fn ->
      case Repo.one(from workspace in Workspace, where: workspace.legacy, lock: "FOR UPDATE") do
        nil ->
          nil

        %Workspace{legacy_claimed: false} = workspace ->
          Repo.insert!(%Membership{workspace_id: workspace.id, user_id: user_id, role: :owner},
            on_conflict: :nothing,
            conflict_target: [:workspace_id, :user_id]
          )

          workspace |> Ecto.Changeset.change(legacy_claimed: true) |> Repo.update!()

        workspace ->
          if Repo.exists?(
               from membership in Membership,
                 where:
                   membership.workspace_id == ^workspace.id and membership.user_id == ^user_id
             ),
             do: workspace,
             else: nil
      end
    end)
  end

  @doc false
  def get_legacy_workspace! do
    Repo.insert!(%Workspace{name: "Devloom", slug: "legacy-devloom", legacy: true},
      on_conflict: :nothing,
      conflict_target: :slug
    )

    Repo.get_by!(Workspace, slug: "legacy-devloom")
  end

  defp owner_transaction(%Scope{user: %User{}, workspace: %Workspace{id: id}} = scope, fun) do
    Repo.transaction(fn ->
      workspace = lock_workspace!(id)

      case fetch_scope(scope, id) do
        {:ok, %Scope{membership: %Membership{role: :owner}}} -> fun.(workspace)
        _ -> Repo.rollback(:forbidden)
      end
    end)
  end

  defp owner_transaction(_scope, _fun), do: {:error, :forbidden}

  defp lock_workspace!(id) do
    Repo.one(from workspace in Workspace, where: workspace.id == ^id, lock: "FOR UPDATE") ||
      Repo.rollback(:not_found)
  end

  defp active_invitation_query(hash) do
    now = now()

    from invitation in Invitation,
      where:
        invitation.token_hash == ^hash and is_nil(invitation.accepted_at) and
          is_nil(invitation.revoked_at) and invitation.expires_at > ^now
  end

  defp validated_token_hash(raw) when is_binary(raw) and byte_size(raw) == 43 do
    case Base.url_decode64(raw, padding: false) do
      {:ok, bytes} when byte_size(bytes) == 32 -> {:ok, token_hash(raw)}
      _ -> :error
    end
  end

  defp validated_token_hash(_raw), do: :error
  defp token_hash(raw), do: :crypto.hash(:sha256, raw)
  defp now, do: DateTime.utc_now(:second)

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp cast_id(id) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 -> {:ok, id}
      _ -> :error
    end
  end

  defp broadcast_membership({:ok, %Workspace{id: id}} = result) do
    Phoenix.PubSub.broadcast(Devloom.PubSub, topic(id), {:workspace_access_changed, id})
    result
  end

  defp broadcast_membership(error), do: error
  defp topic(id), do: "workspace:#{id}:membership"
end
