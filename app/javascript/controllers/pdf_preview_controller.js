import { Controller } from "@hotwired/stimulus"
import PdfInk from "pdf_ink"

// One document/worker, independent ink per page, sequential PDF rendering.
export default class extends Controller {
  static targets = ["status", "container", "canvas", "ink", "tool", "sizes", "size"]
  static values = { url: String, assetsUrl: String }

  connect() {
    this.active = true
    this.session = Symbol()
    this.pageStates = []
    this.pagesReady = false
    this.statesByCanvas = new WeakMap()
    this.tool = "pen"
    this.eraserSize = "medium"
    this.revision = 0
    this.renderQueue = Promise.resolve()
    this.updateTool()
    this.watchPixelRatio()
    this.load(this.session)
  }

  current(session) {
    return this.active && session === this.session
  }

  watchPixelRatio() {
    this.resolutionQuery?.removeEventListener("change", this.resolutionChanged)
    this.resolutionQuery = window.matchMedia(`(resolution: ${window.devicePixelRatio || 1}dppx)`)
    this.resolutionChanged = () => {
      this.watchPixelRatio()
      this.scheduleRender()
    }
    this.resolutionQuery.addEventListener("change", this.resolutionChanged)
  }

  async load(session) {
    try {
      const pdfjs = await import("pdfjs")
      if (!this.current(session)) return
      this.worker = new Worker(`${this.assetsUrlValue}pdf.worker.min.mjs`, { type: "module" })
      this.worker.addEventListener("error", () => { if (this.current(session)) this.fail() })
      this.pdfWorker = new pdfjs.PDFWorker({ port: this.worker })
      const loadingTask = this.loadingTask = pdfjs.getDocument({
        url: this.urlValue, worker: this.pdfWorker,
        cMapUrl: `${this.assetsUrlValue}cmaps/`, cMapPacked: true,
        standardFontDataUrl: `${this.assetsUrlValue}standard_fonts/`,
        wasmUrl: `${this.assetsUrlValue}wasm/`, iccUrl: `${this.assetsUrlValue}iccs/`,
        isEvalSupported: false, enableXfa: false
      })
      const pdf = await loadingTask.promise
      if (!this.current(session)) return
      this.pdf = pdf
      const template = this.containerTarget.firstElementChild.cloneNode(true)
      this.containerTarget.replaceChildren()
      for (let number = 1; number <= pdf.numPages; number++) {
        const page = await pdf.getPage(number)
        if (!this.current(session)) return
        const sheet = template.cloneNode(true)
        sheet.dataset.pageNumber = number
        sheet.setAttribute("aria-label", `教材PDFの${number}ページ目`)
        sheet.querySelector(".pdf-preview-page-number").textContent = `${number}ページ目`
        const canvas = sheet.querySelector('[data-pdf-preview-target="canvas"]')
        canvas.hidden = true
        canvas.setAttribute("aria-label", `教材PDFの${number}ページ目`)
        const inkCanvas = sheet.querySelector('[data-pdf-preview-target="ink"]')
        inkCanvas.hidden = true
        inkCanvas.setAttribute("aria-label", `${number}ページ目のペン・消しゴム領域`)
        const ink = new PdfInk(inkCanvas, number)
        ink.setTool(this.tool)
        ink.setEraserSize(this.eraserSize)
        const cursor = sheet.querySelector(".pdf-preview-eraser-cursor")
        const state = { page, canvas, inkCanvas, ink, sheet, cursor }
        this.pageStates.push(state)
        this.statesByCanvas.set(inkCanvas, state)
        this.containerTarget.append(sheet)
      }
      this.pagesReady = true
      this.layoutPages()
      this.intersections = new IntersectionObserver(() => this.queueRender(), { rootMargin: "200px 0px" })
      for (const state of this.pageStates) this.intersections.observe(state.sheet)
      await this.queueRender()
      if (!this.current(session)) return
      let observedWidth = this.pageStates[0]?.renderedWidth
      this.observer = new ResizeObserver(() => {
        const width = this.containerTarget.clientWidth
        if (width !== observedWidth) {
          observedWidth = width
          this.scheduleRender()
        }
      })
      this.observer.observe(this.containerTarget)
    } catch {
      if (this.current(session)) this.fail()
    }
  }

  scheduleRender() {
    if (!this.active) return
    // Invalidate a running render immediately; coalesce resize bursts before restarting.
    this.revision++
    window.clearTimeout(this.resizeTimer)
    this.resizeTimer = window.setTimeout(() => this.queueRender(), 100)
  }

