import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String }

  connect() {
    this.timer = window.setTimeout(() => {
      const frame = this.element.closest("turbo-frame")
      if (frame.src) {
        frame.reload()
      } else {
        frame.src = this.urlValue
      }
    }, 10000)
  }

  disconnect() {
    window.clearTimeout(this.timer)
  }
}
