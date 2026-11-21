import {DisconnectReason, Room, RoomEvent, Track} from "livekit-client"

const trackEvents = [
  RoomEvent.ParticipantConnected, RoomEvent.ParticipantDisconnected,
  RoomEvent.ParticipantNameChanged, RoomEvent.TrackSubscribed, RoomEvent.TrackUnsubscribed,
  RoomEvent.TrackPublished, RoomEvent.TrackUnpublished,
  RoomEvent.TrackMuted, RoomEvent.TrackUnmuted, RoomEvent.LocalTrackPublished,
  RoomEvent.LocalTrackUnpublished, RoomEvent.AudioPlaybackStatusChanged,
]

let call

export const MeetingRoom = {
  mounted() {
    this.online = true
    this.enter = this.el.querySelector("[data-action=enter]")
    this.title = this.el.querySelector("[data-meeting-lobby-title]")
    this.message = this.el.querySelector("[data-meeting-message]")
    this.onEnter = () => call.room ? call.controls.restore.click() : void call.enter(this)
    this.enter.addEventListener("click", this.onEnter)
    call ??= new MeetingCall(document.getElementById("meeting-call-shell"))
    call.attachLobby(this)
  },

  updated() { call.refreshLobby(this, true) },
  disconnected() { this.online = false; call.refreshLobby(this) },
  reconnected() { this.online = true; call.refreshLobby(this, true) },

  destroyed() {
    this.enter.removeEventListener("click", this.onEnter)
    call.detachLobby(this)
  },
}

export const MeetingBanner = {
  mounted() {
    this.link = this.el.querySelector("a")
    this.refresh = () => {
      this.link.textContent = call?.meetingId === this.el.dataset.meetingId ? "Return to call" : "Join meeting"
    }
    window.addEventListener("devloom:meeting-state", this.refresh)
    this.refresh()
  },

  updated() { this.refresh() },
  destroyed() { window.removeEventListener("devloom:meeting-state", this.refresh) },
}

class MeetingCall {
  constructor(shell) {
    this.shell = shell
    this.page = document.getElementById("devloom-page")
    this.notice = document.getElementById("meeting-notice")
    this.elements = Object.fromEntries(
      ["workspace", "state", "count", "shares", "participants", "audio", "message", "recording"]
        .map(name => [name, this.shell.querySelector(`[data-meeting-${name}]`)])
    )
    this.controls = Object.fromEntries(
      Array.from(this.shell.querySelectorAll("[data-action]"), control => [control.dataset.action, control])
    )
    this.tiles = new Map()
    this.shares = new Map()
    this.audioTracks = new Map()
    this.phase = "lobby"
    this.attempt = 0
    this.controls.screen.hidden = !navigator.mediaDevices?.getDisplayMedia
    this.controls.fullscreen.hidden = !document.fullscreenEnabled || !this.shell.requestFullscreen
    this.shell.addEventListener("click", event => this.handleClick(event))
    this.shell.addEventListener("keydown", event => {
      if (event.key === "Escape" && this.shell.dataset.mode === "expanded" && !document.fullscreenElement) {
        event.stopPropagation()
        this.setMode("compact")
      }
    })
    document.addEventListener("fullscreenchange", () => this.refreshFullscreen())
    window.addEventListener("pagehide", () => { if (this.room) this.leave(null, false) })
  }

  attachLobby(view) {
    this.lobby = view
    this.refreshLobby(view, true)
    if (this.isCallLobby(view)) this.setMode("expanded")
  }

  detachLobby(view) {
    if (this.lobby !== view) return
    this.lobby = null
    if (this.room) {
      this.setMode("compact", false)
      this.syncRecording()
    }
    if (this.phase === "opening") this.leave(null, false)
  }

  isCallLobby(view = this.lobby) {
    return Boolean(this.room && view && view.el.dataset.workspaceId === this.workspaceId)
  }

  refreshLobby(view = this.lobby, checkMeeting = false) {
    if (!view || view !== this.lobby) return
    const meetingId = view.el.dataset.meetingId
    if (checkMeeting && this.isCallLobby(view) && view.online && this.meetingId !== meetingId) {
      this.leave("This meeting has ended.")
      return
    }

    view.enter.disabled = this.phase === "opening" || (!this.room && !view.online)
    view.title.textContent = meetingId ? "Meeting in progress" : "Ready to meet?"
    view.enter.textContent = this.room ? "Return to call"
      : this.phase === "opening" ? "Connecting…" : meetingId ? "Join meeting" : "Start meeting"
    this.controls.end.hidden = !this.isCallLobby(view) || !view.el.closest(".meeting-page").querySelector("#end-meeting")
    this.controls.end.disabled = !view.online
    this.syncRecording()
  }

