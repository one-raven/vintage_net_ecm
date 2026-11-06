# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM.TestPTY do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def tty(pid), do: GenServer.call(pid, :tty)
  def write(pid, bytes), do: GenServer.call(pid, {:write, bytes})
  def read(pid, count), do: GenServer.call(pid, {:read, count})
  def disconnect(pid), do: GenServer.call(pid, :disconnect)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    socat = System.find_executable("socat") || raise "PTY tests require socat"

    dir =
      Path.join(
        System.tmp_dir!(),
        "ecm-pty-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    tty = Path.join(dir, "channel")
    peer_tty = Path.join(dir, "peer")

    port =
      Port.open({:spawn_executable, socat}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["pty,raw,echo=0,link=#{tty}", "pty,raw,echo=0,link=#{peer_tty}"]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    await_tty(peer_tty, 100)
    {:ok, peer} = Circuits.UART.start_link()
    responder = Keyword.get(opts, :responder)
    :ok = Circuits.UART.open(peer, peer_tty, active: responder != nil)

    {:ok,
     %{
       dir: dir,
       tty: tty,
       port: port,
       os_pid: os_pid,
       peer: peer,
       responder: responder,
       observer: Keyword.get(opts, :observer),
       buffer: ""
     }}
  end

  defp await_tty(path, attempts) when attempts > 0 do
    if File.exists?(path),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await_tty(path, attempts - 1)
        )
  end

  defp await_tty(_path, 0), do: raise("socat did not create a PTY")

  @impl true
  def handle_call(:tty, _from, state), do: {:reply, state.tty, state}

  def handle_call({:write, bytes}, _from, state),
    do: {:reply, Circuits.UART.write(state.peer, bytes), state}

  def handle_call({:read, count}, _from, state),
    do: {:reply, read_bytes(state.peer, count, ""), state}

  def handle_call(:disconnect, _from, state) do
    stop_socat(state.port, state.os_pid)
    {:reply, :ok, %{state | os_pid: nil}}
  end

  defp read_bytes(_peer, count, bytes) when byte_size(bytes) >= count, do: bytes

  defp read_bytes(peer, count, bytes) do
    case Circuits.UART.read(peer, 1_000) do
      {:ok, ""} -> raise "PTY read timed out; received #{inspect(bytes)}"
      {:ok, more} -> read_bytes(peer, count, bytes <> more)
      {:error, reason} -> raise "PTY read failed: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_info({:circuits_uart, _, bytes}, state) when is_binary(bytes) do
    parts = String.split(state.buffer <> bytes, "\r")
    {commands, [buffer]} = Enum.split(parts, -1)

    for command <- commands do
      if state.observer, do: send(state.observer, {:at_command, command})
      :ok = Circuits.UART.write(state.peer, state.responder.(command))
    end

    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({:EXIT, _port, :normal}, state), do: {:noreply, state}
  def handle_info({_port, {:data, _}}, state), do: {:noreply, state}
  def handle_info({_port, {:exit_status, _}}, state), do: {:noreply, %{state | os_pid: nil}}

  @impl true
  def terminate(_reason, state) do
    Circuits.UART.stop(state.peer)
    if state.os_pid, do: stop_socat(state.port, state.os_pid)
    File.rm_rf!(state.dir)
  end

  defp stop_socat(port, os_pid) do
    System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      1_000 -> raise "socat did not exit"
    end
  end
end
