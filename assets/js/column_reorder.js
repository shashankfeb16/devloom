const rowSelector = "[data-column-id]"
const handleSelector = "[data-column-drag-handle]"

// LiveView keeps ownership of the streamed rows. Only paint drop indicators
// during a gesture; the server persists and renders the resulting order.
export const ColumnReorder = {
  mounted() {
    this.listeners = []
    const listen = (element, name, callback, options) => {
      element.addEventListener(name, callback, options)
      this.listeners.push(() => element.removeEventListener(name, callback, options))
    }
    listen(this.el, "pointerdown", event => {
      const handle = event.target.closest(handleSelector)
      if (!handle || handle.disabled || event.button !== 0 || this.drag || this.pending) return
      event.preventDefault()
      if (!this.begin(handle, "pointer")) return
      handle.focus()
      handle.setPointerCapture(event.pointerId)
      this.pointerId = event.pointerId
      this.point = {x: event.clientX, y: event.clientY}
      this.scrollFrame = requestAnimationFrame(() => this.scroll())
    })
    listen(document, "pointermove", event => {
      if (!this.drag || event.pointerId !== this.pointerId) return
      event.preventDefault()
      this.point = {x: event.clientX, y: event.clientY}
      this.chooseTarget()
    }, {passive: false})
    listen(document, "pointerup", event => {
      if (!this.drag || event.pointerId !== this.pointerId) return
      this.chooseTarget()
      if (this.inside) this.drop()
      else this.cancel()
    })
    listen(document, "pointercancel", event => {
      if (event.pointerId === this.pointerId) this.cancel()
    })
    listen(this.el, "lostpointercapture", () => {
      if (this.drag?.mode === "pointer") this.cancel()
    })
    listen(this.el, "keydown", event => this.keydown(event))
    listen(this.el, "click", event => {
      if (event.target.closest(handleSelector)) {
        event.preventDefault()
        event.stopPropagation()
      }
    })
  },

  rows() { return [...this.el.querySelectorAll(rowSelector)] },
  others() { return this.rows().filter(row => row !== this.drag?.row) },
  announce(message) {
    const status = document.getElementById("column-reorder-announcer")
    if (status) status.textContent = message
  },

  begin(handle, mode) {
    if (this.liveSocket.isConnected() === false) return false
    const row = handle.closest(rowSelector)
    this.drag = {row, handle, mode, title: row.dataset.columnTitle}
    this.order = this.rows().map(row => row.dataset.columnId).join(",")
    this.index = this.rows().indexOf(row)
    row.classList.add("is-dragging")
    handle.setAttribute("aria-pressed", "true")
    this.paint()
    this.announce(`Picked up ${this.drag.title}. Use arrow keys to move, Enter to drop, or Escape to cancel.`)
    return true
  },

  chooseTarget() {
    const bounds = this.el.getBoundingClientRect()
    this.inside = this.point.x >= bounds.left && this.point.x <= bounds.right &&
      this.point.y >= bounds.top && this.point.y <= bounds.bottom
    const rows = this.others()
    const index = rows.findIndex(row => {
      const rect = row.getBoundingClientRect()
      return this.point.y < rect.top + rect.height / 2
    })
    this.index = index < 0 ? rows.length : index
    this.paint(this.inside)
  },

  paint(visible = true) {
    this.rows().forEach(row => row.classList.remove("drop-before", "drop-after"))
    if (!visible) return
    const rows = this.others()
    if (rows[this.index]) rows[this.index].classList.add("drop-before")
    else rows.at(-1)?.classList.add("drop-after")
  },

  scroll() {
    if (!this.drag || !this.point) return
    const container = this.el.closest(".column-settings-body")
    if (container) {
      const bounds = container.getBoundingClientRect()
      if (this.point.x >= bounds.left && this.point.x <= bounds.right) {
        const speed = this.point.y < bounds.top + 48 ? -8 : this.point.y > bounds.bottom - 48 ? 8 : 0
        container.scrollTop += speed
      }
    }
    this.chooseTarget()
    this.scrollFrame = requestAnimationFrame(() => this.scroll())
  },

  keydown(event) {
    const handle = event.target.closest(handleSelector)
    if (!handle || handle.disabled) return
    if (!this.drag) {
      if ((event.key === " " || event.key === "Enter") && !this.pending) {
        event.preventDefault()
        this.begin(handle, "keyboard")
      }
      return
    }
    if (event.key === "Escape") {
      event.preventDefault()
      this.cancel()
    } else if (this.drag.mode === "keyboard") {
      if (["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) {
        event.preventDefault()
        const last = this.others().length
        if (event.key === "Home") this.index = 0
        else if (event.key === "End") this.index = last
        else this.index = Math.max(0, Math.min(last, this.index + (event.key === "ArrowUp" ? -1 : 1)))
        this.paint()
        this.announce(`${this.drag.title}, position ${this.index + 1} of ${last + 1}.`)
      } else if (event.key === " " || event.key === "Enter") {
        event.preventDefault()
        this.drop()
      } else if (event.key === "Tab") this.cancel()
    }
  },

  drop() {
    const {row, handle, title} = this.drag
    const beforeId = this.others()[this.index]?.dataset.columnId || null
    const changed = this.index !== this.rows().indexOf(row)
    this.reset()
    if (!changed) {
      this.announce(`${title} kept in its original position.`)
      return
    }
    this.pending = true
    this.focusId = handle.id
    this.announce(`Saving ${title} position.`)
    this.pushEvent("reorder_column", {id: row.dataset.columnId, before_id: beforeId}, () => {
      this.pending = false
      document.getElementById(this.focusId)?.focus({preventScroll: true})
      this.focusId = null
      this.announce(document.getElementById("column-settings-notice") ? "Column could not be moved. Check the settings message." : `${title} position saved.`)
    })
  },

  cancel() {
    if (this.drag) this.announce(`Move cancelled. ${this.drag.title} kept in its original position.`)
    this.reset()
  },

  reset() {
    cancelAnimationFrame(this.scrollFrame)
    const handle = this.drag?.handle
    const pointerId = this.pointerId
    this.drag = null
    this.pointerId = null
    this.point = null
    this.rows().forEach(row => row.classList.remove("is-dragging", "drop-before", "drop-after"))
    handle?.setAttribute("aria-pressed", "false")
    if (pointerId != null && handle?.hasPointerCapture(pointerId)) handle.releasePointerCapture(pointerId)
  },

  updated() {
    if (this.drag && this.order !== this.rows().map(row => row.dataset.columnId).join(",")) {
      this.cancel()
      this.announce("Columns changed in another session. Pick up the column again.")
    } else if (this.drag) {
      this.drag.row.classList.add("is-dragging")
      this.drag.handle.setAttribute("aria-pressed", "true")
      this.paint()
    }
  },
  disconnected() { this.cancel(); this.pending = false },
  destroyed() { this.reset(); this.listeners.forEach(remove => remove()) },
}
