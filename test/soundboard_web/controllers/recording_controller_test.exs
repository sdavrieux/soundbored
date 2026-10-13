defmodule SoundboardWeb.RecordingControllerTest do
  use SoundboardWeb.ConnCase
  alias Soundboard.Accounts.User
  alias Soundboard.Capture.Storage
  alias Soundboard.Repo

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "soundboard-download-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:soundboard, :recordings_dir)
    Application.put_env(:soundboard, :recordings_dir, dir)
    File.mkdir_p!(dir)
    name = "moment-20260101T120000Z-0123456789abcdef.wav"
    File.write!(Path.join(dir, name), "RIFF")

    {:ok, user} =
      %User{} |> User.changeset(%{username: "operator", discord_id: "123"}) |> Repo.insert()

    on_exit(fn ->
      File.rm_rf!(dir)

      if previous,
        do: Application.put_env(:soundboard, :recordings_dir, previous),
        else: Application.delete_env(:soundboard, :recordings_dir)
    end)

    %{name: name, user: user}
  end

  test "recordings require sign-in", %{conn: conn, name: name} do
    conn = get(conn, ~p"/recordings/#{name}")
    assert redirected_to(conn) == "/auth/discord"
  end

  test "authenticated downloads cannot be cached", %{conn: conn, name: name, user: user} do
    conn = conn |> init_test_session(%{user_id: user.id}) |> get(~p"/recordings/#{name}")
    assert response(conn, 200) == "RIFF"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert {:error, :not_found} = Storage.download_path("../../mix.exs")
  end

  test "authenticated requests for missing or invalid names return 404", %{conn: conn, user: user} do
    conn =
      conn |> init_test_session(%{user_id: user.id}) |> get("/recordings/not-a-recording.wav")

    assert response(conn, 404) == "Recording not found"
  end
end
