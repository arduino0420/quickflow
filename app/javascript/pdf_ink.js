// PDF coordinates are the source of truth. Canvas pixels are only a display cache.
export default class PdfInk {
  constructor(canvas, pageNumber = 1) {
    this.canvas = canvas
    this.pages = new Map([[pageNumber, []]])
    this.pageNumber = pageNumber
    this.width = 1.2 // PDF user-space units; scales with the page, not the screen.
    this.eraserWidth = 4
    this.tool = "pen"
    this.nextOperationId = 1
  }

  setTool(tool) {
    if (!["pen", "eraser"].includes(tool)) return
    if (this.stroke) this.end()
    this.tool = tool
  }

  setViewport(viewport, ratio) {
    this.end()
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
    if (event && event.pointerId !== this.pointerId) return
    // A pointerup may contain a last position absent from pointermove.
    if (event?.type === "pointerup" && this.stroke && this.contains(event)) {
      const point = this.point(event)
      const previous = this.stroke.points.at(-1)
      if (point[0] !== previous[0] || point[1] !== previous[1]) this.stroke.points.push(point)
    }
    this.stroke = null
    this.pointerId = null
    if (this.viewport) this.redraw()
  }

  redraw() {
    const context = this.canvas.getContext("2d")
    context.globalCompositeOperation = "source-over"
    context.resetTransform()
    context.clearRect(0, 0, this.canvas.width, this.canvas.height)
    // Use the actual backing-store dimensions, including pixel rounding.
    context.scale(this.canvas.width / this.viewport.width, this.canvas.height / this.viewport.height)
    context.lineCap = "round"
    context.lineJoin = "round"
    for (const stroke of this.pages.get(this.pageNumber)) {
      context.globalCompositeOperation = stroke.tool === "eraser" ? "destination-out" : "source-over"
      const points = stroke.points.map(point => this.viewport.convertToViewportPoint(...point))
      context.fillStyle = context.strokeStyle = stroke.color
      context.lineWidth = stroke.width * Math.hypot(this.viewport.transform[0], this.viewport.transform[1])
      context.beginPath()
      if (points.length === 1) {
        context.arc(...points[0], context.lineWidth / 2, 0, Math.PI * 2)
        context.fill()
        continue
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
    context.globalCompositeOperation = "source-over"
  }
}
