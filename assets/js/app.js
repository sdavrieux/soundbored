// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const clamp = (value, min, max) => Math.min(Math.max(value, min), max)
const roundTo = (value, decimals = 4) => {
  const factor = Math.pow(10, decimals)
  return Math.round(value * factor) / factor
}

const MAX_VOLUME_PERCENT_DEFAULT = 150
const BOOST_CAP = 1.5

const getAudioContextCtor = () => window.AudioContext || window.webkitAudioContext || null

const parsePercent = (
  value,
  fallback = MAX_VOLUME_PERCENT_DEFAULT,
  maxPercent = MAX_VOLUME_PERCENT_DEFAULT
) => {
  const parseNumeric = (input) => {
    if (typeof input === "number" && Number.isFinite(input)) {
      return input
    }
    if (typeof input === "string") {
      const parsed = parseFloat(input.trim())
      if (!Number.isNaN(parsed)) {
        return parsed
      }
    }
    return null
  }

  const parsedValue = parseNumeric(value)
  const parsedFallback = parseNumeric(fallback)
  const base = parsedValue === null ? (parsedFallback === null ? maxPercent : parsedFallback) : parsedValue
  return clamp(Math.round(base), 0, maxPercent)
}

const percentToGain = (percent, maxPercent = MAX_VOLUME_PERCENT_DEFAULT) => {
  const clampedPercent = clamp(Math.round(percent), 0, maxPercent)
  if (clampedPercent <= 100) {
    return roundTo(clampedPercent / 100)
  }
  const boosted = 1 + (clampedPercent - 100) * 0.01
  return roundTo(Math.min(boosted, BOOST_CAP))
}

let masterGain = 1
const browserAudio = new Set()
const setElementGain = (audio, gain) => {
  if (!audio) return
  audio.__clipGain = clamp(gain, 0, BOOST_CAP)
  browserAudio.add(audio)
  const combined = audio.__clipGain * masterGain
  if (audio.__gainNode) {
    audio.volume = 1
    audio.__gainNode.gain.setValueAtTime(combined, audio.__context.currentTime)
  } else {
    audio.volume = Math.min(combined, 1)
  }
}
const updateMaster = (percent) => {
  masterGain = clamp(Number(percent), 0, 100) / 100
  for (const audio of browserAudio) setElementGain(audio, audio.__clipGain ?? 1)
}
const connectAudio = async (audio, context) => {
  if (!context) return
  if (!audio.__gainNode) {
    const source = context.createMediaElementSource(audio)
    const gain = context.createGain()
    source.connect(gain).connect(context.destination)
    audio.__gainNode = gain
    audio.__context = context
    audio.__source = source
  }
  if (context.state === "suspended") await context.resume()
}
window.addEventListener("phx:master-volume", (event) => updateMaster(event.detail.volume))
window.addEventListener("phx:stop-all-sounds", () => {
  for (const audio of browserAudio) { audio.pause(); audio.currentTime = 0 }
})

let activeLocalPlayer = null

const stopActiveLocalPlayer = () => {
  if (activeLocalPlayer && typeof activeLocalPlayer.stopPlayback === "function") {
    activeLocalPlayer.stopPlayback()
  }
}

window.addEventListener("phx:stop-all-sounds", stopActiveLocalPlayer)

