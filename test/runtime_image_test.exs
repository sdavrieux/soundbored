defmodule Soundboard.RuntimeImageTest do
  use ExUnit.Case, async: true
  import Bitwise

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "soundboard-runtime-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "image permission recipe handles a private checkout and a non-readable shell script", %{
    directory: directory
  } do
    config = Path.join(directory, "config")
    File.mkdir_p!(config)
    File.chmod!(config, 0o700)
    source = Path.join(config, "runtime.exs")
    File.write!(source, "# public configuration source\n")
    File.chmod!(source, 0o600)
    entrypoint = Path.join(directory, "entrypoint.sh")
    File.write!(entrypoint, "#!/bin/sh\necho startup-fixture\n")
    # Execute without read permission reproduces the observed shell exit before Elixir starts.
    File.chmod!(entrypoint, 0o111)

    unless System.cmd("id", ["-u"]) == {"0\n", 0} do
      assert {output, 2} = System.cmd(entrypoint, [], stderr_to_stdout: true)
      assert output =~ "Permission denied"
    end

    dockerfile = File.read!("Dockerfile")

    assert [_, read_mode, execute_mode] =
             Regex.run(
               ~r/^RUN chmod -R (a\+rX) \/app && chmod (0755) \/app\/entrypoint\.sh$/m,
               dockerfile
             )

    assert {_, 0} = System.cmd("chmod", ["-R", read_mode, directory])
    assert {_, 0} = System.cmd("chmod", [execute_mode, entrypoint])
    assert band(File.stat!(config).mode, 0o005) == 0o005
    assert band(File.stat!(source).mode, 0o004) == 0o004
    assert band(File.stat!(entrypoint).mode, 0o005) == 0o005
    assert {"startup-fixture\n", 0} = System.cmd(entrypoint, [])
  end

  test "entrypoint uses precompiled code for migrations and server startup", %{
    directory: directory
  } do
    log = fake_mix(directory)

    assert {_, 0} =
             System.cmd("sh", [Path.expand("entrypoint.sh")],
               env: [
                 {"PATH", directory <> ":" <> System.get_env("PATH")},
                 {"SOUNDBOARD_ENTRYPOINT_TEST_LOG", log},
                 {"SOUNDBOARD_ENTRYPOINT_TEST_MIGRATION_STATUS", "0"}
               ]
             )

    assert File.read!(log) == "ecto.migrate --no-compile\nphx.server --no-compile\n"
  end

  test "entrypoint stops when migrations fail", %{directory: directory} do
    log = fake_mix(directory)

    assert {_, 7} =
             System.cmd("sh", [Path.expand("entrypoint.sh")],
               env: [
                 {"PATH", directory <> ":" <> System.get_env("PATH")},
                 {"SOUNDBOARD_ENTRYPOINT_TEST_LOG", log},
                 {"SOUNDBOARD_ENTRYPOINT_TEST_MIGRATION_STATUS", "7"}
               ]
             )

    assert File.read!(log) == "ecto.migrate --no-compile\n"
  end

  defp fake_mix(directory) do
    path = Path.join(directory, "mix")

    File.write!(path, """
    #!/bin/sh
    echo "$*" >> "$SOUNDBOARD_ENTRYPOINT_TEST_LOG"
    case "$1" in
      ecto.migrate) exit "$SOUNDBOARD_ENTRYPOINT_TEST_MIGRATION_STATUS" ;;
      phx.server) exit 0 ;;
      *) exit 99 ;;
    esac
    """)

    File.chmod!(path, 0o755)
    Path.join(directory, "commands.log")
  end
end
