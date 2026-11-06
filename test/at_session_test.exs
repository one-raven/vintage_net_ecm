# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM.ATSessionTest do
  use ExUnit.Case, async: true
  alias VintageNetECM.AT
  alias VintageNetECM.AT.Channel
  alias VintageNetECM.TestPTY, as: PTY

  setup do
    pty = start_supervised!({PTY, []})
    channel = start_supervised!({Channel, tty: PTY.tty(pty), intermediate_responses: ["> "]})
    assert :sys.get_state(channel).available
    %{pty: pty, channel: channel}
  end

  test "callback results, exceptions, PID ownership, stale handles and competing sessions", %{
    channel: channel
  } do
    handle =
      AT.session(channel, fn at ->
        task = Task.async(fn -> AT.send(at, "foreign") end)
        assert Task.await(task) == {:error, :invalid_session}
        assert AT.session(channel, fn _ -> flunk("busy") end) == {:error, :busy}
        at
      end)

    assert AT.send(handle, "stale") == {:error, :invalid_session}

    assert_raise RuntimeError, "callback failed", fn ->
      AT.session(channel, fn _ -> raise "callback failed" end)
    end

    assert AT.session(channel, fn _ -> :application_result end) == :application_result
  end

  test "fragmented prompts and responses retain interleaved unsolicited lines", %{
    pty: pty,
    channel: channel
  } do
    task =
      Task.async(fn ->
        AT.session(channel, fn at ->
          assert AT.send(at, "AT+X\r") == :ok
          assert AT.receive(at) == {:ok, {:intermediate, "> "}}
          assert AT.send(at, "payload" <> <<26>>) == :ok
          AT.receive(at)
        end)
      end)

    assert PTY.read(pty, 5) == "AT+X\r"

    for fragment <- ["\r", "\n>", " "] do
      assert PTY.write(pty, fragment) == :ok
      Process.sleep(5)
    end

    assert PTY.read(pty, 8) == "payload" <> <<26>>

    for fragment <- ["+NOTICE: 1\r\n+X:", " 7\r\nO", "K\r\n"] do
      assert PTY.write(pty, fragment) == :ok
      Process.sleep(5)
    end

    assert Task.await(task) == {:ok, {:response, ["+NOTICE: 1", "+X: 7", "OK"]}}
    assert AT.session(channel, fn _ -> :clean end) == :clean
  end

  test "standard commands strip echo and keep extended errors synchronized", %{
    pty: pty,
    channel: channel
  } do
    for {response, result} <- [
          {"AT\r\nvalue\r\nOK\r\n", {:ok, ["value"]}},
          {"+CME ERROR: 30\r\n", {:error, {:cme, "30"}}}
        ] do
      task = Task.async(fn -> AT.session(channel, &AT.command(&1, "AT")) end)
      assert PTY.read(pty, 3) == "AT\r"
      assert PTY.write(pty, response) == :ok
      assert Task.await(task) == result
    end
  end

  test "a shortened operation deadline fences a pending exchange immediately", %{
    channel: channel,
    pty: pty
  } do
    AT.session(channel, fn at ->
      assert AT.send(at, "AT\r") == :ok
      assert PTY.read(pty, 3) == "AT\r"
      expired = %{at | deadline: System.monotonic_time(:millisecond) - 1}
      assert AT.receive(expired) == {:error, :timeout}
      assert AT.receive(at) == {:error, :desynchronized}
    end)

    assert AT.session(channel, fn _ -> flunk("fenced") end) == {:error, :desynchronized}
  end

  test "response timeout obeys the session deadline and recovery never replays writes", %{
    channel: channel,
    pty: pty
  } do
    started = System.monotonic_time(:millisecond)

    assert AT.session(
             channel,
             fn at ->
               assert AT.send(at, "AT+SLOW\r") == :ok
               AT.receive(at, timeout: 120_000)
             end,
             timeout: 40
           ) == {:error, :timeout}

    assert System.monotonic_time(:millisecond) - started < 1_000
    assert PTY.read(pty, 8) == "AT+SLOW\r"
    assert AT.session(channel, fn _ -> flunk("fenced") end) == {:error, :desynchronized}

    # The simulated modem has finished its old operation before explicit recovery.
    assert PTY.write(pty, "OK\r\n") == :ok
    assert Channel.recover(channel) == :ok
    task = Task.async(fn -> AT.session(channel, &AT.command(&1, "AT")) end)
    assert PTY.read(pty, 3) == "AT\r"
    assert PTY.write(pty, "OK\r\n") == :ok
    assert Task.await(task) == {:ok, []}
  end

  test "caller death with an incomplete exchange fences the channel", %{
    channel: channel,
    pty: pty
  } do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        AT.session(channel, fn at ->
          :ok = AT.send(at, "AT+X\r")
          send(parent, :sent)

          receive do
            :never -> :ok
          end
        end)
      end)

    assert_receive :sent
    assert PTY.read(pty, 5) == "AT+X\r"
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    # This queued request is handled after the channel's owner monitor notification.
    assert AT.session(channel, fn _ -> flunk("must not run") end) in [
             {:error, :desynchronized},
             {:error, :busy}
           ]

    assert :sys.get_state(channel).blocked
  end

  test "abandoned prompts and expired leases cannot reopen admission", %{
    channel: channel,
    pty: pty
  } do
    task =
      Task.async(fn ->
        AT.session(channel, fn at ->
          :ok = AT.send(at, "AT+X\r")
          assert AT.receive(at) == {:ok, {:intermediate, "> "}}
          :unfinished
        end)
      end)

    assert PTY.read(pty, 5) == "AT+X\r"
    :ok = PTY.write(pty, "> ")
    assert Task.await(task) == :unfinished
    assert AT.session(channel, fn _ -> flunk("fenced") end) == {:error, :desynchronized}
  end

  test "idle lease expiration is safe, pending expiration is fenced", %{channel: channel} do
    for pending <- [false, true] do
      AT.session(
        channel,
        fn at ->
          if pending, do: assert(AT.send(at, "AT\r") == :ok)
          Process.sleep(40)

          assert AT.send(at, "late") ==
                   {:error, if(pending, do: :desynchronized, else: :invalid_session)}
        end,
        timeout: 20
      )

      assert :sys.get_state(channel).blocked == pending
    end
  end

  test "UART process loss is fenced without killing the channel", %{channel: channel} do
    uart = :sys.get_state(channel).uart
    monitor = Process.monitor(uart)
    Process.exit(uart, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^uart, :killed}

    assert AT.session(channel, fn at -> AT.send(at, "AT\r") end) in [
             {:error, :desynchronized},
             {:error, :io_error}
           ]

    assert Process.alive?(channel)
    assert :sys.get_state(channel).blocked
    assert Channel.recover(channel) == :ok
    assert AT.session(channel, fn _ -> :recovered end) == :recovered
  end

  test "UART disconnect and explicit recovery onto a replacement PTY", %{
    channel: channel,
    pty: pty
  } do
    tty = PTY.tty(pty)
    :ok = PTY.disconnect(pty)
    assert {:error, _} = AT.session(channel, &AT.command(&1, "AT", timeout: 100))
    assert AT.session(channel, fn _ -> flunk("fenced") end) == {:error, :desynchronized}
    replacement = start_supervised!({PTY, []}, id: :replacement)
    File.rm(tty)
    File.ln_s!(PTY.tty(replacement), tty)
    assert Channel.recover(channel) == :ok
    assert AT.session(channel, fn _ -> :available end) == :available
  end

  test "invalid inputs fail before I/O and duplicate ownership is rejected", %{
    channel: channel,
    pty: pty
  } do
    assert AT.session(channel, fn _ -> flunk("invalid") end, timeout: 0) ==
             {:error, :invalid_options}

    AT.session(channel, fn at ->
      assert AT.send(at, "") == {:error, :invalid_data}
      assert AT.send(at, String.duplicate("x", 4_097)) == {:error, :invalid_data}
      assert AT.receive(at, until: ">") == {:error, :invalid_options}
      assert Channel.recover(channel) == {:error, :busy}
    end)

    refute :sys.get_state(channel).blocked
    assert {:error, reason} = start_supervised({Channel, tty: PTY.tty(pty)}, id: :duplicate)
    assert inspect(reason) =~ "already_open"
  end

  test "an intermediate response without a preceding write still leaves an unfinished exchange",
       %{channel: channel, pty: pty} do
    task = Task.async(fn -> AT.session(channel, &AT.receive/1) end)
    :ok = PTY.write(pty, "> ")
    assert Task.await(task) == {:ok, {:intermediate, "> "}}
    assert AT.session(channel, fn _ -> flunk("fenced") end) == {:error, :desynchronized}
  end

  test "standalone channel names and tty claims follow supervised lifetimes" do
    pty = start_supervised!({PTY, []}, id: :named_pty)
    name = {:global, {__MODULE__, make_ref()}}
    start_supervised!({Channel, tty: PTY.tty(pty), name: name}, id: :named_channel)
    assert AT.session(name, fn _ -> :named end) == :named
    :ok = stop_supervised(:named_channel)
    channel = start_supervised!({Channel, tty: PTY.tty(pty)}, id: :replacement_channel)
    assert AT.session(channel, fn _ -> :reclaimed end) == :reclaimed
  end

  test "PTY supervision stops its owned OS process", %{pty: pty} do
    os_pid = :sys.get_state(pty).os_pid
    :ok = stop_supervised(PTY)
    assert {_, 1} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
  end

  test "status diagnostics redact requests and payloads" do
    assert Channel.format_status(%{
             state: "private",
             message: "private",
             reason: "private",
             log: ["private"]
           }) ==
             %{state: :redacted, message: :redacted, reason: :redacted, log: []}
  end
end