let Hooks = {}
Hooks.Sidebar = {
  // Desktop/iPad: a sidebar that collapses to an icon rail (choice remembered).
  // Phone: hidden off-canvas, opened from the top bar as a drawer over the content.
  mounted() {
    this.button = this.el.querySelector("[data-sidebar-toggle]")
    this.media = window.matchMedia("(max-width: 639px)")
    try { this.preference = localStorage.getItem("soundboard.sidebar.collapsed") } catch (_err) {}
    this.collapsed = this.media.matches || this.preference === "true"
    this.apply = () => {
      const phone = this.media.matches
      document.body.classList.toggle("sidebar-collapsed", this.collapsed)
      document.body.classList.toggle("drawer-open", phone && !this.collapsed)
      this.el.dataset.collapsed = String(this.collapsed)
      document.querySelectorAll("[data-sidebar-toggle][aria-label]").forEach(button => {
        button.setAttribute("aria-expanded", String(!this.collapsed))
        button.setAttribute("aria-label", phone
          ? (this.collapsed ? "Open menu" : "Close menu")
          : (this.collapsed ? "Expand sidebar" : "Collapse sidebar"))
      })
    }
    this.toggle = (event) => {
      if (!event.target.closest("[data-sidebar-toggle]")) return
      this.collapsed = !this.collapsed
      if (!this.media.matches) {
        this.preference = String(this.collapsed)
        try { localStorage.setItem("soundboard.sidebar.collapsed", this.preference) } catch (_err) {}
      }
      this.apply()
    }
    // Following a link on a phone closes the drawer so the new page is visible.
    this.onNavigate = (event) => {
      if (this.media.matches && event.target.closest("a")) { this.collapsed = true; this.apply() }
    }
    this.onKey = (event) => {
      if (event.key === "Escape" && this.media.matches && !this.collapsed) { this.collapsed = true; this.apply() }
    }
    this.resize = () => {
      this.collapsed = this.media.matches || this.preference === "true"
      this.apply()
    }
    document.addEventListener("click", this.toggle)
    this.el.addEventListener("click", this.onNavigate)
    window.addEventListener("keydown", this.onKey)
    this.media.addEventListener("change", this.resize)
    this.apply()
  },
  updated() { this.apply() },
  destroyed() {
    document.removeEventListener("click", this.toggle)
    this.el.removeEventListener("click", this.onNavigate)
    window.removeEventListener("keydown", this.onKey)
    this.media.removeEventListener("change", this.resize)
    document.body.classList.remove("drawer-open")
  }
}

Hooks.MasterVolume = {
  mounted() {
    this.editing = false
    this.timer = null
    this.apply = () => {
      updateMaster(this.el.value)
      this.el.style.setProperty("--fill", `${this.el.value}%`)
    }
    this.apply()
    this.send = () => this.pushEvent("set_master_volume", {volume: this.el.value})
    // Throttle rather than debounce so Discord follows the slider while it is dragged.
    this.onInput = () => {
      this.editing = true
      this.apply()
      document.getElementById("master-volume-value").textContent = `${this.el.value}%`
      if (!this.timer) this.timer = setTimeout(() => { this.timer = null; this.send() }, 80)
    }
    this.onChange = () => {
      clearTimeout(this.timer)
      this.timer = null
      this.editing = false
      this.send()
    }
    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("change", this.onChange)
  },
  updated() {
    if (this.editing) this.el.style.setProperty("--fill", `${this.el.value}%`)
    else { this.el.value = this.el.getAttribute("value"); this.apply() }
  },
  destroyed() {
    clearTimeout(this.timer)
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("change", this.onChange)
  }
}
// Shows a UTC timestamp in the viewer's own time zone, e.g. "Tue 4 Nov, 21:14".
const localTimeFormat = new Intl.DateTimeFormat(undefined, {
  weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit"
})
Hooks.LocalTime = {
  mounted() { this.format() },
  updated() { this.format() },
  format() {
    const date = new Date(this.el.getAttribute("datetime"))
    if (!Number.isNaN(date.getTime())) this.el.textContent = localTimeFormat.format(date)
  }
}

// Keeps the active FX chip visible in the scrolling strip. Only re-centres when the
// choice changes, so the capture timer's updates don't fight someone scrolling.
Hooks.FxStrip = {
  mounted() { this.reveal() },
  updated() { this.reveal() },
  reveal() {
    const active = this.el.querySelector(".is-active")
    const id = active?.id || null
    if (id === this.shown) return
    this.shown = id
    if (active) this.el.scrollLeft = active.offsetLeft - (this.el.clientWidth - active.offsetWidth) / 2
  }
}
// Moment cutter. The recording is decoded once with Web Audio, so "Play cut" plays
// exactly the selected samples: no seeking an <audio> element (which iPad Safari
// often ignores before buffering) and no timeupdate overshoot at the end.
const MIN_CUT = 0.05
const formatCutTime = (seconds) => {
  const minutes = Math.floor(seconds / 60)
  return `${minutes}:${(seconds - minutes * 60).toFixed(2).padStart(5, "0")}`
}
const round2 = (value) => Math.round(value * 100) / 100