  handleClick(event) {
    switch (event.target.closest("[data-action]")?.dataset.action) {
      case "minimize": return this.setMode("compact")
      case "restore":
        if (this.isCallLobby()) {
          event.preventDefault()
          event.stopPropagation()
          this.setMode("expanded")
        }
        return
      case "fullscreen": return this.toggleFullscreen()
      case "end": return this.end()
      case "record": return this.toggleRecording()
      case "leave": return this.leave()
      case "audio": return this.enableAudio()
      case "microphone": return this.toggle("microphone", "isMicrophoneEnabled", "setMicrophoneEnabled", "microphone")
      case "camera": return this.toggle("camera", "isCameraEnabled", "setCameraEnabled", "camera")
      case "screen": return this.toggle("screen", "isScreenShareEnabled", "setScreenShareEnabled", "screen share")
    }
  }

  async enter(view) {
    if (!view.online || this.phase !== "lobby") return
    if (!window.isSecureContext || !window.RTCPeerConnection) {
      this.message("Open Devloom over HTTPS in a browser that supports video calls.")
      return
    }

    const attempt = ++this.attempt
    const meetingId = view.el.dataset.meetingId
    this.message()
    this.phase = "opening"
    this.refreshLobby()

    try {
      const reply = await view.pushEvent("enter_meeting", {
        action: meetingId ? "join" : "start",
        meeting_id: meetingId,
      })
      if (attempt !== this.attempt) return
      if (reply.status !== "ok") {
        this.leave(reply.message)
        return
      }

      this.meetingId = reply.meeting_id
      this.workspaceId = view.el.dataset.workspaceId
      this.elements.workspace.textContent = view.el.dataset.workspaceName
      this.controls.restore.href = view.el.dataset.meetingPath
      const room = new Room({adaptiveStream: true, dynacast: true})
      this.room = room
      this.phase = "connecting"
      this.elements.state.textContent = "Connecting…"
      this.setMode("expanded")
      this.refreshLobby()
      this.syncRoom()
      window.dispatchEvent(new Event("devloom:meeting-state"))
      this.bindRoom(room)
      await room.connect(reply.url, reply.token)
      if (this.room !== room) return
      this.phase = "connected"
      this.elements.state.textContent = "In meeting"
      this.syncRoom()
    } catch {
      if (attempt === this.attempt) {
        this.leave("Could not connect to the meeting. Check your connection and try again.")
      }
    }
  }

  setMode(mode, focus = true) {
    const expanded = mode === "expanded"
    this.shell.dataset.mode = mode
    this.shell.hidden = !this.room
    this.page.inert = expanded

    if (expanded) {
      this.shell.setAttribute("role", "dialog")
      this.shell.setAttribute("aria-modal", "true")
    } else {
      this.shell.removeAttribute("role")
      this.shell.removeAttribute("aria-modal")
      if (document.fullscreenElement === this.shell) void document.exitFullscreen().catch(() => {})
    }

    if (focus && this.room) {
      (expanded ? this.controls.minimize : this.controls.restore).focus({preventScroll: true})
    }
  }

  async toggleFullscreen() {
    try {
      if (document.fullscreenElement === this.shell) {
        await document.exitFullscreen()
      } else {
        await this.shell.requestFullscreen()
      }
    } catch {
      this.message("Browser full screen is unavailable.")
    }
  }

  refreshFullscreen() {
    const fullscreen = document.fullscreenElement === this.shell
    const button = this.controls.fullscreen
    button.setAttribute("aria-pressed", String(fullscreen))
    button.querySelector("span:last-child").textContent = fullscreen ? "Exit full screen" : "Full screen"
  }

  async end() {
    const view = this.lobby
    const id = this.meetingId
    if (!this.isCallLobby(view) || !view.online || !window.confirm("End this meeting for everyone?")) return

    try {
      const reply = await view.pushEvent("end_meeting", {id})
      if (this.meetingId === id && reply.status === "error") this.message(reply.message)
    } catch {
      if (this.meetingId === id) this.message("Could not end the meeting. Try again.")
    }
  }

