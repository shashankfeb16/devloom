const cardSelector = "article[data-work-item-id]"
const handleSelector = "[data-drag-handle]"
const interactiveSelector = "a, button, input, textarea, select, [contenteditable='true']"

// LiveView owns the card DOM. This hook only observes gestures, paints transient
// drop indicators, and asks the server to persist the final position.
export const KanbanBoard = {
  mounted() {
    this.drag = null
    this.target = null
    this.pointer = null
    this.pendingId = null
    this.listeners = []

    this.listen = (element, name, listener, options) => {
      element.addEventListener(name, listener, options)
      this.listeners.push(() => element.removeEventListener(name, listener, options))
    }
    this.listen(this.el, "dragstart", event => this.startNativeDrag(event))
    this.listen(this.el, "dragenter", event => this.overNativeDrag(event))
    this.listen(this.el, "dragover", event => this.overNativeDrag(event))
    this.listen(this.el, "drop", event => this.dropNativeDrag(event))
    this.listen(this.el, "dragleave", event => {
      if (!this.el.contains(event.relatedTarget)) {
        this.clearIndicators()
        this.dragPoint = null
      }
    })
    this.listen(this.el, "dragend", () => this.resetDrag())
    this.listen(this.el, "pointerdown", event => this.startPointer(event))
    this.listen(document, "pointermove", event => this.movePointer(event), {passive: false})
    this.listen(document, "pointerup", event => this.endPointer(event))
    this.listen(document, "pointercancel", event => {
      // Native HTML dragging emits pointercancel after dragstart. Only cancel
      // the custom touch/pen gesture that owns this specific pointer.
      if (this.pointer?.id === event.pointerId) this.cancelDrag()
    })
    this.listen(document, "keydown", event => this.handleKey(event))
    this.listen(this.el, "click", event => {
      if (this.suppressClickUntil > Date.now() || event.target.closest(handleSelector)) {
        event.preventDefault()
        event.stopImmediatePropagation()
      }
    }, true)
  },

  beforeUpdate() {
    const handle = document.activeElement?.closest(handleSelector)
    this.focusedHandleId = handle && this.el.contains(handle)
      ? handle.closest(cardSelector)?.dataset.workItemId
      : null
  },

  updated() {
    if (this.drag && !this.dragStillValid()) {
      this.cancelDrag("The board changed during this move. Pick up the work item again.")
    }
    if (this.pointer && !this.el.contains(this.pointer.card)) this.resetDrag()
    if (this.pendingId) {
      const card = this.findCard(this.pendingId)
      if (card) card.classList.add("is-pending")
      else {
        this.finishPending()
        this.announce("This work item is no longer visible on the board.")
      }
    }
    if (this.focusedHandleId && !this.el.contains(document.activeElement)) {
      this.restoreHandleFocus(this.focusedHandleId)
    }
  },

  disconnected() {
    this.cancelDrag()
    this.finishPending()
    this.announce("Connection interrupted. Reconnect before moving a work item.")
  },

  destroyed() {
    this.listeners.forEach(remove => remove())
    cancelAnimationFrame(this.focusFrame)
    this.resetDrag()
    this.finishPending()
  },

  findCard(id) {
    return this.el.querySelector(`${cardSelector}[data-work-item-id="${CSS.escape(String(id))}"]`)
  },

  columns() {
    return [...this.el.querySelectorAll(".kanban-column[data-status]")]
  },

  cards(column) {
    return [...column.querySelectorAll(cardSelector)].filter(card => card.dataset.workItemId !== this.drag?.id)
  },

  announce(message) {
    const announcer = document.getElementById("board-announcer")
    if (announcer) announcer.textContent = message
  },

  beginDrag(card, mode) {
    if (this.pendingId || this.drag || !card || this.liveSocket.isConnected?.() === false) return false
    const sourceColumn = card.closest(".kanban-column[data-status]")
    if (!sourceColumn || !this.el.contains(card) || !this.el.contains(sourceColumn)) return false
    this.drag = {
      id: card.dataset.workItemId,
      element: card,
      sourceColumn,
      sourceStatus: sourceColumn.dataset.status,
      title: card.querySelector("[data-card-title]")?.textContent.trim() || `Work item ${card.dataset.workItemId}`,
      mode,
    }
    card.classList.add("is-dragging")
    card.querySelector(handleSelector)?.setAttribute("aria-pressed", "true")
    return true
  },

  dragStillValid() {
    if (!this.drag) return false
    const {id, element, sourceColumn, sourceStatus} = this.drag
    if (this.findCard(id) !== element || !this.el.contains(sourceColumn) ||
        element.closest(".kanban-column[data-status]") !== sourceColumn ||
        sourceColumn.dataset.status !== sourceStatus) return false
    if (!this.target) return true
    const {column, status, beforeId} = this.target
    if (!this.el.contains(column) || column.dataset.status !== status) return false
    return !beforeId || this.cards(column).some(card => card.dataset.workItemId === beforeId)
  },

  startNativeDrag(event) {
    const card = event.target.closest(cardSelector)
    if (this.pointer || this.blockNativeDrag || !this.beginDrag(card, "mouse")) {
      event.preventDefault()
      return
    }
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", this.drag.id)
    this.announce(`Moving ${this.drag.title}. Drop it in a column.`)
  },

  overNativeDrag(event) {
    if (!this.drag || this.drag.mode !== "mouse") return
    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
    this.setPointerTarget(event.clientX, event.clientY)
    this.scrollAtEdge(event.clientX, event.clientY)
  },

  dropNativeDrag(event) {
    if (!this.drag || this.drag.mode !== "mouse") return
    event.preventDefault()
    this.setPointerTarget(event.clientX, event.clientY)
    this.commitDrop()
  },

  startPointer(event) {
    const handle = event.target.closest(handleSelector)
    this.blockNativeDrag = !!event.target.closest(interactiveSelector) && !handle
    if (event.pointerType === "mouse" || event.button !== 0 || !handle || this.pendingId) return
    const card = handle.closest(cardSelector)
    this.pointer = {id: event.pointerId, x: event.clientX, y: event.clientY, card, handle, active: false}
  },

  movePointer(event) {
    const pointer = this.pointer
    if (!pointer || event.pointerId !== pointer.id) return
    if (!pointer.active && Math.hypot(event.clientX - pointer.x, event.clientY - pointer.y) > 7) {
      pointer.active = this.beginDrag(pointer.card, "touch")
      if (!pointer.active) return
      pointer.handle.setPointerCapture?.(pointer.id)
      this.announce(`Moving ${this.drag.title}. Release to drop.`)
    }
    if (!pointer.active) return
    event.preventDefault()
    this.setPointerTarget(event.clientX, event.clientY)
    this.scrollAtEdge(event.clientX, event.clientY)
  },

  endPointer(event) {
    if (!this.pointer || event.pointerId !== this.pointer.id) return
    if (this.pointer.active) {
      this.suppressClickUntil = Date.now() + 350
      this.commitDrop()
    }
    this.pointer = null
  },

  setPointerTarget(x, y) {
    const underPointer = document.elementFromPoint(x, y)
    const column = underPointer?.closest(".kanban-column[data-status]")
    if (!column || !this.el.contains(column)) {
      this.clearIndicators()
      return
    }
    const cards = this.cards(column)
    const before = cards.find(card => {
      const bounds = card.getBoundingClientRect()
      return y < bounds.top + bounds.height / 2
    })
    this.paintTarget(column, before || null)
  },

  paintTarget(column, before) {
    this.clearIndicators()
    if (!column || !this.el.contains(column)) return
    const cards = this.cards(column)
    this.target = {column, status: column.dataset.status, beforeId: before?.dataset.workItemId || null}
    column.classList.add("is-drag-over")
    if (before) before.classList.add("drop-before")
    else cards.at(-1)?.classList.add("drop-after")
  },

  clearIndicators() {
    this.el.querySelectorAll(".is-drag-over, .drop-before, .drop-after").forEach(element => {
      element.classList.remove("is-drag-over", "drop-before", "drop-after")
    })
    this.target = null
  },

  scrollAtEdge(x, y) {
    this.dragPoint = {x, y}
    if (this.dragScrollFrame) return
    const tick = () => {
      this.dragScrollFrame = null
      if (!this.drag || !this.dragPoint) return
      this.scrollDragViewport()
      this.dragScrollFrame = requestAnimationFrame(tick)
    }
    this.dragScrollFrame = requestAnimationFrame(tick)
  },

  scrollDragViewport() {
    const {x, y} = this.dragPoint
    const scroll = this.el.closest(".board-scroll") || this.el.querySelector(".board-scroll") || this.el
    const bounds = scroll.getBoundingClientRect()
    if (y < bounds.top - 20 || y > bounds.bottom + 20 || x < bounds.left - 20 || x > bounds.right + 20) return
    const previousLeft = scroll.scrollLeft
    const previousTop = window.scrollY
    if (x < bounds.left + 50) scroll.scrollLeft -= 10
    else if (x > bounds.right - 50) scroll.scrollLeft += 10
    if (y < 65) window.scrollBy(0, -8)
    else if (y > window.innerHeight - 65) window.scrollBy(0, 8)
    if (previousLeft !== scroll.scrollLeft || previousTop !== window.scrollY) this.setPointerTarget(x, y)
  },

  handleKey(event) {
    const editable = event.target.closest("input, textarea, select, [contenteditable='true']")
    const shortcutAllowed = !editable && !this.drag && !document.querySelector("[role='dialog']") && !event.metaKey && !event.ctrlKey && !event.altKey
    if (event.key === "?" && shortcutAllowed) {
      event.preventDefault()
      this.pushEvent("show_help", {})
      return
    }
    if (event.key === "/" && shortcutAllowed) {
      const search = document.getElementById("board-search") || document.querySelector("input[type='search']")
      if (search) {
        event.preventDefault()
        search.focus()
      }
      return
    }
    if (event.key === "Escape" && this.drag) {
      event.preventDefault()
      event.stopPropagation()
      this.cancelDrag()
      return
    }
    const handle = event.target.closest(handleSelector)
    if (!handle || !this.el.contains(handle) || editable) return
    const activate = event.key === " " || event.key === "Enter"
    if (!this.drag && activate) {
      event.preventDefault()
      const card = handle.closest(cardSelector)
      if (!this.beginDrag(card, "keyboard")) return
      this.el.classList.add("is-keyboard-dragging")
      const column = card.closest(".kanban-column")
      const columnCards = [...column.querySelectorAll(cardSelector)]
      const following = columnCards[columnCards.indexOf(card) + 1]
      this.paintTarget(column, following || null)
      this.announce(`Picked up ${this.drag.title}. Use left and right arrows to choose a column, up and down to reorder, Enter to drop, or Escape to cancel.`)
      return
    }
    if (this.drag?.mode !== "keyboard") return
    if (!this.dragStillValid()) {
      event.preventDefault()
      this.cancelDrag("The board changed during this move. Pick up the work item again.")
      return
    }
    if (activate) {
      event.preventDefault()
      this.commitDrop(true)
      return
    }
    if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(event.key)) return
    event.preventDefault()
    const columns = this.columns()
    let column = this.target?.column || handle.closest(".kanban-column")
    let cards = this.cards(column)
    let index = this.target?.beforeId ? cards.findIndex(card => card.dataset.workItemId === this.target.beforeId) : cards.length
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      const direction = event.key === "ArrowLeft" ? -1 : 1
      column = columns[Math.max(0, Math.min(columns.length - 1, columns.indexOf(column) + direction))]
      cards = this.cards(column)
      index = Math.min(index, cards.length)
      column.scrollIntoView({block: "nearest", inline: "nearest"})
    } else {
      const direction = event.key === "ArrowUp" ? -1 : 1
      index = Math.max(0, Math.min(cards.length, index + direction))
    }
    this.paintTarget(column, cards[index] || null)
    this.announce(`${this.columnName(column)}, position ${index + 1} of ${cards.length + 1}. Enter to drop.`)
  },

  columnName(column) {
    return column.querySelector("[data-column-title]")?.textContent.trim() || column.dataset.status.replaceAll("_", " ")
  },

  commitDrop(restoreFocus = false) {
    if (!this.drag || !this.target) {
      this.cancelDrag()
      return
    }
    if (!this.dragStillValid()) {
      this.cancelDrag("The board changed during this move. Pick up the work item again.")
      return
    }
    const {id, title} = this.drag
    const {status, beforeId, column} = this.target
    const columnName = this.columnName(column)
    this.resetDrag()
    if (this.liveSocket.isConnected?.() === false) {
      this.announce("Connection interrupted. Reconnect before moving a work item.")
      return
    }
    this.pendingId = id
    const request = Symbol("move")
    this.pendingRequest = request
    this.findCard(id)?.classList.add("is-pending")
    this.pendingTimeout = setTimeout(() => {
      if (this.pendingRequest !== request) return
      this.finishPending()
      this.announce("The move could not be confirmed. Check your connection and try again.")
    }, 10000)
    this.pushEvent("move_item", {id, status, before_id: beforeId}, reply => {
      if (this.pendingRequest !== request) return
      this.finishPending()
      if (reply?.ok === false) this.announce(reply.error || "The work item could not be moved. Please try again.")
      else {
        const currentColumn = this.findCard(id)?.closest(".kanban-column[data-status]")
        this.announce(`Moved ${title} to ${currentColumn ? this.columnName(currentColumn) : columnName}.`)
      }
      if (restoreFocus) this.restoreHandleFocus(id)
    })
  },

  restoreHandleFocus(id) {
    cancelAnimationFrame(this.focusFrame)
    this.focusFrame = requestAnimationFrame(() => {
      if (document.querySelector("[role='dialog']")) return
      const handle = this.findCard(id)?.querySelector(handleSelector)
      ;(handle || document.getElementById("new-work-item"))?.focus({preventScroll: true})
    })
  },

  finishPending() {
    clearTimeout(this.pendingTimeout)
    this.el.querySelectorAll(".is-pending").forEach(card => card.classList.remove("is-pending"))
    this.pendingId = null
    this.pendingRequest = null
  },

  resetDrag() {
    cancelAnimationFrame(this.dragScrollFrame)
    this.dragScrollFrame = null
    this.dragPoint = null
    this.el.querySelectorAll(".is-dragging").forEach(card => {
      card.classList.remove("is-dragging")
      card.querySelector(handleSelector)?.setAttribute("aria-pressed", "false")
    })
    this.el.classList.remove("is-keyboard-dragging")
    this.clearIndicators()
    this.drag = null
    this.pointer = null
  },

  cancelDrag(message = "Move cancelled.") {
    if (this.drag) this.announce(message)
    this.resetDrag()
  },
}

