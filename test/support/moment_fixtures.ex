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

  @doc """
  A two-second moment where Ana talks for the first second and Ben for the second,
  with a stem for each, as a capture with two speakers would leave it.
  """
  def create_with_stems(directory, suffix \\ "fedcba9876543210") do
    File.mkdir_p!(directory)
    name = "moment-20260102T120000Z-#{suffix}.wav"
    ana = tone(0..47_999) <> silence(48_000)
    ben = silence(48_000) <> tone(48_000..95_999)
    write(Path.join(directory, name), mix(ana, ben))
    stems = Path.join(directory, name <> ".stems")
    File.mkdir_p!(stems)
    write(Path.join(stems, "1.wav"), ana)
    write(Path.join(stems, "2.wav"), ben)

    File.write!(
      Path.join(directory, name <> ".json"),
      Jason.encode!(%{title: nil, tags: [], revision: "r1", speakers: ["Ana", "Ben"]})
    )

    name
  end

  defp tone(range),
    do:
      for(
        index <- range,
        into: <<>>,
        do: <<if(rem(index, 100) < 50, do: 8000, else: -8000)::little-signed-16>>
      )

  defp silence(samples), do: :binary.copy(<<0::16>>, samples)

  defp mix(a, b) do
    for {<<x::little-signed-16>>, <<y::little-signed-16>>} <- Enum.zip(chunks(a), chunks(b)),
        into: <<>>,
        do: <<x + y::little-signed-16>>
  end

  defp chunks(pcm), do: for(<<sample::binary-size(2) <- pcm>>, do: sample)

  defp write(path, pcm) do
    size = byte_size(pcm)

    File.write!(
      path,
      <<"RIFF", size + 36::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
        48_000::little-32, 96_000::little-32, 2::little-16, 16::little-16, "data",
        size::little-32, pcm::binary>>
    )
  end
end
