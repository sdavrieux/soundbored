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
