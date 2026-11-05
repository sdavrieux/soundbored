defmodule SoundboardWeb.Soundboard.SoundFilterTest do
  use ExUnit.Case, async: true

  alias SoundboardWeb.Soundboard.SoundFilter

  describe "filter_sounds/4" do
    test "keeps sounds matching every selected tag" do
      alpha = %{id: 1, name: "alpha"}
      beta = %{id: 2, name: "beta"}

      sounds = [
        %{filename: "alpha-beta.mp3", tags: [alpha, beta]},
        %{filename: "alpha-only.mp3", tags: [alpha]},
        %{filename: "beta-only.mp3", tags: [beta]}
      ]

      assert [matched] = SoundFilter.filter_sounds(sounds, "", [alpha, beta])
      assert matched.filename == "alpha-beta.mp3"
    end

    test "keeps sounds matching any selected tag in :any mode" do
      alpha = %{id: 1, name: "alpha"}
      beta = %{id: 2, name: "beta"}
      gamma = %{id: 3, name: "gamma"}

      sounds = [
        %{filename: "alpha-only.mp3", tags: [alpha]},
        %{filename: "beta-only.mp3", tags: [beta]},
        %{filename: "gamma-only.mp3", tags: [gamma]}
      ]

      assert ["alpha-only.mp3", "beta-only.mp3"] =
               sounds
               |> SoundFilter.filter_sounds("", [alpha, beta], :any)
               |> Enum.map(& &1.filename)
    end

    test "matches against filenames and tag names" do
      alpha = %{id: 1, name: "alpha"}
      reaction = %{id: 2, name: "reaction"}

      sounds = [
        %{filename: "victory.mp3", tags: [alpha]},
        %{filename: "sad-trombone.mp3", tags: [reaction]}
      ]

      assert [%{filename: "victory.mp3"}] = SoundFilter.filter_sounds(sounds, "victory", [])

      assert [%{filename: "sad-trombone.mp3"}] =
               SoundFilter.filter_sounds(sounds, "reaction", [])
    end
  end
end