Hooks.MomentEditor = {
  mounted() {
    this.duration = Number(this.el.dataset.duration)
    this.start = Number(this.el.dataset.start)
    this.stop = Number(this.el.dataset.stop)
    this.playhead = null
    this.highlights = this.readHighlights()
    this.cutter = this.el.querySelector("[data-cutter]")
    this.wave = this.el.querySelector("[data-wave]")
    this.canvas = this.wave.querySelector("canvas")
    this.handles = {
      start: this.wave.querySelector('[data-handle="start"]'),
      stop: this.wave.querySelector('[data-handle="stop"]')
    }
    const Ctor = getAudioContextCtor()
    this.context = Ctor ? new Ctor() : null
    // iOS 17+: play through the silent switch like a media app.
    try { if (navigator.audioSession) navigator.audioSession.type = "playback" } catch (_) {}

    this.onPointerDown = (event) => this.pointerDown(event)
    this.onPointerMove = (event) => this.pointerMove(event)
    this.onPointerUp = () => this.pointerUp()
    this.onClick = (event) => this.click(event)
    this.onKey = (event) => this.key(event)
    this.onStopAll = () => this.stopPlayback()
    this.wave.addEventListener("pointerdown", this.onPointerDown)
    this.wave.addEventListener("pointermove", this.onPointerMove)
    this.wave.addEventListener("pointerup", this.onPointerUp)
    this.wave.addEventListener("pointercancel", this.onPointerUp)
    this.cutter.addEventListener("click", this.onClick)
    Object.values(this.handles).forEach(handle => handle.addEventListener("keydown", this.onKey))
    window.addEventListener("phx:stop-all-sounds", this.onStopAll)
    this.resizer = new ResizeObserver(() => this.draw())
    this.resizer.observe(this.wave)
    this.handleEvent("moment-preview", () => this.play("selection"))

    this.load(this.el.dataset.src)
    this.render()
  },

  updated() {
    if (this.el.dataset.src !== this.src) this.load(this.el.dataset.src)
    this.highlights = this.readHighlights()
    // The server echoes our own edits; it only moves the cut for Auto-trim/highlights.
    if (!this.dragging) {
      this.start = Number(this.el.dataset.start)
      this.stop = Number(this.el.dataset.stop)
    }
    this.render()
  },

  destroyed() {
    this.stopPlayback()
    this.resizer.disconnect()
    window.removeEventListener("phx:stop-all-sounds", this.onStopAll)
    this.context?.close()
  },

  readHighlights() {
    try { return JSON.parse(this.el.dataset.highlights || "[]") } catch (_) { return [] }
  },

  status(message) {
    const status = this.wave.querySelector("[data-status]")
    status.hidden = !message
    status.textContent = message || ""
  },

  async load(src) {
    this.src = src
    this.stopPlayback()
    this.buffer = null
    this.peaks = null
    this.draw()
    if (!this.context) return this.status("This browser cannot play the editor. Use Download WAV.")
    this.status("Loading audio…")
    const token = (this.loading = {})

    try {
      const response = await fetch(src, {credentials: "same-origin"})
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const data = await response.arrayBuffer()
      // Older Safari only has the callback form of decodeAudioData.
      const buffer = await new Promise((resolve, reject) => {
        const result = this.context.decodeAudioData(data, resolve, reject)
        if (result && result.then) result.then(resolve, reject)
      })
      if (token !== this.loading) return
      this.buffer = buffer
      this.status(null)
      this.draw()
    } catch (_) {
      if (token === this.loading) this.status("Could not load this recording. Try Download WAV.")
    }
  },

  // --- selection ------------------------------------------------------------

  setBound(bound, seconds) {
    if (bound === "start") this.start = round2(clamp(seconds, 0, this.stop - MIN_CUT))
    else this.stop = round2(clamp(seconds, this.start + MIN_CUT, this.duration))
    this.render()
  },

  // Hidden form fields carry the cut to the server (save, publish, Auto-trim).
  push() {
    const start = this.el.querySelector("#trim-start")
    const stop = this.el.querySelector("#trim-stop")
    if (!start || !stop) return
    start.value = this.start
    stop.value = this.stop
    start.dispatchEvent(new Event("input", {bubbles: true}))
  },

  render() {
    const percent = (seconds) => `${(seconds / this.duration) * 100}%`
    this.wave.querySelector('[data-shade="start"]').style.cssText = `left:0;width:${percent(this.start)}`
    this.wave.querySelector('[data-shade="stop"]').style.cssText = `left:${percent(this.stop)};right:0`
    for (const [bound, handle] of Object.entries(this.handles)) {
      const value = this[bound]
      handle.style.left = percent(value)
      handle.setAttribute("aria-valuemax", this.duration)
      handle.setAttribute("aria-valuenow", value)
      handle.setAttribute("aria-valuetext", formatCutTime(value))
    }
    this.cutter.querySelector('[data-time="start"]').textContent = formatCutTime(this.start)
    this.cutter.querySelector('[data-time="stop"]').textContent = formatCutTime(this.stop)
    this.cutter.querySelector('[data-time="length"]').textContent = `${(this.stop - this.start).toFixed(2)} s`
    this.renderPlayhead()
    this.draw()
  },

  renderPlayhead() {
    const line = this.wave.querySelector("[data-playhead]")
    line.hidden = this.playhead == null
    if (this.playhead != null) line.style.left = `${(this.playhead / this.duration) * 100}%`
  },

  draw() {
    const width = this.wave.clientWidth
    const height = this.wave.clientHeight
    if (!width || !height) return
    const ratio = window.devicePixelRatio || 1
    this.canvas.width = Math.round(width * ratio)
    this.canvas.height = Math.round(height * ratio)
    const ctx = this.canvas.getContext("2d")
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0)
    ctx.clearRect(0, 0, width, height)

    // Highlights are a band along the top so they never hide the waveform.
    for (const [from, to] of this.highlights) {
      ctx.fillStyle = "#f59e0b"
      ctx.fillRect((from / this.duration) * width, 0, ((to - from) / this.duration) * width, 5)
    }
    if (!this.buffer) return

    const columns = Math.floor(width / 3)
    if (!this.peaks || this.peaks.length !== columns) this.peaks = this.computePeaks(columns)
    const dark = window.matchMedia("(prefers-color-scheme: dark)").matches
    const middle = height / 2
    this.peaks.forEach((peak, index) => {
      const time = ((index + 0.5) / columns) * this.duration
      const inside = time >= this.start && time <= this.stop
      ctx.fillStyle = inside ? (dark ? "#60a5fa" : "#2563eb") : (dark ? "#4b5563" : "#9ca3af")
      const bar = Math.max(1, peak * (height - 8))
      ctx.fillRect(index * 3, middle - bar / 2, 2, bar)
    })
  },

  computePeaks(columns) {
    const samples = this.buffer.getChannelData(0)
    const size = Math.max(1, Math.floor(samples.length / columns))
    const peaks = new Array(columns)
    let loudest = 0
    for (let column = 0; column < columns; column++) {
      let peak = 0
      const end = Math.min(samples.length, (column + 1) * size)
      for (let index = column * size; index < end; index++) {
        const value = Math.abs(samples[index])
        if (value > peak) peak = value
      }
      peaks[column] = peak
      if (peak > loudest) loudest = peak
    }
    // Normalise so quiet voice chat still shows a readable shape.
    return peaks.map(peak => (loudest > 0 ? Math.sqrt(peak / loudest) : 0))
  },

  timeAt(event) {
    const box = this.wave.getBoundingClientRect()
    return clamp((event.clientX - box.left) / box.width, 0, 1) * this.duration
  },

  // --- touch and mouse ------------------------------------------------------

  pointerDown(event) {
    const handle = event.target.closest("[data-handle]")
    event.preventDefault()
    this.wave.setPointerCapture(event.pointerId)
    if (handle) {
      this.dragging = handle.dataset.handle
      handle.focus({preventScroll: true})
    } else {
      // Tap anywhere else: move the playhead there and listen from it.
      this.playhead = this.timeAt(event)
      this.renderPlayhead()
      this.play("all", true)
    }
  },

  pointerMove(event) {
    if (!this.dragging) return
    this.setBound(this.dragging, this.timeAt(event))
  },

  pointerUp() {
    if (!this.dragging) return
    const bound = this.dragging
    this.dragging = null
    this.push()
    this.audition(bound)
  },

  key(event) {
    const bound = event.target.dataset.handle
    const step = event.shiftKey ? 0.5 : 0.05
    const moves = {ArrowLeft: -step, ArrowDown: -step, ArrowRight: step, ArrowUp: step}
    if (!(event.key in moves)) return
    event.preventDefault()
    this.setBound(bound, this[bound] + moves[event.key])
    this.push()
  },

  click(event) {
    const button = event.target.closest("button")
    if (!button || !this.cutter.contains(button)) return
    if (button.dataset.nudge) {
      const [bound, delta] = button.dataset.nudge.split(":")
      this.setBound(bound, this[bound] + Number(delta))
      this.push()
      this.audition(bound)
    } else if (button.dataset.mark) {
      if (this.playhead == null) return
      this.setBound(button.dataset.mark, this.playhead)
      this.push()
    } else if (button.dataset.play) {
      this.play(button.dataset.play)
    }
  },

  // After moving an end, play the two seconds around it so the edge can be judged.
  audition(bound) {
    if (bound === "start") this.playRange(this.start, Math.min(this.stop, this.start + 2), "selection")
    else this.playRange(Math.max(this.start, this.stop - 2), this.stop, "selection")
  },

  // --- playback -------------------------------------------------------------

  play(mode, restart = false) {
    if (this.mode === mode && !restart) return this.stopPlayback()
    if (mode === "selection") return this.playRange(this.start, this.stop, mode)
    let from = this.playhead ?? this.start
    if (from >= this.duration - MIN_CUT) from = 0
    this.playRange(from, this.duration, mode)
  },

  async playRange(from, to, mode) {
    if (!this.buffer || !this.context) return
    this.stopPlayback()
    if (this.context.state === "suspended") await this.context.resume()
    const source = this.context.createBufferSource()
    const gain = this.context.createGain()
    gain.gain.value = masterGain
    source.buffer = this.buffer
    source.connect(gain).connect(this.context.destination)
    source.onended = () => { if (this.source === source) this.stopPlayback() }
    source.start(0, from, Math.max(0.01, to - from))
    this.source = source
    this.mode = mode
    this.startedAt = this.context.currentTime
    this.offset = from
    this.cutter.dataset.playing = mode
    const tick = () => {
      if (this.source !== source) return
      this.playhead = Math.min(to, this.offset + this.context.currentTime - this.startedAt)
      this.renderPlayhead()
      this.frame = requestAnimationFrame(tick)
    }
    tick()
  },

  stopPlayback() {
    if (this.frame) cancelAnimationFrame(this.frame)
    const source = this.source
    this.source = null
    this.mode = null
    if (this.cutter) delete this.cutter.dataset.playing
    try { source?.stop() } catch (_) {}
  }
}
Hooks.LocalPlayer = {
  mounted() {
    this.audio = null
    this.audioContext = null
    this.cleanup = null
    this.handleClick = this.handleClick.bind(this)
    this.el.addEventListener("click", this.handleClick)
  },
  updated() {
    if (this.audio && !this.audio.paused) {
      this.configureGain(this.readGain())
    }
  },
  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
    this.stopPlayback()
    this.audioContext?.close()
  },
  readGain() {
    const raw = parseFloat(this.el.dataset.volume)
    return Number.isFinite(raw) ? clamp(raw, 0, BOOST_CAP) : 1
  },
  async handleClick(event) {
    event.preventDefault()
    event.stopPropagation()

    if (this.audio && !this.audio.paused) {
      this.stopPlayback()
      return
    }

    if (activeLocalPlayer && activeLocalPlayer !== this) {
      activeLocalPlayer.stopPlayback()
    }

    await this.startPlayback()
  },
  async startPlayback() {
    this.stopPlayback()

    const sourceType = this.el.dataset.sourceType
    const url = this.el.dataset.url
    const filename = this.el.dataset.filename

    const audio = new Audio()

    if (sourceType === "url" && url) {
      audio.crossOrigin = "anonymous"
      audio.src = url
    } else if (filename) {
      audio.src = `/uploads/${filename}`
    } else {
      return
    }

    audio.addEventListener("ended", () => this.stopPlayback())
    audio.addEventListener("error", () => this.stopPlayback())

    this.audio = audio

    await this.configureGain(this.readGain())

    try {
      await audio.play()
      this.setPlaying(true)
      activeLocalPlayer = this
    } catch (error) {
      console.error("Audio playback failed", error)
      this.stopPlayback()
    }
  },
  async configureGain(targetGain) {
    if (!this.audio) return
    const ContextCtor = getAudioContextCtor()
    if (!this.audioContext && ContextCtor) this.audioContext = new ContextCtor()
    try { await connectAudio(this.audio, this.audioContext) } catch (_err) {}
    setElementGain(this.audio, targetGain)
  },
  releaseBoost() {
    if (this.audio) {
      browserAudio.delete(this.audio)
      this.audio.__source?.disconnect()
      this.audio.__gainNode?.disconnect()
    }
  },
  stopPlayback() {
    this.releaseBoost()
    if (this.audio) {
      try {
        this.audio.pause()
        this.audio.currentTime = 0
      } catch (_err) {}
      this.audio = null
    }
    this.setPlaying(false)
    if (activeLocalPlayer === this) {
      activeLocalPlayer = null
    }
  },
  setPlaying(isPlaying) {
    const playIcon = this.el.querySelector(".play-icon")
    const stopIcon = this.el.querySelector(".stop-icon")

    if (!playIcon || !stopIcon) {
      return
    }

    if (isPlaying) {
      playIcon.classList.add("hidden")
      stopIcon.classList.remove("hidden")
    } else {
      playIcon.classList.remove("hidden")
      stopIcon.classList.add("hidden")
    }
  }
}

