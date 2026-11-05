defmodule SoundboardWeb.Soundboard.SoundFilter do
  @moduledoc """
  Filters sounds based on the selected tags and search query.

  `match` decides how several selected tags combine: `:all` keeps sounds
  carrying every selected tag, `:any` keeps sounds carrying at least one.
  """

  def filter_sounds(sounds, query, selected_tags, match \\ :all) do
    sounds
    |> filter_by_tags(selected_tags, match)
    |> filter_by_search(query)
  end

  defp filter_by_tags(sounds, [], _match), do: sounds

  defp filter_by_tags(sounds, selected_tags, match) do
    selected_tag_ids = MapSet.new(selected_tags, & &1.id)

    Enum.filter(sounds, fn sound ->
      sound_tag_ids = MapSet.new(sound.tags, & &1.id)

      case match do
        :any -> not MapSet.disjoint?(selected_tag_ids, sound_tag_ids)
        _ -> MapSet.subset?(selected_tag_ids, sound_tag_ids)
      end
    end)
  end

  defp filter_by_search(sounds, ""), do: sounds

  defp filter_by_search(sounds, query) do
    query = String.downcase(query)

    Enum.filter(sounds, fn sound ->
      filename_matches = String.downcase(sound.filename) =~ query

      tag_matches =
        Enum.any?(sound.tags, fn tag ->
          String.downcase(tag.name) =~ query
        end)

      filename_matches || tag_matches
    end)
  end
end
