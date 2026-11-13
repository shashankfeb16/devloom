import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs/promises"
const geometrySource = await fs.readFile(new URL("../../assets/js/whiteboard_scene.js", import.meta.url), "utf8")
const geometryURL = `data:text/javascript;base64,${Buffer.from(geometrySource).toString("base64")}`
const hookSource = (await fs.readFile(new URL("../../assets/js/whiteboard.js", import.meta.url), "utf8")).replace('"./whiteboard_scene"', JSON.stringify(geometryURL))
const {Whiteboard} = await import(`data:text/javascript;base64,${Buffer.from(hookSource + "\n//# sourceURL=whiteboard-hook-test.js").toString("base64")}`)
const {DEFAULT_STYLE} = await import(geometryURL)
const element = (id, x = 0) => ({...DEFAULT_STYLE, id, type: "rectangle", x, y: 0, width: 40, height: 40})
function hook(elements = [element("local")]) {
  const node = {hidden: true}
  return {...Whiteboard, el: {dataset: {boardId: "7"}, querySelectorAll: () => [node]}, elements, revision: 1, dirty: true, offline: false, inFlight: null, pendingRemote: null, destroying: false, messages: [], renders: 0, queued: 0, render() { this.renders++ }, updateControls() {}, status(text) { this.messages.push(text) }, storeDraft() {}, queueSave() { this.queued++ }, pushEvent(name, payload, callback) { this.request = {name, payload, callback} }}
}

test("acknowledging a save after an own broadcast does not create a conflict", () => {
  const board = hook()
  board.save()
  assert.equal(board.request.name, "save_scene")
  board.remote({revision: 2, scene: board.snapshot()})
  assert.equal(board.revision, 2)
  assert.equal(board.pendingRemote, null)
  board.request.callback({status: "ok", revision: 2})
  assert.equal(board.dirty, false)
  assert.equal(board.inFlight, null)
})

test("edits made while a save is in flight stay dirty and schedule another save", () => {
  const board = hook()
  board.save()
  board.elements.push(element("second", 100))
  board.request.callback({status: "ok", revision: 2})
  assert.equal(board.dirty, true)
  assert.equal(board.elements.length, 2)
  assert.equal(board.revision, 2)
  assert.equal(board.queued, 1)
})

test("a teammate update cannot overwrite unsaved work and older messages cannot replace the latest conflict", () => {
  const board = hook()
  board.remote({revision: 4, scene: {elements: [element("teammate")]}})
  assert.equal(board.elements[0].id, "local")
  assert.equal(board.pendingRemote.revision, 4)
  board.remote({revision: 3, scene: {elements: [element("older")]}})
  assert.equal(board.pendingRemote.scene.elements[0].id, "teammate")
})

test("clean boards receive live changes and drop stale undo history", () => {
  const board = hook()
  board.dirty = false
  board.history = [{elements: []}]
  board.future = [{elements: []}]
  board.remote({revision: 2, scene: {elements: [element("teammate")]}})
  assert.equal(board.elements[0].id, "teammate")
  assert.equal(board.revision, 2)
  assert.deepEqual(board.history, [])
  assert.deepEqual(board.future, [])
})

test("stale saves preserve the draft and carry the latest shared scene for review", () => {
  const board = hook()
  board.save()
  board.request.callback({status: "conflict", revision: 3, scene: {elements: [element("shared")]}})
  assert.equal(board.dirty, true)
  assert.equal(board.elements[0].id, "local")
  assert.equal(board.pendingRemote.scene.elements[0].id, "shared")
  assert.equal(board.pendingRemote.revision, 3)
})

test("disconnection invalidates an old callback and reconnect recognizes a committed save", () => {
  const board = hook()
  board.save()
  const old = board.request.callback
  board.disconnected()
  old({status: "ok", revision: 2})
  assert.equal(board.dirty, true)
  assert.equal(board.offline, true)
  assert.equal(board.revision, 1)
  board.reconnected()
  assert.equal(board.request.name, "sync_scene")
  board.request.callback({status: "ok", revision: 2, scene: board.snapshot()})
  assert.equal(board.revision, 2)
  assert.equal(board.dirty, false)
  assert.equal(board.pendingRemote, null)
})

test("disconnected edits create a conflict on reconnect when a teammate saved first", () => {
  const board = hook()
  board.offline = true
  board.reconnected()
  board.request.callback({status: "ok", revision: 2, scene: {elements: [element("shared")]}})
  assert.equal(board.dirty, true)
  assert.equal(board.elements[0].id, "local")
  assert.equal(board.pendingRemote.revision, 2)
})

test("failed saves keep dirty work available for an explicit retry", () => {
  const board = hook()
  board.save()
  board.request.callback({status: "error", message: "Try again"})
  assert.equal(board.inFlight, null)
  assert.equal(board.dirty, true)
  assert.equal(board.elements[0].id, "local")
  assert.equal(board.messages.at(-1), "Try again")
  board.save()
  assert.equal(board.inFlight.revision, 1)
})


test("an older reconnect reply cannot replace a newer board or clear its conflict", () => {
  const board = hook()
  board.reconnected()
  const callback = board.request.callback
  board.remote({revision: 4, scene: {elements: [element("latest")]}})
  callback({status: "ok", revision: 2, scene: board.snapshot()})
  assert.equal(board.dirty, true)
  assert.equal(board.pendingRemote.revision, 4)
  assert.equal(board.pendingRemote.scene.elements[0].id, "latest")
})

test("clean live updates are received while panning without a version conflict", () => {
  const board = hook()
  board.dirty = false
  board.drag = {mode: "pan"}
  board.history = []
  board.future = []
  board.remote({revision: 2, scene: {elements: [element("live")]}})
  assert.equal(board.elements[0].id, "live")
  assert.equal(board.pendingRemote, null)
  assert.equal(board.drag.mode, "pan")
})


test("two nearby stationary text taps open editing even when SVG targets are replaced", () => {
  const board = hook([element("text")])
  board.elements[0].type = "text"
  board.elements[0].text = "idea"
  board.selected = "text"
  board.dirty = false
  board.svg = {hasPointerCapture: () => false}
  board.openText = function (item, fresh) { this.opened = {item, fresh} }
  const tap = (time, x = 120, changed = false) => {
    board.drag = {mode: "move", id: 1, original: board.snapshot().elements[0], before: board.snapshot(), changed}
    board.pointerUp({pointerId: 1, timeStamp: time, clientX: x, clientY: 80})
  }
  tap(100)
  assert.equal(board.opened, undefined)
  tap(350)
  assert.equal(board.opened.item.text, "idea")
  assert.equal(board.opened.fresh, false)
})

test("a text drag or a distant or slow second tap does not open editing", () => {
  for (const second of [{time: 300, x: 140}, {time: 700, x: 120}, {time: 300, x: 120, changed: true}]) {
    const board = hook([element("text")])
    board.elements[0].type = "text"
    board.elements[0].text = "idea"
    board.selected = "text"
    board.dirty = false
    board.history = []
    board.svg = {hasPointerCapture: () => false}
    board.openText = () => { board.opened = true }
    board.drag = {mode: "move", id: 1, original: board.snapshot().elements[0]}
    board.pointerUp({pointerId: 1, timeStamp: 100, clientX: 120, clientY: 80})
    board.drag = {mode: "move", id: 1, original: board.snapshot().elements[0], before: board.snapshot(), changed: second.changed}
    board.pointerUp({pointerId: 1, timeStamp: second.time, clientX: second.x, clientY: 80})
    assert.equal(board.opened, undefined)
  }
})
