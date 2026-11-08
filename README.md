# Devloom

Devloom is the working name for a shared developer workspace: one place to organize work and preserve the discussions and knowledge around it.

This is **increment 1: the shared Kanban board**. It builds on the Phoenix, LiveView, PostgreSQL, and health-check foundation with a DevOps-inspired project shell and a persistent, live team board. The feature modules are being built one at a time:

1. Kanban board — implemented with work item CRUD and live collaboration
2. Work items and ticket details
3. Project documentation and the team handbook
4. Chat
5. Meetings

Documentation, chat, meetings, and richer ticket workflows remain planned. Authentication, invitations, membership permissions, and server hosting are future work. Run this increment locally for development.

## Use the Kanban board

New boards start with five workflow columns: **Backlog → To do → In progress → In review → Done**. Select **Configure board** to adapt this workflow to your team.

- **Create:** select **New work item**, or use a column's **+** button to prefill its status.
- **Read and edit:** select a card title to open its details panel. Work items support a title, description, type (feature/task/bug), priority, status, story points, comma-separated labels, and an optional assignee name.
- **Move:** drag a card to another column or between cards to reorder it. On touch screens, drag the three-dot handle. Alternatively, focus that handle, press Space, choose a position with the arrow keys, and press Space again to save. Status can also be changed in the editor.
- **Delete:** select **Delete** in the details panel and confirm the inline prompt.
- **Find:** search titles and descriptions or filter by type, priority, and unassigned work. Switch between **Board** and **Work items** to inspect the same work in a compact list.
- **Explore:** an empty board offers **Try an example board**. Examples are added only on request, only to an empty board, and remain ordinary editable work items. Refreshing never recreates deleted items.

### Configure the workflow

Select **Configure board** beside **New work item** to add columns, edit their names and descriptions, choose a color, or move them earlier/later in the workflow. Column names must be unique within the board. Mark a column as complete when its work should contribute to the progress indicator; more than one column can count as complete.

To remove a column, select its trash button and confirm. A column with work items requires a destination: its cards move to the end of the selected column in their existing order. Deleting a column never deletes its work items, and the final column cannot be removed. Renaming keeps cards in place. Configuration survives reloads and synchronizes with other open sessions, including work-item status menus and drag targets.

Existing boards keep their workflow and cards when the migration runs. Removed default columns are never recreated on refresh. Column configuration is available to all sessions for now; an admin permission check can be added when accounts and roles are implemented.

Changes persist in PostgreSQL. Open the same board in two browser tabs to see creates, edits, deletes, and moves synchronize without refreshing. Phoenix PubSub publishes changes after transactions commit. Board-level database locks keep simultaneous moves ordered, and version checks prevent an older editor from overwriting a newer change. A stale editor keeps its draft and offers to load the latest version.

This increment has one shared board and no sign-in. All connected sessions can edit it. Assignees are plain names, not user accounts; the context scopes work items, mutations, and subscriptions to a persisted board so a later membership layer can resolve authorized boards before calling it. The development server is published only on localhost by default; users on other computers will need a shared deployment in a later increment.

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
