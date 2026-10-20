function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical)
  if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]))
  return value
}

// Server only. No localStorage / IndexedDB copies on shared school devices.
export default class PdfDraft {
  constructor({ url, context, read, restore, status, editable, fetch: request = window.fetch.bind(window), delay = 2500 }) {
    Object.assign(this, { url, context, read, restore, status, editable, request, delay })
    this.revision = this.savedRevision = 0
    this.version = null
    this.saveBlocked = this.blocked = this.failed = false
    this.abort = new AbortController()
  }

  async call(method, body) {
    const response = await this.request(this.url, {
      method, credentials: "same-origin", cache: "no-store", redirect: "error", signal: AbortSignal.any([this.abort.signal, AbortSignal.timeout(30_000)]),
      headers: { "Accept": "application/json", "Content-Type": "application/json", "X-Draft-Context": this.context,
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
      ...(body ? { body: JSON.stringify(body) } : {})
    })
    if (!response.ok) {
      const error = new Error("draft request failed")
      error.code = response.status
      try {
        const payload = await response.json()
        if (typeof payload?.error === "string") error.reason = payload.error
      } catch { /* An HTML or empty error response has no trusted reason code. */ }
      throw error
    }
    return response.json()
  }

  async start() {
    this.status("下書きの復元中…")
    try {
      const { draft, editable } = await this.call("GET")
      if (this.disposed) return
      if (draft) this.restore(draft)
      this.version = draft?.version ?? null
      this.ready = true
      this.allowed = editable
      this.editable(editable)
      this.status(editable ? (draft ? "保存済み" : "未保存") : "提出済みです。下書きは変更できません。")
    } catch (error) {
      if (this.disposed) return
      this.failed = true
      this.blocked = [400, 401, 403, 409, 413, 415, 422].includes(error.code)
      this.status(this.blocked ? "下書きを復元できません。ログイン状態・教材の変更を確認してください。" : "下書きを復元できませんでした。接続を確認して再試行してください。", !this.blocked)
    }
  }

  changed() {
    if (!this.ready || !this.allowed || this.disposed) return
    this.revision++
    if (this.blocked || this.saveBlocked) return
    this.status(this.failed ? this.failureMessage : "未保存", this.failed)
    if (!this.failed) this.schedule()
  }

  schedule() {
    if (this.submitting) return
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.save(), this.delay)
  }

  get dirty() { return this.revision !== this.savedRevision }

  async save() {
    if (this.disposed || this.saving || this.submitting || this.blocked || this.saveBlocked || !this.ready || !this.allowed || !this.dirty) return
    clearTimeout(this.timer)
    this.saving = true
    const revision = this.revision
    try {
      const data = structuredClone(this.read())
      this.lastAttempt = data
      this.lastAttemptRevision = revision
      this.status("保存中…")
      const { draft } = await this.call("PUT", { expected_version: this.version, draft_data: data })
      if (this.disposed) return
      this.version = draft.version
      this.savedRevision = revision
      this.failed = false
      this.failureMessage = null
      this.status(this.dirty ? "未保存" : "保存済み")
    } catch (error) {
      if (!this.disposed) this.failure(error)
    } finally {
      this.saving = false
      if (!this.disposed && this.dirty && !this.failed && !this.blocked && !this.saveBlocked) this.schedule()
    }
  }

  rejectionMessage(error) {
    const keep = "手書きはこの画面に残っています。画面を閉じたり再読み込みしたりせず、先生に確認してください。"
    const submit = "サーバーに保存できていないため、画面を閉じたり再読み込みしたりすると答案が失われる可能性があります。手書きと提出は続けられます。"
    if (error.code === 413) return `送信する手書きデータの容量が上限を超えたため、保存できませんでした。${submit}`
    if (error.code === 400 || error.code === 415) return `保存するデータを正しく送信できませんでした。${keep}`
    if (error.code !== 422) return null
    const reasons = {
      draft_bytes_limit: "手書きデータの容量が上限を超えたため、保存できませんでした。",
      draft_pages_limit: "答案のページ数が上限を超えたため、保存できませんでした。",
      draft_operations_limit: "書いた線の数が上限に達したため、保存できませんでした。",
      draft_points_limit: "手書きの細かな動きの記録が上限に達したため、保存できませんでした。",
      invalid_data: "手書きデータを正しく読み取れなかったため、保存できませんでした。",
      csrf_failed: "ログイン状態を確認できず、保存を停止しました。"
    }
    return `${Object.hasOwn(reasons, error.reason) ? reasons[error.reason] : "保存の要求を受け付けられませんでした。"}${
      this.capacityReason(error) ? submit : keep}`
  }

