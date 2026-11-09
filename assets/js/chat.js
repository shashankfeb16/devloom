// LiveView owns the conversation DOM. These hooks only preserve scroll position,
// enhance form input, and localize the explicitly ignored <time> elements.
export const ChatScroll = {
  mounted() {
    this.jumpButton = document.getElementById("chat-scroll-jump")
    this.onScroll = () => this.updateJumpButton()
    this.onJump = () => this.scrollLatest()
    this.el.addEventListener("scroll", this.onScroll, {passive: true})
    this.jumpButton.addEventListener("click", this.onJump)
    this.handleEvent("chat:scroll-latest", () => requestAnimationFrame(() => this.scrollLatest()))
    this.scrollFrame = requestAnimationFrame(() => this.scrollLatest())
  },

  beforeUpdate() {
    this.wasAtBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 70
    const top = this.el.getBoundingClientRect().top
    const anchor = [...this.el.querySelectorAll("[data-message-id]")]
      .find(item => item.getBoundingClientRect().bottom > top)
    this.anchor = anchor ? {id: anchor.id, offset: anchor.getBoundingClientRect().top - top} : null
  },

  updated() {
    if (this.wasAtBottom && this.el.dataset.history !== "true") {
      this.scrollLatest()
    } else if (this.anchor) {
      const anchor = document.getElementById(this.anchor.id)
      if (anchor) this.el.scrollTop += anchor.getBoundingClientRect().top - this.el.getBoundingClientRect().top - this.anchor.offset
    }
    this.updateJumpButton()
  },

  scrollLatest() {
    this.el.scrollTop = this.el.scrollHeight
    this.updateJumpButton()
  },

  updateJumpButton() {
    this.jumpButton.hidden = this.el.dataset.history === "true" || this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 70
  },

  destroyed() {
    cancelAnimationFrame(this.scrollFrame)
    this.el.removeEventListener("scroll", this.onScroll)
    this.jumpButton.removeEventListener("click", this.onJump)
  },
}

export const ChatComposer = {
  mounted() {
    this.bodyInput = this.el.querySelector("[name='message[body]']")
    this.refInput = this.el.querySelector("[name='message[client_ref]']")
    this.key = this.el.dataset.storageKey

    this.restoreDraft()

    this.onInput = () => this.saveDraft()
    this.onKeydown = event => {
      if (event.target === this.bodyInput && event.key === "Enter" && (event.metaKey || event.ctrlKey) && !event.isComposing) {
        event.preventDefault()
        if (!this.el.querySelector("[type='submit']").disabled) this.el.requestSubmit()
      }
    }
    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("keydown", this.onKeydown)
    this.handleEvent("chat:sent", ({body, storage_key: storageKey}) => {
      if (storageKey && storageKey !== this.key) return
      // Do not erase a new draft typed while the previous message was saving.
      if (this.bodyInput.value.trim() === body) this.bodyInput.value = ""
      this.saveDraft()
      this.bodyInput.focus({preventScroll: true})
    })
  },

  beforeUpdate() {
    this.saveDraft()
  },

  updated() {
    if (this.key !== this.el.dataset.storageKey) {
      this.key = this.el.dataset.storageKey
      this.bodyInput.value = ""
      this.refInput.value = this.el.dataset.clientRef
      this.restoreDraft()
    }
  },

  restoreDraft() {
    try {
      const draft = JSON.parse(sessionStorage.getItem(this.key) || "null")
      if (draft?.body) {
        this.bodyInput.value = draft.body
        if (draft.clientRef) this.refInput.value = draft.clientRef
        this.bodyInput.dispatchEvent(new Event("input", {bubbles: true}))
      }
    } catch (_) { /* Browser storage is optional. */ }
  },

  saveDraft() {
    try {
      sessionStorage.setItem(this.key, JSON.stringify({body: this.bodyInput.value, clientRef: this.refInput.value}))
    } catch (_) { /* Storage is optional. LiveView also recovers the form. */ }
  },

  disconnected() {
    this.saveDraft()
    this.el.querySelector("[type='submit']").disabled = true
    document.getElementById("chat-offline-notice").hidden = false
  },

  reconnected() {
    this.el.querySelector("[type='submit']").disabled = false
    document.getElementById("chat-offline-notice").hidden = true
  },

  destroyed() {
    this.saveDraft()
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("keydown", this.onKeydown)
  },
}

export const ChatTimestamp = {
  mounted() {
    const date = new Date(this.el.dateTime)
    if (Number.isNaN(date.getTime())) return
    this.el.textContent = new Intl.DateTimeFormat(undefined, {
      month: "short", day: "numeric", hour: "numeric", minute: "2-digit",
    }).format(date)
    this.el.title = new Intl.DateTimeFormat(undefined, {dateStyle: "full", timeStyle: "long"}).format(date)
  },
}
