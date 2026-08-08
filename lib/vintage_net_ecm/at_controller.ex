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
    5. Publish the modem/SIM identity (see `t:property/0`) once, retrying anything the
       modem wasn't ready to answer.
    6. Periodically publish registration, signal, technology and serving-cell details
       under `["interface", ifname, "mobile", ...]` and re-activate the data call if it
       drops.

  Steps 1-3 and the identity/registration/signal reporting use standard 3GPP commands
  handled here. The vendor-specific bits — data-call control, access technology, ICCID,
  serving-cell info and network time — are delegated to the configured
  `VintageNetECM.Modem` implementation (defaulting to `VintageNetECM.Modem.Quectel`).

  Teardown is handled out-of-band by `deactivate_data_call/3` (a `VintageNetECM`
  `down_cmds` `:fun`), because VintageNet kills this process *before* running down_cmds,
  so `terminate/2` is not a reliable place to talk to the modem.

  ## Published properties

  Everything is published under `["interface", ifname, "mobile", ...]`. A property is
  `nil` when the modem couldn't answer for it.

  | Property | Source |
  | -------- | ------ |
  | `"manufacturer"`, `"model"`, `"firmware_version"` | `AT+CGMI` / `AT+CGMM` / `AT+CGMR` |
  | `"imei"`, `"serial_number"` | `AT+CGSN` / `AT+CGSN=0` |
  | `"imsi"` | `AT+CIMI` |
  | `"iccid"` | `c:VintageNetECM.Modem.iccid/1` |
  | `"registration"` | `AT+CEREG?` |
  | `"signal_dbm"` | `AT+CSQ` |
  | `"operator"` | `AT+COPS?` |
  | `"access_technology"` | `c:VintageNetECM.Modem.access_technology/1` |
  | `"mcc"`, `"mnc"`, `"cell_id"`, `"tac"`, `"band"`, `"channel"`, `"rsrp_dbm"`, `"rsrq_db"`, `"sinr_db"` | `c:VintageNetECM.Modem.network_info/1` |
  | `"timezone"`, `"utc_offset"`, `"dst_offset"` | `c:VintageNetECM.Modem.network_time/1`, falling back to `AT+CCLK?` |

  The current time is deliberately *not* a property — it would be stale the moment it
  was published. Read it with `VintageNetECM.utc_now/1` instead.
  """

  use GenServer
  require Logger

  alias VintageNetECM.AT
  alias VintageNetECM.Modem

  @monitor_interval 30_000
  @register_poll 3_000

  # Identity properties: read once, then retried on each monitor tick until answered.
  @static_properties ~w(manufacturer model firmware_version imei serial_number imsi iccid)

  # Keys of `t:VintageNetECM.Modem.network_info/0`, published under their own names.
  @network_info_properties [
    :mcc,
    :mnc,
    :cell_id,
    :tac,
    :band,
    :channel,
    :rsrp_dbm,
    :rsrq_db,
    :sinr_db
  ]

  @typedoc ~s(The name of a property published under `["interface", ifname, "mobile", ...]`.)
  @type property :: String.t()

  @doc false
  def start_link(opts) do
    ifname = Keyword.fetch!(opts, :ifname)
    GenServer.start_link(__MODULE__, opts, name: via(ifname))
  end

  # Registered in VintageNet's own registry, keyed like VintageNet.Interface.Supervisor,
  # so the controller can be reached by ifname alone (see `network_time/1`).
  defp via(ifname), do: {:via, Registry, {VintageNet.Interface.Registry, {__MODULE__, ifname}}}

  @doc """
  Ask the modem what time the network says it is.

  The AT tty is owned by this GenServer, so the query is serialized with the rest of
  the lifecycle rather than opening a second connection. Returns
  `{:error, :not_running}` if `ifname` has no `VintageNetECM` controller.
  """
  @spec network_time(VintageNet.ifname()) :: {:ok, Modem.network_time()} | {:error, term()}
  def network_time(ifname) do
    GenServer.call(via(ifname), :network_time, 10_000)
  catch
    :exit, _reason -> {:error, :not_running}
  end

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
      uart: nil,
      static: Map.new(@static_properties, &{&1, nil})
    }

    {:ok, state, {:continue, :open}}
  end

  @impl GenServer
  def handle_continue(:open, state) do
    case AT.open(state.tty) do
      {:ok, uart} ->
        state = %{state | uart: uart}
        configure_radio(state)
        state = refresh_static_properties(state)
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
    # The SIM and radio may not have been ready when we first asked, so keep trying.
    state = refresh_static_properties(state)
    publish(state)

    unless state.modem.data_call_active?(state.uart) do
      Logger.info("[VintageNetECM] #{state.ifname}: data call down; re-activating")
      if registered?(state.uart), do: activate_data_call(state)
    end

    Process.send_after(self(), :monitor, @monitor_interval)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:network_time, _from, %{uart: nil} = state) do
    {:reply, {:error, :tty_not_open}, state}
  end

  def handle_call(:network_time, _from, state) do
    {:reply, network_time(state.modem, state.uart), state}
  end

  # --- modem interactions -------------------------------------------------------

  defp configure_radio(state) do
    [
      "ATE0",
      "AT+CMEE=1",
      "AT+CEREG=2",
      "AT+CFUN=1",
      # Take the time and timezone from the network (NITZ) — modems ship with this
      # off. 3GPP TS 27.007 only defines 0 and 1, so ask for 1 first, which every
      # modem takes, then for Quectel's 3, which additionally writes local time to
      # the RTC that the AT+CCLK? fallback reads.
      "AT+CTZU=1",
      "AT+CTZU=3",
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
    properties =
      [
        {"registration", registration(state.uart)},
        {"signal_dbm", signal_dbm(state.uart)},
        {"operator", operator(state.uart)},
        {"access_technology", state.modem.access_technology(state.uart)}
      ] ++ network_info_properties(state) ++ time_properties(state)

    put_properties(state.ifname, properties)
  end

  defp put_properties(ifname, properties) do
    properties
    |> Enum.map(fn {name, value} -> {["interface", ifname, "mobile", name], value} end)
    |> then(&PropertyTable.put_many(VintageNet, &1))
  end

  defp network_info_properties(state) do
    info = state.modem.network_info(state.uart)
    Enum.map(@network_info_properties, &{Atom.to_string(&1), Map.get(info, &1)})
  end

  defp time_properties(state) do
    case network_time(state.modem, state.uart) do
      {:ok, %{utc_offset: utc_offset, dst_offset: dst_offset}} ->
        [
          {"timezone", format_offset(utc_offset)},
          {"utc_offset", utc_offset},
          {"dst_offset", dst_offset}
        ]

      {:error, _reason} ->
        [{"timezone", nil}, {"utc_offset", nil}, {"dst_offset", nil}]
    end
  end

  # Read whatever identity properties we don't have yet and publish just those.
  defp refresh_static_properties(state) do
    read =
      state.static
      |> Enum.filter(fn {_name, value} -> is_nil(value) end)
      |> Map.new(fn {name, _value} -> {name, read_static_property(state, name)} end)

    if map_size(read) == 0 do
      state
    else
      put_properties(state.ifname, Map.to_list(read))
      %{state | static: Map.merge(state.static, read)}
    end
  end

  defp read_static_property(state, "manufacturer"), do: bare_line(state.uart, "AT+CGMI")
  defp read_static_property(state, "model"), do: bare_line(state.uart, "AT+CGMM")
  defp read_static_property(state, "firmware_version"), do: bare_line(state.uart, "AT+CGMR")
  defp read_static_property(state, "imei"), do: bare_line(state.uart, "AT+CGSN")
  defp read_static_property(state, "imsi"), do: bare_line(state.uart, "AT+CIMI")

  defp read_static_property(state, "serial_number") do
    case AT.command(state.uart, "AT+CGSN=0", timeout: 2_000) do
      {:ok, lines} -> parse_serial_number(lines)
      _ -> nil
    end
  end

  defp read_static_property(state, "iccid") do
    case state.modem.iccid(state.uart) do
      {:ok, iccid} -> iccid
      {:error, _reason} -> nil
    end
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

  defp operator(uart) do
    case AT.command(uart, "AT+COPS?", timeout: 2_000) do
      {:ok, lines} -> parse_operator(lines)
      _ -> nil
    end
  end

  # The modem's own command is preferred — it reports what the *network* said. The
  # standard RTC is only a fallback, since it starts at the epoch and is only correct
  # once something (NITZ, `AT+CTZU=3`, ...) has set it.
  defp network_time(modem, uart) do
    case modem.network_time(uart) do
      {:ok, network_time} -> {:ok, network_time}
      {:error, _reason} -> clock_time(uart)
    end
  end

  defp clock_time(uart) do
    case AT.command(uart, "AT+CCLK?", timeout: 2_000) do
      {:ok, lines} -> parse_clock(lines)
      {:error, reason} -> {:error, reason}
    end
  end

  # Commands like AT+CGMI answer with a bare value line and no `+CMD:` prefix.
  defp bare_line(uart, cmd) do
    with {:ok, lines} <- AT.command(uart, cmd, timeout: 2_000),
         value when value not in [nil, ""] <-
           lines |> List.first() |> to_string() |> String.trim() do
      value
    else
      _ -> nil
    end
  end

  defp format_offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    minutes = div(abs(seconds), 60)

    "#{sign}#{pad(div(minutes, 60))}:#{pad(rem(minutes, 60))}"
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

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

  @doc false
  # `+CGSN: <SN>` — the module's serial number, which some firmware quotes.
  @spec parse_serial_number([String.t()]) :: String.t() | nil
  def parse_serial_number(lines) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/\+CGSN:\s*"?([^"\r\n]+?)"?\s*$/, line) do
        [_, serial_number] -> serial_number
        _ -> nil
      end
    end)
  end

  @doc false
  # `+COPS: <mode>[,<format>,<oper>[,<Act>]]` — `<oper>` is missing when no operator
  # is selected. Its format follows `<format>`; the controller leaves `AT+COPS` at the
  # default 0 (long alphanumeric), so this is normally the operator's name.
  @spec parse_operator([String.t()]) :: String.t() | nil
  def parse_operator(lines) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/\+COPS:\s*\d+,\d+,"([^"]*)"/, line) do
        [_, ""] -> nil
        [_, operator] -> operator
        _ -> nil
      end
    end)
  end

  @doc false
  # `+CCLK: "yy/MM/dd,hh:mm:ss±zz"` — *local* time, with ±zz the offset from UTC in
  # quarter hours. 3GPP TS 27.007 has no daylight-saving field here, so `:dst_offset`
  # is always 0; use a modem that implements `c:VintageNetECM.Modem.network_time/1`
  # if you need to tell DST apart from a standard offset.
  @spec parse_clock([String.t()]) :: {:ok, Modem.network_time()} | {:error, term()}
  def parse_clock(lines) do
    fields =
      Enum.find_value(lines, fn line ->
        Regex.run(
          ~r/\+CCLK:\s*"(\d{2})\/(\d{2})\/(\d{2}),(\d{2}):(\d{2}):(\d{2})([+-]\d+)"/,
          line,
          capture: :all_but_first
        )
      end)

    case fields do
      [year, month, day, hour, minute, second, quarter_hours] ->
        utc_offset = String.to_integer(quarter_hours) * 15 * 60

        [year, month, day, hour, minute, second]
        |> Enum.map(&String.to_integer/1)
        |> local_to_utc(utc_offset)

      nil ->
        {:error, :no_clock}
    end
  end

  defp local_to_utc([year, month, day, hour, minute, second], utc_offset) do
    with {:ok, date} <- Date.new(2000 + year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         # The wall clock is built in "Etc/UTC" — which never needs a timezone
         # database, so DateTime.new/3's ambiguous/gap replies can't happen — and then
         # shifted by the offset the modem reported.
         {:ok, local} <- unwrap(DateTime.new(date, time, "Etc/UTC")) do
      {:ok,
       %{utc: DateTime.add(local, -utc_offset, :second), utc_offset: utc_offset, dst_offset: 0}}
    end
  end

  defp unwrap({:ok, datetime}), do: {:ok, datetime}
  defp unwrap(_other), do: {:error, :invalid_time}
end
