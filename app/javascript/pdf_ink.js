// PDF coordinates are the source of truth. Canvas pixels are only a display cache.
export const ERASER_WIDTHS = Object.freeze({ small: 4, medium: 8, large: 18 })

export default class PdfInk {
  constructor(canvas, pageNumber = 1, { cache = false } = {}) {
    this.canvas = canvas
    this.cache = cache ? canvas.ownerDocument.createElement("canvas") : null
    this.pages = new Map([[pageNumber, []]])
    this.pageNumber = pageNumber
    this.width = 1.2 // PDF user-space units; scales with the page, not the screen.
    this.eraserWidth = ERASER_WIDTHS.medium
    this.tool = "pen"
    this.nextOperationId = 1
  }

  setEraserSize(size) {
    if (!Object.hasOwn(ERASER_WIDTHS, size)) return
    if (this.stroke) this.end()
    this.eraserWidth = ERASER_WIDTHS[size]
  }

  setTool(tool) {
    if (!["pen", "eraser"].includes(tool)) return
    if (this.stroke) this.end()
    this.tool = tool
  }

  setViewport(viewport, ratio) {
    this.end()
    this.cachedOperations = null
    this.viewport = viewport
    this.canvas.width = Math.ceil(viewport.width * ratio)
    this.canvas.height = Math.ceil(viewport.height * ratio)
    this.redraw()
  }

  point(event) {
    const rect = this.canvas.getBoundingClientRect()
    return this.viewport.convertToPdfPoint(
      (event.clientX - rect.left) * this.viewport.width / rect.width,
      (event.clientY - rect.top) * this.viewport.height / rect.height
    )
  }

  contains(event) {
    const rect = this.canvas.getBoundingClientRect()
    return event.clientX >= rect.left && event.clientX <= rect.left + rect.width &&
      event.clientY >= rect.top && event.clientY <= rect.top + rect.height
  }

  start(event) {
    if (!this.viewport || this.stroke || !["mouse", "pen"].includes(event.pointerType) || event.button !== 0 || !this.contains(event)) return false
    this.pointerId = event.pointerId
    // Array order is replay order; the ID identifies each operation within this session.
    this.stroke = { id: this.nextOperationId++, tool: this.tool, color: "#000000",
      width: this.tool === "eraser" ? this.eraserWidth : this.width, points: [this.point(event)] }
    this.pages.get(this.pageNumber).push(this.stroke)
    this.redraw()
    return true
  }

  move(event) {
    if (!this.stroke || event.pointerId !== this.pointerId) return
    if ((event.buttons & 1) === 0) {
      this.end()
      return
    }
    for (const sample of [...(event.getCoalescedEvents?.() || []), event]) {
      if (!this.contains(sample)) { this.end(); return }
      const point = this.point(sample)
      const previous = this.stroke.points.at(-1)
      if (point[0] !== previous[0] || point[1] !== previous[1]) this.stroke.points.push(point)
    }
  }

  end(event) {
    if (!this.stroke || (event && event.pointerId !== this.pointerId)) return
    // A pointerup may contain a last position absent from pointermove.
    if (event?.type === "pointerup" && this.stroke && this.contains(event)) {
      const point = this.point(event)
      const previous = this.stroke.points.at(-1)
      if (point[0] !== previous[0] || point[1] !== previous[1]) this.stroke.points.push(point)
    }
    const completed = this.stroke
    this.stroke = null
    this.pointerId = null
    if (this.viewport) this.redraw()
    if (completed) this.onChange?.()
  }

  redraw() {
    if (!this.canvas.width || !this.canvas.height) return
    const context = this.canvas.getContext("2d")
    context.globalCompositeOperation = "source-over"
    context.resetTransform()
    context.clearRect(0, 0, this.canvas.width, this.canvas.height)
    const operations = this.pages.get(this.pageNumber)
    if (this.cache) {
      const count = operations.length - (this.stroke ? 1 : 0)
      if (this.cachedOperations !== operations || this.cachedCount > count ||
          this.cache.width !== this.canvas.width || this.cache.height !== this.canvas.height) {
        this.cache.width = this.canvas.width
        this.cache.height = this.canvas.height
        this.cachedOperations = operations
        this.cachedCount = 0
      }
      const cached = this.cache.getContext("2d")
      this.prepareContext(cached)
      while (this.cachedCount < count) this.drawStroke(cached, operations[this.cachedCount++])
      cached.globalCompositeOperation = "source-over"
      context.drawImage(this.cache, 0, 0)
      this.prepareContext(context)
      if (this.stroke) this.drawStroke(context, this.stroke)
    } else {
      this.prepareContext(context)
      for (const stroke of operations) this.drawStroke(context, stroke)
    }
    context.globalCompositeOperation = "source-over"
  }

  releaseCache() {
    if (this.cache) this.cache.width = this.cache.height = 0
    this.cachedOperations = null
    this.cachedCount = 0
  }

  prepareContext(context) {
    // Use the actual backing-store dimensions, including pixel rounding.
    context.resetTransform()
    context.scale(this.canvas.width / this.viewport.width, this.canvas.height / this.viewport.height)
    context.lineCap = "round"
    context.lineJoin = "round"
  }

  drawStroke(context, stroke) {
    context.globalCompositeOperation = stroke.tool === "eraser" ? "destination-out" : "source-over"
    const points = stroke.points.map(point => this.viewport.convertToViewportPoint(...point))
    context.fillStyle = context.strokeStyle = stroke.color
    context.lineWidth = stroke.width * Math.hypot(this.viewport.transform[0], this.viewport.transform[1])
    context.beginPath()
    if (points.length === 1) {
      context.arc(...points[0], context.lineWidth / 2, 0, Math.PI * 2)
      context.fill()
      return
    }
    context.moveTo(...points[0])
    // Quadratic curves through midpoints smooth sampled pointer movements.
    for (let i = 1; i < points.length - 1; i++) {
      const next = points[i + 1]
      context.quadraticCurveTo(...points[i], (points[i][0] + next[0]) / 2, (points[i][1] + next[1]) / 2)
    }
    context.lineTo(...points.at(-1))
    context.stroke()
  }
}
