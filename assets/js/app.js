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
Hooks.MasterVolume = {
  mounted() {
    this.editing = false
    updateMaster(this.el.value)
    this.send = () => this.pushEvent("set_master_volume", {volume: this.el.value})
    this.onInput = () => {
      this.editing = true
      updateMaster(this.el.value)
      document.getElementById("master-volume-value").textContent = `${this.el.value}%`
      clearTimeout(this.timer)
      this.timer = setTimeout(this.send, 80)
    }
    this.onChange = () => { clearTimeout(this.timer); this.editing = false; this.send() }
    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("change", this.onChange)
  },
  updated() {
    if (!this.editing) { this.el.value = this.el.getAttribute("value"); updateMaster(this.el.value) }
  },
  destroyed() {
    clearTimeout(this.timer)
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("change", this.onChange)
  }
}
Hooks.MomentEditor = {
  mounted() {
    this.audio = this.el.querySelector("audio")
    const Ctor = getAudioContextCtor()
    this.context = Ctor ? new Ctor() : null
    this.ranges = [...this.el.querySelectorAll("[data-range]")]
    this.fields = [...this.el.querySelectorAll("[data-bound]")]
    this.onRange = (event) => {
      const field = this.fields.find(field => field.dataset.bound === event.target.dataset.range)
      field.value = event.target.value
      field.dispatchEvent(new Event("input", {bubbles: true}))
    }
    this.ranges.forEach(range => range.addEventListener("input", this.onRange))
    this.onPlay = async () => {
      await connectAudio(this.audio, this.context)
      setElementGain(this.audio, 1)
    }
    this.onPreview = async () => {
      await this.onPlay()
      const start = Number(this.fields[0].value), stop = Number(this.fields[1].value)
      if (!(start >= 0 && stop > start && stop <= Number(this.el.dataset.duration))) return
      this.previewEnd = stop
      this.audio.currentTime = start
      await this.audio.play()
    }
    this.onTime = () => { if (this.previewEnd != null && this.audio.currentTime >= this.previewEnd) { this.audio.pause(); this.previewEnd = null } }
    this.onPause = () => { this.previewEnd = null }
    this.preview = this.el.querySelector("[data-preview]")
    this.preview.addEventListener("click", this.onPreview)
    this.audio.addEventListener("play", this.onPlay)
    this.audio.addEventListener("timeupdate", this.onTime)
    this.audio.addEventListener("pause", this.onPause)
    this.updated()
  },
  updated() {
    this.ranges?.forEach(range => { range.value = this.fields.find(field => field.dataset.bound === range.dataset.range).value })
  },
  destroyed() {
    this.audio.pause()
    this.preview.removeEventListener("click", this.onPreview)
    this.ranges.forEach(range => range.removeEventListener("input", this.onRange))
    this.audio.removeEventListener("play", this.onPlay)
    this.audio.removeEventListener("timeupdate", this.onTime)
    this.audio.removeEventListener("pause", this.onPause)
    browserAudio.delete(this.audio)
    this.context?.close()
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

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
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
