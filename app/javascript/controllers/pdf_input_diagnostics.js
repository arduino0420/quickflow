// Opt-in, bounded, memory-only diagnostics. Never retain events, DOM nodes or ink data in rows.
const EVENTS = ["pointerdown", "pointermove", "pointerup", "pointercancel", "lostpointercapture"]
const TOUCH_EVENTS = ["touchstart", "touchend", "touchcancel"]
const ALL_EVENTS = [...EVENTS, ...TOUCH_EVENTS]
const BOUNDARIES = EVENTS.filter(type => type !== "pointermove")
const REJECTIONS = new Set(["exporting", "canvas-hidden", "unknown-canvas", "unsupported-input", "pinch-active",
  "draft-not-editable", "input-busy", "viewport-mismatch", "ink-start-rejected"])
const CAPACITY = 2048
const number = value => Number.isFinite(value) ? value : null

export default class PdfInputDiagnostics {
  constructor(controller) {
    this.controller = controller
    this.reset()
    this.listener = event => {
      // Include pen events outside the preview to distinguish hit-testing from missing events.
      if (event.pointerType === "pen" || controller.element.contains(event.target)) this.record("document", event, "capture")
    }
    this.windowListener = event => {
      if (event.pointerType === "pen" || controller.element.contains(event.target)) this.record("window", event, "capture")
    }
    for (const type of ALL_EVENTS) document.addEventListener(type, this.listener, { capture: true, passive: true })
    for (const type of [...BOUNDARIES, ...TOUCH_EVENTS]) window.addEventListener(type, this.windowListener, { capture: true, passive: true })
  }

  reset() {
    this.rows = new Array(CAPACITY)
    this.count = 0
    this.eventIds = new WeakMap()
    this.nextEventId = 1
    this.started = performance.now()
    this.pen = Object.fromEntries(["window", "document", "controller"].map(source => [source,
      { pointerdown: 0, inkDown: 0, pointerup: 0, pointercancel: 0, lostpointercapture: 0 }]))
    this.accepted = this.ended = this.rejected = 0
    this.reasons = {}
    this.touch = { touchstart: 0, touchend: 0, touchcancel: 0 }
    this.lastPenUp = this.lastGap = null
    this.recent = []
    this.dirty = true
  }

  record(source, event, reason) {
    const c = this.controller
    const state = c.statesByCanvas.get(event?.target) || c.statesByCanvas.get(event?.currentTarget)
    const active = c.inputState
    let eventId = null
    if (event) {
      if (!this.eventIds.has(event)) this.eventIds.set(event, this.nextEventId++)
      eventId = this.eventIds.get(event)
    }
    const row = {
      sequence: ++this.count, eventId, source, reason,
      elapsedMs: performance.now() - this.started,
      eventTimeMs: number(event?.timeStamp),
      type: ALL_EVENTS.includes(event?.type) ? event.type : null,
      pointerId: number(event?.pointerId),
      pointerType: ["pen", "mouse", "touch"].includes(event?.pointerType) ? event.pointerType : null,
      button: number(event?.button), buttons: number(event?.buttons),
      target: !event ? null : state ? "ink" : c.element.contains(event.target) ? "preview" : "outside-preview",
      inputActive: !!active, activePointerId: number(active?.ink.pointerId),
      activeStroke: !!active?.ink.stroke, targetStroke: !!state?.ink.stroke,
      touchActive: !!c.touch, touchPointerId: number(c.touch?.id),
      captured: !!(state && event?.pointerId != null && state.inkCanvas.hasPointerCapture(event.pointerId)),
      activeCaptured: !!(active && active.ink.pointerId != null && active.inkCanvas.hasPointerCapture(active.ink.pointerId)),
      canvasHidden: state ? !!state.inkCanvas.hidden : null,
      draftEditable: !!c.draftEditable, draftSaving: !!c.draft?.saving,
      exporting: !!c.exporting, framePending: !!c.inkFrame, multiTouch: !!c.multiTouch,
      touches: number(event?.touches?.length), changedTouches: number(event?.changedTouches?.length),
      cancelable: !!event?.cancelable, defaultPrevented: !!event?.defaultPrevented
    }
    this.rows[(this.count - 1) % CAPACITY] = row
    // Pointer moves keep the existing bounded trace, but never update counters or the display.
    if (event?.type === "pointermove") return
    // Scrolling back to read the panel must not replace the last pen results with idle scroll rows.
    if (!event && reason === "window-scrolled" && !active) return
    if (row.pointerType === "pen" && BOUNDARIES.includes(row.type)) {
      if (source !== "controller" || ["down-enter", "end-enter"].includes(reason)) {
        this.pen[source][row.type]++
        if (row.type === "pointerdown" && row.target === "ink") this.pen[source].inkDown++
      }
      if (source === "window" && row.target === "ink") {
        if (row.type === "pointerup") this.lastPenUp = row.eventTimeMs
        if (row.type === "pointerdown") this.lastGap = this.lastPenUp == null || row.eventTimeMs == null ? null : row.eventTimeMs - this.lastPenUp
      }
      if (source === "controller") {
        if (reason === "stroke-accepted") this.accepted++
        if (reason === "stroke-ended") this.ended++
        if (row.type === "pointerdown" && REJECTIONS.has(reason)) {
          this.rejected++
          this.reasons[reason] = (this.reasons[reason] || 0) + 1
        }
      }
    }
    if (source === "window" && TOUCH_EVENTS.includes(row.type)) this.touch[row.type]++
    this.recent.push(row)
    if (this.recent.length > 16) this.recent.shift()
    this.dirty = true
  }

  summary() {
    return { pen: Object.fromEntries(Object.entries(this.pen).map(([source, counts]) => [source, { ...counts }])),
      accepted: this.accepted, ended: this.ended, rejected: this.rejected, reasons: { ...this.reasons }, touch: { ...this.touch },
      lastGap: this.lastGap, recent: this.recent.map(row => ({ ...row })) }
  }

  snapshot() {
    const start = Math.max(0, this.count - CAPACITY)
    return { capacity: CAPACITY, total: this.count, dropped: start,
      rows: Array.from({ length: this.count - start }, (_, i) => ({ ...this.rows[(start + i) % CAPACITY] })) }
  }

  stop() {
    for (const type of ALL_EVENTS) document.removeEventListener(type, this.listener, true)
    for (const type of [...BOUNDARIES, ...TOUCH_EVENTS]) window.removeEventListener(type, this.windowListener, true)
    this.reset()
  }
}
