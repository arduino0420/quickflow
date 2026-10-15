import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["link"]

  open(event) {
    if (event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return
    if (event.target.closest("a, button, input, select, textarea, label")) return
    if (window.getSelection()?.toString()) return

    this.followLink()
  }

  openWithKeyboard(event) {
    if (event.target !== this.element || !["Enter", " "].includes(event.key)) return
    if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return

    event.preventDefault()
    this.followLink()
  }

  followLink() {
    const link = this.hasLinkTarget ? this.linkTarget : this.element.querySelector(".grade-row-link")
    link?.click()
  }
}
