# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM.ATController do
  @moduledoc """
  Supervised AT-control sidecar for `VintageNetECM`.

  Started by VintageNet (as a `child_spec`) once the ECM netdev is present. Lifecycle:

    1. Open the AT tty.
    2. Configure the radio: `ATE0`, verbose errors, `AT+CEREG=2`, `AT+CFUN=1`, set the
       APN (`AT+CGDCONT`), automatic operator selection (`AT+COPS=0`).
    3. Poll `AT+CEREG?` until registered (stat 1 = home or 5 = roaming).
    4. Bring the ECM data call up via the `VintageNetECM.Modem` implementation. DHCP on
       the netdev — run by the composed `VintageNetEthernet` config — then obtains the
       lease.
    5. Periodically publish `+CEREG` / `+CSQ` / technology under
       `["interface", ifname, "mobile", ...]` and re-activate the data call if it drops.

  Steps 1-3 and the `+CEREG`/`+CSQ` reporting use standard 3GPP commands handled here.
  The modem-specific data-call control and access-technology reporting are delegated to
  the configured `VintageNetECM.Modem` implementation (defaulting to
  `VintageNetECM.Modem.Quectel`).

  Teardown is handled out-of-band by `deactivate_data_call/3` (a `VintageNetECM`
  `down_cmds` `:fun`), because VintageNet kills this process *before* running down_cmds,
  so `terminate/2` is not a reliable place to talk to the modem.
  """

  use GenServer
  require Logger

  alias VintageNetECM.AT

  @monitor_interval 30_000
  @register_poll 3_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Tear the modem's ECM data call down. Invoked from `VintageNetECM` `down_cmds`, where
  the controller GenServer is already gone — so this opens its own short-lived UART and
  delegates the actual command to the `VintageNetECM.Modem` implementation.
  """
  @spec deactivate_data_call(module(), String.t(), pos_integer()) :: :ok
  def deactivate_data_call(modem, tty, context_id) do
    case AT.open(tty) do
      {:ok, uart} ->
        _ = modem.deactivate_data_call(uart, context_id)
        AT.close(uart)

      {:error, reason} ->
        Logger.warning("[VintageNetECM] deactivate: could not open #{tty}: #{inspect(reason)}")
        :ok
    end
  end

  @impl GenServer
  def init(opts) do
    state = %{
      ifname: Keyword.fetch!(opts, :ifname),
      tty: Keyword.fetch!(opts, :tty),
      context_id: Keyword.get(opts, :context_id, 1),
      apn: Keyword.fetch!(opts, :apn),
      modem: Keyword.get(opts, :modem, VintageNetECM.Modem.Quectel),
      uart: nil
    }

    {:ok, state, {:continue, :open}}
  end

  @impl GenServer
  def handle_continue(:open, state) do
    case AT.open(state.tty) do
      {:ok, uart} ->
        state = %{state | uart: uart}
        configure_radio(state)
        send(self(), :check_registration)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning(
          "[VintageNetECM] #{state.ifname}: open #{state.tty} failed: #{inspect(reason)}; retrying"
        )

        Process.send_after(self(), :open, 5_000)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:open, state), do: {:noreply, state, {:continue, :open}}

  def handle_info(:check_registration, state) do
    if registered?(state.uart) do
      Logger.info("[VintageNetECM] #{state.ifname}: registered, activating data call")
      activate_data_call(state)
      publish(state)
      Process.send_after(self(), :monitor, @monitor_interval)
    else
      Process.send_after(self(), :check_registration, @register_poll)
    end

    {:noreply, state}
  end

  def handle_info(:monitor, state) do
    publish(state)

    unless state.modem.data_call_active?(state.uart) do
      Logger.info("[VintageNetECM] #{state.ifname}: data call down; re-activating")
      if registered?(state.uart), do: activate_data_call(state)
    end

    Process.send_after(self(), :monitor, @monitor_interval)
    {:noreply, state}
  end

  # --- modem interactions -------------------------------------------------------

  defp configure_radio(state) do
    [
      "ATE0",
      "AT+CMEE=1",
      "AT+CEREG=2",
      "AT+CFUN=1",
      ~s(AT+CGDCONT=#{state.context_id},"IP","#{state.apn}"),
      "AT+COPS=0"
    ]
    |> Enum.each(fn cmd ->
      case AT.command(state.uart, cmd, timeout: 5_000) do
        {:ok, _} -> :ok
        other -> Logger.debug("[VintageNetECM] #{state.ifname}: #{cmd} -> #{inspect(other)}")
      end
    end)
  end

  defp activate_data_call(state) do
    case state.modem.activate_data_call(state.uart, state.context_id) do
      :ok ->
        :ok

      other ->
        Logger.warning("[VintageNetECM] #{state.ifname}: activate failed: #{inspect(other)}")
    end
  end

  defp registered?(uart) do
    case AT.command(uart, "AT+CEREG?", timeout: 2_000) do
      {:ok, lines} -> parse_registered?(lines)
      _ -> false
    end
  end

  defp publish(state) do
    PropertyTable.put_many(VintageNet, [
      {["interface", state.ifname, "mobile", "registration"], registration(state.uart)},
      {["interface", state.ifname, "mobile", "signal_dbm"], signal_dbm(state.uart)},
      {["interface", state.ifname, "mobile", "access_technology"],
       state.modem.access_technology(state.uart)}
    ])
  end

  defp registration(uart) do
    case AT.command(uart, "AT+CEREG?", timeout: 2_000) do
      {:ok, lines} -> parse_registration(lines)
      _ -> :unknown
    end
  end

  defp signal_dbm(uart) do
    case AT.command(uart, "AT+CSQ", timeout: 2_000) do
      {:ok, lines} -> parse_signal_dbm(lines)
      _ -> nil
    end
  end

  # --- pure response parsing (exposed for tests) --------------------------------

  @typedoc false
  @type registration ::
          :registered_home
          | :registered_roaming
          | :searching
          | :registration_denied
          | :not_registered

  @doc false
  # `+CEREG: <n>,<stat>` — stat 1 (home) or 5 (roaming) means registered.
  @spec parse_registered?([String.t()]) :: boolean()
  def parse_registered?(lines) do
    parse_cereg_stat(lines) in ["1", "5"]
  end

  @doc false
  @spec parse_registration([String.t()]) :: registration()
  def parse_registration(lines) do
    case parse_cereg_stat(lines) do
      "1" -> :registered_home
      "5" -> :registered_roaming
      "2" -> :searching
      "3" -> :registration_denied
      _ -> :not_registered
    end
  end

  defp parse_cereg_stat(lines) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/\+CEREG:\s*\d+,(\d+)/, line) do
        [_, stat] -> stat
        _ -> nil
      end
    end)
  end

  @doc false
  # `+CSQ: <rssi 0..31|99>,<ber>`. dBm = -113 + 2*rssi; 99 = unknown.
  @spec parse_signal_dbm([String.t()]) :: integer() | nil
  def parse_signal_dbm(lines) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/\+CSQ:\s*(\d+),/, line) do
        [_, "99"] -> nil
        [_, asu] -> -113 + 2 * String.to_integer(asu)
        _ -> nil
      end
    end)
  end
end
