defmodule SoundboardWeb.Live.SoundboardLive.BulkDeleteFlow do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Soundboard.Sounds
  alias SoundboardWeb.Live.Support.LiveTags

  def assign_defaults(socket) do
    socket
    |> assign(:selecting, false)
    |> assign(:selected_ids, MapSet.new())
    |> assign(:show_bulk_delete_confirm, false)
  end

  def toggle_selecting(socket) do
    if socket.assigns.selecting do
      {:noreply, assign_defaults(socket)}
    else
      {:noreply, assign(socket, :selecting, true)}
    end
  end

  def toggle_select(socket, id) do
    with {:ok, id} <- parse_id(id),
         %{} <- Enum.find(deletable_sounds(socket), &(&1.id == id)) do
      selected = socket.assigns.selected_ids

      selected =
        if MapSet.member?(selected, id),
          do: MapSet.delete(selected, id),
          else: MapSet.put(selected, id)

      {:noreply, assign(socket, :selected_ids, selected)}
    else
      _ -> {:noreply, socket}
    end
  end

  def select_visible(socket, visible_sounds) do
    ids =
      visible_sounds
      |> Enum.filter(&deletable?(&1, socket))
      |> MapSet.new(& &1.id)

    {:noreply, assign(socket, :selected_ids, MapSet.union(socket.assigns.selected_ids, ids))}
  end

  def clear_selection(socket) do
    {:noreply, assign(socket, :selected_ids, MapSet.new())}
  end

  def show_confirm(socket) do
    {:noreply, assign(socket, :show_bulk_delete_confirm, selected_sounds(socket.assigns) != [])}
  end

  def hide_confirm(socket) do
    {:noreply, assign(socket, :show_bulk_delete_confirm, false)}
  end

  def delete_selected(socket) do
    user_id = socket.assigns.current_user && socket.assigns.current_user.id

    # Reload first so sounds removed elsewhere are skipped rather than crashing Repo.get!.
    socket = assign(socket, :uploaded_files, Sounds.list_detailed())

    {deleted, failed} =
      socket.assigns
      |> selected_sounds()
      |> Enum.split_with(&(Sounds.delete_sound(&1, user_id) == :ok))

    if deleted != [], do: LiveTags.broadcast_update()

    socket =
      socket
      |> assign_defaults()
      |> assign(:uploaded_files, Sounds.list_detailed())
      |> put_result_flash(length(deleted), length(failed))

    {:noreply, socket}
  end

  @doc "Drops selections for sounds that no longer exist after the list reloads."
  def prune_selection(socket) do
    present = MapSet.new(socket.assigns.uploaded_files, & &1.id)
    assign(socket, :selected_ids, MapSet.intersection(socket.assigns.selected_ids, present))
  end

  def selected_sounds(assigns) do
    Enum.filter(assigns.uploaded_files, &MapSet.member?(assigns.selected_ids, &1.id))
  end

  def deletable?(sound, %{assigns: assigns}), do: deletable?(sound, assigns)

  def deletable?(sound, %{current_user: %{id: user_id}}), do: sound.user_id == user_id
  def deletable?(_sound, _assigns), do: false

  defp deletable_sounds(socket) do
    Enum.filter(socket.assigns.uploaded_files, &deletable?(&1, socket))
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp put_result_flash(socket, deleted, 0) do
    Phoenix.LiveView.put_flash(socket, :info, "Deleted #{pluralize(deleted)}")
  end

  defp put_result_flash(socket, deleted, failed) do
    Phoenix.LiveView.put_flash(
      socket,
      :error,
      "Deleted #{pluralize(deleted)}; #{pluralize(failed)} could not be deleted"
    )
  end

  defp pluralize(1), do: "1 sound"
  defp pluralize(count), do: "#{count} sounds"
end
