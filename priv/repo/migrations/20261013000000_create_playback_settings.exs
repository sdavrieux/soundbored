defmodule Soundboard.Repo.Migrations.CreatePlaybackSettings do
  use Ecto.Migration

  def change do
    create table(:playback_settings, primary_key: false) do
      add :id, :integer, primary_key: true
      add :volume, :integer, null: false, default: 100
    end
  end
end
