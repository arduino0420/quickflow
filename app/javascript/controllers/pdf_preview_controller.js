import { Controller } from "@hotwired/stimulus"
import PdfInk from "pdf_ink"
import PdfInputDiagnostics from "controllers/pdf_input_diagnostics"
import PdfDraft from "pdf_draft"
import { snapshotPages, generateAnswerPdf } from "pdf_export"

// One document/worker, independent ink per page, sequential PDF rendering.
export default class extends Controller {
  static targets = ["status", "container", "canvas", "ink", "tool", "sizes", "size", "draftStatus", "retry", "submit", "submitStatus",
    "diagnostics", "diagnosticSummary", "diagnosticEvents"]
  static values = { url: String, assetsUrl: String, assignmentId: Number, draftUrl: String, draftContext: String, submissionUrl: String }

  connect() {
    this.previousTurboSetting = document.documentElement.getAttribute("data-turbo")
    document.documentElement.setAttribute("data-turbo", "false")
    this.exporting = false
    this.draftEditable = false
    this.sourceBytes = null
    this.submissionAttempt = null
    this.submissionConfirmed = false
    this.active = true
    this.session = Symbol()
    this.pageStates = []
    this.pagesReady = false
    this.statesByCanvas = new WeakMap()
    this.touchIds = new Set()
    this.multiTouch = false
    this.tool = "pen"
    this.eraserSize = "medium"
    this.revision = 0
    this.renderQueue = Promise.resolve()
    this.updateTool()
    this.watchPixelRatio()
    if (window.location.hash === "#pdf-input-diagnostics") this.startInputDiagnostics()
    this.load(this.session)
  }

  inkTargetConnected(canvas) {
    this.inkTouchListeners ||= new Map()
    if (this.inkTouchListeners.has(canvas)) return
    const listener = event => this.preventStylusGesture(event)
    this.inkTouchListeners.set(canvas, listener)
    for (const type of ["touchstart", "touchend"]) {
      canvas.addEventListener(type, listener, { passive: false })
    }
  }

  inkTargetDisconnected(canvas) {
    const listener = this.inkTouchListeners?.get(canvas)
    if (!listener) return
    for (const type of ["touchstart", "touchend"]) canvas.removeEventListener(type, listener)
    this.inkTouchListeners.delete(canvas)
  }

