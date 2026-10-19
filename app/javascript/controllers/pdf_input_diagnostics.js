// Opt-in, bounded, memory-only diagnostics. Never retain events, DOM nodes or ink data in rows.
const EVENTS = ["pointerdown", "pointermove", "pointerup", "pointercancel", "lostpointercapture"]
const CAPACITY = 2048
const number = value => Number.isFinite(value) ? value : null

export default class PdfInputDiagnostics {
  constructor(controller) {
    this.controller = controller
    this.rows = new Array(CAPACITY)
    this.count = 0
    this.eventIds = new WeakMap()
    this.nextEventId = 1
    this.started = performance.now()
    this.listener = event => {
      // Include pen events outside the preview to distinguish hit-testing from missing events.
      if (event.pointerType === "pen" || controller.element.contains(event.target)) this.record("document", event, "capture")
    }
    for (const type of EVENTS) document.addEventListener(type, this.listener, { capture: true, passive: true })
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
    this.rows[this.count % CAPACITY] = {
      sequence: ++this.count, eventId, source, reason,
      elapsedMs: performance.now() - this.started,
      eventTimeMs: number(event?.timeStamp),
      type: EVENTS.includes(event?.type) ? event.type : null,
      pointerId: number(event?.pointerId),
      pointerType: ["pen", "mouse", "touch"].includes(event?.pointerType) ? event.pointerType : null,
      button: number(event?.button), buttons: number(event?.buttons),
      target: !event ? null : state ? "ink" : c.element.contains(event.target) ? "preview" : "outside-preview",
      inputActive: !!active, activePointerId: number(active?.ink.pointerId),
      activeStroke: !!active?.ink.stroke, targetStroke: !!state?.ink.stroke,
      touchActive: !!c.touch, touchPointerId: number(c.touch?.id),
      captured: !!(state && event && state.inkCanvas.hasPointerCapture(event.pointerId)),
      activeCaptured: !!(active && active.ink.pointerId != null && active.inkCanvas.hasPointerCapture(active.ink.pointerId)),
      canvasHidden: state ? !!state.inkCanvas.hidden : null,
      draftEditable: !!c.draftEditable, draftSaving: !!c.draft?.saving,
      exporting: !!c.exporting, framePending: !!c.inkFrame
    }
  }

  snapshot() {
    const start = Math.max(0, this.count - CAPACITY)
    return { capacity: CAPACITY, total: this.count, dropped: start,
      rows: Array.from({ length: this.count - start }, (_, i) => ({ ...this.rows[(start + i) % CAPACITY] })) }
  }

  stop() {
    for (const type of EVENTS) document.removeEventListener(type, this.listener, true)
    this.rows = []
    this.count = 0
    this.eventIds = new WeakMap()
  }
}
