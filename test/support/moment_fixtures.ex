defmodule Soundboard.MomentFixtures do
  @moduledoc false
  def create(directory, suffix \\ "0123456789abcdef") do
    File.mkdir_p!(directory)
    name = "moment-20260101T120000Z-#{suffix}.wav"
    path = Path.join(directory, name)
    pcm = for index <- 1..96_000, into: <<>>, do: <<rem(index, 1000)::little-signed-16>>
    size = byte_size(pcm)

    File.write!(
      path,
      <<"RIFF", size + 36::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
        48_000::little-32, 96_000::little-32, 2::little-16, 16::little-16, "data",
        size::little-32, pcm::binary>>
    )

    name
  end
end
