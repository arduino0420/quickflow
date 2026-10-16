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
      this.blocked = [401, 403, 409].includes(error.code)
      this.status(this.blocked ? "下書きを復元できません。ログイン状態・教材の変更を確認してください。" : "下書きを復元できませんでした。接続を確認して再試行してください。", !this.blocked)
    }
  }

  changed() {
    if (!this.ready || !this.allowed || this.blocked || this.disposed) return
    this.revision++
    this.status(this.failed ? "保存できませんでした。接続を確認して再試行してください。" : "未保存", this.failed)
    if (!this.failed) this.schedule()
  }

  schedule() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.save(), this.delay)
  }

  get dirty() { return this.revision !== this.savedRevision }

  async save() {
    if (this.disposed || this.saving || this.blocked || !this.ready || !this.allowed || !this.dirty) return
    clearTimeout(this.timer)
    this.saving = true
    const revision = this.revision
    try {
      const data = structuredClone(this.read())
      this.lastAttempt = data
      this.status("保存中…")
      const { draft } = await this.call("PUT", { expected_version: this.version, draft_data: data })
      if (this.disposed) return
      this.version = draft.version
      this.savedRevision = revision
      this.failed = false
      this.status(this.dirty ? "未保存" : "保存済み")
    } catch (error) {
      if (!this.disposed) this.failure(error)
    } finally {
      this.saving = false
      if (!this.disposed && this.dirty && !this.failed && !this.blocked) this.schedule()
    }
  }

  failure(error) {
    this.failed = true
    this.blocked = [401, 403, 409, 413, 422].includes(error.code)
    if ([413, 422].includes(error.code)) {
      this.editable(false)
      this.status("保存できませんでした。下書きの容量・形式が上限に達しました。この画面を閉じず、先生に確認してください。")
    } else if (this.blocked) {
      this.editable(false)
      this.status("保存を停止しました。別のタブ・端末、教材変更、提出・ログイン状態を確認してください。手書きが残るこの画面を閉じず、先生に確認してください。")
    } else {
      this.status("保存できませんでした。手書きはこの画面に残っています。接続を確認して再試行してください。", true)
    }
  }

  async retry() {
    if (this.disposed || this.blocked || this.saving || this.retrying) return
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

  stop() {
    this.disposed = true
    clearTimeout(this.timer)
    this.abort.abort()
  }
}
