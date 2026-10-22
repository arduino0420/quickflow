function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical)
  if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]))
  return value
}

// Server only. No localStorage / IndexedDB copies on shared school devices.
export default class PdfDraft {
  constructor({ url, context, read, restore, status, editable, expired, fetch: request = window.fetch.bind(window), delay = 2500, maxWait = Math.max(10_000, delay) }) {
    Object.assign(this, { url, context, read, restore, status, editable, expired, request, delay, maxWait })
    this.revision = this.savedRevision = 0
    this.version = null
    this.saveBlocked = this.blocked = this.failed = false
    this.abort = new AbortController()
  }

  async call(method, body) {
    const response = await this.request(this.url, {
      method, credentials: "same-origin", cache: "no-store", redirect: "error", signal: AbortSignal.any([this.abort.signal, AbortSignal.timeout(30_000)]),
      headers: { "Accept": "application/json", "Content-Type": "application/json", "X-Draft-Context": this.context,
        "X-Draft-Response": "acknowledgment",
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
    if (this.starting || this.ready || this.disposed) return
    this.starting = true
    this.status("下書きの復元中…")
    try {
      const { draft, editable, append_supported } = await this.call("GET")
      if (this.disposed) return
      if (draft) this.restore(draft)
      this.appendSupported = append_supported === true
      this.confirmedSnapshot = draft && { format_version: draft.format_version, pages: draft.pages }
      this.version = draft?.version ?? null
      this.ready = true
      this.allowed = editable
      this.failed = this.blocked = false
      this.editable(editable)
      this.status(editable ? (draft ? "保存済み" : "未保存") : "提出済みです。下書きは変更できません。")
    } catch (error) {
      if (this.disposed) return
      this.failed = true
      this.blocked = [400, 401, 403, 409, 413, 415, 422].includes(error.code)
      if (error.code === 401) this.expired?.()
      this.status(error.code === 401 ? "ログインの有効期限が切れました。答案画面を閉じず、別タブで再ログインしてください。" :
        this.blocked ? "下書きを復元できません。ログイン状態・教材の変更を確認してください。" :
          "下書きを復元できませんでした。接続を確認して再試行してください。", !this.blocked)
    } finally { this.starting = false }
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
    // Debounce short pauses, but checkpoint completed strokes during continuous writing.
    this.pendingSince ??= Date.now()
    const wait = Math.min(this.delay, Math.max(0, this.maxWait - (Date.now() - this.pendingSince)))
    this.timer = setTimeout(() => this.save(), wait)
  }

  get dirty() { return this.revision !== this.savedRevision }

  async save() {
    if (this.disposed || this.saving || this.submitting || this.blocked || this.saveBlocked || !this.ready || !this.allowed || !this.dirty) return
    clearTimeout(this.timer)
    this.saving = true
    this.pendingSince = null
    const revision = this.revision
    try {
      const data = structuredClone(this.read())
      this.lastAttempt = data
      this.lastAttemptRevision = revision
      this.status("保存中…")
      const append = this.appendData(data)
      const { draft } = await this.call("PUT", { expected_version: this.version,
        ...(append ? { append_data: append } : { draft_data: data }) })
      if (this.disposed) return
      this.version = draft.version
      this.confirmedSnapshot = data
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

  appendData(data) {
    const previous = this.confirmedSnapshot
    if (!this.appendSupported || this.version === null || !previous ||
        Object.keys(data).sort().join() !== "format_version,pages" || data.format_version !== 1 ||
        data.format_version !== previous.format_version || data.pages.length !== previous.pages.length) return null
    const pages = []
    for (let index = 0; index < data.pages.length; index++) {
      const page = data.pages[index], saved = previous.pages[index]
      if (Object.keys(page).sort().join() !== "operations,page_number" ||
          page.page_number !== saved.page_number || page.operations.length < saved.operations.length) return null
      for (let operation = 0; operation < saved.operations.length; operation++) {
        const a = page.operations[operation], b = saved.operations[operation]
        if (Object.keys(a).sort().join() !== "color,id,points,tool,width" ||
            !["id", "tool", "color", "width"].every(key => a[key] === b[key]) ||
            a.points.length !== b.points.length || !a.points.every((point, i) =>
              point.length === 2 && b.points[i].length === 2 &&
              point[0] === b.points[i][0] && point[1] === b.points[i][1])) return null
      }
      pages.push({ page_number: page.page_number, operations: page.operations.slice(saved.operations.length) })
    }
    return { format_version: data.format_version, pages }
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
    if (error.code === 401 || (error.code === 422 && error.reason === "csrf_failed")) {
      this.failureMessage = "ログインの有効期限が切れました。答案画面を閉じず、別タブで再ログインしてください。未保存の手書きはこの画面だけに残っています。"
      this.editable(false)
      this.expired?.()
      this.status(this.failureMessage)
      return
    }
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
      const { draft, editable, append_supported } = await this.call("GET")
      if (this.disposed) return
      const version = draft?.version ?? null
      const remote = draft && { format_version: draft.format_version, pages: draft.pages }
      if (!editable || (version !== this.version && JSON.stringify(canonical(remote)) !== JSON.stringify(canonical(this.lastAttempt)))) {
        const error = new Error("conflict"); error.code = 409; throw error
      }
      this.version = version
      this.appendSupported = append_supported === true
      this.confirmedSnapshot = remote
      if (this.lastAttempt && JSON.stringify(canonical(remote)) === JSON.stringify(canonical(this.lastAttempt))) {
        this.savedRevision = this.lastAttemptRevision
      }
      this.failed = false
      this.failureMessage = null
      if (this.dirty) await this.save()
      else {
        this.pendingSince = null
        this.status("保存済み")
      }
    } catch (error) {
      if (!this.disposed) this.failure(error)
    } finally { this.retrying = false }
  }

  resume(remoteDraft) {
    if (this.disposed || this.saving || this.retrying || this.submitting || !this.ready) return false
    const version = remoteDraft?.version ?? null
    const remote = remoteDraft && { format_version: remoteDraft.format_version, pages: remoteDraft.pages }
    const same = (left, right) => JSON.stringify(canonical(left)) === JSON.stringify(canonical(right))
    if (version !== this.version) {
      if (!this.lastAttempt || !same(remote, this.lastAttempt)) return false
      this.savedRevision = this.lastAttemptRevision
    }
    this.version = version
    this.confirmedSnapshot = remote
    this.failed = this.blocked = this.saveBlocked = false
    this.failureMessage = null
    this.editable(true)
    this.status(this.dirty ? "未保存" : "保存済み")
    if (this.dirty) this.schedule()
    return true
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
