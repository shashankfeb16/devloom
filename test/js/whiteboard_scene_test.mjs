import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs/promises"
// The Phoenix project does not need a package.json or runtime JS dependencies.
const source = await fs.readFile(new URL("../../assets/js/whiteboard_scene.js", import.meta.url), "utf8")
const {DEFAULT_STYLE, validateScene, bounds, sceneBounds, hitTest, resizeElement, moveElement, wrapText} = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`)
const shape = overrides => ({id: "one", type: "rectangle", x: 10, y: 20, width: 100, height: 60, ...DEFAULT_STYLE, ...overrides})

test("portable scenes normalize missing styles and discard non-scene fields", () => {
  const {elements: [element]} = validateScene({elements: [{id: "a", type: "rectangle", x: 0, y: 0, width: 20, height: 30, onClick: "malicious", workspace_id: 1}]})
  assert.equal(element.stroke, DEFAULT_STYLE.stroke)
  assert.equal(element.onClick, undefined)
  assert.equal(element.workspace_id, undefined)
})

test("invalid import coordinates, duplicate IDs, unknown types and styles fail before editing", () => {
  for (const override of [{x: Infinity}, {x: NaN}, {type: "script"}, {width: -1}, {fill: "url(https://example.com)"}, {stroke: "red"}, {opacity: 101}, {roundness: "yes"}]) {
    assert.throws(() => validateScene({elements: [shape(override)]}))
  }
  assert.throws(() => validateScene({elements: [shape(), shape()]}))
})

test("file limits bound text, points, elements and actual Unicode bytes", () => {
  assert.throws(() => validateScene({elements: Array.from({length: 1001}, (_, i) => shape({id: String(i)}))}))
  assert.throws(() => validateScene({elements: [shape({type: "text", text: "a".repeat(10001)})]}))
  assert.throws(() => validateScene({elements: [shape({type: "freedraw", points: []})]}))
  assert.throws(() => validateScene({elements: [shape({type: "freedraw", points: [[0, 0], [Infinity, 1]]})]}))
  assert.throws(() => validateScene({elements: [], padding: "😀".repeat(500001)}))
})

test("leftward and upward arrows retain their endpoints", () => {
  const arrow = shape({type: "arrow", width: -70, height: -40})
  assert.equal(validateScene({elements: [arrow]}).elements[0].width, -70)
  assert.deepEqual(bounds(arrow), {x: -60, y: -20, width: 70, height: 40})
  assert.equal(hitTest(arrow, {x: -25, y: 0}), true)
  assert.equal(hitTest(arrow, {x: -50, y: 15}, 2), false)
})

test("ellipse and diamond picking follows their shape rather than the bounding rectangle", () => {
  assert.equal(hitTest(shape({type: "ellipse"}), {x: 60, y: 50}, 0), true)
  assert.equal(hitTest(shape({type: "ellipse"}), {x: 10, y: 20}, 0), false)
  assert.equal(hitTest(shape({type: "diamond"}), {x: 60, y: 50}, 0), true)
  assert.equal(hitTest(shape({type: "diamond"}), {x: 12, y: 22}, 0), false)
})

test("pencil picking and bounds include negative local coordinates", () => {
  const pencil = shape({type: "freedraw", points: [[0, 0], [-30, 20], [-50, -10]]})
  assert.deepEqual(bounds(pencil), {x: -40, y: 10, width: 50, height: 30})
  assert.equal(hitTest(pencil, {x: -5, y: 30}, 1), true)
  assert.equal(hitTest(pencil, {x: 8, y: 40}, 1), false)
})

test("resizing crosses an anchor and retains positive shape dimensions", () => {
  const result = resizeElement(shape(), "nw", {x: 150, y: 100})
  assert.deepEqual(bounds(result), {x: 110, y: 80, width: 40, height: 20})
})

test("pencil resizing scales its points relative to actual stroke bounds", () => {
  const pencil = shape({type: "freedraw", points: [[0, 0], [-20, -10], [-40, 20]]})
  const result = resizeElement(pencil, "se", {x: 50, y: 70})
  assert.deepEqual(bounds(result), {x: -30, y: 10, width: 80, height: 60})
})

test("moves preserve all drawing data and scene fit includes every shape", () => {
  const original = shape({type: "text", text: "hello"})
  const moved = moveElement(original, -50, 100)
  assert.equal(original.x, 10)
  assert.equal(moved.text, "hello")
  assert.deepEqual(sceneBounds([original, moved]), {x: -40, y: 20, width: 150, height: 160})
  assert.equal(sceneBounds([]), null)
})


test("notes wrap at word boundaries and keep punctuation attached to its word", () => {
  assert.deepEqual(wrapText("Build together.", 14), ["Build", "together."])
  assert.deepEqual(wrapText("Sketch an idea, then build it together.", 18), ["Sketch an idea,", "then build it", "together."])
})

test("text wrapping preserves explicit empty paragraphs and safely breaks long Unicode tokens", () => {
  assert.deepEqual(wrapText("First line\n\nNext line", 20), ["First line", "", "Next line"])
  assert.deepEqual(wrapText("😀😀😀😀😀", 3), ["😀😀😀", "😀😀"])
  assert.deepEqual(wrapText("unbreakable", 4), ["unbr", "eaka", "ble"])
  assert.deepEqual(wrapText("", 14), [""])
})