  queueRender() {
    const session = this.session
    this.revision++
    this.renderQueue = this.renderQueue.then(() => this.renderPages(session))
      .catch(() => { if (this.current(session)) this.fail() })
    return this.renderQueue
  }

  layoutPages() {
    const width = this.containerTarget.clientWidth
    if (!width) return
    for (const state of this.pageStates) {
      const original = state.page.getViewport({ scale: 1 })
      state.viewport = state.page.getViewport({ scale: width / original.width })
      state.sheet.querySelector(".pdf-preview-page").style.height = `${state.viewport.height}px`
    }
  }

  releasePage(state) {
    if (state === this.inputState || state === this.touch?.state) this.finishInput()
    state.canvas.hidden = state.inkCanvas.hidden = true
    state.cursor.hidden = true
    state.canvas.width = state.canvas.height = state.inkCanvas.width = state.inkCanvas.height = 0
    state.renderedWidth = state.renderedDpr = null
    state.page.cleanup()
  }

  async renderPages(session) {
    if (!this.current(session) || !this.pagesReady || !this.pageStates.length) return
    const revision = this.revision
    const width = this.containerTarget.clientWidth
    const dpr = window.devicePixelRatio || 1
    if (!width) return
    this.layoutPages()
    const height = window.innerHeight
    const wanted = this.pageStates.filter(state => {
      const rect = state.sheet.getBoundingClientRect()
      return rect.bottom > -200 && rect.top < height + 200
    })
    // The visible page is drawn before nearby pages. Page count no longer reduces quality.
    wanted.sort((a, b) => {
      const overlap = state => { const r = state.sheet.getBoundingClientRect(); return Math.max(0, Math.min(r.bottom, height) - Math.max(r.top, 0)) }
      return overlap(b) - overlap(a)
    })
    for (const state of this.pageStates) {
      if (!wanted.includes(state) && state.canvas.width) this.releasePage(state)
    }
    this.containerTarget.setAttribute("aria-busy", "true")
    for (const state of wanted) {
      if (!this.current(session) || revision !== this.revision) return
      const viewport = state.viewport
      const ratio = Math.min(dpr, 2, Math.sqrt(Math.min(8_000_000, 16_000_000 / wanted.length) /
        (viewport.width * viewport.height)))
      if (state.renderedWidth === width && state.renderedDpr === dpr && state.ratio === ratio) continue
      if (state === this.inputState) this.finishInput()
      const { canvas, inkCanvas } = state
      canvas.hidden = inkCanvas.hidden = true
      canvas.width = Math.ceil(viewport.width * ratio)
      canvas.height = Math.ceil(viewport.height * ratio)
      canvas.style.height = `${viewport.height}px`
      state.renderTask = state.page.render({
        canvasContext: canvas.getContext("2d"), viewport,
        transform: [canvas.width / viewport.width, 0, 0, canvas.height / viewport.height, 0, 0]
      })
      await state.renderTask.promise
      if (!this.current(session) || revision !== this.revision) return
      state.ink.setViewport(viewport, ratio)
      state.renderedWidth = width
      state.renderedDpr = dpr
      state.ratio = ratio
      canvas.hidden = inkCanvas.hidden = false
      this.updateCursor(state)
    }
    if (!this.current(session) || revision !== this.revision) return
    this.containerTarget.setAttribute("aria-busy", "false")
    this.statusTarget.textContent = this.pdf.numPages === 1 ? "1ページ目を表示しています。" : `${this.pdf.numPages}ページを表示しています。`
  }

  selectTool(event) {
    if (!["pen", "eraser"].includes(event.params.tool)) return
    this.finishInput()
    this.tool = event.params.tool
    for (const state of this.pageStates) state.ink.setTool(this.tool)
    this.updateTool()
  }

  selectSize(event) {
    if (!["small", "medium", "large"].includes(event.params.size)) return
    this.finishInput()
    this.eraserSize = event.params.size
    for (const state of this.pageStates) state.ink.setEraserSize(this.eraserSize)
    this.updateTool()
  }

  updateTool() {
    this.sizesTarget.hidden = this.tool !== "eraser"
    for (const button of this.sizeTargets) {
      button.setAttribute("aria-pressed", String(button.dataset.pdfPreviewSizeParam === this.eraserSize))
    }
    for (const button of this.toolTargets) {
      button.setAttribute("aria-pressed", String(button.dataset.pdfPreviewToolParam === this.tool))
    }
    for (const state of this.pageStates) this.updateCursor(state)
  }

