import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.hasAnimated ||= false
    this.waiting = ["submitted", "grading"].includes(this.state(this.element)) && !this.hasAnimated
  }

  beforeRender(event) {
    if (!this.ownFrame(event)) return

    this.stopAnimations()
    if (this.responseFailed) return

    delete this.element.dataset.gradingPresentationPaused
    const frame = event.detail.newFrame
    const state = this.state(frame)
    if (state !== "completed") {
      if (state !== "submitted" && state !== "grading") this.waiting = false
      return
    }

    const reveal = this.waiting && !this.hasAnimated
    this.waiting = false
    if (!reveal) return

    this.hasAnimated = true
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return

    this.cards = Array.from(frame.querySelectorAll("[data-grading-presentation-card]"))
    if (this.cards.length === 0) return

    // DOM order is the server's question-position order. Spread every start
    // across at most 900ms, including large quizzes; each entrance lasts 480ms.
    const step = Math.min(75, 900 / Math.max(this.cards.length - 1, 1))
    this.cards.forEach((card, index) => {
      card.style.setProperty("--student-result-delay", `${Math.min(index * step, 900)}ms`)
      card.classList.add("student-result-enter")
    })
    this.cleanupTimer = window.setTimeout(() => this.stopAnimations(), 1600)
  }

  frameLoaded(event) {
    if (!this.ownFrame(event)) return

    if (!["submitted", "grading"].includes(this.state(event.target))) this.waiting = false
  }

  responseReceived(event) {
    if (!this.ownFrame(event)) return

    this.responseFailed = !event.detail.fetchResponse.succeeded
    if (this.responseFailed) this.requestFailed(event)
  }

  requestFailed(event) {
    if (!this.ownFrame(event)) return

    this.stopAnimations()
    this.responseFailed = true
    this.element.dataset.gradingPresentationPaused = "true"
  }

  disconnect() {
    this.stopAnimations()
  }

  stopAnimations() {
    window.clearTimeout(this.cleanupTimer)
    this.cleanupTimer = null
    this.cards?.forEach((card) => {
      card.classList.remove("student-result-enter")
      card.style.removeProperty("--student-result-delay")
    })
    this.cards = []
  }

  state(root) {
    return root.querySelector("[data-grading-state]")?.dataset.gradingState
  }

  ownFrame(event) {
    return event.target.id === "grading-status" && this.element.contains(event.target)
  }
}
