defmodule DevloomWeb.WhiteboardLive do
  use DevloomWeb, :live_view

  alias Devloom.Whiteboards

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    whiteboard = Whiteboards.get_whiteboard!(scope)
    if connected?(socket), do: Whiteboards.subscribe(scope)

    {:ok,
     assign(socket,
       page_title: "Whiteboard",
       whiteboard: whiteboard,
       name_form: to_form(%{"name" => whiteboard.name}, as: :whiteboard)
     )}
  end

  @impl true
  def handle_event("sync_scene", %{"board_id" => id}, socket) do
    if id in [socket.assigns.whiteboard.id, Integer.to_string(socket.assigns.whiteboard.id)] do
      board = Whiteboards.get_whiteboard!(socket.assigns.current_scope)

      {:reply, Map.put(scene_payload(board), :status, "ok"), assign(socket, whiteboard: board)}
    else
      {:reply, %{status: "error", message: "This whiteboard is not available."}, socket}
    end
  end

  def handle_event("sync_scene", _params, socket) do
    {:reply, %{status: "error", message: "This whiteboard is not available."}, socket}
  end

  def handle_event(
        "save_scene",
        %{"board_id" => id, "scene" => scene, "revision" => revision},
        socket
      ) do
    if id in [socket.assigns.whiteboard.id, Integer.to_string(socket.assigns.whiteboard.id)] do
      case Whiteboards.save_scene(socket.assigns.current_scope, id, scene, revision) do
        {:ok, board} ->
          {:reply, %{status: "ok", revision: board.revision}, assign(socket, whiteboard: board)}

        {:error, :stale} ->
          board = Whiteboards.get_whiteboard!(socket.assigns.current_scope)

          {:reply, %{status: "conflict", scene: board.scene, revision: board.revision},
           assign(socket, whiteboard: board)}

        {:error, _reason} ->
          {:reply,
           %{status: "error", message: "Unable to save. Your draft is kept here. Try again."},
           socket}
      end
    else
      {:reply, %{status: "error", message: "This whiteboard is not available."}, socket}
    end
  end

  def handle_event("save_scene", _params, socket) do
    {:reply, %{status: "error", message: "This drawing could not be saved."}, socket}
  end

  def handle_event("rename_whiteboard", %{"whiteboard" => %{"name" => name}}, socket) do
    case Whiteboards.rename_whiteboard(
           socket.assigns.current_scope,
           socket.assigns.whiteboard.id,
           name
         ) do
      {:ok, board} ->
        {:noreply,
         socket
         |> assign(
           whiteboard: board,
           name_form: to_form(%{"name" => board.name}, as: :whiteboard)
         )
         |> push_event("whiteboard:updated", scene_payload(board))}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Use a whiteboard name between 1 and 100 characters.")}
    end
  end

  @impl true
  def handle_info({:whiteboard_updated, board}, socket) do
    if board.id == socket.assigns.whiteboard.id and
         board.revision > socket.assigns.whiteboard.revision do
      {:noreply,
       socket
       |> assign(
         whiteboard: board,
         name_form: to_form(%{"name" => board.name}, as: :whiteboard)
       )
       |> push_event("whiteboard:updated", scene_payload(board))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:workspace_access_changed, _id}, socket), do: {:noreply, socket}

  defp scene_payload(board), do: %{scene: board.scene, revision: board.revision}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_view="whiteboard">
      <section id="whiteboard-page" class="wb-page" aria-labelledby="whiteboard-title">
        <header class="wb-heading">
          <div class="wb-heading-main">
            <div class="page-eyebrow">
              <span class="eyebrow-line"></span>ROOM FOR YOUR NEXT BIG IDEA
            </div>
            <details class="wb-rename">
              <summary title="Rename whiteboard">
                <h1 id="whiteboard-title">{@whiteboard.name}</h1>
                <.icon name="hero-pencil" class="size-3.5" />
              </summary>
              <.form
                for={@name_form}
                id="whiteboard-name-form"
                phx-submit="rename_whiteboard"
                class="wb-name-form"
              >
                <.input
                  field={@name_form[:name]}
                  label="Whiteboard name"
                  maxlength="100"
                  required
                  class="wb-name-input"
                />
                <button type="submit" class="button button-primary">Save name</button>
              </.form>
            </details>
            <p class="page-intro">Sketch it out. Connect the dots. Build something together.</p>
          </div>
          <span class="wb-shared-badge"><.icon name="hero-user-group" class="size-4" /><span>Shared with workspace</span></span>
        </header>

        <div
          id="whiteboard-canvas-hook"
          phx-hook="Whiteboard"
          phx-update="ignore"
          class="wb-editor"
          data-board-id={@whiteboard.id}
          data-workspace-id={@workspace.id}
          data-user-id={@current_scope.user.id}
          data-scene={Jason.encode!(@whiteboard.scene)}
          data-revision={@whiteboard.revision}
          tabindex="0"
          aria-label="Shared whiteboard editor"
        >
          <div class="wb-stage">
            <svg
              id="whiteboard-svg"
              class="wb-svg"
              xmlns="http://www.w3.org/2000/svg"
              aria-label="Drawing canvas. Choose a tool, then drag to draw."
              role="img"
            >
              <g data-layer="elements"></g>
              <g data-layer="selection"></g>
            </svg>

            <div class="wb-toolbar" role="toolbar" aria-label="Drawing tools">
              <.tool tool="hand" icon="hero-hand-raised" label="Hand" shortcut="H" />
              <span class="wb-toolbar-divider"></span>
              <.tool tool="select" icon="hero-cursor-arrow-rays" label="Select" shortcut="V" selected />
              <.tool tool="rectangle" icon="hero-stop" label="Rectangle" shortcut="R" />
              <.tool tool="diamond" icon="hero-square-2-stack" label="Diamond" shortcut="D" />
              <.tool tool="ellipse" icon="hero-minus-circle" label="Ellipse" shortcut="O" />
              <.tool tool="arrow" icon="hero-arrow-up-right" label="Arrow" shortcut="A" />
              <.tool tool="line" icon="hero-minus" label="Line" shortcut="L" />
              <.tool tool="freedraw" icon="hero-pencil" label="Draw" shortcut="P" />
              <.tool tool="text" icon="hero-language" label="Text" shortcut="T" />
              <.tool tool="note" icon="hero-document-text" label="Sticky note" shortcut="N" />
              <span class="wb-toolbar-divider"></span>
              <.tool tool="eraser" icon="hero-backspace" label="Eraser" shortcut="E" />
            </div>

            <details class="wb-properties" open>
              <summary>
                <.icon name="hero-adjustments-horizontal" class="size-4" />Style<span data-whiteboard-selection>Drawing settings</span>
              </summary>
              <div class="wb-properties-body">
                <fieldset>
                  <legend>Stroke</legend>
                  <div class="wb-swatches">
                    <.swatch
                      :for={
                        {color, label} <- [
                          {"#263449", "Ink"},
                          {"#e05a67", "Rose"},
                          {"#2d9b78", "Green"},
                          {"#377be8", "Blue"},
                          {"#e5a12c", "Amber"}
                        ]
                      }
                      color={color}
                      label={label}
                      style="stroke"
                    />
                    <label class="wb-custom-color" title="Custom stroke color"><input
                      type="color"
                      value="#263449"
                      data-style="stroke"
                      aria-label="Custom stroke color"
                    /></label>
                  </div>
                </fieldset>
                <fieldset>
                  <legend>Background</legend>
                  <div class="wb-swatches">
                    <.swatch
                      :for={
                        {color, label} <- [
                          {"transparent", "Transparent"},
                          {"#ffe0e5", "Light rose"},
                          {"#d5f3e5", "Light green"},
                          {"#dceaff", "Light blue"},
                          {"#fff0b8", "Light amber"}
                        ]
                      }
                      color={color}
                      label={label}
                      style="fill"
                    />
                    <label class="wb-custom-color" title="Custom background color"><input
                      type="color"
                      value="#ffffff"
                      data-style="fill"
                      aria-label="Custom background color"
                    /></label>
                  </div>
                </fieldset>
                <fieldset>
                  <legend>Stroke width</legend>
                  <div class="wb-option-row">
                    <button
                      :for={{width, label} <- [{1, "Thin"}, {2, "Medium"}, {4, "Thick"}]}
                      type="button"
                      data-style="strokeWidth"
                      data-value={width}
                      title={label}
                      aria-label={label}
                      aria-pressed={to_string(width == 2)}
                    ><span class="wb-stroke-sample" style={"height: #{width}px"}></span></button>
                  </div>
                </fieldset>
                <fieldset>
                  <legend>Stroke style</legend>
                  <div class="wb-option-row">
                    <button
                      :for={
                        {style, label} <- [
                          {"solid", "Solid"},
                          {"dashed", "Dashed"},
                          {"dotted", "Dotted"}
                        ]
                      }
                      type="button"
                      data-style="strokeStyle"
                      data-value={style}
                      title={label}
                      aria-label={label}
                      aria-pressed={to_string(style == "solid")}
                    ><span
                      class="wb-dash-sample"
                      style={"border-top-style: #{if style == "solid", do: "solid", else: style}"}
                    ></span></button>
                  </div>
                </fieldset>
                <fieldset>
                  <legend>Drawing style</legend>
                  <div class="wb-option-row wb-word-options">
                    <button
                      :for={{value, label} <- [{0, "Clean"}, {1, "Sketch"}, {2, "Loose"}]}
                      type="button"
                      data-style="roughness"
                      data-value={value}
                      aria-pressed={to_string(value == 1)}
                    >{label}</button>
                  </div>
                </fieldset>
                <fieldset>
                  <legend>Edges</legend>
                  <div class="wb-option-row wb-word-options">
                    <button
                      type="button"
                      data-style="roundness"
                      data-value="false"
                      aria-pressed="false"
                    >Sharp</button>
                    <button type="button" data-style="roundness" data-value="true" aria-pressed="true">Round</button>
                  </div>
                </fieldset>
                <fieldset>
                  <legend>Opacity <output data-whiteboard-opacity>100%</output></legend>
                  <input
                    type="range"
                    min="0"
                    max="100"
                    step="5"
                    value="100"
                    data-style="opacity"
                    aria-label="Opacity"
                  />
                </fieldset>
                <div class="wb-selection-actions">
                  <button
                    type="button"
                    data-action="duplicate"
                    title="Duplicate selection (Ctrl/⌘ D)"
                  ><.icon name="hero-square-2-stack" class="size-3.5" />Duplicate</button>
                  <button type="button" data-action="delete" title="Delete selection"><.icon
                    name="hero-trash"
                    class="size-3.5"
                  />Delete</button>
                </div>
              </div>
            </details>

            <div class="wb-empty" data-whiteboard-empty>
              <div class="wb-empty-sketch" aria-hidden="true">
                <span class="wb-sketch-box"></span><span class="wb-sketch-connector">↗</span><span class="wb-sketch-note">what if…</span>
              </div>
              <h2>Every great idea starts somewhere.</h2>
              <p>
                A quick sketch, a messy brainstorm, your next big plan.<br />This space is yours and your team's.
              </p>
              <span class="wb-empty-tip">Pick a tool above and let your ideas take shape</span>
            </div>

            <div class="wb-conflict" data-whiteboard-conflict hidden role="alert">
              <.icon name="hero-exclamation-triangle" class="size-5" />
              <div>
                <strong>The board changed while you were drawing.</strong><p>
                  Your draft is safe. Load the latest board, or replace it with your draft.
                </p>
              </div>
              <button type="button" data-action="load-latest">Load latest</button>
              <button type="button" data-action="keep-local">Use my draft</button>
            </div>

            <div class="wb-bottom-left">
              <div class="wb-control-group" aria-label="Canvas zoom">
                <button type="button" data-action="zoom-out" title="Zoom out" aria-label="Zoom out"><.icon
                  name="hero-minus"
                  class="size-4"
                /></button>
                <button
                  type="button"
                  data-action="fit"
                  data-whiteboard-zoom
                  title="Fit drawing to view"
                >100%</button>
                <button type="button" data-action="zoom-in" title="Zoom in" aria-label="Zoom in"><.icon
                  name="hero-plus"
                  class="size-4"
                /></button>
                <span class="wb-toolbar-divider"></span>
                <button
                  type="button"
                  data-action="grid"
                  title="Toggle grid"
                  aria-label="Toggle grid"
                  aria-pressed="true"
                ><.icon name="hero-squares-2x2" class="size-4" /></button>
              </div>
              <div class="wb-control-group" aria-label="Drawing history">
                <button type="button" data-action="undo" title="Undo (Ctrl/⌘ Z)" aria-label="Undo"><.icon
                  name="hero-arrow-uturn-left"
                  class="size-4"
                /></button>
                <button
                  type="button"
                  data-action="redo"
                  title="Redo (Ctrl/⌘ Shift Z)"
                  aria-label="Redo"
                ><.icon name="hero-arrow-uturn-right" class="size-4" /></button>
              </div>
            </div>
            <div class="wb-bottom-right">
              <details class="wb-menu wb-help">
                <summary title="Keyboard shortcuts" aria-label="Keyboard shortcuts">
                  <.icon name="hero-question-mark-circle" class="size-4" />
                </summary>
                <div class="wb-menu-panel">
                  <strong>A little help for your ideas</strong>
                  <p>Choose a tool and drag on the canvas. Double-click text to edit it.</p>
                  <p>
                    <kbd>Space</kbd>
                    + drag to pan<br /><kbd>Ctrl/⌘</kbd>
                    + scroll to zoom<br /><kbd>Ctrl/⌘ Z</kbd>
                    Undo<br /><kbd>Ctrl/⌘ Shift Z</kbd>
                    Redo<br /><kbd>Delete</kbd>
                    Remove selection
                  </p>
                  <p>
                    Text: Enter to finish, Shift+Enter for a new line. Changes save automatically and sync with workspace members.
                  </p>
                </div>
              </details>
              <details class="wb-menu wb-file-menu">
                <summary>
                  <.icon name="hero-arrow-down-tray" class="size-4" />Export<.icon
                    name="hero-chevron-down"
                    class="size-3"
                  />
                </summary>
                <div class="wb-menu-panel">
                  <button type="button" data-action="export-svg"><.icon
                    name="hero-photo"
                    class="size-4"
                  />Export image (SVG)</button>
                  <button type="button" data-action="export-json"><.icon
                    name="hero-document-arrow-down"
                    class="size-4"
                  />Export drawing (JSON)</button>
                  <button type="button" data-action="import"><.icon
                    name="hero-document-arrow-up"
                    class="size-4"
                  />Import drawing (JSON)</button>
                  <hr />
                  <button type="button" data-action="clear" class="wb-danger"><.icon
                    name="hero-trash"
                    class="size-4"
                  />Clear whiteboard</button>
                </div>
              </details>
            </div>
          </div>
          <footer class="wb-footer">
            <span class="wb-save-state"><span class="wb-save-dot"></span><span
              data-whiteboard-status
              role="status"
              aria-live="polite"
            >Connecting to whiteboard…</span><button type="button" data-action="retry" hidden>Retry save</button></span>
            <span class="wb-footer-hint">A shared space for unfinished thoughts.<span> Space to pan · Ctrl/⌘ + scroll to zoom</span></span>
          </footer>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :tool, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :shortcut, :string, required: true
  attr :selected, :boolean, default: false

  defp tool(assigns) do
    ~H"""
    <button
      type="button"
      id={"wb-tool-#{@tool}"}
      data-tool={@tool}
      class="wb-tool"
      title={"#{@label} (#{@shortcut})"}
      aria-label={"#{@label} (#{@shortcut})"}
      aria-pressed={to_string(@selected)}
    >
      <.icon name={@icon} class="size-[18px]" /><span class="wb-tool-shortcut">{@shortcut}</span>
    </button>
    """
  end

  attr :color, :string, required: true
  attr :label, :string, required: true
  attr :style, :string, required: true

  defp swatch(assigns) do
    ~H"""
    <button
      type="button"
      class={["wb-swatch", @color == "transparent" && "wb-swatch-transparent"]}
      data-style={@style}
      data-value={@color}
      style={"--swatch: #{@color}"}
      title={@label}
      aria-label={"#{@label} #{@style}"}
      aria-pressed={to_string(@color in ["#263449", "transparent"])}
    ></button>
    """
  end
end