  preventStylusGesture(event) {
    // Unknown touch types and finger gestures retain their native behavior.
    if (!event.cancelable || event.changedTouches.length !== 1 ||
        event.changedTouches[0].touchType !== "stylus") return
    if (event.type === "touchstart") {
      if (event.touches.length !== 1 || event.touches[0].touchType !== "stylus" ||
          event.touches[0].identifier !== event.changedTouches[0].identifier) return
    } else if (event.type !== "touchend" || event.touches.length !== 0) return
    event.preventDefault()
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
        const canvas = sheet.querySelector('[data-pdf-preview-target="canvas"]')
        canvas.hidden = true
        canvas.setAttribute("aria-label", `教材PDFの${number}ページ目`)
        const inkCanvas = sheet.querySelector('[data-pdf-preview-target="ink"]')
        inkCanvas.hidden = true
        inkCanvas.setAttribute("aria-label", `${number}ページ目のペン・消しゴム領域`)
        const ink = new PdfInk(inkCanvas, number, { cache: true })
        ink.onChange = () => this.draft?.changed()
        ink.setTool(this.tool)
        ink.setEraserSize(this.eraserSize)
        const cursor = sheet.querySelector(".pdf-preview-eraser-cursor")
        const state = { page, canvas, inkCanvas, ink, sheet, cursor }
        this.pageStates.push(state)
        this.statesByCanvas.set(inkCanvas, state)
        this.containerTarget.append(sheet)
      }
      await this.restoreDraft(session)
      if (!this.current(session)) return
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
    state.ink.releaseCache()
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
      // Budget includes the PDF, visible ink and completed-ink cache bitmaps.
      const ratio = Math.min(dpr, 2, Math.sqrt(Math.min(8_000_000, 32_000_000 / (3 * wanted.length)) /
        (viewport.width * viewport.height)))
      if (state.renderedWidth === width && state.renderedDpr === dpr && state.ratio === ratio) continue
      if (state === this.inputState) this.finishInput()
      const { canvas, inkCanvas } = state
      this.inputDiagnostics?.record("controller", null, "pdf-render-start")
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
      this.inputDiagnostics?.record("controller", null, "pdf-render-end")
      this.updateCursor(state)
    }
    if (!this.current(session) || revision !== this.revision) return
    this.containerTarget.setAttribute("aria-busy", "false")
    this.statusTarget.textContent = ""
    this.statusTarget.hidden = true
    if (this.hasSubmitTarget) this.submitTarget.disabled = this.exporting || !this.draft?.ready || !this.draft?.allowed || this.draft?.blocked
  }

  selectTool(event) {
    if (this.exporting) return
    if (!["pen", "eraser"].includes(event.params.tool)) return
    this.finishInput()
    this.tool = event.params.tool
    for (const state of this.pageStates) state.ink.setTool(this.tool)
    this.updateTool()
  }

  selectSize(event) {
    if (this.exporting) return
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

  preventPageSelection(event) {
    event.preventDefault()
  }

  startInputDiagnostics() {
    this.stopInputDiagnostics()
    this.inputDiagnostics = new PdfInputDiagnostics(this)
    if (this.hasDiagnosticsTarget) {
      this.diagnosticsTarget.hidden = false
      this.refreshInputDiagnostics()
      this.diagnosticTimer = window.setInterval(() => this.refreshInputDiagnostics(), 250)
    }
  }

  stopInputDiagnostics() {
    if (this.diagnosticTimer != null) window.clearInterval(this.diagnosticTimer)
    this.diagnosticTimer = null
    this.inputDiagnostics?.stop()
    this.inputDiagnostics = null
    if (this.hasDiagnosticsTarget) this.diagnosticsTarget.hidden = true
  }

  resetInputDiagnostics() {
    this.inputDiagnostics?.reset()
    this.refreshInputDiagnostics()
  }

  refreshInputDiagnostics() {
    const diagnostics = this.inputDiagnostics
    if (!diagnostics?.dirty || !this.hasDiagnosticsTarget) return
    diagnostics.dirty = false
    const s = diagnostics.summary()
    const sources = ["window", "document", "controller"]
    const counts = key => sources.map(source => s.pen[source][key]).join("/")
    const latest = s.recent.at(-1)
    const active = this.inputState
    this.diagnosticSummaryTarget.textContent = [
      `ペンdown W/D/C: ${counts("pointerdown")}（W=window D=document C=controller）`,
      `筆記領域内: ${counts("inkDown")} / 領域外: ${sources.map(source => s.pen[source].pointerdown - s.pen[source].inkDown).join("/")}`,
      `開始: ${s.accepted} / イベントによる終了: ${s.ended} / 拒否: ${s.rejected}`,
      `拒否理由: ${Object.entries(s.reasons).map(([reason, count]) => `${reason}=${count}`).join(", ") || "なし"}`,
      `up W/D/C: ${counts("pointerup")} / cancel: ${counts("pointercancel")} / capture失効: ${counts("lostpointercapture")}`,
      `touch start/end/cancel: ${s.touch.touchstart}/${s.touch.touchend}/${s.touch.touchcancel}`,
      `直近up→down: ${s.lastGap == null ? "未計測" : `${Math.round(s.lastGap)}ms`}`,
      `状態: 入力=${!!active} 筆跡=${!!active?.ink.stroke} 保存中=${!!this.draft?.saving} ピンチ=${!!this.multiTouch}`,
      `直近: ${latest?.reason || "待機中"}（${latest?.type || "－"} / ${latest?.pointerType || "－"} / id=${latest?.pointerId ?? "－"}）`
    ].join("\n")
    this.diagnosticEventsTarget.textContent = s.recent.map(row =>
      `${Math.round(row.elapsedMs)}ms t=${row.eventTimeMs ?? "－"} #${row.eventId ?? "－"} ${row.source} ${row.type || "－"} ${row.pointerType || "－"}:${row.pointerId ?? "－"} ${row.target || "－"} ${row.reason} input=${row.inputActive} activeId=${row.activePointerId ?? "－"} stroke=${row.activeStroke} targetStroke=${row.targetStroke} captured=${row.captured} touch=${row.touches ?? "－"}`
    ).join("\n") || "イベント待機中"
  }

  pointerDown(event) {
    this.inputDiagnostics?.record("controller", event, "down-enter")
    if (this.exporting) { this.inputDiagnostics?.record("controller", event, "exporting"); return }
    this.showCursor(event)
    const state = this.statesByCanvas.get(event.currentTarget)
    if (!state || state.inkCanvas.hidden) {
      this.inputDiagnostics?.record("controller", event, state ? "canvas-hidden" : "unknown-canvas")
      return
    }
    if (event.pointerType === "touch") {
      this.touchIds ||= new Set()
      this.touchIds.add(event.pointerId)
      if (this.touchIds.size > 1) {
        this.multiTouch = true
        this.finishInput()
        this.inputDiagnostics?.record("controller", event, "pinch-delegated")
        return
      }
      if (!this.multiTouch && !this.inputState && !this.touch) {
        this.touch = { id: event.pointerId, y: event.clientY, state }
        state.inkCanvas.setPointerCapture(event.pointerId)
        this.inputDiagnostics?.record("controller", event, "touch-scroll-started")
      } else {
        this.inputDiagnostics?.record("controller", event, "touch-busy")
      }
      return
    }
    if (event.button !== 0 || !["mouse", "pen"].includes(event.pointerType)) {
      this.inputDiagnostics?.record("controller", event, "unsupported-input")
      return
    }
    // Keep native selection out of the ink surface even while drawing is unavailable.
    if (event.cancelable) event.preventDefault()
    if (this.multiTouch) { this.inputDiagnostics?.record("controller", event, "pinch-active"); return }
    if (!this.draftEditable) { this.inputDiagnostics?.record("controller", event, "draft-not-editable"); return }
    if (this.inputState || state.renderedWidth !== this.containerTarget.clientWidth || state.renderedDpr !== (window.devicePixelRatio || 1)) {
      this.inputDiagnostics?.record("controller", event, this.inputState ? "input-busy" : "viewport-mismatch")
      return
    }
    this.finishInput()
    if (state.ink.start(event)) {
      this.inputState = state
      this.inputDiagnostics?.record("controller", event, "stroke-accepted")
      this.showDraftStatus(this.draft?.failed ? this.draft.failureMessage : "未保存",
        !!this.draft?.failed && !this.draft.blocked && !this.draft.saveBlocked)
      state.inkCanvas.setPointerCapture(event.pointerId)
      this.inputDiagnostics?.record("controller", event, "stroke-started")
    } else {
      this.inputDiagnostics?.record("controller", event, "ink-start-rejected")
    }
  }

  pointerMove(event) {
    this.inputDiagnostics?.record("controller", event, "move-enter")
    if (this.exporting) { this.inputDiagnostics?.record("controller", event, "exporting"); return }
    this.showCursor(event)
    if (!this.multiTouch && event.pointerId === this.touch?.id) {
      window.scrollBy(0, this.touch.y - event.clientY)
      this.touch.y = event.clientY
      this.inputDiagnostics?.record("controller", event, "touch-scrolled")
      return
    }
    const state = this.inputState
    if (!state || state.inkCanvas !== event.currentTarget || event.pointerId !== state.ink.pointerId) {
      this.inputDiagnostics?.record("controller", event, !state ? "no-active-input" : "different-pointer-or-canvas")
      return
    }
    if (event.cancelable) event.preventDefault()
    state.ink.move(event)
    if (!state.ink.stroke) {
      this.inputDiagnostics?.record("controller", event, "ink-ended-during-move")
      this.finishInput()
      return
    }
    this.inputDiagnostics?.record("controller", event, "stroke-moved")
    if (!this.inkFrame) {
      this.inkFrame = window.requestAnimationFrame(() => {
        this.inkFrame = null
        if (this.active) state.ink.redraw()
      })
    }
  }

  scrolled() {
    this.inputDiagnostics?.record("controller", null, "window-scrolled")
    // A wheel/trackpad scroll must not extend a held pen stroke as the page moves.
    // Finger scrolling has no inputState and keeps its own pointer capture.
    if (this.inputState) this.finishInput()
  }

  pointerEnd(event) {
    this.inputDiagnostics?.record("controller", event, "end-enter")
    const state = this.statesByCanvas.get(event.currentTarget)
    if (!state) { this.inputDiagnostics?.record("controller", event, "unknown-canvas"); return }
    const drawing = state === this.inputState && event.pointerId === state.ink.pointerId
    if (event.pointerType === "touch") {
      this.touchIds?.delete(event.pointerId)
      if (!this.touchIds?.size) this.multiTouch = false
    }
    if (drawing) {
      window.cancelAnimationFrame(this.inkFrame)
      this.inkFrame = null
    }
    state.ink.end(event)
    if (drawing) this.inputState = null
    if (event.pointerId === this.touch?.id) this.touch = null
    if (state.inkCanvas.hasPointerCapture(event.pointerId)) state.inkCanvas.releasePointerCapture(event.pointerId)
    this.inputDiagnostics?.record("controller", event, drawing ? "stroke-ended" : "end-without-matching-stroke")
  }

  finishInput(event) {
    this.inputDiagnostics?.record("controller", null, event?.type === "blur" ? "window-blurred" : "finish-input-enter")
    if (event?.type === "blur" || !this.multiTouch) {
      this.touchIds?.clear()
      this.multiTouch = false
    }
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
    this.inputDiagnostics?.record("controller", null, "finish-input-exit")
  }

  fail() {
    if (!this.active) return
    this.statusTarget.hidden = false
    this.statusTarget.setAttribute("role", "alert")
    this.statusTarget.textContent = "問題を表示できませんでした。通信状態を確認して、ページを再読み込みしてください。"
    for (const state of this.pageStates) state.canvas.hidden = state.inkCanvas.hidden = true
    this.containerTarget.setAttribute("aria-busy", "false")
    this.disconnect()
  }

  async restoreDraft(session) {
    this.draft = new PdfDraft({ url: this.draftUrlValue, context: this.draftContextValue,
      read: () => ({ format_version: 1, pages: this.pageStates.map((state, index) => ({
        page_number: index + 1,
        operations: state.ink.pages.get(index + 1).filter(operation => operation !== state.ink.stroke)
      })) }),
      restore: draft => {
        if (draft.format_version !== 1 || !Array.isArray(draft.pages) || draft.pages.length !== this.pageStates.length) throw new Error("invalid draft")
        // Validate the whole restored snapshot before changing any page.
        draft.pages.forEach((data, index) => {
          const view = this.pageStates[index].page.view
          if (data.page_number !== index + 1 || !Array.isArray(data.operations)) throw new Error("invalid page")
          for (const operation of data.operations) {
            if (!Number.isSafeInteger(operation.id) || !["pen", "eraser"].includes(operation.tool) ||
                operation.color !== "#000000" || !Array.isArray(operation.points) || !operation.points.length ||
                !(operation.tool === "pen" ? [1.2] : [4, 8, 12, 18]).includes(operation.width)) throw new Error("invalid operation")
            for (const point of operation.points) {
              if (!Array.isArray(point) || point.length !== 2 || !point.every(Number.isFinite) ||
                  point[0] < view[0] - 0.01 || point[0] > view[2] + 0.01 ||
                  point[1] < view[1] - 0.01 || point[1] > view[3] + 0.01) throw new Error("invalid coordinates")
            }
          }
        })
        draft.pages.forEach((data, index) => {
          const ink = this.pageStates[index].ink
          ink.pages.set(index + 1, structuredClone(data.operations))
          ink.nextOperationId = data.operations.reduce((maximum, operation) => Math.max(maximum, operation.id + 1), 1)
          if (ink.viewport) ink.redraw()
        })
      },
      status: (message, retry = false) => {
        if (!this.current(session)) return
        this.showDraftStatus(message === "保存済み" && this.inputState?.ink.stroke ? "未保存" : message, retry)
      },
      editable: value => {
        if (!this.current(session)) return
        this.draftEditable = value
        if (this.hasSubmitTarget) this.submitTarget.disabled = this.exporting || !this.pagesReady || !value
        if (!value) this.finishInput()
      }
    })
    await this.draft.start()
  }

  showDraftStatus(message, retry = false) {
    this.draftStatusTarget.textContent = message
    this.draftStatusTarget.classList.toggle("pdf-preview-status-quiet", ["未保存", "保存中…", "保存済み"].includes(message))
    this.retryTarget.hidden = !retry
  }

  async retryDraft() {
    await this.draft?.retry()
    if (this.active) this.queueRender()
  }

  warnUnsaved(event) {
    this.finishInput()
    if (this.draft?.dirty && !this.submissionConfirmed) { event.preventDefault(); event.returnValue = "" }
  }

  confirmLeave(event) {
    this.finishInput()
    if (this.draft?.dirty && !this.submissionConfirmed && !window.confirm("保存が完了していない手書きがあります。このまま移動すると失われる可能性があります。移動しますか？")) event.preventDefault()
  }

  async submissionState(options = {}) {
    const response = await fetch(this.submissionUrlValue, {
      credentials: "same-origin", cache: "no-store", redirect: "error", signal: AbortSignal.timeout(30_000),
      headers: { "Accept": "application/json", "X-Draft-Context": this.draftContextValue,
        "X-Handwritten-Submission": "1", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
      ...options
    })
    if (!response.ok) {
      const error = new Error("submission failed")
      error.code = response.status
      throw error
    }
    return response.json()
  }

  async submitAnswer() {
    if (this.exporting || !this.active || !this.pagesReady || !this.pdf ||
        !this.draft?.ready || !this.draft.allowed || this.draft.blocked) return
    this.finishInput()
    this.exporting = true
    const session = this.session
    this.submitTarget.disabled = true
    for (const button of [...this.toolTargets, ...this.sizeTargets]) button.disabled = true
    const status = this.submitStatusTarget
    status.setAttribute("role", "status")
    status.textContent = "提出状況を確認しています…"
    try {
      // Reconcile a successful POST whose response was lost before attempting another upload.
      let result = await this.submissionState()
      if (!this.current(session)) return
      if (result.submitted && (!this.submissionAttempt ||
          result.submission_token !== this.submissionAttempt.token ||
          this.draft.revision !== this.submissionAttempt.revision)) {
        const error = new Error("another submission exists")
        error.code = 409
        throw error
      }
      if (!result.submitted) {
        status.textContent = "答案を準備しています…"
        const version = await this.draft.prepareSubmission()
        if (!this.current(session)) return
        if (!this.submissionAttempt || this.submissionAttempt.revision !== this.draft.revision) {
          const pages = snapshotPages(this.pageStates)
          this.sourceBytes ||= await this.pdf.getData()
          const bytes = await generateAnswerPdf({ source: this.sourceBytes, pages, current: () => this.current(session) })
          this.submissionAttempt = { token: crypto.randomUUID(), revision: this.draft.revision, bytes }
        }
        if (!this.current(session)) return
        if (this.submissionAttempt.bytes.length > 25 * 1024 * 1024) {
          const error = new Error("PDF too large"); error.code = 413; throw error
        }
        const body = new FormData()
        body.append("submission[answer_file]", new Blob([this.submissionAttempt.bytes], { type: "application/pdf" }), "answer.pdf")
        body.append("draft_version", version === null ? "" : String(version))
        body.append("submission_token", this.submissionAttempt.token)
        status.textContent = "提出しています…"
        try {
          result = await this.submissionState({ method: "POST", body })
        } catch (error) {
          // A 409 must remain a conflict even if another tab has since submitted.
          if (error.code) throw error
          result = await this.submissionState()
          if (!result.submitted) throw error
        }
      }
      if (!this.current(session) || !result.submitted) throw new Error("not submitted")
      if (!this.submissionAttempt || result.submission_token !== this.submissionAttempt.token ||
          this.draft.revision !== this.submissionAttempt.revision) {
        const error = new Error("another submission exists"); error.code = 409; throw error
      }
      this.submissionConfirmed = true
      this.draft.allowed = this.draftEditable = false
      this.draft.stop()
      status.textContent = result.alert || "提出が完了しました。"
      window.location.assign(result.location)
    } catch (error) {
      if (this.current(session)) {
        status.setAttribute("role", "alert")
        status.textContent = error.code === 409 ?
          "教材または下書きが変更されています。提出を停止しました。手書きが残るこの画面を閉じず、先生に確認してください。" :
          [401, 403, 404].includes(error.code) ?
            "ログイン状態または小テストの利用権限を確認できません。手書きが残るこの画面を閉じず、先生に確認してください。" :
          error.code === 413 ?
            "PDFのサイズが上限を超えています。手書きと下書きは残っています。ページ数を減らすか先生に確認してください。" :
            "提出できませんでした。手書きはこの画面に残っています。保存状況と接続を確認して、もう一度お試しください。"
        if ([401, 403, 409, 404].includes(error.code)) {
          this.draft.blocked = true
          this.draftEditable = false
        }
      }
    } finally {
      this.draft?.finishSubmission()
      this.exporting = false
      if (this.current(session)) {
        this.submitTarget.disabled = !this.draft.allowed || this.draft.blocked
        for (const button of [...this.toolTargets, ...this.sizeTargets]) button.disabled = false
      }
    }
  }

  disconnect() {
    for (const canvas of this.inkTouchListeners?.keys() || []) this.inkTargetDisconnected(canvas)
    this.stopInputDiagnostics()
    this.touchIds?.clear()
    this.multiTouch = false
    if (this.previousTurboSetting === null) document.documentElement.removeAttribute("data-turbo")
    else document.documentElement.setAttribute("data-turbo", this.previousTurboSetting)
    this.draft?.stop()
    this.sourceBytes = null
    this.active = false
    this.resolutionQuery?.removeEventListener("change", this.resolutionChanged)
    this.finishInput()
    window.clearTimeout(this.resizeTimer)
    this.observer?.disconnect()
    this.intersections?.disconnect()
    for (const state of this.pageStates) {
      state.renderTask?.cancel()
      state.canvas.width = state.canvas.height = state.inkCanvas.width = state.inkCanvas.height = 0
      state.ink.releaseCache()
      state.page.cleanup()
    }
    this.loadingTask?.destroy().catch(() => {})
    this.pdfWorker?.destroy()
    this.worker?.terminate()
  }
}