  updateCursor(state) {
    state.inkCanvas.style.cursor = "crosshair"
    state.cursor.hidden = true
    if (this.tool !== "eraser" || !state.ink.viewport) return
    const viewport = state.ink.viewport
    const diameter = state.ink.eraserWidth * Math.hypot(viewport.transform[0], viewport.transform[1]) *
      state.inkCanvas.getBoundingClientRect().width / viewport.width
    state.inkCanvas.style.cursor = "none"
    state.cursor.style.width = state.cursor.style.height = `${diameter}px`
  }

  showCursor(event) {
    const state = this.statesByCanvas.get(event.currentTarget)
    if (!state) return
    this.updateCursor(state)
    state.cursor.hidden = this.tool !== "eraser" || event.pointerType === "touch" || state.inkCanvas.hidden
    const rect = state.inkCanvas.getBoundingClientRect()
    state.cursor.style.left = `${event.clientX - rect.left}px`
    state.cursor.style.top = `${event.clientY - rect.top}px`
  }

  hideCursor(event) {
    const state = this.statesByCanvas.get(event.currentTarget)
    if (state) state.cursor.hidden = true
  }

  pointerDown(event) {
    this.showCursor(event)
    const state = this.statesByCanvas.get(event.currentTarget)
    if (!state || state.inkCanvas.hidden) return
    if (event.pointerType === "touch") {
      if (!this.inputState && !this.touch) {
        this.touch = { id: event.pointerId, y: event.clientY, state }
        state.inkCanvas.setPointerCapture(event.pointerId)
      }
      return
    }
    if (event.button !== 0 || !["mouse", "pen"].includes(event.pointerType)) return
    if (this.inputState || state.renderedWidth !== this.containerTarget.clientWidth || state.renderedDpr !== (window.devicePixelRatio || 1)) return
    this.finishInput()
    if (state.ink.start(event)) {
      this.inputState = state
      event.preventDefault()
      state.inkCanvas.setPointerCapture(event.pointerId)
    }
  }

  pointerMove(event) {
    this.showCursor(event)
    if (event.pointerId === this.touch?.id) {
      window.scrollBy(0, this.touch.y - event.clientY)
      this.touch.y = event.clientY
      return
    }
    const state = this.inputState
    if (!state || state.inkCanvas !== event.currentTarget) return
    state.ink.move(event)
    if (!state.ink.stroke) { this.finishInput(); return }
    if (!this.inkFrame) {
      this.inkFrame = window.requestAnimationFrame(() => {
        this.inkFrame = null
        if (this.active) state.ink.redraw()
      })
    }
  }

  scrolled() {
    // A wheel/trackpad scroll must not extend a held pen stroke as the page moves.
    // Finger scrolling has no inputState and keeps its own pointer capture.
    if (this.inputState) this.finishInput()
  }

  pointerEnd(event) {
    const state = this.statesByCanvas.get(event.currentTarget)
    if (!state) return
    const drawing = state === this.inputState && event.pointerId === state.ink.pointerId
    state.ink.end(event)
    if (drawing) this.inputState = null
    if (event.pointerId === this.touch?.id) this.touch = null
    if (state.inkCanvas.hasPointerCapture(event.pointerId)) state.inkCanvas.releasePointerCapture(event.pointerId)
  }

  finishInput() {
    window.cancelAnimationFrame(this.inkFrame)
    this.inkFrame = null
    const state = this.inputState
    const pointerId = state?.ink.pointerId
    const touch = this.touch
    this.inputState = null
    this.touch = null
    state?.ink.end()
    if (pointerId != null && state.inkCanvas.hasPointerCapture(pointerId)) state.inkCanvas.releasePointerCapture(pointerId)
    if (touch && touch.state.inkCanvas.hasPointerCapture(touch.id)) touch.state.inkCanvas.releasePointerCapture(touch.id)
  }

  fail() {
    if (!this.active) return
    this.statusTarget.setAttribute("role", "alert")
    this.statusTarget.textContent = "問題を表示できませんでした。通信状態を確認して、ページを再読み込みしてください。"
    for (const state of this.pageStates) state.canvas.hidden = state.inkCanvas.hidden = true
    this.containerTarget.setAttribute("aria-busy", "false")
    this.disconnect()
  }

  disconnect() {
    this.active = false
    this.resolutionQuery?.removeEventListener("change", this.resolutionChanged)
    this.finishInput()
    window.clearTimeout(this.resizeTimer)
    this.observer?.disconnect()
    this.intersections?.disconnect()
    for (const state of this.pageStates) {
      state.renderTask?.cancel()
      state.canvas.width = state.canvas.height = state.inkCanvas.width = state.inkCanvas.height = 0
      state.page.cleanup()
    }
    this.loadingTask?.destroy().catch(() => {})
    this.pdfWorker?.destroy()
    this.worker?.terminate()
  }
}
