import { Controller } from "@hotwired/stimulus"
import SubmissionConfirmation from "submission_confirmation"

// The legacy upload retains its existing form/CSRF and server uniqueness guard.
export default class extends Controller {
  static targets = ["submit", "file", "status"]
  static values = { context: String, stateUrl: String }

  connect() {
    this.active = true
    this.session = Symbol()
    this.confirming = this.submitting = this.permitSubmit = this.blocked = false
    try {
      this.confirmation = new SubmissionConfirmation()
      this.submitTarget.disabled = false
    } catch {
      this.submitTarget.disabled = true
      this.statusTarget.textContent = "提出の確認を表示できません。JavaScriptの設定を確認してください。"
    }
  }

  async request(event) {
    if (this.permitSubmit && this.active) {
      this.permitSubmit = false
      this.submitting = true
      this.submitTarget.disabled = true
      return
    }
    event.preventDefault()
    if (!this.active || this.blocked || this.confirming || this.submitting || !this.confirmation) return
    const session = this.session
    const file = this.fileTarget.files[0]
    this.confirming = true
    this.submitTarget.disabled = true
    this.statusTarget.textContent = ""
    let deadline
    try {
      if (!await this.confirmation.ask(this.submitTarget) || !this.current(session)) return
      const url = new URL(this.stateUrlValue, window.location.href)
      if (url.origin !== window.location.origin) throw new Error("Invalid submission origin")
      const preflight = this.preflight = new AbortController()
      deadline = setTimeout(() => preflight.abort(), 30_000)
      const response = await fetch(url, { credentials: "same-origin", cache: "no-store", redirect: "error",
        signal: preflight.signal, headers: { "Accept": "text/html" } })
      if (!this.current(session)) return
      if (!response.ok) throw new Error("Submission state unavailable")
      const page = new DOMParser().parseFromString(await response.text(), "text/html")
      if (!this.current(session)) return
      const form = page.querySelector('form[data-controller~="submission-confirmation"]')
      if (!form || form.dataset.submissionConfirmationContextValue !== this.contextValue) {
        this.blocked = true
        throw new Error("Submission context changed")
      }
      if (file !== this.fileTarget.files[0]) throw new Error("Selected PDF changed")
      this.permitSubmit = true
      this.submitTarget.disabled = false
      this.element.requestSubmit(this.submitTarget)
    } catch {
      if (this.current(session)) this.statusTarget.textContent =
        "提出状況を確認できないため送信していません。選択したPDFはこの画面に残っています。ログイン状態や提出済みでないか確認してください。"
    } finally {
      clearTimeout(deadline)
      if (this.current(session)) {
        this.preflight = null
        this.confirming = false
        if (!this.submitting) this.permitSubmit = false
        this.submitTarget.disabled = this.blocked || this.submitting
      }
    }
  }

  current(session) { return this.active && this.session === session && this.element.isConnected }

  submitted() {
    this.submitting = false
    if (this.active) this.submitTarget.disabled = this.blocked
  }

  cancel() {
    this.session = Symbol()
    this.preflight?.abort()
    this.preflight = null
    this.confirmation?.cancel()
    this.confirming = this.permitSubmit = false
    if (this.active) this.submitTarget.disabled = this.blocked || this.submitting
  }

  disconnect() {
    this.active = false
    this.cancel()
    this.confirmation?.destroy()
    if (this.hasSubmitTarget) this.submitTarget.disabled = true
  }
}
