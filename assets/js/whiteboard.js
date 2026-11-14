import {DEFAULT_STYLE, clone, validateScene, bounds, sceneBounds, hitTest, resizeElement, moveElement, wrapText} from "./whiteboard_scene"

const NS = "http://www.w3.org/2000/svg"
const editable = target => target?.closest("input, textarea, select, [contenteditable='true']")
const create = (tag, attrs = {}) => {
  const node = document.createElementNS(NS, tag)
  Object.entries(attrs).forEach(([key, value]) => node.setAttribute(key, value))
  return node
}
const uuid = () => globalThis.crypto?.randomUUID?.() || `shape-${Date.now()}-${Math.random().toString(36).slice(2)}`
const sceneKey = scene => JSON.stringify(scene.elements.map(e => Object.keys(e).sort().map(k => [k, e[k]])))
const shortcuts = {v: "select", h: "hand", r: "rectangle", d: "diamond", o: "ellipse", a: "arrow", l: "line", p: "freedraw", t: "text", n: "note", e: "eraser"}
const limit = n => Math.max(-999000, Math.min(999000, n))

export const Whiteboard = {
  mounted() {
    this.svg = this.el.querySelector("#whiteboard-svg")
    if (!this.svg) return
    this.stage = this.svg.closest(".wb-stage") || this.svg.parentElement
    this.layer = this.svg.querySelector('[data-layer="elements"]') || this.svg.appendChild(create("g", {"data-layer": "elements"}))
    this.selectionLayer = this.svg.querySelector('[data-layer="selection"]') || this.svg.appendChild(create("g", {"data-layer": "selection"}))
    this.svg.classList.add("wb-svg")
    this.svg.setAttribute("tabindex", "0")
    this.svg.setAttribute("aria-label", "Whiteboard canvas. Choose a drawing tool, then drag to draw. Press V to select or T to add text.")
    this.svg.style.touchAction = "none"
    if (window.matchMedia("(max-width: 700px)").matches) this.el.querySelector(".wb-properties")?.removeAttribute("open")
    this.listeners = []
    this.style = {...DEFAULT_STYLE}
    this.tool = "select"
    this.view = {x: 0, y: 0, zoom: 1}
    this.history = []
    this.future = []
    this.selected = null
    this.grid = true
    this.revision = Number(this.el.dataset.revision)
    this.storageKey = `devloom:whiteboard:${this.el.dataset.userId}:${this.el.dataset.workspaceId}:${this.el.dataset.boardId}`
    this.elements = this.readScene(this.el.dataset.scene).elements
    this.dirty = false
    this.offline = false
    this.inFlight = null
    this.pendingRemote = null
    this.destroying = false
    this.listen = (element, name, handler, options) => {
      element.addEventListener(name, handler, options)
      this.listeners.push(() => element.removeEventListener(name, handler, options))
    }
    this.listen(this.el, "click", event => this.click(event))
    this.listen(this.el, "input", event => this.input(event))
    this.listen(this.svg, "pointerdown", event => this.pointerDown(event))
    this.listen(this.svg, "pointermove", event => this.pointerMove(event))
    this.listen(this.svg, "pointerup", event => this.pointerUp(event))
    this.listen(this.svg, "pointercancel", () => this.cancelGesture())
    this.listen(this.svg, "lostpointercapture", () => this.cancelGesture())
    this.listen(this.svg, "dblclick", event => this.doubleClick(event))
    this.listen(this.svg, "wheel", event => this.wheel(event), {passive: false})
    this.listen(this.el, "keydown", event => this.keyDown(event))
    this.listen(this.el, "keyup", event => {
      if (event.code === "Space") { this.space = false; this.updateControls() }
    })
    this.listen(this.el, "focusout", event => {
      if (!this.el.contains(event.relatedTarget)) { this.space = false; this.updateControls() }
    })
    this.listen(window, "blur", () => { this.space = false; this.cancelGesture(); this.updateControls() })
    this.listen(window, "beforeunload", event => {
      if (this.dirty) { this.storeDraft(); event.preventDefault(); event.returnValue = "" }
    })
    this.handleEvent("whiteboard:updated", data => this.remote(data))
    this.observer = new ResizeObserver(() => this.render())
    this.observer.observe(this.stage)
    this.restoreDraft()
    this.render()
    this.status(this.dirty ? "Draft restored · saving…" : "All changes saved")
    if (this.pendingRemote) this.showConflict()
    else if (this.dirty) this.queueSave()
  },

  readScene(raw) {
    try { return validateScene(typeof raw === "string" ? JSON.parse(raw) : raw) }
    catch { return {elements: []} }
  },

  snapshot() { return {elements: clone(this.elements)} },

  status(message) {
    this.el.querySelectorAll("[data-whiteboard-status]").forEach(node => node.textContent = message)
  },

  restoreDraft() {
    try {
      const saved = JSON.parse(localStorage.getItem(this.storageKey))
      if (!saved) return
      const scene = validateScene(saved.scene)
      if (sceneKey(scene) === sceneKey(this.snapshot())) { localStorage.removeItem(this.storageKey); return }
      if (saved.revision !== this.revision) this.pendingRemote = {scene: this.snapshot(), revision: this.revision}
      this.elements = scene.elements
      this.dirty = true
    } catch { /* Storage may be unavailable. The server remains the source of truth. */ }
  },

  storeDraft() {
    try {
      if (this.dirty) localStorage.setItem(this.storageKey, JSON.stringify({scene: this.snapshot(), revision: this.revision}))
      else localStorage.removeItem(this.storageKey)
    } catch { /* Editing is still available when browser storage is full or disabled. */ }
  },

  remember() {
    this.history.push(this.snapshot())
    if (this.history.length > 80) this.history.shift()
    this.future = []
  },

  changed() {
    this.dirty = true
    this.storeDraft()
    this.render()
    this.queueSave()
  },

  queueSave() {
    clearTimeout(this.saveTimer)
    if (this.destroying) return
    if (this.pendingRemote) { this.showConflict(); return }
    if (this.offline) { this.status("Offline · draft kept on this device"); return }
    this.status("Saving…")
    this.saveTimer = setTimeout(() => this.save(), 550)
  },

  save() {
    if (!this.dirty || this.inFlight || this.pendingRemote || this.offline || this.destroying || this.drag || this.editor) return
    let scene
    try { scene = validateScene(this.snapshot()) }
    catch (error) { this.status(error.message); return }
    const request = {scene, revision: this.revision}
    this.inFlight = request
    this.status("Saving…")
    this.pushEvent("save_scene", {board_id: Number(this.el.dataset.boardId), scene, revision: this.revision}, reply => {
      if (this.destroying || this.inFlight !== request) return
      this.inFlight = null
      if (reply.status === "ok") {
        this.revision = Math.max(this.revision, reply.revision)
        this.dirty = sceneKey(this.snapshot()) !== sceneKey(scene)
        this.storeDraft()
        if (this.pendingRemote && this.pendingRemote.revision <= this.revision) this.pendingRemote = null
        if (this.pendingRemote) this.showConflict()
        else if (this.dirty) this.queueSave()
        else { this.status("All changes saved"); this.hideConflict() }
      } else if (reply.status === "conflict") {
        this.pendingRemote = {scene: this.readScene(reply.scene), revision: reply.revision}
        this.showConflict()
      } else {
        this.status(reply.message || "Could not save · select Retry")
        this.el.querySelectorAll('[data-action="retry"]').forEach(node => node.hidden = false)
        this.storeDraft()
      }
      this.updateControls()
    })
  },

  remote(data) {
    if (data.revision <= this.revision || data.revision < (this.pendingRemote?.revision || 0)) return
    const scene = this.readScene(data.scene)
    if (this.inFlight && sceneKey(scene) === sceneKey(this.inFlight.scene)) {
      this.revision = data.revision
      return
    }
    if (this.dirty || this.drag && this.drag.mode !== "pan" || this.editor || this.inFlight) {
      this.pendingRemote = {scene, revision: data.revision}
      this.showConflict()
      return
    }
    this.revision = data.revision
    this.pendingRemote = null
    this.hideConflict()
    this.elements = scene.elements
    this.selected = null
    this.history = []
    this.future = []
    this.render()
    this.status("Updated by a teammate")
  },

  showConflict() {
    clearTimeout(this.saveTimer)
    this.status("A teammate changed this board · choose which version to keep")
    this.el.querySelectorAll("[data-whiteboard-conflict]").forEach(node => node.hidden = false)
  },

  hideConflict() {
    this.el.querySelectorAll("[data-whiteboard-conflict]").forEach(node => node.hidden = true)
    this.el.querySelectorAll('[data-action="retry"]').forEach(node => node.hidden = true)
  },

  disconnected() {
    this.offline = true
    this.inFlight = null
    clearTimeout(this.saveTimer)
    this.storeDraft()
    this.status("Offline · draft kept on this device")
  },

  reconnected() {
    this.offline = false
    this.pushEvent("sync_scene", {board_id: Number(this.el.dataset.boardId)}, reply => {
      if (this.destroying || reply.status !== "ok" || reply.revision < this.revision || reply.revision < (this.pendingRemote?.revision || 0)) return
      this.remote(reply)
      // A write may have committed just before the connection dropped.
      if (sceneKey(this.readScene(reply.scene)) === sceneKey(this.snapshot())) {
        this.revision = reply.revision
        this.dirty = false
        this.pendingRemote = null
        this.storeDraft()
        this.hideConflict()
        this.status("All changes saved")
      } else if (this.dirty && !this.pendingRemote) this.queueSave()
      else if (!this.pendingRemote) this.status("All changes saved")
    })
  },

  destroyed() {
    this.destroying = true
    clearTimeout(this.saveTimer)
    if (this.editor) this.finishText(true)
    this.storeDraft()
    this.listeners?.forEach(remove => remove())
    this.observer?.disconnect()
  },

  selectedElement() { return this.elements.find(element => element.id === this.selected) },

  selectTool(tool) {
    if (this.editor) this.finishText(true)
    this.tool = tool
    this.selected = null
    this.render()
    this.svg.focus({preventScroll: true})
  },

  click(event) {
    const tool = event.target.closest("[data-tool]")
    if (tool && this.el.contains(tool)) { this.selectTool(tool.dataset.tool); return }
    const style = event.target.closest("button[data-style]")
    if (style) {
      if (this.editor) this.finishText(true)
      this.setStyle(style.dataset.style, style.dataset.value); return
    }
    const action = event.target.closest("[data-action]")?.dataset.action
    if (!action) return
    if (this.editor && !["load-latest", "keep-local"].includes(action)) this.finishText(true)
    switch (action) {
      case "undo": this.undo(); break
      case "redo": this.redo(); break
      case "delete": this.deleteSelected(); break
      case "duplicate": this.duplicate(); break
      case "zoom-in": this.zoomAt(1.2); break
      case "zoom-out": this.zoomAt(1 / 1.2); break
      case "fit": this.fit(); break
      case "grid": this.grid = !this.grid; this.render(); break
      case "export-svg": this.exportSVG(); break
      case "export-json": this.download(JSON.stringify({type: "devloom-whiteboard", version: 1, ...this.snapshot()}, null, 2), "application/json", "whiteboard.devloom.json"); break
      case "import": this.importFile(); break
      case "clear":
        if (this.elements.length && window.confirm("Clear this whiteboard for everyone in the workspace? You can undo this change.")) { this.remember(); this.elements = []; this.selected = null; this.changed() }
        break
      case "retry": this.hideConflict(); this.queueSave(); break
      case "load-latest":
        if (this.pendingRemote) {
          if (this.editor) this.finishText(false)
          this.remember()
          this.elements = clone(this.pendingRemote.scene.elements)
          this.revision = this.pendingRemote.revision
          this.pendingRemote = null
          this.dirty = false
          this.selected = null
          this.storeDraft()
          this.hideConflict()
          this.render()
          this.status("Latest version loaded")
        }
        break
      case "keep-local":
        if (this.pendingRemote && window.confirm("Replace the latest shared board with your draft? Your teammate’s version will be overwritten.")) {
          if (this.editor) this.finishText(true)
          this.revision = this.pendingRemote.revision
          this.pendingRemote = null
          this.hideConflict()
          this.dirty = true
          this.queueSave()
        }
        break
    }
  },

  input(event) {
    const input = event.target.closest("[data-style]")
    if (input && !input.matches("button")) this.setStyle(input.dataset.style, input.value)
  },

  setStyle(key, value) {
    if (!(key in DEFAULT_STYLE)) return
    if (["strokeWidth", "opacity", "roughness"].includes(key)) value = Number(value)
    if (key === "roundness") value = value === "true"
    const candidate = {...this.style, [key]: value}
    try { validateScene({elements: [{...candidate, id: "style", type: "rectangle", x: 0, y: 0, width: 10, height: 10}]}) } catch { return }
    this.style = candidate
    const element = this.selectedElement()
    if (element) {
      if (element[key] === value) return
      this.remember()
      element[key] = value
      this.changed()
    } else this.updateControls()
  },

  undo() {
    if (!this.history.length || this.drag) return
    this.future.push(this.snapshot())
    this.elements = this.history.pop().elements
    this.selected = null
    this.changed()
  },

  redo() {
    if (!this.future.length || this.drag) return
    this.history.push(this.snapshot())
    this.elements = this.future.pop().elements
    this.selected = null
    this.changed()
  },

  deleteSelected() {
    if (!this.selected) return
    this.remember()
    this.elements = this.elements.filter(element => element.id !== this.selected)
    this.selected = null
    this.changed()
  },

  duplicate() {
    const selected = this.selectedElement()
    if (!selected || this.elements.length >= 1000) return
    this.remember()
    const duplicate = {...clone(selected), id: uuid(), x: selected.x + 24, y: selected.y + 24}
    this.elements.push(duplicate)
    this.selected = duplicate.id
    this.changed()
  },

  point(event) {
    const rect = this.svg.getBoundingClientRect()
    return {x: limit((event.clientX - rect.left) / this.view.zoom + this.view.x), y: limit((event.clientY - rect.top) / this.view.zoom + this.view.y)}
  },

  findAt(point) { return this.elements.findLast(element => hitTest(element, point, 7 / this.view.zoom)) },

  pointerDown(event) {
    if (event.button !== 0 && event.button !== 1 || this.drag) return
    if (this.editor) this.finishText(true)
    event.preventDefault()
    this.svg.focus({preventScroll: true})
    this.svg.setPointerCapture(event.pointerId)
    const point = this.point(event)
    if (this.tool !== "select") this.lastTap = null
    if (this.tool === "hand" || this.space || event.button === 1) {
      this.drag = {mode: "pan", id: event.pointerId, screen: {x: event.clientX, y: event.clientY}, view: {...this.view}}
    } else if (this.tool === "select") {
      const handle = event.target.closest("[data-resize]")
      const selected = this.selectedElement()
      if (handle && selected) {
        this.drag = {mode: "resize", id: event.pointerId, original: clone(selected), corner: handle.dataset.resize, before: this.snapshot()}
      } else {
        const hit = this.findAt(point)
        if (hit?.id !== this.lastTap?.id) this.lastTap = null
        this.selected = hit?.id || null
        if (hit) {
          this.style = Object.fromEntries(Object.keys(DEFAULT_STYLE).map(k => [k, hit[k] ?? DEFAULT_STYLE[k]]))
          this.drag = {mode: "move", id: event.pointerId, start: point, original: clone(hit), before: this.snapshot()}
        }
      }
    } else if (this.tool === "eraser") {
      this.drag = {mode: "erase", id: event.pointerId, before: this.snapshot(), changed: false}
      const hit = this.findAt(point)
      if (hit) { this.elements = this.elements.filter(e => e.id !== hit.id); this.drag.changed = true }
    } else if (["text", "note"].includes(this.tool)) {
      if (this.elements.length >= 1000) { this.status("This board has reached its 1,000 element limit."); return }
      this.openText({id: uuid(), type: this.tool, x: point.x, y: point.y, width: this.tool === "note" ? 210 : 240, height: this.tool === "note" ? 170 : 30, ...this.style, ...(this.tool === "note" ? {fill: this.style.fill === "transparent" ? "#fef3c7" : this.style.fill} : {}), text: ""}, true)
    } else {
      if (this.elements.length >= 1000) { this.status("This board has reached its 1,000 element limit."); return }
      const element = {id: uuid(), type: this.tool, x: point.x, y: point.y, width: 0, height: 0, ...this.style}
      if (this.tool === "freedraw") element.points = [[0, 0]]
      this.drag = {mode: "draw", id: event.pointerId, start: point, element, before: this.snapshot()}
      this.elements.push(element)
    }
    this.render()
  },

  pointerMove(event) {
    const drag = this.drag
    if (!drag || drag.id !== event.pointerId) return
    const point = this.point(event)
    if (drag.mode === "pan") {
      this.view.x = drag.view.x - (event.clientX - drag.screen.x) / this.view.zoom
      this.view.y = drag.view.y - (event.clientY - drag.screen.y) / this.view.zoom
    } else if (drag.mode === "move") {
      this.replace(moveElement(drag.original, point.x - drag.start.x, point.y - drag.start.y))
      drag.changed = Math.hypot(point.x - drag.start.x, point.y - drag.start.y) > 1 / this.view.zoom
    } else if (drag.mode === "resize") {
      this.replace(resizeElement(drag.original, drag.corner, point))
      drag.changed = true
    } else if (drag.mode === "draw") {
      let dx = point.x - drag.start.x, dy = point.y - drag.start.y
      if (event.shiftKey) {
        if (["line", "arrow"].includes(drag.element.type)) {
          const angle = Math.round(Math.atan2(dy, dx) / (Math.PI / 4)) * Math.PI / 4, length = Math.hypot(dx, dy)
          dx = Math.cos(angle) * length; dy = Math.sin(angle) * length
        } else { const size = Math.max(Math.abs(dx), Math.abs(dy)); dx = Math.sign(dx || 1) * size; dy = Math.sign(dy || 1) * size }
      }
      drag.element.width = dx
      drag.element.height = dy
      if (drag.element.type === "freedraw" && drag.element.points.length < 10000) {
        const last = drag.element.points.at(-1)
        if (Math.hypot(dx - last[0], dy - last[1]) >= 1 / this.view.zoom) drag.element.points.push([dx, dy])
      }
    } else if (drag.mode === "erase") {
      const hit = this.findAt(point)
      if (hit) { this.elements = this.elements.filter(e => e.id !== hit.id); drag.changed = true }
    }
    this.render()
  },

  replace(element) { this.elements = this.elements.map(item => item.id === element.id ? element : item) },

  pointerUp(event) {
    const drag = this.drag
    if (!drag || drag.id !== event.pointerId) return
    this.drag = null
    if (drag.mode === "draw") {
      const element = drag.element
      if (Math.hypot(element.width, element.height) < 3 / this.view.zoom && element.type !== "freedraw") { element.width = 140; element.height = ["line", "arrow"].includes(element.type) ? 0 : 100 }
      if (!["line", "arrow", "freedraw"].includes(element.type)) Object.assign(element, bounds(element))
      if (element.type === "freedraw") { const box = bounds(element); element.width = box.width; element.height = box.height }
      this.history.push(drag.before)
      if (this.history.length > 80) this.history.shift()
      this.future = []
      this.selected = element.id
      if (element.type !== "freedraw" && !event.shiftKey) this.tool = "select"
      this.changed()
    } else if (["move", "resize", "erase"].includes(drag.mode) && drag.changed) {
      this.history.push(drag.before)
      if (this.history.length > 80) this.history.shift()
      this.future = []
      this.changed()
    } else this.render()
    // Rendering refreshes SVG children, so native dblclick cannot reliably keep
    // the same text target between clicks. Recognize two stationary taps here.
    if (drag.mode === "move" && !drag.changed && ["text", "note"].includes(drag.original.type)) {
      const tap = {id: drag.original.id, time: event.timeStamp, x: event.clientX, y: event.clientY}
      const previous = this.lastTap
      if (previous?.id === tap.id && tap.time - previous.time >= 0 && tap.time - previous.time <= 450 && Math.hypot(tap.x - previous.x, tap.y - previous.y) <= 8) {
        this.lastTap = null
        this.openText(clone(this.selectedElement()), false)
      } else this.lastTap = tap
    } else this.lastTap = null
    if (this.svg.hasPointerCapture(event.pointerId)) this.svg.releasePointerCapture(event.pointerId)
    if (this.pendingRemote && !this.dirty) this.remote(this.pendingRemote)
    if (this.dirty && !this.pendingRemote) this.queueSave()
  },

  cancelGesture() {
    if (!this.drag) return
    if (this.drag.before) this.elements = this.drag.before.elements
    this.drag = null
    this.render()
    if (this.pendingRemote && !this.dirty) this.remote(this.pendingRemote)
    if (this.dirty) this.queueSave()
  },

  doubleClick(event) {
    if (this.editor || !["select", "text", "note"].includes(this.tool)) return
    const hit = this.findAt(this.point(event))
    if (hit && ["text", "note"].includes(hit.type)) { event.preventDefault(); this.openText(clone(hit), false) }
  },

  openText(element, fresh) {
    this.selected = element.id
    const textarea = document.createElement("textarea")
    textarea.className = "wb-text-editor"
    textarea.setAttribute("aria-label", element.type === "note" ? "Sticky note text" : "Whiteboard text")
    textarea.setAttribute("placeholder", element.type === "note" ? "Write an idea…" : "Type your idea…")
    textarea.maxLength = 10000
    textarea.value = element.text
    const box = this.svg.getBoundingClientRect(), stageBox = this.stage.getBoundingClientRect()
    const inset = element.type === "note" ? 18 : 0
    Object.assign(textarea.style, {position: "absolute", left: `${box.left - stageBox.left + (element.x - this.view.x + inset) * this.view.zoom}px`, top: `${box.top - stageBox.top + (element.y - this.view.y + inset) * this.view.zoom}px`, width: `${Math.max(120, element.width - inset * 2) * this.view.zoom}px`, minHeight: `${Math.max(40, element.height - inset * 2) * this.view.zoom}px`, fontSize: `${20 * this.view.zoom}px`, lineHeight: "1.4", color: element.stroke, background: element.type === "note" ? element.fill : "#ffffff", zIndex: 15, resize: "both"})
    this.editor = {textarea, element, fresh}
    textarea.addEventListener("keydown", event => {
      event.stopPropagation()
      if (event.key === "Escape") { event.preventDefault(); this.finishText(false) }
      else if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); this.finishText(true) }
    })
    textarea.addEventListener("blur", () => {
      // Buttons can finish or cancel the editor in their click handler first.
      setTimeout(() => { if (this.editor?.textarea === textarea) this.finishText(true) }, 0)
    })
    this.stage.appendChild(textarea)
    this.render()
    textarea.focus()
    textarea.setSelectionRange(textarea.value.length, textarea.value.length)
  },

  finishText(commit) {
    if (!this.editor) return
    const {element, fresh, textarea} = this.editor
    this.editor = null
    const text = textarea.value.trimEnd()
    textarea.remove()
    if (commit && (text.trim() || element.type === "note")) {
      const available = Math.max(1, Math.floor((element.width - (element.type === "note" ? 36 : 0)) / 12))
      const lines = wrapText(text, available).length
      const next = {...element, text, height: Math.max(element.type === "note" ? 170 : 30, lines * 28 + (element.type === "note" ? 36 : 0))}
      if (fresh || sceneKey({elements: [next]}) !== sceneKey({elements: [element]})) {
        this.remember()
        if (fresh) this.elements.push(next)
        else this.replace(next)
        this.tool = "select"
        this.selected = next.id
        this.changed()
      }
    } else if (fresh) this.selected = null
    this.render()
    if (!this.destroying) {
      this.svg.focus({preventScroll: true})
      if (this.dirty) this.queueSave()
    }
  },

  keyDown(event) {
    if (editable(event.target) || this.editor) return
    const key = event.key.toLowerCase(), mod = event.ctrlKey || event.metaKey
    if (event.code === "Space") {
      if (event.target.closest("button, summary, a")) return
      event.preventDefault(); this.space = true; this.updateControls(); return
    }
    if (this.drag) { if (key === "escape") this.cancelGesture(); return }
    if (mod && key === "z") { event.preventDefault(); event.shiftKey ? this.redo() : this.undo() }
    else if (mod && key === "y") { event.preventDefault(); this.redo() }
    else if (mod && key === "d") { event.preventDefault(); this.duplicate() }
    else if (["delete", "backspace"].includes(key)) { event.preventDefault(); this.deleteSelected() }
    else if (key === "escape") { this.selected = null; this.tool = "select"; this.render() }
    else if (key === "enter" && this.selectedElement() && ["text", "note"].includes(this.selectedElement().type)) { event.preventDefault(); this.openText(clone(this.selectedElement()), false) }
    else if (!mod && !event.altKey && shortcuts[key]) { event.preventDefault(); this.selectTool(shortcuts[key]) }
    else if (["arrowleft", "arrowright", "arrowup", "arrowdown"].includes(key) && this.selectedElement()) {
      event.preventDefault()
      const offset = event.shiftKey ? 10 : 1
      this.remember()
      this.replace(moveElement(this.selectedElement(), key === "arrowleft" ? -offset : key === "arrowright" ? offset : 0, key === "arrowup" ? -offset : key === "arrowdown" ? offset : 0))
      this.changed()
    }
  },

  wheel(event) {
    if (this.editor || this.drag) return
    event.preventDefault()
    if (event.ctrlKey || event.metaKey) this.zoomAt(Math.exp(-event.deltaY * 0.01), event)
    else { this.view.x += event.deltaX / this.view.zoom; this.view.y += event.deltaY / this.view.zoom; this.render() }
  },

  zoomAt(factor, event) {
    if (this.editor) this.finishText(true)
    const rect = this.svg.getBoundingClientRect()
    const px = event ? event.clientX - rect.left : rect.width / 2, py = event ? event.clientY - rect.top : rect.height / 2
    const x = this.view.x + px / this.view.zoom, y = this.view.y + py / this.view.zoom
    this.view.zoom = Math.max(0.1, Math.min(4, this.view.zoom * factor))
    this.view.x = x - px / this.view.zoom
    this.view.y = y - py / this.view.zoom
    this.render()
  },

  fit() {
    const box = sceneBounds(this.elements), rect = this.svg.getBoundingClientRect()
    if (!box) this.view = {x: 0, y: 0, zoom: 1}
    else {
      const zoom = Math.max(0.1, Math.min(1.5, (rect.width - 100) / Math.max(100, box.width), (rect.height - 100) / Math.max(100, box.height)))
      this.view = {x: box.x + box.width / 2 - rect.width / zoom / 2, y: box.y + box.height / 2 - rect.height / zoom / 2, zoom}
    }
    this.render()
  },

  render() {
    if (!this.svg) return
    const rect = this.svg.getBoundingClientRect(), zoom = this.view.zoom
    this.svg.setAttribute("viewBox", `${this.view.x} ${this.view.y} ${Math.max(1, rect.width) / zoom} ${Math.max(1, rect.height) / zoom}`)
    this.layer.replaceChildren(...this.elements.filter(e => e.id !== this.editor?.element.id).map(e => this.renderElement(e)))
    this.selectionLayer.replaceChildren()
    const selected = this.selectedElement()
    if (selected && !this.editor && this.tool === "select") {
      const box = bounds(selected), pad = 5 / zoom
      this.selectionLayer.appendChild(create("rect", {x: box.x - pad, y: box.y - pad, width: box.width + pad * 2, height: box.height + pad * 2, fill: "none", stroke: "#7c6ee6", "stroke-width": 1 / zoom, "stroke-dasharray": `${4 / zoom} ${3 / zoom}`, "pointer-events": "none"}))
      for (const [corner, x, y] of [["nw", box.x - pad, box.y - pad], ["ne", box.x + box.width + pad, box.y - pad], ["sw", box.x - pad, box.y + box.height + pad], ["se", box.x + box.width + pad, box.y + box.height + pad]]) {
        const handle = create("rect", {x: x - 4 / zoom, y: y - 4 / zoom, width: 8 / zoom, height: 8 / zoom, rx: 2 / zoom, fill: "#ffffff", stroke: "#7c6ee6", "stroke-width": 1.2 / zoom, "data-resize": corner})
        handle.style.cursor = `${corner}-resize`
        this.selectionLayer.appendChild(handle)
      }
    }
    if (this.grid) {
      this.svg.style.backgroundImage = "radial-gradient(circle, #d8dee9 1px, transparent 1px)"
      this.svg.style.backgroundSize = `${24 * zoom}px ${24 * zoom}px`
      this.svg.style.backgroundPosition = `${-this.view.x * zoom}px ${-this.view.y * zoom}px`
    } else this.svg.style.backgroundImage = "none"
    this.el.querySelectorAll("[data-whiteboard-empty]").forEach(node => node.hidden = this.elements.length > 0 || !!this.editor || !!this.drag)
    this.updateControls()
  },

  renderElement(element) {
    const e = {...DEFAULT_STYLE, ...element}, box = bounds(e)
    const group = create("g", {"data-element-id": e.id, opacity: e.opacity / 100})
    const attrs = {stroke: e.stroke, "stroke-width": e.strokeWidth, fill: e.fill, "stroke-linecap": "round", "stroke-linejoin": "round"}
    if (e.strokeStyle === "dashed") attrs["stroke-dasharray"] = `${e.strokeWidth * 5} ${e.strokeWidth * 3}`
    if (e.strokeStyle === "dotted") attrs["stroke-dasharray"] = `0 ${e.strokeWidth * 3}`
    let shape
    if (e.type === "rectangle" || e.type === "note") shape = create("rect", {...attrs, ...box, rx: e.type === "note" ? 3 : e.roundness ? Math.min(16, box.width / 6, box.height / 6) : 0, ...(e.type === "note" ? {stroke: "#000000", "stroke-opacity": 0.08, "stroke-width": 1} : {})})
    else if (e.type === "ellipse") shape = create("ellipse", {...attrs, cx: box.x + box.width / 2, cy: box.y + box.height / 2, rx: box.width / 2, ry: box.height / 2})
    else if (e.type === "diamond") shape = create("polygon", {...attrs, points: `${box.x + box.width / 2},${box.y} ${box.x + box.width},${box.y + box.height / 2} ${box.x + box.width / 2},${box.y + box.height} ${box.x},${box.y + box.height / 2}`})
    else if (e.type === "line" || e.type === "arrow") {
      shape = create("path", {...attrs, fill: "none", d: `M ${e.x} ${e.y} L ${e.x + e.width} ${e.y + e.height}`})
      if (e.type === "arrow") {
        const angle = Math.atan2(e.height, e.width), size = 11 + e.strokeWidth * 2, endX = e.x + e.width, endY = e.y + e.height
        const head = create("path", {...attrs, fill: "none", d: `M ${endX - size * Math.cos(angle - 0.5)} ${endY - size * Math.sin(angle - 0.5)} L ${endX} ${endY} L ${endX - size * Math.cos(angle + 0.5)} ${endY - size * Math.sin(angle + 0.5)}`})
        group.appendChild(head)
      }
    } else if (e.type === "freedraw") shape = create("path", {...attrs, fill: "none", d: e.points.map((p, i) => `${i ? "L" : "M"} ${e.x + p[0]} ${e.y + p[1]}`).join(" ") + (e.points.length === 1 ? ` l 0.1 0.1` : "")})
    if (shape) {
      group.appendChild(shape)
      // A second, slightly displaced stroke gives shapes a restrained sketch feel.
      if (e.roughness && ["rectangle", "ellipse", "diamond"].includes(e.type) && box.width > 6 && box.height > 6) {
        const sketch = shape.cloneNode()
        sketch.setAttribute("fill", "none")
        sketch.setAttribute("opacity", e.roughness === 2 ? "0.35" : "0.18")
        sketch.setAttribute("transform", `translate(${e.roughness * 0.75} ${-e.roughness * 0.5})`)
        sketch.setAttribute("stroke-width", Math.max(0.6, e.strokeWidth * 0.65))
        group.appendChild(sketch)
      }
    }
    if (e.type === "text" || e.type === "note") {
      const inset = e.type === "note" ? 18 : 0
      const text = create("text", {x: e.x + inset, y: e.y + inset + 21, fill: e.stroke, "font-size": 20, "font-family": "'Comic Sans MS', 'Chalkboard SE', cursive", "xml:space": "preserve"})
      const available = Math.max(1, Math.floor((e.width - inset * 2) / 12))
      const lines = wrapText(e.text, available)
      lines.forEach((line, index) => {
        const span = create("tspan", {x: e.x + inset, dy: index ? 28 : 0})
        span.textContent = line || " "
        text.appendChild(span)
      })
      group.appendChild(text)
    }
    return group
  },

  updateControls() {
    const selected = this.selectedElement(), style = selected || this.style
    this.el.dataset.activeTool = this.space ? "hand" : this.tool
    this.svg.style.cursor = this.drag?.mode === "pan" ? "grabbing" : this.space || this.tool === "hand" ? "grab" : this.tool === "select" ? "default" : ["text", "note"].includes(this.tool) ? "text" : "crosshair"
    this.el.querySelectorAll("[data-tool]").forEach(node => node.setAttribute("aria-pressed", String(node.dataset.tool === this.tool)))
    this.el.querySelectorAll("[data-whiteboard-zoom]").forEach(node => node.textContent = `${Math.round(this.view.zoom * 100)}%`)
    this.el.querySelectorAll("[data-whiteboard-opacity]").forEach(node => node.textContent = `${style.opacity ?? 100}%`)
    this.el.querySelectorAll("[data-whiteboard-selection]").forEach(node => node.textContent = selected ? `${selected.type === "freedraw" ? "Pencil" : selected.type[0].toUpperCase() + selected.type.slice(1)} selected` : "Drawing styles")
    this.el.querySelectorAll("[data-style]").forEach(node => {
      const value = style[node.dataset.style] ?? DEFAULT_STYLE[node.dataset.style]
      if (node.matches("button")) node.setAttribute("aria-pressed", String(node.dataset.value === String(value)))
      else if (node !== document.activeElement && (node.type !== "color" || value !== "transparent")) node.value = value
    })
    this.el.querySelectorAll('[data-action="undo"]').forEach(node => node.disabled = !this.history.length)
    this.el.querySelectorAll('[data-action="redo"]').forEach(node => node.disabled = !this.future.length)
    this.el.querySelectorAll('[data-action="delete"], [data-action="duplicate"]').forEach(node => node.disabled = !selected)
    this.el.querySelectorAll('[data-action="grid"]').forEach(node => node.setAttribute("aria-pressed", String(this.grid)))
  },

  download(content, type, name) {
    const url = URL.createObjectURL(new Blob([content], {type}))
    const link = document.createElement("a")
    link.href = url
    link.download = name
    link.click()
    setTimeout(() => URL.revokeObjectURL(url), 1000)
  },

  exportSVG() {
    const box = sceneBounds(this.elements) || {x: 0, y: 0, width: 800, height: 600}
    const svg = create("svg", {xmlns: NS, width: box.width + 80, height: box.height + 80, viewBox: `${box.x - 40} ${box.y - 40} ${box.width + 80} ${box.height + 80}`})
    svg.appendChild(create("rect", {x: box.x - 40, y: box.y - 40, width: box.width + 80, height: box.height + 80, fill: "#ffffff"}))
    this.elements.forEach(element => svg.appendChild(this.renderElement(element)))
    this.download(new XMLSerializer().serializeToString(svg), "image/svg+xml", "whiteboard.svg")
  },

  importFile() {
    const input = document.createElement("input")
    input.type = "file"
    input.accept = ".json,application/json"
    input.addEventListener("change", async () => {
      const file = input.files?.[0]
      if (!file) return
      if (file.size > 2000000) { this.status("Import a JSON file smaller than 2 MB."); return }
      try {
        const scene = validateScene(JSON.parse(await file.text()))
        if (this.destroying || this.elements.length && !window.confirm("Replace the current whiteboard with this file? You can undo this change.")) return
        this.remember()
        this.elements = scene.elements
        this.selected = null
        this.changed()
        this.fit()
      } catch (error) { this.status(error.message || "This file is not a valid Devloom whiteboard.") }
    }, {once: true})
    input.click()
  },
}
