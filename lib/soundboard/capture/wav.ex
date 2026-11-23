defmodule Soundboard.Capture.Wav do
  @moduledoc """
  The only audio format moments use: 48 kHz mono 16-bit PCM WAV.
  Chunks are parsed instead of assuming FFmpeg's header is always the same size.
  """

  @bytes_per_second 96_000

  def bytes_per_second, do: @bytes_per_second

  @doc "Returns the PCM data offset and size, or an error for anything but our format."
  def format(path) do
    File.open(path, [:read, :binary], fn io ->
      case IO.binread(io, 12) do
        <<"RIFF", _::little-32, "WAVE">> -> chunks(io, nil)
        _ -> {:error, :invalid_audio}
      end
    end)
    |> unwrap()
  end

  @doc "Reads the whole PCM payload. Moments are at most a minute, so this stays small."
  def read(path) do
    with {:ok, info} <- format(path) do
      File.open(path, [:read, :binary], &read_data(&1, info))
      |> unwrap()
    end
  end

  defp read_data(io, info) do
    {:ok, _} = :file.position(io, info.offset)

    case IO.binread(io, info.size) do
      data when is_binary(data) and byte_size(data) == info.size -> {:ok, data}
      _ -> {:error, :invalid_audio}
    end
  end

  def header(size) do
    <<"RIFF", size + 36::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
      48_000::little-32, @bytes_per_second::little-32, 2::little-16, 16::little-16, "data",
      size::little-32>>
  end

  @doc "Copies the samples between two times (seconds) into a new private file."
  def copy_segment(path, output, start, stop) do
    with {:ok, info} <- format(path) do
      first = trunc(start * 48_000) * 2
      size = max(0, min(trunc(stop * 48_000) * 2, info.size) - first)

      File.open(path, [:read, :binary], fn source ->
        write_segment(source, output, header(size), info.offset + first, size)
      end)
      |> unwrap()
    end
  end

  defp chunks(io, rate) do
    case IO.binread(io, 8) do
      <<"fmt ", size::little-32>> when size >= 16 and size <= 1024 ->
        read_format(io, size)

      <<"data", size::little-32>> when not is_nil(rate) ->
        {:ok, offset} = :file.position(io, :cur)
        {:ok, %{offset: offset, size: size, rate: rate}}

      <<_, _, _, _, size::little-32>> when size < 65_536 ->
        :file.position(io, {:cur, size + rem(size, 2)})
        chunks(io, rate)

      _ ->
        {:error, :invalid_audio}
    end
  end

  defp read_format(io, size) do
    case IO.binread(io, size) do
      <<1::little-16, 1::little-16, 48_000::little-32, @bytes_per_second::little-32, 2::little-16,
        16::little-16, _::binary>> ->
        if rem(size, 2) == 1, do: IO.binread(io, 1)
        chunks(io, @bytes_per_second)

      _ ->
        {:error, :invalid_audio}
    end
  end

  defp write_segment(source, output, header, offset, size) do
    File.open(output, [:write, :binary, :exclusive], fn target ->
      :ok = File.chmod(output, 0o600)
      :ok = IO.binwrite(target, header)
      {:ok, _} = :file.position(source, offset)
      copy_bytes(source, target, size)
    end)
    |> unwrap()
  end

  defp copy_bytes(_, _, 0), do: :ok

  defp copy_bytes(source, target, remaining) do
    count = min(remaining, 65_536)

    case IO.binread(source, count) do
      data when is_binary(data) and byte_size(data) == count ->
        with :ok <- IO.binwrite(target, data), do: copy_bytes(source, target, remaining - count)

      _ ->
        {:error, :invalid_audio}
    end
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap(error), do: error
end
