defmodule SoundboardWeb.RadioDeskTest do
  use SoundboardWeb.ConnCase
  import Phoenix.LiveViewTest
  import Mock
  alias Soundboard.{Accounts.User, MasterVolume, Repo}
  alias SoundboardWeb.Live.Support.StudioControls

  setup %{conn: conn} do
    {:ok, user} =
      %User{} |> User.changeset(%{username: "operator", discord_id: "123"}) |> Repo.insert()

    %{conn: init_test_session(conn, %{user_id: user.id})}
  end

  test "operators share a persistent master level and invalid input leaves it unchanged", %{
    conn: conn
  } do
    {:ok, first, _} = live(conn, "/")
    {:ok, second, _} = live(conn, "/")
    assert render_hook(first, "set_master_volume", %{volume: "35"}) =~ "35%"
    assert MasterVolume.get() == 35
    assert has_element?(second, "#master-volume[value='35']")
    assert render_hook(first, "set_master_volume", %{volume: "999"}) =~ "Choose a volume"
    assert MasterVolume.get() == 35
    {:ok, reopened, _} = live(conn, "/")
    assert has_element?(reopened, "#master-volume[value='35']")
  end

  test "bottom bar stops playback on every page", %{conn: conn} do
    {:ok, view, _} = live(conn, "/moments")

    with_mock Soundboard.AudioPlayer, stop_sound: fn -> :ok end do
      view |> element("[phx-click='stop_sound']") |> render_click()
      assert_called(Soundboard.AudioPlayer.stop_sound())
      assert has_element?(view, "#master-volume")
    end
  end

  test "capture starts off and save remains disabled until voice audio arrives", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Capture off"
    assert has_element?(view, "[phx-click='save_moment'][disabled]")
    status = %{target: {"guild", "channel"}, has_audio: true, seconds: 25, saving: false}
    send(view.pid, {:capture_status, status})
    assert render(view) =~ "25/60s"
    refute has_element?(view, "[phx-click='save_moment'][disabled]")
    send(view.pid, {:capture_status, %{status | saving: true}})
    assert render(view) =~ "Saving"
    assert has_element?(view, "[phx-click='save_moment'][disabled]")
    send(view.pid, {:capture_saved, {:error, :storage_full}})
    assert render(view) =~ "Recording folder is full"
  end

  test "unsigned events cannot change master level or start capture" do
    socket = %Phoenix.LiveView.Socket{assigns: %{current_user: nil, __changed__: %{}, flash: %{}}}

    assert {:halt, socket} =
             StudioControls.handle_event(
               "set_master_volume",
               %{"volume" => 0},
               socket
             )

    assert socket.assigns.flash["error"] =~ "Sign in"
    assert MasterVolume.get() == 100

    assert {:halt, socket} =
             StudioControls.handle_event("start_capture", %{}, socket)

    assert socket.assigns.flash["error"] =~ "Sign in"
  end
end
