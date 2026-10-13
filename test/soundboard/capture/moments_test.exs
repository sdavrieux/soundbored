defmodule Soundboard.Capture.MomentsTest do
  use Soundboard.DataCase, async: false
  alias Soundboard.{Accounts.User, MomentFixtures, Repo}
  alias Soundboard.Capture.{Moments, Storage}

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "soundboard-moments-test-#{System.unique_integer([:positive])}"
      )

    uploads = dir <> "-uploads"
    previous = Application.get_env(:soundboard, :recordings_dir)
    previous_uploads = Application.get_env(:soundboard, :uploads_dir)
    Application.put_env(:soundboard, :recordings_dir, dir)
    Application.put_env(:soundboard, :uploads_dir, uploads)
    name = MomentFixtures.create(dir)

    {:ok, user} =
      %User{} |> User.changeset(%{username: "editor", discord_id: "123"}) |> Repo.insert()

    on_exit(fn ->
      File.rm_rf!(dir)
      File.rm_rf!(uploads)
      restore(:recordings_dir, previous)
      restore(:uploads_dir, previous_uploads)
    end)

    %{name: name, dir: dir, user: user}
  end

  test "trim saves only the selected samples, updates title and refuses stale edits", %{
    name: name,
    dir: dir
  } do
    assert {:ok, moment} = Moments.get(name)
    assert moment.duration == 2.0
    attrs = %{"title" => "A good moment", "start" => "0.5", "stop" => "1.5"}
    assert {:ok, saved} = Moments.save(name, moment.revision, attrs)
    assert saved.duration == 1.0
    assert saved.title == "A good moment"
    assert saved.revision != moment.revision
    assert {:error, :stale} = Moments.save(name, moment.revision, attrs)
    assert {:error, :stale} = Moments.delete(name, moment.revision)
    assert {:ok, path} = Storage.download_path(name)
    assert %{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert :ok = Moments.delete(name, saved.revision)
    assert Moments.list() == []
    assert File.ls!(dir) == []
  end

  test "invalid selections, symlinks and traversal cannot alter recordings", %{
    name: name,
    dir: dir
  } do
    {:ok, moment} = Moments.get(name)

    for {start, stop} <- [{"-1", "1"}, {"1", "1"}, {"0", "3"}, {"0bad", "1"}] do
      assert {:error, :invalid_selection} =
               Moments.save(name, moment.revision, %{
                 "title" => "Clip",
                 "start" => start,
                 "stop" => stop
               })
    end

    assert {:error, :not_found} = Moments.delete("../private.wav", moment.revision)
    path = Path.join(dir, name)
    File.rename!(path, path <> ".original")
    File.ln_s!(path <> ".original", path)
    assert {:error, :not_found} = Moments.get(name)
    assert Moments.list() == []
    assert File.exists?(path <> ".original")
  end

  test "publishing a trim creates a dashboard sound and preserves the private original", %{
    name: name,
    user: user
  } do
    {:ok, moment} = Moments.get(name)
    attrs = %{"title" => "First moment", "start" => "0.5", "stop" => "1.0"}
    assert {:ok, sound} = Moments.publish(name, moment.revision, attrs, user)
    assert sound.user_id == user.id
    assert sound.filename == "First moment.wav"
    assert {:ok, ^moment} = Moments.get(name)
    assert {:error, _} = Moments.publish(name, moment.revision, attrs, user)
  end

  defp restore(key, nil), do: Application.delete_env(:soundboard, key)
  defp restore(key, value), do: Application.put_env(:soundboard, key, value)
end
