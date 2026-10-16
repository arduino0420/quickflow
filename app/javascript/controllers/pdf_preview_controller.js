import { Controller } from "@hotwired/stimulus"
import PdfInk from "pdf_ink"

// The material URL remains protected by the existing student controller.
export default class extends Controller {
  static targets = ["status", "container", "canvas", "ink", "tool"]
  static values = { url: String, assetsUrl: String }

  connect() {
    this.active = true
    this.page = null
    this.renderedWidth = null
    this.renderedDpr = null
    this.renderQueue = Promise.resolve()
    this.ink = new PdfInk(this.inkTarget)
    this.updateTool()
    this.watchPixelRatio()
    this.load()
  }

  watchPixelRatio() {
    this.resolutionQuery?.removeEventListener("change", this.resolutionChanged)
    this.resolutionQuery = window.matchMedia(`(resolution: ${window.devicePixelRatio || 1}dppx)`)
    this.resolutionChanged = () => {
      this.watchPixelRatio()
      this.queueRender()
    }
    this.resolutionQuery.addEventListener("change", this.resolutionChanged)
  }

  async load() {
    try {
      const pdfjs = await import("pdfjs")
      if (!this.active) return

      // An explicit module Worker prevents a silent fallback to main-thread parsing.
      this.worker = new Worker(`${this.assetsUrlValue}pdf.worker.min.mjs`, { type: "module" })
      this.worker.addEventListener("error", () => this.fail())
      this.pdfWorker = new pdfjs.PDFWorker({ port: this.worker })
      this.loadingTask = pdfjs.getDocument({
        url: this.urlValue,
        worker: this.pdfWorker,
        cMapUrl: `${this.assetsUrlValue}cmaps/`,
        cMapPacked: true,
        standardFontDataUrl: `${this.assetsUrlValue}standard_fonts/`,
        wasmUrl: `${this.assetsUrlValue}wasm/`,
        iccUrl: `${this.assetsUrlValue}iccs/`,
        isEvalSupported: false,
        enableXfa: false
      })
      this.pdf = await this.loadingTask.promise
      if (!this.active) return
      this.page = await this.pdf.getPage(1)
      if (!this.active) return
      await this.queueRender()
      if (!this.active) return
      this.observer = new ResizeObserver(() => {
        window.clearTimeout(this.resizeTimer)
        this.resizeTimer = window.setTimeout(() => this.queueRender(), 100)
      })
      this.observer.observe(this.containerTarget)
    } catch {
      this.fail()
    }
  }

  queueRender() {
    this.renderQueue = (this.renderQueue || Promise.resolve())
      .then(() => this.renderPage()).catch(() => this.fail())
    return this.renderQueue
  }

  async renderPage() {
    if (!this.active || !this.page) return
    const width = this.containerTarget.clientWidth
    const dpr = window.devicePixelRatio || 1
    if (!width || (width === this.renderedWidth && dpr === this.renderedDpr)) return
    this.finishInput()
    this.inkTarget.hidden = true
    const original = this.page.getViewport({ scale: 1 })
    const viewport = this.page.getViewport({ scale: width / original.width })
    // Bound backing-store memory on high-DPI / very large displays.
    const ratio = Math.min(window.devicePixelRatio || 1, 2,
      Math.sqrt(8_000_000 / (viewport.width * viewport.height)))
    const canvas = this.canvasTarget
    canvas.hidden = true
    canvas.width = Math.ceil(viewport.width * ratio)
    canvas.height = Math.ceil(viewport.height * ratio)
    canvas.style.height = `${viewport.height}px`
    this.renderTask = this.page.render({
      canvasContext: canvas.getContext("2d"), viewport,
      transform: [canvas.width / viewport.width, 0, 0, canvas.height / viewport.height, 0, 0]
    })
    await this.renderTask.promise
    if (!this.active) return
    this.renderedWidth = width
    this.renderedDpr = dpr
    this.ink.setViewport(viewport, ratio)
    canvas.hidden = false
    this.inkTarget.hidden = false
    this.updateTool()
    this.containerTarget.setAttribute("aria-busy", "false")
    this.statusTarget.textContent = "1ページ目を表示しています。"
  }

