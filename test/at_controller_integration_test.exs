# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM.ATControllerIntegrationTest do
  use ExUnit.Case, async: true
  alias VintageNetECM.{AT, ATController}
  alias VintageNetECM.TestPTY, as: PTY

  setup do
    ifname = "pty#{System.unique_integer([:positive])}"
    pty = start_supervised!({PTY, responder: &response/1, observer: self()})
    name = VintageNetECM.channel_name(ifname)
    channel = start_supervised!({AT.Channel, tty: PTY.tty(pty), name: name})
    controller = start_supervised!({ATController, ifname: ifname, channel: name, apn: "test"})
    assert :sys.get_state(controller).ready
    # Wait for initial registration/property traffic before each assertion.
    :sys.get_state(controller)
    flush_commands()
    on_exit(fn -> PropertyTable.delete_matches(VintageNet, ["interface", ifname, "mobile"]) end)
    %{ifname: ifname, channel: channel, controller: controller, pty: pty}
  end

  test "managed commands and modem callbacks share the supervised channel", %{ifname: ifname} do
    assert VintageNetECM.command(ifname, "AT+CGMI") == {:ok, ["PTY modem"]}
    assert {:ok, %{utc: ~U[2026-08-08 17:04:31Z]}} = VintageNetECM.network_time(ifname)
    assert VintageNetECM.session(ifname, &AT.command(&1, "AT")) == {:ok, []}
    assert VintageNet.get(["interface", ifname, "mobile", "manufacturer"]) == "PTY modem"
  end

  test "application sessions exclude polling, which resumes without losing state", context do
    before = :sys.get_state(context.controller)

    VintageNetECM.session(context.ifname, fn _ ->
      send(context.controller, :monitor)
      during = :sys.get_state(context.controller)
      assert during.static == before.static
      refute_received {:at_command, _}
      assert VintageNetECM.command(context.ifname, "AT") == {:error, :busy}
    end)

    send(context.controller, :monitor)
    assert :sys.get_state(context.controller).static == before.static
    assert_receive {:at_command, "AT+CEREG?"}
  end

  test "temporary fencing preserves modem state and explicit recovery restores polling",
       context do
    before = :sys.get_state(context.controller)
    assert VintageNetECM.session(context.ifname, fn at -> AT.send(at, "AT\r") end) == :ok
    assert VintageNetECM.command(context.ifname, "AT") == {:error, :desynchronized}
    send(context.controller, :monitor)
    assert :sys.get_state(context.controller).static == before.static
    assert AT.Channel.recover(context.channel) == :ok
    assert VintageNetECM.command(context.ifname, "AT+CGMI") == {:ok, ["PTY modem"]}
  end

  test "channel replacement reruns initialization before managed admission", context do
    old_state = :sys.get_state(context.controller)
    assert ATController.channel(context.ifname) == {:ok, context.channel}
    :ok = stop_supervised(AT.Channel)
    assert AT.session(context.channel, fn _ -> flunk("old channel") end) == {:error, :not_running}

    assert VintageNetECM.session(context.ifname, fn _ -> flunk("not ready") end) ==
             {:error, :not_ready}

    channel =
      start_supervised!(
        {AT.Channel, tty: PTY.tty(context.pty), name: VintageNetECM.channel_name(context.ifname)}
      )

    send(context.controller, :initialize)
    state = :sys.get_state(context.controller)
    assert state.ready
    assert state.channel_pid == channel
    assert state.static == old_state.static
    assert VintageNetECM.command(context.ifname, "AT") == {:ok, []}
    assert_receive {:at_command, "ATQ0V1"}
  end

  test "teardown cannot steal a live tty and uses a supervised channel after shutdown", context do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert ATController.deactivate_data_call(
                 VintageNetECM.Modem.Quectel,
                 PTY.tty(context.pty),
                 1
               ) == :ok
      end)

    assert log =~ "already_open"
    refute_received {:at_command, _}
    :ok = stop_supervised(ATController)
    :ok = stop_supervised(AT.Channel)

    assert ATController.deactivate_data_call(VintageNetECM.Modem.Quectel, PTY.tty(context.pty), 1) ==
             :ok

    assert_receive {:at_command, "AT+QNETDEVCTL=0,1,1"}
  end

  test "initial unavailability refuses admission and supervises UART retries" do
    ifname = "missing#{System.unique_integer([:positive])}"
    name = VintageNetECM.channel_name(ifname)
    missing = Path.join(System.tmp_dir!(), ifname)
    channel = start_supervised!({AT.Channel, tty: missing, name: name}, id: :missing_channel)

    controller =
      start_supervised!({ATController, ifname: ifname, channel: name, apn: "test"},
        id: :missing_controller
      )

    refute :sys.get_state(controller).ready
    assert VintageNetECM.session(ifname, fn _ -> flunk("not ready") end) == {:error, :not_ready}
    assert AT.session(channel, fn _ -> flunk("unavailable") end) == {:error, :tty_not_open}
    refute :sys.get_state(channel).blocked
  end

  defp response(command) do
    lines =
      Map.get(
        %{
          "AT+CGMI" => "PTY modem\r\n",
          "AT+CGMM" => "test-model\r\n",
          "AT+CGMR" => "test-firmware\r\n",
          "AT+CGSN" => "test-identity\r\n",
          "AT+CIMI" => "test-identity\r\n",
          "AT+CGSN=0" => "+CGSN: test-serial\r\n",
          "AT+QCCID" => "+QCCID: 000\r\n",
          "AT+CEREG?;+CGREG?;+CREG?;+CGATT?;+COPS?" => "+CEREG: 0,1\r\n",
          "AT+CEREG?" => "+CEREG: 0,1\r\n",
          "AT+QNETDEVSTATUS?" => "+QNETDEVSTATUS: 1,2\r\n",
          "AT+QLTS=1" => "+QLTS: \"2026/08/08,17:04:31+00,0\"\r\n"
        },
        command,
        ""
      )

    lines <> "OK\r\n"
  end

  defp flush_commands do
    receive do
      {:at_command, _} -> flush_commands()
    after
      0 -> :ok
    end
  end
end
