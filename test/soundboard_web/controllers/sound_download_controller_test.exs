defmodule SoundboardWeb.SoundDownloadControllerTest do
  use SoundboardWeb.ConnCase

  alias Soundboard.{Accounts.User, Repo, Sound}

  setup %{conn: conn} do
    {:ok, user} =
      %User{}
      |> User.changeset(%{
        username: "download_user_#{System.unique_integer([:positive])}",
        discord_id: Integer.to_string(System.unique_integer([:positive])),
        avatar: "avatar.png"
      })
      |> Repo.insert()

    uploads_dir = Soundboard.UploadsPath.dir()
    File.mkdir_p!(uploads_dir)

    sounds =
      for {name, body} <- [{"Bravo.mp3", "bravo audio"}, {"alpha.wav", "alpha audio"}] do
        filename = "dl_#{System.unique_integer([:positive])}_#{name}"
        path = Path.join(uploads_dir, filename)
        File.write!(path, body)
        on_exit(fn -> File.rm(path) end)

        %Sound{}
        |> Sound.changeset(%{filename: filename, source_type: "local", user_id: user.id})
        |> Repo.insert!()
      end

    remote =
      %Sound{}
      |> Sound.changeset(%{
        filename: "dl_remote_#{System.unique_integer([:positive])}.mp3",
        source_type: "url",
        url: "https://example.com/remote.mp3",
        user_id: user.id
      })
      |> Repo.insert!()

    %{conn: init_test_session(conn, %{user_id: user.id}), sounds: sounds, remote: remote}
  end

  test "redirects unauthenticated users", %{sounds: [sound | _]} do
    conn = get(build_conn(), "/sounds/download?ids=#{sound.id}")
    assert redirected_to(conn) == "/auth/discord"
  end

  test "one sound downloads as its own file", %{conn: conn, sounds: [sound | _]} do
    conn = get(conn, "/sounds/download?ids=#{sound.id}")

    assert response(conn, 200) == "bravo audio"
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ sound.filename
  end

  test "several sounds download as one zip and skip remote ones", %{
    conn: conn,
    sounds: sounds,
    remote: remote
  } do
    ids = Enum.map_join(sounds ++ [remote], ",", & &1.id)
    conn = get(conn, "/sounds/download?ids=#{ids},nope")

    body = response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/zip"
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "soundboard-2-sounds.zip"

    {:ok, files} = :zip.unzip(body, [:memory])

    assert Map.new(files, fn {name, data} -> {to_string(name), data} end) ==
             Map.new(sounds, fn sound ->
               {sound.filename, File.read!(Soundboard.UploadsPath.file_path(sound.filename))}
             end)
  end

  test "nothing downloadable returns 404", %{conn: conn, remote: remote} do
    assert conn |> get("/sounds/download?ids=#{remote.id}") |> response(404)
    assert conn |> get("/sounds/download?ids=999999") |> response(404)
  end

  test "missing ids is a bad request", %{conn: conn} do
    assert conn |> get("/sounds/download") |> response(400)
  end
end