  async toggleRecording() {
    const view = this.lobby
    const id = this.meetingId
    const button = this.controls.record
    if (button.hidden || button.disabled) return
    const action = this.recordingStatus() === "recording" ? "stop" : "start"
    if (action === "start" && !window.confirm(
      "Start recording this meeting? Everyone in the call will see a recording indicator. Workspace members can watch the saved recording."
    )) return

    button.dataset.pending = "true"
    this.syncRecording()
    this.message()

    try {
      const reply = await view.pushEvent("recording_control", {id, action})
      if (this.meetingId === id && reply.status === "error") this.message(reply.message)
    } catch {
      if (this.meetingId === id) this.message("Could not update the recording. Check the recording status and try again.")
    } finally {
      delete button.dataset.pending
      this.syncRecording()
    }
  }

  recordingStatus() {
    const status = this.isCallLobby() && this.lobby.el.dataset.recordingStatus
    return status || (this.room?.isRecording ? "recording" : "")
  }

  syncRecording() {
    const view = this.lobby
    const status = this.recordingStatus()
    const button = this.controls.record
    const label = this.elements.recording
    const recording = status === "recording"

    const notice = ({
      starting: this.room?.isRecording ? "Recording" : "Starting recording…",
      recording: "Recording",
      processing: "Saving recording…",
    })[status] || ""

    label.hidden = !notice
    label.dataset.status = status
    if (label.textContent !== notice) label.textContent = notice

    const configured = view?.el.dataset.recordingsConfigured === "true"
    button.hidden = !this.isCallLobby(view) || view.el.dataset.canRecord !== "true"
    button.disabled = !configured || !view?.online || this.phase !== "connected" ||
      status === "starting" || status === "processing" || button.dataset.pending === "true"
    button.setAttribute("aria-pressed", String(recording))
    button.title = configured ? "" : "Set up recording storage to record meetings."
    const action = recording ? "Stop recording" : "Start recording"
    button.querySelector("span:last-child").textContent = configured ? action : "Recording unavailable"
  }

  bindRoom(room) {
    // LiveKit can emit an unsubscribe event before it clears the publication.
    const syncAfterRoomEvent = () => queueMicrotask(() => {
      if (room === this.room) this.syncRoom()
    })
    for (const event of trackEvents) {
      room.on(event, syncAfterRoomEvent)
    }

    room.on(RoomEvent.RecordingStatusChanged, () => {
      if (room === this.room) this.syncRecording()
    })
    room.on(RoomEvent.Reconnecting, () => {
      if (room !== this.room) return
      this.phase = "reconnecting"
      this.elements.state.textContent = "Reconnecting…"
      this.syncRoom()
    })
    room.on(RoomEvent.Reconnected, () => {
      if (room !== this.room) return
      this.phase = "connected"
      this.elements.state.textContent = "In meeting"
      this.syncRoom()
    })
    room.on(RoomEvent.Disconnected, reason => {
      if (room !== this.room) return
      if (this.phase === "connecting") {
        this.leave("Could not connect to the meeting. Try again.")
      } else {
        this.leave(reason === DisconnectReason.ROOM_DELETED
          ? "This meeting has ended." : "You’ve been disconnected from the meeting.")
      }
    })
  }

  leave(message, focus = true) {
    this.attempt++
    const room = this.room
    this.room = null
    this.meetingId = null
    this.phase = "lobby"
    if (room) void room.disconnect().catch(() => {})
    clearMedia(this.tiles)
    clearMedia(this.shares)
    clearMedia(this.audioTracks)
    this.elements.shares.hidden = true
    this.elements.count.textContent = ""
    this.setMode("compact", false)
    this.refreshLobby()
    this.syncRecording()
    this.message(message)
    if (focus) this.lobby?.enter.focus({preventScroll: true})
    window.dispatchEvent(new Event("devloom:meeting-state"))
  }

  async toggle(control, state, method, label) {
    const room = this.room
    if (!room || this.phase !== "connected") return
    const button = this.controls[control]
    const participant = room.localParticipant
    button.dataset.pending = "true"
    button.disabled = true
    this.message()
    const enabling = !participant[state]
    try {
      await participant[method](enabling)
    } catch (error) {
      if (room === this.room) {
        const denied = error?.name === "NotAllowedError" || error?.name === "PermissionDeniedError"
        this.message(denied ? `Permission to use the ${label} was denied.` : `Could not turn ${enabling ? "on" : "off"} the ${label}.`)
      }
    } finally {
      delete button.dataset.pending
      if (room === this.room) this.syncRoom()
    }
  }

  async enableAudio() {
    const room = this.room
    try {
      await room?.startAudio()
    } catch {
      if (room === this.room) this.message("Sound is blocked. Check your browser settings and try again.")
    }
  }