Hooks.VolumeControl = {
  mounted() {
    this.previewAudio = null
    this.previewContext = null
    this.previewSource = null
    this.previewGain = null
    this.objectUrl = null
    this.lastFile = null
    this.pushTimer = null
    this.previewLabel = "Preview"

    this.handleSliderInput = this.handleSliderInput.bind(this)
    this.handlePreviewClick = this.handlePreviewClick.bind(this)

    this.syncDataset()
    this.bindElements()

    this.setPercent(this.initialPercent(), {emit: false})
  },
  updated() {
    const previousKind = this.previewKind
    const previousSrc = this.previewSrc

    this.syncDataset()
    this.bindElements()
    this.setPercent(this.initialPercent(), {emit: false})

    if (previousKind && previousKind !== this.previewKind) {
      this.stopPreview(true)
    } else if (previousSrc !== this.previewSrc && this.previewKind !== "local-upload") {
      this.stopPreview()
    }
  },
  destroyed() {
    if (this.slider) {
      this.slider.removeEventListener("input", this.handleSliderInput)
    }
    if (this.previewButton) {
      this.previewButton.removeEventListener("click", this.handlePreviewClick)
    }
    if (this.pushTimer) {
      clearTimeout(this.pushTimer)
      this.pushTimer = null
    }
    this.stopPreview(true)
    if (this.previewSource) {
      try {
        this.previewSource.disconnect()
      } catch (_err) {}
    }
    if (this.previewGain) {
      try {
        this.previewGain.disconnect()
      } catch (_err) {}
    }
    this.previewSource = null
    this.previewGain = null
    if (this.previewContext) {
      try {
        this.previewContext.close()
      } catch (_err) {}
      this.previewContext = null
    }
  },
  syncDataset() {
    const dataset = this.el.dataset
    const parsedMax = parseInt(dataset.maxPercent || "", 10)
    this.maxPercent =
      Number.isInteger(parsedMax) && parsedMax > 0 ? parsedMax : MAX_VOLUME_PERCENT_DEFAULT
    this.pushEventName = dataset.pushEvent || null
    this.volumeTarget = dataset.volumeTarget || null
    this.previewKind = dataset.previewKind || "existing"
    this.fileInputId = dataset.fileInputId || null
    this.urlInputId = dataset.urlInputId || null
    this.previewSrc = dataset.previewSrc || ""
  },
  bindElements() {
    const slider = this.el.querySelector("[data-role='volume-slider']")
    if (this.slider !== slider) {
      if (this.slider) {
        this.slider.removeEventListener("input", this.handleSliderInput)
      }
      this.slider = slider
      if (this.slider) {
        this.slider.addEventListener("input", this.handleSliderInput)
      }
    }

    const previewButton = this.el.querySelector("[data-role='volume-preview']")
    if (this.previewButton !== previewButton) {
      if (this.previewButton) {
        this.previewButton.removeEventListener("click", this.handlePreviewClick)
      }
      this.previewButton = previewButton
      if (this.previewButton) {
        this.previewButton.addEventListener("click", this.handlePreviewClick)
      }
    }

    if (this.previewButton) {
      this.previewLabel = this.previewButton.textContent?.trim() || this.previewLabel
    }

    this.hiddenInput = this.el.querySelector("[data-role='volume-hidden']")
    this.display = this.el.querySelector("[data-role='volume-display']")
  },
  initialPercent() {
    const hiddenValue = this.hiddenInput?.value
    const sliderValue = this.slider?.value
    return parsePercent(hiddenValue ?? sliderValue ?? this.maxPercent, this.maxPercent, this.maxPercent)
  },
  setPercent(percent, {emit = false} = {}) {
    const bounded = clamp(Math.round(percent), 0, this.maxPercent)
    if (this.slider && Number(this.slider.value) !== bounded) {
      this.slider.value = bounded
    }

    if (this.hiddenInput && Number(this.hiddenInput.value) !== bounded) {
      this.hiddenInput.value = bounded
    }

    if (this.display) {
      this.display.textContent = `${bounded}%`
    }

    if (emit) {
      this.queuePush(bounded)
    }

    this.updatePreviewGain(bounded)
  },
  async handleSliderInput(event) {
    const fallback = this.hiddenInput?.value ?? this.slider?.value ?? this.maxPercent
    const nextPercent = parsePercent(event.target.value, fallback, this.maxPercent)
    event.target.value = nextPercent
    this.setPercent(nextPercent, {emit: true})
  },
  queuePush(percent) {
    if (!this.pushEventName) {
      return
    }

    if (this.pushTimer) {
      clearTimeout(this.pushTimer)
    }

    this.pushTimer = setTimeout(() => {
      const payload = {volume: percent}
      if (this.volumeTarget) {
        payload.target = this.volumeTarget
      }
      this.pushEvent(this.pushEventName, payload)
      this.pushTimer = null
    }, 100)
  },
  async handlePreviewClick(event) {
    event.preventDefault()

    if (this.previewButton && this.previewButton.disabled) {
      return
    }

    if (this.previewAudio && !this.previewAudio.paused) {
      this.stopPreview()
      return
    }

    const src = this.getPreviewSource()
    if (!src) {
      return
    }

    if (!this.previewAudio) {
      this.previewAudio = new Audio()
      this.previewAudio.crossOrigin = "anonymous"
      this.previewAudio.addEventListener("ended", () => this.stopPreview())
      this.previewAudio.addEventListener("error", () => this.stopPreview())
    }

    this.previewAudio.src = src

    const percent = parsePercent(
      this.hiddenInput?.value ?? this.slider?.value ?? this.maxPercent,
      this.maxPercent,
      this.maxPercent
    )
    const gain = percentToGain(percent, this.maxPercent)
    await this.ensurePreviewGraph(gain)
    this.applyPreviewGain(gain)

    try {
      await this.previewAudio.play()
      this.setPreviewState(true)
    } catch (error) {
      console.error("Preview playback failed", error)
      this.setPreviewState(false)
    }
  },
  async updatePreviewGain(percent) {
    const gain = percentToGain(percent, this.maxPercent)

    if (!this.previewAudio) {
      return
    }

    await this.ensurePreviewGraph(gain)
    this.applyPreviewGain(gain)
  },
  async ensurePreviewGraph() {
    if (!this.previewAudio) return
    const ContextCtor = getAudioContextCtor()
    if (!ContextCtor) return
    if (!this.previewContext) this.previewContext = new ContextCtor()
    try {
      await connectAudio(this.previewAudio, this.previewContext)
      this.previewSource = this.previewAudio.__source
      this.previewGain = this.previewAudio.__gainNode
    } catch (_err) {}
  },
  applyPreviewGain(targetGain) {
    setElementGain(this.previewAudio, targetGain)
  },
  getPreviewSource() {
    if (this.previewKind === "local-upload" && this.fileInputId) {
      const input = document.getElementById(this.fileInputId)
      const file = input && input.files && input.files[0]

      if (!file) {
        return null
      }

      if (this.lastFile !== file) {
        if (this.objectUrl) {
          URL.revokeObjectURL(this.objectUrl)
        }
        this.objectUrl = URL.createObjectURL(file)
        this.lastFile = file
      }

      return this.objectUrl
    }

    if (this.previewKind === "url") {
      if (this.urlInputId) {
        const urlInput = document.getElementById(this.urlInputId)
        const value =
          urlInput && typeof urlInput.value === "string" ? urlInput.value.trim() : ""
        if (value) {
          return value
        }
      }

      return this.previewSrc || null
    }

    return this.previewSrc || null
  },
  stopPreview(forceRevoke = false) {
    if (this.previewAudio) {
      browserAudio.delete(this.previewAudio)
      try {
        this.previewAudio.pause()
        this.previewAudio.currentTime = 0
      } catch (_err) {}
      this.previewAudio.src = ""
    }
    this.setPreviewState(false)

    if (forceRevoke && this.objectUrl) {
      URL.revokeObjectURL(this.objectUrl)
      this.objectUrl = null
      this.lastFile = null
    }
  },
  setPreviewState(isPlaying) {
    if (!this.previewButton) {
      return
    }

    this.previewButton.textContent = isPlaying ? "Stop Preview" : this.previewLabel
    this.previewButton.dataset.previewState = isPlaying ? "playing" : "stopped"
  }
}

