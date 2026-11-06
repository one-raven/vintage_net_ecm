# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM.ATController do
  @moduledoc """
  Modem management for `VintageNetECM` over a supervised AT channel.

  Initializes the radio and APN, waits for registration, activates the ECM data
  call, and publishes modem/SIM identity and network information under
  `["interface", ifname, "mobile", ...]`. Identity properties are retried until
  known; registration, signal, operator, technology, serving-cell details and
  timezone are refreshed every 30 seconds. Current time is a live query through
  `VintageNetECM.network_time/1`, not a stale property.

  Every operation leases the same channel as application sessions. Busy or
  unavailable channels defer polling without discarding controller state.
  External managed sessions are admitted only after radio initialization.

  Vendor-specific commands belong to `VintageNetECM.Modem`. Teardown runs after
  VintageNet stops its children, so `deactivate_data_call/3` uses a temporary
  supervisor and channel rather than accessing a UART directly.
  """
  use GenServer
  require Logger
  alias VintageNetECM.{AT, Modem}

  @monitor_interval 30_000
  @register_poll 3_000
  @static_properties ~w(manufacturer model firmware_version imei serial_number imsi iccid)
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

  @type property :: String.t()

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: server(Keyword.fetch!(opts, :ifname)))
  end

  defp server(ifname), do: {:via, Registry, {VintageNet.Interface.Registry, {__MODULE__, ifname}}}

  @doc false
  def channel(ifname) do
    GenServer.call(server(ifname), :channel, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, _ -> {:error, :not_ready}
  end

  @doc "Query network time through an exclusive AT session."
  @spec network_time(VintageNet.ifname()) :: {:ok, Modem.network_time()} | {:error, term()}
  def network_time(ifname) do
    GenServer.call(server(ifname), :network_time, 10_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, _ -> {:error, :outcome_unknown}
  end

  @doc false
  def deactivate_data_call(modem, tty, context_id) do
    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)

    try do
      case Supervisor.start_child(supervisor, {AT.Channel, tty: tty}) do
        {:ok, channel} ->
          AT.session(channel, &modem.deactivate_data_call(&1, context_id), timeout: 6_000)

        {:error, reason} ->
          Logger.warning("[VintageNetECM] deactivate: channel unavailable: #{inspect(reason)}")
      end
    after
      Supervisor.stop(supervisor)
    end

    :ok
  end

  @impl true
  def init(opts) do
    state = %{
      ifname: Keyword.fetch!(opts, :ifname),
      channel: Keyword.fetch!(opts, :channel),
      channel_pid: nil,
      channel_monitor: nil,
      ready: false,
      at: nil,
      context_id: Keyword.get(opts, :context_id, 1),
      apn: Keyword.fetch!(opts, :apn),
      modem: Keyword.get(opts, :modem, Modem.Quectel),
      static: Map.new(@static_properties, &{&1, nil})
    }

    {:ok, state, {:continue, :initialize}}
  end

  @impl true
  def handle_continue(:initialize, state) do
    state = watch_channel(state)

    result =
      AT.session(
        state.channel_pid,
        fn at ->
          state = %{state | at: at}

          with :ok <- configure_radio(state) do
            {:initialized, refresh_static_properties(state)}
          end
        end,
        timeout: 120_000
      )

    with {:initialized, initialized} <- result,
         :ok <- AT.session(state.channel_pid, fn _ -> :ok end) do
      send(self(), :check_registration)
      {:noreply, %{initialized | at: nil, ready: true}}
    else
      _ ->
        Process.send_after(self(), :initialize, @register_poll)
        {:noreply, %{state | ready: false}}
    end
  end

  @impl true
  def handle_info(:initialize, %{ready: true} = state), do: {:noreply, state}
  def handle_info(:initialize, state), do: {:noreply, state, {:continue, :initialize}}

  def handle_info({:DOWN, monitor, :process, _, _}, %{channel_monitor: monitor} = state) do
    send(self(), :initialize)
    {:noreply, %{state | ready: false, channel_pid: nil, channel_monitor: nil}}
  end

  def handle_info(event, %{ready: false} = state) when event in [:monitor, :check_registration],
    do: {:noreply, state}

  def handle_info(:check_registration, state) do
    result =
      AT.session(
        state.channel_pid,
        fn at ->
          state = %{state | at: at}

          if registered?(at) do
            activate_data_call(state)
            publish(state)
            :registered
          else
            :searching
          end
        end,
        timeout: 60_000
      )

    event = if result == :registered, do: :monitor, else: :check_registration
    delay = if event == :monitor, do: @monitor_interval, else: @register_poll
    Process.send_after(self(), event, delay)
    {:noreply, state}
  end

  def handle_info(:monitor, state) do
    result =
      AT.session(
        state.channel_pid,
        fn at ->
          state = refresh_static_properties(%{state | at: at})
          publish(state)

          if registered?(at) and not state.modem.data_call_active?(at) do
            activate_data_call(state)
          end

          %{state | at: nil}
        end,
        timeout: 60_000
      )

    Process.send_after(
      self(),
      :monitor,
      if(is_map(result), do: @monitor_interval, else: @register_poll)
    )

    {:noreply, if(is_map(result), do: result, else: state)}
  end

  @impl true
  def handle_call(:channel, _from, state) do
    result =
      if state.ready and state.channel_pid == GenServer.whereis(state.channel),
        do: {:ok, state.channel_pid},
        else: {:error, :not_ready}

    {:reply, result, state}
  end

  def handle_call(:network_time, _from, %{ready: false} = state),
    do: {:reply, {:error, :not_ready}, state}

  def handle_call(:network_time, _from, state) do
    result = AT.session(state.channel_pid, &network_time(state.modem, &1))
    {:reply, result, state}
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:log, _} -> {:log, []}
      {key, _} when key in [:state, :message, :reason] -> {key, :redacted}
      entry -> entry
    end)
  end

  defp watch_channel(state) do
    pid = GenServer.whereis(state.channel)

    if pid == state.channel_pid do
      state
    else
      if state.channel_monitor, do: Process.demonitor(state.channel_monitor, [:flush])
      %{state | channel_pid: pid, channel_monitor: if(pid, do: Process.monitor(pid))}
    end
  end

  defp configure_radio(state) do
    [
      "ATQ0V1",
      "ATE0",
      "AT+CMEE=1",
      "AT+CEREG=2",
      "AT+CFUN=1",
      # Standard NITZ first; Quectel's 3 also updates the RTC used by CCLK.
      "AT+CTZU=1",
      "AT+CTZU=3",
      ~s(AT+CGDCONT=#{state.context_id},"IP","#{state.apn}"),
      "AT+COPS=0"
    ]
    |> Enum.reduce_while(:ok, fn cmd, :ok ->
      case AT.command(state.at, cmd, timeout: 5_000) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} when reason == :error or is_tuple(reason) -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp activate_data_call(state) do
    case state.modem.activate_data_call(state.at, state.context_id) do
      :ok ->
        :ok

      other ->
        Logger.warning("[VintageNetECM] #{state.ifname}: activate failed: #{inspect(other)}")
    end
  end

  defp registered?(at) do
    with {:error, _} <- AT.command(at, "AT+CEREG?;+CGREG?;+CREG?;+CGATT?;+COPS?", timeout: 2_000),
         {:error, _} <- AT.command(at, "AT+CEREG?", timeout: 2_000) do
      false
    else
      {:ok, lines} -> parse_registered?(lines)
    end
  end

  defp publish(state) do
    properties =
      [
        {"registration", registration(state.at)},
        {"signal_dbm", signal_dbm(state.at)},
        {"operator", operator(state.at)},
        {"access_technology", state.modem.access_technology(state.at)}
      ] ++ network_info_properties(state) ++ time_properties(state)

    put_properties(state.ifname, properties)
  end

  defp put_properties(ifname, properties) do
    properties
    |> Enum.map(fn {name, value} -> {["interface", ifname, "mobile", name], value} end)
    |> then(&PropertyTable.put_many(VintageNet, &1))
  end

  defp network_info_properties(state) do
    info = state.modem.network_info(state.at)
    Enum.map(@network_info_properties, &{Atom.to_string(&1), Map.get(info, &1)})
  end

  defp time_properties(state) do
    case network_time(state.modem, state.at) do
      {:ok, %{utc_offset: utc_offset, dst_offset: dst_offset}} ->
        [
          {"timezone", format_offset(utc_offset)},
          {"utc_offset", utc_offset},
          {"dst_offset", dst_offset}
        ]

      {:error, _} ->
        [{"timezone", nil}, {"utc_offset", nil}, {"dst_offset", nil}]
    end
  end

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

  defp read_static_property(state, "manufacturer"), do: bare_line(state.at, "AT+CGMI")
  defp read_static_property(state, "model"), do: bare_line(state.at, "AT+CGMM")
  defp read_static_property(state, "firmware_version"), do: bare_line(state.at, "AT+CGMR")
  defp read_static_property(state, "imei"), do: bare_line(state.at, "AT+CGSN")
  defp read_static_property(state, "imsi"), do: bare_line(state.at, "AT+CIMI")

  defp read_static_property(state, "serial_number") do
    case AT.command(state.at, "AT+CGSN=0", timeout: 2_000) do
      {:ok, lines} -> parse_serial_number(lines)
      _ -> nil
    end
  end

  defp read_static_property(state, "iccid") do
    case state.modem.iccid(state.at) do
      {:ok, iccid} -> iccid
      _ -> nil
    end
  end

  defp registration(at) do
    case AT.command(at, "AT+CEREG?", timeout: 2_000) do
      {:ok, lines} -> parse_registration(lines)
      _ -> :unknown
    end
  end

  defp signal_dbm(at) do
    case AT.command(at, "AT+CSQ", timeout: 2_000) do
      {:ok, lines} -> parse_signal_dbm(lines)
      _ -> nil
    end
  end

  defp operator(at) do
    case AT.command(at, "AT+COPS?", timeout: 2_000) do
      {:ok, lines} -> parse_operator(lines)
      _ -> nil
    end
  end

  defp network_time(modem, at) do
    case modem.network_time(at) do
      {:ok, time} -> {:ok, time}
      {:error, _} -> clock_time(at)
    end
  end

  defp clock_time(at) do
    case AT.command(at, "AT+CCLK?", timeout: 2_000) do
      {:ok, lines} -> parse_clock(lines)
      {:error, reason} -> {:error, reason}
    end
  end

  defp bare_line(at, cmd) do
    with {:ok, lines} <- AT.command(at, cmd, timeout: 2_000),
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

  @typedoc false
  @type registration ::
          :registered_home
          | :registered_roaming
          | :searching
          | :registration_denied
          | :not_registered

  @doc false
  @spec parse_registered?([String.t()]) :: boolean()
  def parse_registered?(lines) do
    Enum.any?(lines, &Regex.match?(~r/^\+C(E|G)?REG:\s*\d+,[15](,|$)/, &1)) or
      ("+CGATT: 1" in lines and Enum.any?(lines, &Regex.match?(~r/^\+COPS:\s*\d,\d,"/, &1)))
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
         {:ok, local} <- unwrap(DateTime.new(date, time, "Etc/UTC")) do
      {:ok,
       %{utc: DateTime.add(local, -utc_offset, :second), utc_offset: utc_offset, dst_offset: 0}}
    end
  end

  defp unwrap({:ok, datetime}), do: {:ok, datetime}
  defp unwrap(_), do: {:error, :invalid_time}
end