  selectTool(event) {
    this.finishInput()
    this.ink.setTool(event.params.tool)
    this.updateTool()
  }

  updateTool() {
    for (const button of this.toolTargets) {
      button.setAttribute("aria-pressed", String(button.dataset.pdfPreviewToolParam === this.ink.tool))
    }
    this.inkTarget.style.cursor = "crosshair"
    if (this.ink.tool !== "eraser" || !this.ink.viewport) return
    const viewport = this.ink.viewport
    const diameter = this.ink.eraserWidth * Math.hypot(viewport.transform[0], viewport.transform[1]) *
      this.inkTarget.getBoundingClientRect().width / viewport.width
    // Show the approximate erase footprint, scaled with the PDF. Large cursors fall back to crosshair.
    if (diameter > 120) return
    const size = Math.ceil(diameter) + 4
    const center = size / 2
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}"><circle cx="${center}" cy="${center}" r="${diameter / 2}" fill="none" stroke="black"/></svg>`
    this.inkTarget.style.cursor = `url("data:image/svg+xml,${encodeURIComponent(svg)}") ${center} ${center}, crosshair`
  }

  pointerDown(event) {
    if (this.inkTarget.hidden) return
    if (event.pointerType === "touch") {
      // touch-action:none prevents the browser from stealing pen strokes.
      // Finger drags scroll the document here; wheel/trackpad events stay native.
      if (!this.ink.stroke && !this.touch) {
        this.touch = { id: event.pointerId, y: event.clientY }
        this.inkTarget.setPointerCapture(event.pointerId)
      }
      return
    }
    if (this.ink.start(event)) {
      this.touch = null
      event.preventDefault()
      this.inkTarget.setPointerCapture(event.pointerId)
    }
  }

  pointerMove(event) {
    if (event.pointerId === this.touch?.id) {
      window.scrollBy(0, this.touch.y - event.clientY)
      this.touch.y = event.clientY
      return
    }
    this.ink.move(event)
    if (this.ink.stroke && !this.inkFrame) {
      this.inkFrame = window.requestAnimationFrame(() => {
        this.inkFrame = null
        this.ink.redraw()
      })
    }
  }

  pointerEnd(event) {
    this.ink.end(event)
    if (event.pointerId === this.touch?.id) this.touch = null
    if (this.inkTarget.hasPointerCapture(event.pointerId)) this.inkTarget.releasePointerCapture(event.pointerId)
  }

  finishInput() {
    if (!this.ink) return
    const ids = [this.ink.pointerId, this.touch?.id]
    this.ink.end()
    this.touch = null
    for (const id of ids) {
      if (id != null && this.inkTarget.hasPointerCapture(id)) this.inkTarget.releasePointerCapture(id)
    }
  }

  fail() {
    if (!this.active) return
    this.statusTarget.setAttribute("role", "alert")
    this.statusTarget.textContent = "問題を表示できませんでした。通信状態を確認して、ページを再読み込みしてください。"
    this.canvasTarget.hidden = true
    this.inkTarget.hidden = true
    this.containerTarget.setAttribute("aria-busy", "false")
    this.disconnect()
  }

  disconnect() {
    this.active = false
    this.resolutionQuery?.removeEventListener("change", this.resolutionChanged)
    this.finishInput()
    window.cancelAnimationFrame(this.inkFrame)
    this.inkFrame = null
    window.clearTimeout(this.resizeTimer)
    this.observer?.disconnect()
    this.renderTask?.cancel()
    this.loadingTask?.destroy().catch(() => {})
    this.pdfWorker?.destroy()
    this.worker?.terminate()
  }
}
