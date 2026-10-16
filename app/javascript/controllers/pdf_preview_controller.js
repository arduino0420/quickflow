import { Controller } from "@hotwired/stimulus"

// A1: display only. The material URL remains protected by the existing student controller.
export default class extends Controller {
  static targets = ["status", "container", "canvas"]
  static values = { url: String, assetsUrl: String }

  connect() {
    this.active = true
    this.load()
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
    if (!this.active) return
    const width = this.containerTarget.clientWidth
    if (!width || width === this.renderedWidth) return
    const original = this.page.getViewport({ scale: 1 })
    const viewport = this.page.getViewport({ scale: width / original.width })
    // Bound backing-store memory on high-DPI / very large displays.
    const ratio = Math.min(window.devicePixelRatio || 1, 2,
      Math.sqrt(8_000_000 / (viewport.width * viewport.height)))
    const canvas = this.canvasTarget
    canvas.hidden = true
    canvas.width = Math.ceil(viewport.width * ratio)
    canvas.height = Math.ceil(viewport.height * ratio)
    this.renderTask = this.page.render({
      canvasContext: canvas.getContext("2d"), viewport,
      transform: [ratio, 0, 0, ratio, 0, 0]
    })
    await this.renderTask.promise
    if (!this.active) return
    this.renderedWidth = width
    canvas.hidden = false
    this.containerTarget.setAttribute("aria-busy", "false")
    this.statusTarget.textContent = "1ページ目を表示しています。"
  }

  fail() {
    if (!this.active) return
    this.statusTarget.setAttribute("role", "alert")
    this.statusTarget.textContent = "問題を表示できませんでした。通信状態を確認して、ページを再読み込みしてください。"
    this.canvasTarget.hidden = true
    this.containerTarget.setAttribute("aria-busy", "false")
    this.disconnect()
  }

  disconnect() {
    this.active = false
    window.clearTimeout(this.resizeTimer)
    this.observer?.disconnect()
    this.renderTask?.cancel()
    this.loadingTask?.destroy().catch(() => {})
    this.pdfWorker?.destroy()
    this.worker?.terminate()
  }
}
