defmodule Soundboard.MasterVolumeTest do
  use Soundboard.DataCase, async: false
  alias Soundboard.{MasterVolume, PubSubTopics}

  test "defaults to full volume and persists attenuation without changing a clip" do
    assert MasterVolume.get() == 100
    assert {:ok, 35} = MasterVolume.set("35")
    assert MasterVolume.get() == 35
    assert_in_delta MasterVolume.apply(1.2), 0.42, 0.0001
    assert {:ok, 0} = MasterVolume.set(0)
    assert MasterVolume.apply(1.5) == 0.0
  end

  test "rejects invalid percentages instead of changing the level" do
    assert {:ok, 50} = MasterVolume.set(50)

    for invalid <- [-1, 101, "loud", "50junk", nil] do
      assert {:error, _} = MasterVolume.set(invalid)
      assert MasterVolume.get() == 50
    end
  end

  test "notifies other operators" do
    PubSubTopics.subscribe_desk()
    assert {:ok, 60} = MasterVolume.set(60)
    assert_receive {:master_volume, 60}
  end
end
