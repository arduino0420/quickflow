// Synthetic, test-only experiments. Never imported by the application.
const densify = (vertices, steps = 256) => vertices.flatMap((point, index) => {
  if (!index) return [point]
  const previous = vertices[index - 1]
  return Array.from({length: steps}, (_, step) => {
    const t = (step + 1) / steps
    return point.map((value, axis) => previous[axis] + (value - previous[axis]) * t)
  })
})

function distanceSquared(point, a, b) {
  const dx = b[0] - a[0], dy = b[1] - a[1]
  const t = dx || dy ? Math.max(0, Math.min(1, ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / (dx * dx + dy * dy))) : 0
  return (point[0] - a[0] - t * dx) ** 2 + (point[1] - a[1] - t * dy) ** 2
}

function rdp(points, tolerance) {
  const keep = new Set([0, points.length - 1]), stack = [[0, points.length - 1]]
  while (stack.length) {
    const [first, last] = stack.pop()
    let maximum = tolerance ** 2, selected = null
    for (let index = first + 1; index < last; index++) {
      const distance = distanceSquared(points[index], points[first], points[last])
      if (distance > maximum) { maximum = distance; selected = index }
    }
    if (selected != null) {
      keep.add(selected)
      stack.push([first, selected], [selected, last])
    }
  }
  return points.filter((_, index) => keep.has(index))
}

function candidate(operations, method) {
  return operations.map(operation => {
    const copy = structuredClone(operation), points = copy.points
    // Protect erasing, dots, short input and tiny glyphs in every candidate.
    const extent = Math.max(...[0, 1].map(axis => Math.max(...points.map(p => p[axis])) - Math.min(...points.map(p => p[axis]))))
    if (operation.tool !== "pen" || points.length <= 4 || extent <= 3) return copy
    if (method === "rdp_0.02") copy.points = rdp(points, 0.02)
    else {
      const kept = [points[0]], threshold = method === "proximity_0.02" ? 0.02 ** 2 : 0
      for (const point of points.slice(1, -1)) {
        const previous = kept.at(-1)
        if ((point[0] - previous[0]) ** 2 + (point[1] - previous[1]) ** 2 > threshold) kept.push(point)
      }
      kept.push(points.at(-1))
      copy.points = kept
    }
    return copy
  })
}

const definitions = [
  ["digit_2", [[[0, 8], [2, 10], [5, 9], [5, 7], [0, 1], [6, 1]]]],
  ["minus", [[[0, 5], [7, 5]]]],
  ["exponent", [[[0, 2], [0.5, 2.5], [1.2, 2.3], [0, 0], [1.5, 0]]]],
  ["fraction", [[[2, 10], [2, 7]], [[0, 5], [7, 5]], [[0, 2], [2, 3], [4, 2], [0, 0], [5, 0]]]],
  ["root", [[[0, 5], [2, 6], [4, 1], [7, 11], [15, 11]]]],
  ["small_digit", [[[0, 2], [1, 2.5], [2, 2], [2, 0], [0, 0], [0, 2]]]],
  ["dot_and_short", [[[1, 2]], [[3, 1], [3.1, 1.1], [3.2, 1.15]]]],
  ["zero", [Array.from({length: 65}, (_, index) => [3 + 3 * Math.cos(index * Math.PI / 32), 5 + 5 * Math.sin(index * Math.PI / 32)])]]
]
const groups = [], operations = []
definitions.forEach(([name, lines], index) => {
  const x = 20 + (index % 2) * 80, y = 250 - Math.floor(index / 2) * 55
  groups.push({name, bounds: [x - 4, y - 4, x + 25, y + 16]})
  for (const vertices of lines) {
    const points = name === "zero" ? densify(vertices, 16) : densify(vertices)
    operations.push({id: operations.length + 1, tool: "pen", width: 1.2, color: "#000000", points: points.map(p => [x + p[0], y + p[1]])})
  }
})
// Preserve eraser sizes and pen/eraser/pen order verbatim.
for (const width of [4, 8, 18]) operations.push({id: operations.length + 1, tool: "eraser", width, color: "#000000", points: [[150, 30], [155, 35]]})
operations.push({id: operations.length + 1, tool: "pen", width: 1.2, color: "#000000", points: [[150, 30], [155, 35]]})

const methods = ["deduplicate", "proximity_0.02", "rdp_0.02"]
function measure(ops) {
  return {operations: ops.length, points: ops.reduce((sum, op) => sum + op.points.length, 0),
    jsonBytes: new TextEncoder().encode(JSON.stringify([{page_number: 1, operations: ops}])).length}
}
const longWriting = Array.from({length: 377}, (_, index) => ({...structuredClone(operations[index % operations.length]), id: index + 1}))
return {operations, groups, candidates: methods.map(name => ({name, operations: candidate(operations, name)})),
  longWriting: {original: measure(longWriting), candidates: methods.map(name => {
    const started = performance.now(), result = candidate(longWriting, name)
    return {name, ...measure(result), milliseconds: performance.now() - started}
  })}, measure}
