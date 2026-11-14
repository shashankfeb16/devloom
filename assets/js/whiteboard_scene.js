// Geometry and the portable scene format are independent of the browser.
export const DEFAULT_STYLE = {stroke: "#263449", fill: "transparent", strokeWidth: 2, opacity: 100, strokeStyle: "solid", roughness: 1, roundness: true}
export const ELEMENT_TYPES = ["rectangle", "ellipse", "diamond", "line", "arrow", "freedraw", "text", "note"]
const number = value => typeof value === "number" && Number.isFinite(value) && Math.abs(value) <= 1e6
const color = value => typeof value === "string" && /^#[0-9a-f]{6}$/i.test(value)
export const clone = value => JSON.parse(JSON.stringify(value))

export function validateScene(scene) {
  if (!scene || !Array.isArray(scene.elements) || scene.elements.length > 1000) throw new Error("A board can contain up to 1,000 elements.")
  if (new TextEncoder().encode(JSON.stringify(scene)).length > 2000000) throw new Error("This board is too large. Import a file smaller than 2 MB.")
  const ids = new Set()
  return {elements: scene.elements.map(element => {
    if (!element || !ELEMENT_TYPES.includes(element.type) || typeof element.id !== "string" || !element.id || element.id.length > 100 || ids.has(element.id)) throw new Error("The file contains an invalid or duplicate element.")
    if (![element.x, element.y, element.width, element.height].every(number)) throw new Error("The file contains invalid drawing coordinates.")
    if (!["line", "arrow"].includes(element.type) && (element.width < 0 || element.height < 0)) throw new Error("The file contains invalid shape dimensions.")
    ids.add(element.id)
    const style = {...DEFAULT_STYLE, ...element}
    if (!color(style.stroke) || !(color(style.fill) || style.fill === "transparent") || ![1, 2, 4].includes(style.strokeWidth) || !number(style.opacity) || style.opacity < 0 || style.opacity > 100 || !["solid", "dashed", "dotted"].includes(style.strokeStyle) || ![0, 1, 2].includes(style.roughness) || typeof style.roundness !== "boolean") throw new Error("The file contains invalid drawing styles.")
    if (element.text !== undefined && (typeof element.text !== "string" || element.text.length > 10000)) throw new Error("Text is limited to 10,000 characters.")
    const result = Object.fromEntries(["id", "type", "x", "y", "width", "height", ...Object.keys(DEFAULT_STYLE)].map(key => [key, style[key]]))
    if (element.type === "text" || element.type === "note") result.text = element.text || ""
    if (element.type === "freedraw") {
      if (!Array.isArray(element.points) || element.points.length < 1 || element.points.length > 10000 || !element.points.every(point => Array.isArray(point) && point.length === 2 && point.every(number))) throw new Error("The file contains an invalid pencil stroke.")
      result.points = clone(element.points)
    }
    return result
  })}
}

export function bounds(element) {
  if (element.type === "freedraw" && element.points.length) {
    const xs = element.points.map(p => p[0] + element.x), ys = element.points.map(p => p[1] + element.y)
    return {x: Math.min(...xs), y: Math.min(...ys), width: Math.max(...xs) - Math.min(...xs), height: Math.max(...ys) - Math.min(...ys)}
  }
  return {x: Math.min(element.x, element.x + element.width), y: Math.min(element.y, element.y + element.height), width: Math.abs(element.width), height: Math.abs(element.height)}
}

export function sceneBounds(elements) {
  if (!elements.length) return null
  const boxes = elements.map(bounds), x = Math.min(...boxes.map(b => b.x)), y = Math.min(...boxes.map(b => b.y))
  return {x, y, width: Math.max(...boxes.map(b => b.x + b.width)) - x, height: Math.max(...boxes.map(b => b.y + b.height)) - y}
}

export function segmentDistance(point, start, end) {
  const dx = end.x - start.x, dy = end.y - start.y
  const length = dx * dx + dy * dy
  const t = length ? Math.max(0, Math.min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length)) : 0
  return Math.hypot(point.x - start.x - t * dx, point.y - start.y - t * dy)
}

export function hitTest(element, point, tolerance = 6) {
  const box = bounds(element), {x, y} = point
  if (x < box.x - tolerance || x > box.x + box.width + tolerance || y < box.y - tolerance || y > box.y + box.height + tolerance) return false
  if (["line", "arrow"].includes(element.type)) return segmentDistance(point, element, {x: element.x + element.width, y: element.y + element.height}) <= tolerance + element.strokeWidth
  if (element.type === "freedraw") return element.points.some((p, i, points) => segmentDistance(point, {x: element.x + p[0], y: element.y + p[1]}, {x: element.x + points[Math.max(0, i - 1)][0], y: element.y + points[Math.max(0, i - 1)][1]}) <= tolerance + element.strokeWidth)
  if (element.type === "ellipse") {
    const rx = Math.max(box.width / 2, 1), ry = Math.max(box.height / 2, 1)
    return ((x - box.x - rx) / (rx + tolerance)) ** 2 + ((y - box.y - ry) / (ry + tolerance)) ** 2 <= 1
  }
  if (element.type === "diamond") return Math.abs(x - box.x - box.width / 2) / Math.max(1, box.width / 2 + tolerance) + Math.abs(y - box.y - box.height / 2) / Math.max(1, box.height / 2 + tolerance) <= 1
  return true
}

export function resizeElement(original, corner, point) {
  const box = bounds(original)
  const anchor = {x: corner.includes("w") ? box.x + box.width : box.x, y: corner.includes("n") ? box.y + box.height : box.y}
  const x = Math.min(anchor.x, point.x), y = Math.min(anchor.y, point.y)
  const width = Math.max(4, Math.abs(point.x - anchor.x)), height = Math.max(4, Math.abs(point.y - anchor.y))
  if (["line", "arrow"].includes(original.type)) {
    const flipX = original.width < 0, flipY = original.height < 0
    return {...original, x: flipX ? x + width : x, y: flipY ? y + height : y, width: flipX ? -width : width, height: flipY ? -height : height}
  }
  if (original.type === "freedraw") return {...original, x, y, width, height, points: original.points.map(p => [(original.x + p[0] - box.x) / Math.max(1, box.width) * width, (original.y + p[1] - box.y) / Math.max(1, box.height) * height])}
  return {...original, x, y, width, height}
}

export function moveElement(element, dx, dy) {
  return {...element, x: element.x + dx, y: element.y + dy}
}

// Keep paragraph breaks and whole words when they fit; split only long tokens.
// Code points prevent wrapping halfway through a Unicode surrogate pair.
export function wrapText(text, maxCharacters) {
  const limit = Math.max(1, Math.floor(maxCharacters))
  return text.split("\n").flatMap(paragraph => {
    const words = paragraph.match(/\S+/gu)
    if (!words) return [""]
    const lines = []
    let line = ""
    for (const word of words) {
      const letters = Array.from(word)
      if (line && Array.from(line).length + 1 + letters.length <= limit) {
        line += ` ${word}`
        continue
      }
      if (line) { lines.push(line); line = "" }
      while (letters.length > limit) lines.push(letters.splice(0, limit).join(""))
      line = letters.join("")
    }
    if (line) lines.push(line)
    return lines
  })
}
