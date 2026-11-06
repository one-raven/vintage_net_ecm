# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM.AT.Channel do
  @moduledoc """
  A supervised, exclusive AT channel. No radio configuration or network polling.

  Add `{VintageNetECM.AT.Channel, tty: "/dev/ttyUSB2", name: MyApp.Modem}` to your
  supervision tree, then use `VintageNetECM.AT.session/3` with its name or PID.
  Options are `:tty`, `:name`, `:speed` (115,200), and `:intermediate_responses` (`[]`).
  Tty paths are claimed once per node. Do not use aliases for an already-owned tty.

  A failed or unfinished exchange fences the channel. After explicitly recovering
  the modem, call `recover/1` to reopen the UART and discard stale input. Reopening
  alone does not cancel a modem operation. Nothing retries uncertain writes.
  Supervision restarts are not a modem recovery procedure.
  """
  use GenServer
  alias VintageNetECM.AT

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Reopen a fenced channel only after the modem has been explicitly recovered."
  def recover(channel), do: call(channel, :recover, System.monotonic_time(:millisecond) + 5_000)

  @doc false
  def session(channel, callback, opts) when is_function(callback, 1) do
    with {:ok, deadline} <- AT.deadline(opts),
         {:ok, handle} <- call(channel, {:session, deadline}, deadline) do
      try do
        callback.(handle)
      after
        call(handle.channel, {:release, handle.ref}, deadline)
      end
    end
  end

  @doc false
  def exchange(%AT{} = handle, operation, opts) do
    with {:ok, deadline} <- AT.deadline(opts, handle.deadline) do
      call(handle.channel, {:exchange, handle.ref, operation, deadline}, deadline)
    end
  end

  defp call(channel, request, deadline) do
    GenServer.call(channel, request, AT.remaining(deadline) + 1_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, _ -> {:error, :outcome_unknown}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    tty = Path.expand(Keyword.fetch!(opts, :tty), "/dev")
    markers = Keyword.get(opts, :intermediate_responses, [])
    speed = Keyword.get(opts, :speed, 115_200)

    with :ok <- AT.validate_intermediate_responses(markers),
         true <- is_integer(speed) and speed > 0,
         :ok <- claim_tty(tty) do
      state = %{
        tty: tty,
        speed: speed,
        markers: markers,
        uart: nil,
        available: false,
        blocked: false,
        session: nil
      }

      {:ok, state, {:continue, :open}}
    else
      false -> {:stop, :invalid_options}
      {:error, reason} -> {:stop, reason}
    end
  end

  # A node-local OTP lock needs no application registry and is released on process
  # exit, after terminate/2 closes the UART. Channel names remain caller-selected.
  defp claim_tty(tty) do
    if :global.set_lock({{__MODULE__, tty}, self()}, [node()], 0),
      do: :ok,
      else: {:error, :already_open}
  end

  @impl true
  def handle_continue(:open, state) do
    case open_uart(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, _reason, state} ->
        Process.send_after(self(), :open, 5_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:open, %{available: false, blocked: false} = state),
    do: {:noreply, state, {:continue, :open}}

  def handle_info(:open, state), do: {:noreply, state}

  def handle_info({:EXIT, uart, _reason}, %{uart: uart} = state),
    do: {:noreply, %{state | uart: nil, available: false, blocked: true}}

  # A UART deliberately stopped during open/recovery may report its exit later.
  def handle_info({:EXIT, _old_uart, _reason}, state), do: {:noreply, state}

  def handle_info({:session_expired, ref}, %{session: %{ref: ref}} = state),
    do: {:noreply, release(state)}

  def handle_info({:session_expired, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, _, _}, %{session: %{monitor: monitor}} = state),
    do: {:noreply, release(state)}

  @impl true
  def handle_call({:release, ref}, {owner, _}, %{session: %{ref: ref, owner: owner}} = state),
    do: {:reply, :ok, release(state)}

  def handle_call({:release, _}, _from, state),
    do: {:reply, {:error, :invalid_session}, state}

  def handle_call(:recover, _from, %{session: session} = state) when session != nil,
    do: {:reply, {:error, :busy}, state}

  def handle_call(:recover, _from, state) do
    close_uart(state.uart)

    case open_uart(%{state | uart: nil, available: false}) do
      {:ok, state} -> {:reply, :ok, %{state | blocked: false}}
      {:error, reason, state} -> {:reply, {:error, reason}, %{state | blocked: true}}
    end
  end

  def handle_call(_request, _from, %{blocked: true} = state),
    do: {:reply, {:error, :desynchronized}, state}

  def handle_call(_request, _from, %{available: false} = state),
    do: {:reply, {:error, :tty_not_open}, state}

  def handle_call(
        {:exchange, ref, operation, deadline},
        {owner, _},
        %{session: %{ref: ref, owner: owner}} = state
      ) do
    deadline = min(deadline, state.session.deadline)

    if AT.remaining(deadline) == 0 do
      {:reply, {:error, :timeout}, %{state | blocked: state.session.pending}}
    else
      perform(operation, deadline, state)
    end
  end

  def handle_call({:exchange, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_session}, state}

  def handle_call(_request, _from, %{session: session} = state) when session != nil,
    do: {:reply, {:error, :busy}, state}

  def handle_call({:session, deadline}, {owner, _}, state) do
    if AT.remaining(deadline) == 0 or not Process.alive?(owner) do
      {:reply, {:error, :expired}, state}
    else
      ref = make_ref()

      session = %{
        ref: ref,
        owner: owner,
        monitor: Process.monitor(owner),
        timer: Process.send_after(self(), {:session_expired, ref}, AT.remaining(deadline)),
        deadline: deadline,
        buffer: "",
        pending: false
      }

      handle = %AT{channel: self(), ref: ref, deadline: deadline}
      {:reply, {:ok, handle}, %{state | session: session}}
    end
  end

  defp perform({:send, bytes}, deadline, state) do
    case AT.validate_bytes(bytes) do
      :ok ->
        result = write(state.uart, bytes, deadline)

        state = put_in(state.session.pending, true)
        {:reply, result, %{state | blocked: result != :ok}}

      error ->
        {:reply, error, state}
    end
  end

  defp perform(:receive, deadline, state) do
    case read_response(state.uart, state.session.buffer, state.markers, deadline) do
      {:ok, event, rest} ->
        session = %{
          state.session
          | buffer: rest,
            pending: elem(event, 0) != :response
        }

        {:reply, {:ok, event}, %{state | session: session}}

      {:error, _} = error ->
        {:reply, error, %{state | blocked: true}}
    end
  end

  defp perform(:drain, _deadline, %{session: %{pending: true}} = state),
    do: {:reply, {:error, :exchange_pending}, state}

  defp perform(:drain, _deadline, state) do
    case io(fn -> Circuits.UART.read(state.uart, 0) end) do
      {:ok, _} -> {:reply, :ok, put_in(state.session.buffer, "")}
      {:error, _} = error -> {:reply, error, %{state | blocked: true}}
    end
  end

  defp read_response(uart, buffer, markers, deadline) do
    with true <- AT.remaining(deadline) > 0,
         :more <- AT.parse_response(buffer, markers),
         {:ok, bytes} when bytes != "" <-
           io(fn -> Circuits.UART.read(uart, AT.remaining(deadline)) end) do
      read_response(uart, buffer <> bytes, markers, deadline)
    else
      false -> {:error, :timeout}
      {:ok, ""} -> {:error, :timeout}
      result -> result
    end
  end

  defp release(state) do
    _ = Process.cancel_timer(state.session.timer)
    Process.demonitor(state.session.monitor, [:flush])
    %{state | session: nil, blocked: state.blocked or state.session.pending}
  end

  defp open_uart(state) do
    case Circuits.UART.start_link() do
      {:ok, uart} -> configure_uart(uart, state)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp configure_uart(uart, state) do
    with :ok <-
           io(fn -> Circuits.UART.open(uart, state.tty, speed: state.speed, active: false) end),
         :ok <- io(fn -> Circuits.UART.flush(uart, :receive) end) do
      {:ok, %{state | uart: uart, available: true}}
    else
      {:error, reason} ->
        close_uart(uart)
        {:error, reason, state}
    end
  end

  defp write(uart, bytes, deadline) do
    case AT.remaining(deadline) do
      0 -> {:error, :timeout}
      timeout -> io(fn -> Circuits.UART.write(uart, bytes, timeout) end)
    end
  end

  defp io(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :io_error}
  end

  defp close_uart(nil), do: :ok

  defp close_uart(uart) do
    _ = io(fn -> Circuits.UART.close(uart) end)
    _ = io(fn -> Circuits.UART.stop(uart) end)
    :ok
  end

  @impl true
  def terminate(_reason, state), do: close_uart(state.uart)

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:log, _} -> {:log, []}
      {key, _} when key in [:state, :message, :reason] -> {key, :redacted}
      entry -> entry
    end)
  end
end
