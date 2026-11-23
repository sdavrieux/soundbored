defmodule SoundboardWeb.MomentsLiveTest do
  use SoundboardWeb.ConnCase
  alias Soundboard.{Accounts.User, MomentFixtures, Repo}
  alias Soundboard.Capture.Moments

  setup %{conn: conn} do
    dir =
      Path.join(System.tmp_dir!(), "soundboard-editor-test-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:soundboard, :recordings_dir)
    Application.put_env(:soundboard, :recordings_dir, dir)
    File.mkdir!(dir)

    {:ok, user} =
      %User{} |> User.changeset(%{username: "editor", discord_id: "123"}) |> Repo.insert()

    on_exit(fn ->
      File.rm_rf!(dir)

      if previous,
        do: Application.put_env(:soundboard, :recordings_dir, previous),
        else: Application.delete_env(:soundboard, :recordings_dir)
    end)

    %{conn: init_test_session(conn, %{user_id: user.id}), dir: dir}
  end

  test "empty moments page keeps playback controls and links back to capture", %{conn: conn} do
    {:ok, view, html} = live(conn, "/moments")
    assert html =~ "No moments yet"
    assert has_element?(view, "#master-volume")
    assert has_element?(view, "[phx-click=stop_sound]")
    assert has_element?(view, "a[href='/']")
  end

  test "select, trim and delete a recording", %{conn: conn, dir: dir} do
    name = MomentFixtures.create(dir)
    {:ok, view, _} = live(conn, "/moments")
    view |> element("[phx-value-name='#{name}']") |> render_click()
    assert has_element?(view, "audio[controls]")

    view
    |> form("#moment-trim", moment: %{title: "Best line", start: "0.5", stop: "1.5"})
    |> render_submit()

    assert render_async(view) =~ "Changes saved"
    assert {:ok, %{duration: 1.0, title: "Best line"}} = Moments.get(name)
    view |> element("[phx-click=delete_moment]") |> render_click()
    assert render_async(view) =~ "Moment deleted"
    assert render(view) =~ "No moments yet"
  end

  test "speaker picker remixes the preview and saves who is left out", %{conn: conn, dir: dir} do
    name = MomentFixtures.create_with_stems(dir)
    {:ok, view, _} = live(conn, "/moments")
    view |> element("[phx-value-name='#{name}']") |> render_click()
    render_async(view, 5_000)

    assert has_element?(view, "#moment-speakers", "Ana")
    assert has_element?(view, "#moment-speakers", "Ben")
    refute has_element?(view, "audio[src*='speakers=']")

    view |> form("#moment-trim") |> render_change(%{moment: %{speakers: ["", "2"]}})
    assert has_element?(view, "audio[src*='speakers=2']")

    view |> form("#moment-trim") |> render_change(%{moment: %{speakers: [""]}})
    assert render(view) =~ "Keep at least one speaker."

    view |> form("#moment-trim") |> render_change(%{moment: %{speakers: ["", "1"]}})
    view |> form("#moment-trim") |> render_submit()
    # Leaving someone out remixes the stems with FFmpeg, which takes a moment.
    assert render_async(view, 5_000) =~ "Changes saved"
    assert {:ok, %{muted: ["2"]}} = Moments.get(name)
  end

  test "auto-trim selects the speech of the chosen speakers", %{conn: conn, dir: dir} do
    name = MomentFixtures.create_with_stems(dir)
    {:ok, view, _} = live(conn, "/moments")
    view |> element("[phx-value-name='#{name}']") |> render_click()
    render_async(view, 5_000)

    view |> form("#moment-trim") |> render_change(%{moment: %{speakers: ["", "2"]}})
    view |> element("[phx-click=auto_trim]") |> render_click()
    assert has_element?(view, "#trim-start[value='0.75']")
    assert has_element?(view, "#trim-stop[value='2.0']")
    assert_push_event(view, "moment-preview", %{})

    # Two people taking turns at the same level has nothing that stands out.
    assert render(view) =~ "No standout moments found."
    render_click(view, "jump_highlight", %{"index" => "nope"})
    assert has_element?(view, "#trim-start[value='0.75']")
  end

  test "an outdated editor cannot overwrite another session's trim", %{conn: conn, dir: dir} do
    name = MomentFixtures.create(dir)
    {:ok, view, _} = live(conn, "/moments")
    view |> element("[phx-value-name='#{name}']") |> render_click()
    {:ok, moment} = Moments.get(name)

    assert {:ok, _} =
             Moments.save(name, moment.revision, %{
               "title" => "Other session",
               "start" => "0",
               "stop" => "1"
             })

    view
    |> form("#moment-trim", moment: %{title: "Stale", start: "0", stop: "1.5"})
    |> render_submit()

    assert render_async(view) =~ "changed in another session"
    assert {:ok, %{title: "Other session"}} = Moments.get(name)
  end

  test "search and several tags narrow the moment list", %{conn: conn, dir: dir} do
    first = MomentFixtures.create(dir, "aaaaaaaaaaaaaaaa")
    second = MomentFixtures.create(dir, "bbbbbbbbbbbbbbbb")
    {:ok, _} = Moments.label(first, %{"title" => "Raid wipe", "tags" => "sam, fail"})
    {:ok, _} = Moments.label(second, %{"title" => "Sam joke", "tags" => "sam, funny"})
    {:ok, view, _} = live(conn, "/moments")

    view |> element("button[phx-value-tag=sam]") |> render_click()
    html = view |> element("button[phx-value-tag=fail]") |> render_click()
    assert html =~ "Raid wipe"
    refute html =~ "Sam joke"

    view |> element("[phx-click=clear_moment_tags]") |> render_click()
    html = view |> element("form[phx-change=search_moments]") |> render_change(%{query: "joke"})
    assert html =~ "Sam joke"
    refute html =~ "Raid wipe"
  end
end
