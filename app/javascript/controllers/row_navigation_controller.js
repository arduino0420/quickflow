import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  open(event) {
    if (event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return
    if (event.target.closest("a, button, input, select, textarea, label")) return
    if (window.getSelection()?.toString()) return

    this.element.querySelector(".grade-row-link")?.click()
  }
}
