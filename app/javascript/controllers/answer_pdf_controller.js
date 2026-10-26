import { Controller } from "@hotwired/stimulus"

// Read-only answers. Keep native plug-in lifecycle separate from ink editing.
export default class extends Controller {
  static targets = ["status", "pages", "pagination", "page"]
  static values = { url: String, assetsUrl: String }

  connect() {
    this.active = true
    this.session = Symbol()
    this.revision = 0
    this.pageNumber = 1
    this.queue = Promise.resolve()
    this.load(this.session)
  }

  current(session) {
    return this.active && session === this.session
  }

  async load(session) {
    try {
      const pdfjs = await import("pdfjs")
      if (!this.current(session)) return
      this.worker = new Worker(`${this.assetsUrlValue}pdf.worker.min.mjs`, { type: "module" })
      this.worker.addEventListener("error", () => { if (this.current(session)) this.fail() })
      this.pdfWorker = new pdfjs.PDFWorker({ port: this.worker })
      this.loadingTask = pdfjs.getDocument({
        url: this.urlValue, worker: this.pdfWorker,
        cMapUrl: `${this.assetsUrlValue}cmaps/`, cMapPacked: true,
        standardFontDataUrl: `${this.assetsUrlValue}standard_fonts/`,
        wasmUrl: `${this.assetsUrlValue}wasm/`, iccUrl: `${this.assetsUrlValue}iccs/`,
        isEvalSupported: false, enableXfa: false
      })
      const pdf = await this.loadingTask.promise
      if (!this.current(session)) return
      this.pdf = pdf
      this.pageTarget.replaceChildren()
      for (let number = 1; number <= pdf.numPages; number++) {
        const option = document.createElement("option")
        option.value = number
        option.textContent = `${number} / ${pdf.numPages}`
        this.pageTarget.append(option)
      }
      this.paginationTarget.hidden = pdf.numPages <= 1
      this.pageTarget.disabled = false
      let width
      this.observer = new ResizeObserver(() => {
        if (!this.current(session)) return
        const next = this.pagesTarget.clientWidth
        if (next > 0 && next !== width) {
          width = next
          this.scheduleRender()
        }
      })
      this.observer.observe(this.pagesTarget)
    } catch {
      if (this.current(session)) this.fail()
    }
  }

  changePage() {
    const number = Number(this.pageTarget.value)
    if (!Number.isInteger(number) || number < 1 || number > this.pdf.numPages) return
    this.pageNumber = number
    this.scheduleRender()
  }

  scheduleRender() {
    this.statusTarget.textContent = "答案PDFを読み込んでいます。"
    const session = this.session
    const revision = ++this.revision
    this.renderTask?.cancel()
    this.queue = this.queue.catch(() => {}).then(() => this.render(session, revision))
      .catch(() => { if (this.current(session) && revision === this.revision) this.fail() })
  }

  async render(session, revision) {
    if (!this.current(session) || revision !== this.revision) return
    this.pagesTarget.replaceChildren()
    const number = this.pageNumber
    const page = await this.pdf.getPage(number)
    if (!this.current(session) || revision !== this.revision) return
    const original = page.getViewport({ scale: 1 })
    const width = Math.min(this.pagesTarget.clientWidth, 1200)
    const scale = width / original.width
    const ratio = Math.min(window.devicePixelRatio || 1, 2)
    const viewport = page.getViewport({ scale: scale * ratio })
    const canvas = document.createElement("canvas")
    canvas.width = Math.ceil(viewport.width)
    canvas.height = Math.ceil(viewport.height)
    canvas.setAttribute("role", "img")
    canvas.setAttribute("aria-label", `答案PDF ${number} / ${this.pdf.numPages}ページ`)
    this.pagesTarget.append(canvas)
    this.renderTask = page.render({ canvasContext: canvas.getContext("2d"), viewport })
    try {
      await this.renderTask.promise
    } finally {
      page.cleanup()
    }
    if (!this.current(session) || revision !== this.revision) return
    canvas.dataset.rendered = "true"
    this.statusTarget.textContent = `答案PDFを表示しました（${number} / ${this.pdf.numPages}ページ）。`
  }

  fail() {
    this.statusTarget.textContent = "答案PDFを表示できませんでした。時間をおいて画面を再読み込みしてください。"
  }

  disconnect() {
    this.active = false
    this.revision++
    this.observer?.disconnect()
    this.renderTask?.cancel()
    this.loadingTask?.destroy().catch(() => {})
    this.pdfWorker?.destroy()
    this.worker?.terminate()
    for (const canvas of this.pagesTarget.querySelectorAll("canvas")) canvas.width = canvas.height = 0
  }
}