Hooks.CopyButton = {
  mounted() {
    this.handleClick = async (e) => {
      e.preventDefault()
      const original = this.el.textContent
      const text =
        this.el.dataset.copyText ||
        this.el.getAttribute("data-copy-text") ||
        (this.el.nextElementSibling ? this.el.nextElementSibling.innerText : "")
      try {
        if (navigator.clipboard && window.isSecureContext) {
          await navigator.clipboard.writeText(text)
        } else {
          // Fallback for insecure contexts
          const ta = document.createElement("textarea")
          ta.value = text
          ta.style.position = "fixed"
          ta.style.opacity = "0"
          document.body.appendChild(ta)
          ta.select()
          document.execCommand("copy")
          document.body.removeChild(ta)
        }
        this.el.textContent = "Copied!"
        this.el.classList.add("text-green-600")
        setTimeout(() => {
          this.el.textContent = original
          this.el.classList.remove("text-green-600")
        }, 1500)
      } catch (_err) {
        this.el.textContent = "Copy failed"
        this.el.classList.add("text-red-600")
        setTimeout(() => {
          this.el.textContent = original
          this.el.classList.remove("text-red-600")
        }, 1500)
      }
    }
    this.el.addEventListener("click", this.handleClick)
  },
  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
  }
}

// The FX chosen in the bottom bar follows you between pages and reloads.
const fxKey = "soundboard-fx"
window.addEventListener("phx:fx-changed", (event) => {
  try {
    if (event.detail.effect) localStorage.setItem(fxKey, event.detail.effect)
    else localStorage.removeItem(fxKey)
  } catch (_) {}
})
const savedFx = () => { try { return localStorage.getItem(fxKey) } catch (_) { return null } }

let liveSocket = new LiveSocket("/live", Socket, {
  params: () => ({_csrf_token: csrfToken, fx: savedFx()}),
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300))
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

if (window.navigator.standalone) {
  document.documentElement.style.setProperty("--sat", "env(safe-area-inset-top)")
  document.documentElement.classList.add("standalone")
}