export const FocusDialog = {
  mounted() {
    this.previousFocus = document.activeElement
    this.previousFocusId = this.previousFocus?.id
    this.focusFrame = requestAnimationFrame(() => {
      const first = this.el.querySelector("[data-autofocus], [autofocus]") || this.el.querySelector("input:not([type='hidden']), textarea, select, button")
      ;(first || this.el).focus()
    })
    this.trapFocus = event => {
      if (event.key !== "Tab") return
      const focusable = [...this.el.querySelectorAll("a[href], button:not([disabled]), input:not([type='hidden']):not([disabled]), textarea:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex='-1'])")]
        .filter(element => element.getClientRects().length > 0)
      const first = focusable[0]
      const last = focusable.at(-1)
      if (!first) {
        event.preventDefault()
        this.el.focus()
      } else if (event.shiftKey && (document.activeElement === first || !this.el.contains(document.activeElement))) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && (document.activeElement === last || !this.el.contains(document.activeElement))) {
        event.preventDefault()
        first.focus()
      }
    }
    document.addEventListener("keydown", this.trapFocus)
  },

  destroyed() {
    cancelAnimationFrame(this.focusFrame)
    document.removeEventListener("keydown", this.trapFocus)
    const returnFocus = this.previousFocus?.isConnected
      ? this.previousFocus
      : document.getElementById(this.previousFocusId) || document.getElementById("new-work-item")
    returnFocus?.focus()
  },
}
