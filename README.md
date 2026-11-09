# Devloom

Devloom is the working name for a shared developer workspace: one place to organize work and preserve the discussions and knowledge around it.

Devloom uses Phoenix, LiveView, and PostgreSQL for accounts, separate team workspaces, Kanban boards, and persistent team chat.

## Accounts and workspaces

Open [http://localhost:4000](http://localhost:4000). Create an account with your name, email, and password, or sign in to an existing account. Passwords require at least 12 characters and are hashed with bcrypt. Sessions use expiring, revocable database tokens; signing out ends that browser session and disconnects its open live views.

After signing in, **Your workspaces** lists only workspaces you belong to. Create a workspace for each team or project, and use the workspace switcher to move between them. Each workspace has its own members, board, work items, workflow configuration, and conversation. Creating a workspace makes you its owner and starts it with an empty board and chat.

**Upgrading the existing shared board:** the migration preserves existing boards, tasks, columns, and messages in a Devloom workspace. The first account created through the sign-up page becomes its owner. Later accounts access it by invitation. Existing guest messages keep their original display names; new messages record the signed-in account. The migration does not erase or populate work items.

### Invite and manage members

Open a workspace and select **Members & invites**. Owners can enter an email address to create an invitation link, copy it, and share it with the intended teammate. The teammate signs in or creates an account using that email and opens the link to join. Invitations expire after seven days, can be used once, and can be revoked. Creating a replacement invitation invalidates the previous link for that email.

Members can use the workspace board and chat and see the team directory. Owners can invite or remove members. Removing someone ends their access to that workspace, including already-open board and chat sessions; their existing work and messages remain. Owners cannot remove themselves.

Invitation links are shown once to the owner and only token hashes are stored in the database. Email delivery is not configured: share the generated links yourself. Email verification, password recovery, workspace deletion, and ownership transfer are not implemented in this increment.

## Use the Kanban board

New boards start with five workflow columns: **Backlog → To do → In progress → In review → Done**. Select **Configure board** to adapt this workflow to your team.

- **Create:** select **New work item**, or use a column's **+** button to prefill its status.
- **Read and edit:** select a card title to open its details panel. Work items support a title, description, type (feature/task/bug), priority, status, story points, comma-separated labels, and an optional assignee name.
- **Move:** drag a card to another column or between cards to reorder it. On touch screens, drag the three-dot handle. Alternatively, focus that handle, press Space, choose a position with the arrow keys, and press Space again to save. Status can also be changed in the editor.
- **Delete:** select **Delete** in the details panel and confirm the inline prompt.
- **Find:** search titles and descriptions or filter by type, priority, and unassigned work. Switch between **Board** and **Work items** to inspect the same work in a compact list.
- **Explore:** an empty board offers **Try an example board**. Examples are added only on request, only to an empty board, and remain ordinary editable work items. Refreshing never recreates deleted items.

### Configure the workflow

Select **Configure board** beside **New work item** to add columns, edit their names and descriptions, choose a color, or drag their handles to reorder the workflow. Handles support mouse and touch. With a keyboard, focus a handle, press Space, use the up/down arrows, and press Enter to drop or Escape to cancel. Column names must be unique within the board. Mark a column as complete when its work should contribute to the progress indicator; more than one column can count as complete.

To remove a column, select its trash button and confirm. A column with work items requires a destination: its cards move to the end of the selected column in their existing order. Deleting a column never deletes its work items, and the final column cannot be removed. Renaming keeps cards in place. Configuration survives reloads and synchronizes with other open sessions, including work-item status menus and drag targets.

Existing boards keep their workflow and cards when the migration runs. Removed default columns are never recreated on refresh. Column configuration is available to members of that workspace.

Changes persist in PostgreSQL. Open the same board in two browser tabs to see creates, edits, deletes, and moves synchronize without refreshing. Phoenix PubSub publishes changes after transactions commit. Board-level database locks keep simultaneous moves ordered, and version checks prevent an older editor from overwriting a newer change. A stale editor keeps its draft and offers to load the latest version.

All board reads, edits, and live subscriptions resolve the signed-in user's current workspace membership. Assignees remain editable text names. The development server is published only on localhost by default; teammates on other computers need a shared deployment.

## Use Team chat

Open a workspace and select **Chat**, then **Team chat** for the shared conversation. On phones, use the navigation below the top bar to switch between workspaces, the board, chat, and members.

- Write a message and select **Send message**. Your signed-in account supplies the author name. Enter adds a new line; Ctrl+Enter or Cmd+Enter sends.
- Messages persist in PostgreSQL and appear in other connected chat tabs without refreshing. Refreshing loads the latest conversation.
- The latest 50 messages load first. Use **Load older messages** to read previous pages, and return to the latest messages when finished. The visible history is bounded to keep long conversations responsive.
- Your browser temporarily keeps your unsent draft separately for each account and workspace. Validation errors preserve the draft so you can correct it. Reconnecting restores the conversation; repeated sends of the same pending message do not create duplicate records.

Each workspace has one team conversation accessible only to its members. Your messages appear on the right and other members’ messages on the left.

### Private conversations and member status

Choose another workspace member under **Direct messages** to open a private one-on-one conversation. On phones, select **People** above the conversation to open the member list. You can also use the message button beside a person on **Members & invites**.

Only the two participants can read or send messages in that conversation; a workspace owner who is not a participant has no access. Private history is stored separately from team chat. Opening the same pair from either account returns the same conversation, and the same people in a different workspace have a separate history. Switching conversations keeps drafts separate.

Online/offline indicators update automatically in the chat directory, conversation header, and member list. **Online** means at least one live tab is connected to that workspace, including its board or members page. Multiple tabs count as one person; the status becomes **Offline** after the last connection closes or disconnects. An offline member can still receive saved private messages and read them when they return.

Both participants must remain members of the workspace. Removing a member ends their private-chat access and closes the conversation for the other participant. History is retained if that person later rejoins. Attachments, message editing, deletion, and additional group channels are not implemented.

After pulling this change into an already running development stack, install the new password-hashing dependency, apply migrations, and build the browser assets:

```sh
docker compose exec web mix deps.get
docker compose exec web mix ecto.migrate
docker compose exec web mix assets.build
docker compose restart web
```

Normal application startup also applies pending migrations automatically.

## Start the application

Install and start [Docker Desktop](https://www.docker.com/products/docker-desktop/). Use Linux containers. Windows users should use Docker Desktop's WSL 2 backend; macOS users can use the Docker Desktop build for Apple Silicon or Intel as appropriate. Elixir, Erlang, PostgreSQL, and Node.js do not need to be installed on the host.

Open Terminal on macOS or PowerShell on Windows, change into this project folder, and run:

```sh
docker compose up --build -d --wait
```

The first build downloads dependencies and compiles the application, so it takes longer than later starts. Development database creation and migrations run automatically before Phoenix starts.

Open [http://localhost:4000](http://localhost:4000). Check service state with:

```sh
docker compose ps
```

To follow the application logs:

```sh
docker compose logs -f web
```

Press Ctrl+C to stop following logs; the containers keep running. This setup is intended for both macOS and Windows, but a configuration intended for Windows is not a claim that it has been tested on a Windows machine.

## Optional configuration

The default configuration starts without a `.env` file. To customize it, copy the example first.

macOS Terminal:

```sh
cp .env.example .env
```

Windows PowerShell:

```powershell
Copy-Item .env.example .env
```

Edit `.env` in your editor. For example, use `APP_PORT=4001` if port 4000 is already occupied. Apply changes with:

```sh
docker compose up -d --wait
```

The application will then be available at [http://localhost:4001](http://localhost:4001). The published application port is bound to the local machine.

The example also lists the local database settings. These defaults are for development. PostgreSQL is reachable by the `web` container through the `db` service name; its port is not published to the host. PostgreSQL initialization settings apply when the database volume is first created. Changing a password in `.env` does not change the password already stored in an existing PostgreSQL database.

Keep `.env` out of Git. Each teammate has their own configuration and local database.

## Development workflow

The repository is mounted at `/app` in the `web` container. Edit source files with your usual host editor. Phoenix reload detection and Tailwind use polling for Docker Desktop filesystem compatibility; changes can take a moment to appear. Changes to configuration or application startup code require a restart:

```sh
docker compose restart web
```

Run developer commands inside the container so everyone uses the same toolchain:

| Task | Command |
| --- | --- |
| Run the test suite | `docker compose exec web mix test` |
| Check formatting | `docker compose exec web mix format --check-formatted` |
| Format source | `docker compose exec web mix format` |
| Apply migrations | `docker compose exec web mix ecto.migrate` |
| Inspect a generator | `docker compose exec web mix help phx.gen.live` |

The test alias prepares the test database before running tests. It uses a separate database from development.

Run Phoenix generators through `docker compose exec web mix phx.gen.<generator> ...`, replacing the generator name and arguments with the command you need. For example, `phx.gen.live` creates a LiveView resource. Generated source and migrations are written to the repository on your host, so you can review and commit them. After a generator introduces database changes, run `docker compose exec web mix ecto.migrate`; restart `web` when the change affects configuration or startup.

After adding or changing dependencies in `mix.exs`, update the lockfile inside the container and rebuild:

```sh
docker compose exec web mix deps.get
docker compose up --build -d --wait web
```

Commit `mix.exs` and `mix.lock` together. Normal server startup uses `mix deps.get --check-locked`, so it will report an out-of-date lockfile instead of silently changing the team's resolved dependencies.

## Containers and persistence

The development stack uses:

- **Phoenix 1.8.16 and LiveView**, with Elixir 1.19.7 / Erlang OTP 28.
- **Ecto and PostgreSQL 17** for persistence.
- **Tailwind CSS and esbuild** for frontend assets.
- **Docker Compose** services named `web` and `db`.

Compose uses project name `devloom`. The source bind mount is `.:/app`. Named volumes keep compiled artifacts and database files inside Docker:

| Volume | Contents |
| --- | --- |
| `devloom_deps` | Elixir dependency sources |
| `devloom_build` | Compiled code and downloaded asset tools |
| `devloom_pgdata` | PostgreSQL data |

Stop and remove the containers with:

```sh
docker compose down
```

The named volumes remain, including the database. Start again with `docker compose up -d --wait`.

**`docker compose down -v` deletes the stack's named volumes, including all local database data.** It is not needed for a normal stop or rebuild.

After changing Elixir/Erlang versions, a stale build cache may need to be cleared. To remove only dependency and build caches while keeping the database:

```sh
docker compose down
docker volume rm devloom_deps devloom_build
docker compose up --build -d --wait
```

These names assume the default Compose project name. If you explicitly changed that name, use its corresponding cache volume names. Named volumes are populated from an image only when first created; rebuilding the image does not replace an existing volume.

## Health and troubleshooting

Open [http://localhost:4000/health](http://localhost:4000/health), adjusting the port if configured differently. The endpoint checks PostgreSQL with a SQL query. It returns HTTP 200 when the application can reach the database and HTTP 503 when the database check fails. Compose uses this endpoint to determine application readiness.

- If Docker cannot connect to its daemon, start Docker Desktop and wait until it is ready. On Windows, confirm it is using Linux containers.
- If startup fails, inspect `docker compose logs web db` for the failing command or connection error.
- If the host port is occupied, set `APP_PORT` in `.env` and run `docker compose up -d --wait`.
- If a configuration edit does not appear, run `docker compose restart web`.
- If a dependency change causes a lockfile error and `web` has stopped, run `docker compose run --rm --no-deps web mix deps.get`, then `docker compose up --build -d --wait web`. The one-off command works without a running web service. Commit the updated lockfile.

## Foundation verification

Validated on an Apple Silicon Mac using Docker Desktop on 7 November 2026:

- Docker image build and healthy startup from fresh application volumes.
- `mix precommit`: compilation with warnings treated as errors, formatting, and six passing tests.
- A generator writes a migration to the host repository; the next startup applies it automatically.
- Database records survive normal container removal and recreation.
- Database readiness returns HTTP 503 during an outage and HTTP 200 after recovery.
- Host source edits recompile, the browser connection button works, and desktop and phone layouts fit their viewports.

Windows and native AMD64 execution have not been tested on physical machines. The pinned base image manifests support ARM64 and AMD64; Windows runs the same Linux-container setup through Docker Desktop.

## References

[Phoenix installation](https://hexdocs.pm/phoenix/installation.html), [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html), [Docker Desktop on macOS](https://docs.docker.com/desktop/setup/install/mac-install/), [Docker Desktop on Windows](https://docs.docker.com/desktop/setup/install/windows-install/), and [Compose readiness and startup order](https://docs.docker.com/compose/how-tos/startup-order/).
