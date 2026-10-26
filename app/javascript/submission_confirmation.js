// UI intent only: authorization and idempotency remain on the submission path.
export default class SubmissionConfirmation {
  constructor() {
    const dialog = this.dialog = document.createElement("dialog")
    if (typeof dialog.showModal !== "function") throw new Error("Submission confirmation unavailable")
    dialog.className = "submission-confirmation"
    const title = document.createElement("h2")
    title.id = `submission-confirmation-${crypto.randomUUID()}`
    title.textContent = "提出しますか？"
    dialog.setAttribute("aria-labelledby", title.id)
    const actions = document.createElement("div")
    actions.className = "submission-confirmation-actions"
    this.no = this.button("いいえ", "button-secondary", () => this.finish(false))
    const yes = this.button("はい", "", () => this.finish(true))
    const close = this.button("×", "submission-confirmation-close", () => this.finish(false))
    close.setAttribute("aria-label", "確認を閉じる")
    actions.append(this.no, yes)
    dialog.append(title, actions, close)
    dialog.addEventListener("cancel", event => { event.preventDefault(); this.finish(false) })
    dialog.addEventListener("close", () => this.finish(false))
    dialog.addEventListener("click", event => { if (event.target === dialog) this.finish(false) })
    dialog.addEventListener("keydown", event => {
      if (event.key !== "Tab") return
      const buttons = [...dialog.querySelectorAll("button:not(:disabled)")]
      const next = event.shiftKey ? buttons.at(-1) : buttons[0]
      const edge = event.shiftKey ? buttons[0] : buttons.at(-1)
      if (document.activeElement === edge) { event.preventDefault(); next.focus() }
    })
    document.body.append(dialog)
  }

  button(label, className, action) {
    const button = document.createElement("button")
    button.type = "button"
    button.textContent = label
    button.className = className
    button.addEventListener("click", action)
    return button
  }

  ask(returnFocus) {
    if (this.pending) return this.pending.promise
    const position = { left: window.scrollX, top: window.scrollY }
    let resolve
    const promise = new Promise(done => { resolve = done })
    this.pending = { promise, resolve, returnFocus, position }
    try {
      this.dialog.showModal()
      this.no.focus({ preventScroll: true })
    } catch (error) {
      this.pending = null
      throw error
    }
    return promise
  }

  finish(answer, restore = true) {
    const pending = this.pending
    if (!pending) return
    this.pending = null
    if (this.dialog.open) this.dialog.close()
    pending.resolve(answer)
    if (!answer && restore) queueMicrotask(() => {
      if (!pending.returnFocus?.isConnected) return
      pending.returnFocus.focus({ preventScroll: true })
      window.scrollTo(pending.position)
    })
  }

  cancel() { this.finish(false) }

  destroy() {
    this.finish(false, false)
    this.dialog.remove()
  }
}