  capacityReason(error) {
    return error.code === 413 || (error.code === 422 && [
      "draft_bytes_limit", "draft_pages_limit", "draft_operations_limit", "draft_points_limit"
    ].includes(error.reason))
  }

  failure(error) {
    this.failed = true
    this.saveBlocked = this.capacityReason(error)
    this.blocked = !this.saveBlocked && [400, 401, 403, 409, 415, 422].includes(error.code)
    const message = this.rejectionMessage(error)
    if (this.saveBlocked) {
      this.failureMessage = message
      this.status(message)
    } else if (message) {
      this.failureMessage = message
      this.editable(false)
      this.status(message)
    } else if (this.blocked) {
      this.failureMessage = "保存を停止しました。別のタブ・端末、教材変更、提出・ログイン状態を確認してください。手書きが残るこの画面を閉じず、先生に確認してください。"
      this.editable(false)
      this.status(this.failureMessage)
    } else {
      this.failureMessage = "保存できませんでした。サーバーに保存できていないため、画面を閉じると答案が失われる可能性があります。接続を確認して再試行してください。"
      this.status(this.failureMessage, true)
    }
  }

  async retry() {
    if (this.disposed || this.blocked || this.saveBlocked || this.saving || this.retrying || this.submitting) return
    if (!this.ready) { this.failed = false; return this.start() }
    this.retrying = true
    try {
      // A lost response may follow a successful commit. Only adopt the remote
      // version if its exact contents match our last attempted snapshot.
      const { draft, editable } = await this.call("GET")
      if (this.disposed) return
      const version = draft?.version ?? null
      const remote = draft && { format_version: draft.format_version, pages: draft.pages }
      if (!editable || (version !== this.version && JSON.stringify(canonical(remote)) !== JSON.stringify(canonical(this.lastAttempt)))) {
        const error = new Error("conflict"); error.code = 409; throw error
      }
      this.version = version
      this.failed = false
      this.failureMessage = null
      await this.save()
    } catch (error) {
      if (!this.disposed) this.failure(error)
    } finally { this.retrying = false }
  }

  async flush() {
    if (!this.ready || !this.allowed || this.blocked || this.failed || this.disposed) throw new Error("draft unavailable")
    // A blank answer also needs a saved version to bind the final PDF to this editor.
    if (this.version === null && !this.dirty && !this.saving) this.changed()
    const deadline = Date.now() + 30_000
    while (this.saving || this.retrying) {
      if (Date.now() > deadline || this.disposed) throw new Error("draft timeout")
      await new Promise(resolve => setTimeout(resolve, 20))
    }
    if (this.failed || this.blocked) throw new Error("draft failed")
    if (this.dirty) await this.save()
    if (this.dirty || this.failed || this.blocked || this.disposed) throw new Error("draft unsaved")
    return this.version
  }

  async prepareSubmission() {
    if (!this.ready || !this.allowed || this.blocked || this.disposed) {
      const error = new Error("draft unavailable"); error.code = 409; throw error
    }
    this.submitting = true
    clearTimeout(this.timer)
    try {
      const deadline = Date.now() + 35_000
      while (this.saving || this.retrying) {
        if (Date.now() > deadline || this.disposed) throw new Error("draft save still pending")
        await new Promise(resolve => setTimeout(resolve, 20))
      }
      if (this.blocked) { const error = new Error("draft blocked"); error.code = 409; throw error }
      if (this.failed && !this.saveBlocked) {
        // A failed response can follow a committed PUT. Confirm the exact remote snapshot.
        const { draft, editable } = await this.call("GET")
        if (!editable) { const error = new Error("draft not editable"); error.code = 403; throw error }
        const version = draft?.version ?? null
        if (version !== this.version) {
          const remote = draft && { format_version: draft.format_version, pages: draft.pages }
          if (JSON.stringify(canonical(remote)) !== JSON.stringify(canonical(this.lastAttempt))) {
            const error = new Error("draft conflict"); error.code = 409; throw error
          }
          this.version = version
          this.savedRevision = this.lastAttemptRevision
        }
      }
      return this.version
    } catch (error) {
      this.finishSubmission()
      throw error
    }
  }

  finishSubmission() {
    this.submitting = false
    if (this.dirty && !this.failed && !this.blocked && !this.saveBlocked && !this.disposed) this.schedule()
  }

  stop() {
    this.disposed = true
    clearTimeout(this.timer)
    this.abort.abort()
  }
}
