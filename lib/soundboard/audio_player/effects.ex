defmodule Soundboard.AudioPlayer.Effects do
  @moduledoc """
  Play-time effects. Each is an FFmpeg filter chain applied while decoding, so the
  stored sound never changes. Pitch shifts use asetrate + atempo to avoid needing
  an FFmpeg built with rubberband.
  """

  @presets [
    {"chipmunk", "Chipmunk", "🐿️", "asetrate=76800,aresample=48000,atempo=0.625"},
    {"demon", "Demon", "😈", "asetrate=33600,aresample=48000,atempo=1.4286"},
    {"slow", "Slow-mo", "🐢", "atempo=0.65"},
    {"fast", "Fast", "⚡", "atempo=1.6"},
    {"reverse", "Reverse", "🔁", "areverse"},
    {"cathedral", "Cathedral", "⛪", "aecho=0.8:0.85:120|260|420:0.5|0.35|0.2"},
    {"phone", "Phone", "📞",
     "highpass=f=300,lowpass=f=3400,acrusher=bits=8:mix=0.4:mode=log:aa=1"},
    {"megaphone", "Megaphone", "📢", "highpass=f=600,lowpass=f=3500,volume=3,asoftclip=type=atan"},
    {"underwater", "Underwater", "🫧",
     "lowpass=f=450,chorus=0.6:0.9:50|60:0.4|0.32:0.25|0.4:2|1.3"},
    {"robot", "Robot", "🤖",
     "afftfilt=real='hypot(re,im)*sin(0)':imag='hypot(re,im)*cos(0)':win_size=512:overlap=0.75"},
    {"drunk", "Drunk", "🥴", "vibrato=f=4:d=0.6"},
    {"spin", "8D", "🎧", "apulsator=hz=0.125"},
    {"bass", "Bass boost", "🔊", "bass=g=14:f=90"},
    {"vaporwave", "Vaporwave", "🌴", "asetrate=40320,aresample=48000,aecho=0.8:0.7:180:0.35"}
  ]

  @doc "Presets in display order as `%{id, label, icon}`."
  def all,
    do: Enum.map(@presets, fn {id, label, icon, _} -> %{id: id, label: label, icon: icon} end)

  def valid?(id), do: Enum.any?(@presets, &(elem(&1, 0) == id))

  @doc """
  The full decoder filter for an effect, or nil for none. Input is resampled first so
  asetrate maths holds for any source rate; the limiter keeps boosts from clipping and
  arealtime paces output, since `-re` cannot pace reversed or re-timed audio.
  """
  def filter(id) do
    case Enum.find(@presets, &(elem(&1, 0) == id)) do
      {_, _, _, chain} ->
        "aresample=48000,#{chain},aresample=48000,alimiter=limit=0.9:level=false,arealtime"

      nil ->
        nil
    end
  end
end