  syncRoom() {
    const room = this.room
    const local = room.localParticipant
    const participants = [local, ...room.remoteParticipants.values()]
    const people = new Set()
    const shares = new Set()
    const audio = new Set()

    for (const participant of participants) {
      const self = participant === local
      const name = participant.name || "Workspace member"
      const label = self ? `${name} (you)` : name
      people.add(participant.identity)
      const tile = getTile(this.tiles, participant.identity, this.elements.participants)
      tile.label.textContent = label
      tile.avatar.textContent = name.trim().split(/\s+/).slice(0, 2).map(word => word[0]).join("").toUpperCase()
      const mic = participant.getTrackPublication(Track.Source.Microphone)
      tile.mic.textContent = mic && !mic.isMuted ? "Mic on" : "Muted"
      setTrack(tile, videoTrack(participant, Track.Source.Camera))
      tile.avatar.hidden = Boolean(tile.track)

      const share = videoTrack(participant, Track.Source.ScreenShare)
      if (share) {
        shares.add(participant.identity)
        const screen = getTile(this.shares, participant.identity, this.elements.shares, true)
        screen.label.textContent = `${label} is sharing`
        setTrack(screen, share)
      }

      if (!self) {
        for (const publication of participant.audioTrackPublications.values()) {
          if (!publication.track) continue
          audio.add(publication.trackSid)
          let item = this.audioTracks.get(publication.trackSid)
          if (!item) {
            const element = document.createElement("audio")
            element.autoplay = true
            item = {element, media: element}
            this.elements.audio.append(element)
            this.audioTracks.set(publication.trackSid, item)
          }
          setTrack(item, publication.track)
        }
      }
    }

    clearMedia(this.tiles, people)
    clearMedia(this.shares, shares)
    clearMedia(this.audioTracks, audio)
    this.elements.shares.hidden = !shares.size
    this.elements.count.textContent = `${people.size} ${people.size === 1 ? "participant" : "participants"}`
    this.controls.audio.hidden = room.canPlaybackAudio
    this.syncRecording()
    this.setControl("microphone", local.isMicrophoneEnabled, "Mic on", "Mic off")
    this.setControl("camera", local.isCameraEnabled, "Camera on", "Camera off")
    this.setControl("screen", local.isScreenShareEnabled, "Stop sharing", "Share screen")
  }

  setControl(key, enabled, on, off) {
    const button = this.controls[key]
    button.setAttribute("aria-pressed", String(enabled))
    button.querySelector("span:last-child").textContent = enabled ? on : off
    button.disabled = this.phase !== "connected" || button.dataset.pending === "true"
  }

  message(text) {
    clearTimeout(this.noticeTimer)
    const lobbyMessage = this.lobby?.message
    for (const element of [this.elements.message, lobbyMessage, this.notice]) {
      if (!element) continue
      element.textContent = ""
      element.hidden = true
    }
    if (!text) return

    const target = this.room ? this.elements.message : lobbyMessage || this.notice
    target.textContent = text
    target.hidden = false
    if (target === this.notice) this.noticeTimer = setTimeout(() => { this.notice.hidden = true }, 8000)
  }
}

function videoTrack(participant, source) {
  const publication = participant.getTrackPublication(source)
  return publication && !publication.isMuted ? publication.track : null
}

function getTile(tiles, identity, container, screen = false) {
  if (tiles.has(identity)) return tiles.get(identity)
  const element = document.createElement("article")
  element.className = screen ? "meeting-tile meeting-tile-share" : "meeting-tile"
  const media = document.createElement("video")
  media.autoplay = true
  media.playsInline = true
  media.muted = true
  media.hidden = true
  const avatar = document.createElement("span")
  avatar.className = "meeting-avatar"
  avatar.hidden = screen
  avatar.setAttribute("aria-hidden", "true")
  const footer = document.createElement("div")
  footer.className = "meeting-tile-caption"
  const label = document.createElement("span")
  const mic = document.createElement("small")
  footer.append(label)
  if (!screen) footer.append(mic)
  element.append(media, avatar, footer)
  container.append(element)
  const tile = {element, media, avatar, label, mic}
  tiles.set(identity, tile)
  return tile
}

function setTrack(item, track) {
  if (item.track === track) return
  item.track?.detach(item.media)
  track?.attach(item.media)
  item.media.hidden = !track
  item.track = track
}

function clearMedia(items, keep = new Set()) {
  for (const [key, item] of items) {
    if (keep.has(key)) continue
    setTrack(item, null)
    item.element.remove()
    items.delete(key)
  }
}
