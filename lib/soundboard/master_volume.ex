defmodule Soundboard.MasterVolume do
  @moduledoc """
  Persistent master attenuation for this soundboard. Individual clip levels are preserved.
  The multiplier is read when playback starts, including API and automatic sounds.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Soundboard.{PubSubTopics, Repo}

  @primary_key {:id, :integer, autogenerate: false}
  schema "playback_settings" do
    field :volume, :integer, default: 100
  end

  def get, do: (Repo.get(__MODULE__, 1) || %__MODULE__{id: 1}).volume

  def set(value) do
    changeset =
      %__MODULE__{id: 1}
      |> cast(%{volume: value}, [:volume])
      |> validate_required([:volume])
      |> validate_number(:volume, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)

    case Repo.insert(changeset, on_conflict: {:replace, [:volume]}, conflict_target: :id) do
      {:ok, setting} ->
        PubSubTopics.broadcast_master_volume(setting.volume)
        {:ok, setting.volume}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def apply(clip_volume), do: clip_volume * get() / 100
end
