# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM.Modem.Quectel do
  @moduledoc """
  `VintageNetECM.Modem` implementation for Quectel `usbnet` ECM modems (e.g. the
  EG800Q).

  Quectel exposes a handful of proprietary commands that this module wraps:

    * `AT+QNETDEVCTL` — bring the ECM data call up/down and query its state,
    * `AT+QCSQ` — report the radio access technology (system mode),
    * `AT+QCCID` — read the (U)SIM's ICCID,
    * `AT+QENG="servingcell"` — MCC/MNC, cell ID, TAC and serving-cell signal
      quality (RSRP/RSRQ/SINR),
    * `AT+QNWINFO` — the band and channel the modem is camped on, and
    * `AT+QLTS` — the latest time synchronized from the network, plus its timezone.

  Everything else in the `VintageNetECM` lifecycle uses standard 3GPP commands and
  is handled by `VintageNetECM.ATController`.

  Note that the EG800Q/EG91xQ series is LTE-only, so there is no ESN or MEID to
  report — those are 3GPP2 (CDMA) identifiers. The IMEI (`AT+CGSN`) and the
  module's serial number (`AT+CGSN=0`) are standard and come from the controller.
  """

  @behaviour VintageNetECM.Modem

  alias VintageNetECM.AT

  # QNETDEVCTL params: <op 0|1|3>, <context 1-15>, <urc 0|1>. 1 = activate, 0 = deactivate.
  # (`AT+QNETDEVCTL=?` on the EG800Q-NA reports `(0-1,3),(1-15),(0-1)`.)

  @impl VintageNetECM.Modem
  def default_at_tty, do: "ttyUSB2"

  @impl VintageNetECM.Modem
  def activate_data_call(uart, context_id) do
    case AT.command(uart, "AT+QNETDEVCTL=1,#{context_id},1", timeout: 8_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl VintageNetECM.Modem
  def deactivate_data_call(uart, context_id) do
    _ = AT.command(uart, "AT+QNETDEVCTL=0,#{context_id},1", timeout: 5_000)
    :ok
  end

  @impl VintageNetECM.Modem
  def data_call_active?(uart) do
    case AT.command(uart, "AT+QNETDEVCTL?", timeout: 2_000) do
      {:ok, lines} -> parse_data_call_active(lines)
      _ -> false
    end
  end

  @impl VintageNetECM.Modem
  def access_technology(uart) do
    case AT.command(uart, "AT+QCSQ", timeout: 2_000) do
      {:ok, lines} -> parse_access_technology(lines)
      _ -> nil
    end
  end

  @impl VintageNetECM.Modem
  def iccid(uart) do
    with {:ok, lines} <- AT.command(uart, "AT+QCCID", timeout: 2_000) do
      case parse_iccid(lines) do
        nil -> {:error, :no_iccid}
        iccid -> {:ok, iccid}
      end
    end
  end

  @impl VintageNetECM.Modem
  def network_info(uart) do
    # Both are best-effort: QNWINFO knows the band/channel, QENG knows the cell.
    Map.merge(
      query(uart, "AT+QNWINFO", &parse_nwinfo/1),
      query(uart, ~s(AT+QENG="servingcell"), &parse_serving_cell/1)
    )
  end

  @impl VintageNetECM.Modem
  def network_time(uart) do
    # QLTS=1 asks for GMT rather than local time, so no timezone maths is needed to
    # get to UTC. The trailing offset still describes the *local* zone.
    case AT.command(uart, "AT+QLTS=1", timeout: 2_000) do
      {:ok, lines} -> parse_network_time(lines)
      {:error, reason} -> {:error, reason}
    end
  end

  defp query(uart, cmd, parser) do
    case AT.command(uart, cmd, timeout: 2_000) do
      {:ok, lines} -> parser.(lines)
      _ -> %{}
    end
  end

  @doc false
  # `+QNETDEVCTL: <state>,...` — state 1 means the data call is up.
  @spec parse_data_call_active([String.t()]) :: boolean()
  def parse_data_call_active(lines) do
    Enum.any?(lines, fn line ->
      match?([_, "1"], Regex.run(~r/\+QNETDEVCTL:\s*(\d+)/, line))
    end)
  end

  @doc false
  # `+QCSQ: "<sysmode>",...` — e.g. "LTE", "NOSERVICE".
  @spec parse_access_technology([String.t()]) :: String.t() | nil
  def parse_access_technology(lines) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/\+QCSQ:\s*"([^"]+)"/, line) do
        [_, mode] -> mode
        _ -> nil
      end
    end)
  end

  @doc false
  # `+QCCID: <iccid>` — unquoted digits (a trailing 'F' padding nibble is possible).
  @spec parse_iccid([String.t()]) :: String.t() | nil
  def parse_iccid(lines) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/\+QCCID:\s*"?([0-9A-Fa-f]+)"?/, line) do
        [_, iccid] -> iccid
        _ -> nil
      end
    end)
  end

  @doc false
  # `+QNWINFO: <Act>,<oper>,<band>,<channel>` — e.g.
  # `+QNWINFO: "FDD LTE",46011,"LTE BAND 3",1650`. Reports `No Service` when
  # the modem isn't camped, which simply doesn't match.
  @spec parse_nwinfo([String.t()]) :: VintageNetECM.Modem.network_info()
  def parse_nwinfo(lines) do
    Enum.find_value(lines, %{}, fn line ->
      case Regex.run(~r/\+QNWINFO:\s*"[^"]*",[^,]*,"([^"]*)",(\d+)/, line) do
        [_, band, channel] -> put_string(%{channel: String.to_integer(channel)}, :band, band)
        _ -> nil
      end
    end)
  end

  @doc false
  # `+QENG: "servingcell",<state>,"LTE",<is_tdd>,<mcc>,<mnc>,<cellID>,<pcid>,<earfcn>,
  # <freq_band_ind>,<ul_bw>,<dl_bw>,<tac>,<rsrp>,<rsrq>,<rssi>,<sinr>,<s_rxlev>`.
  #
  # While searching, the modem answers with just `+QENG: "servingcell","SEARCH"`,
  # and any single field may be `-` to mean "invalid right now"; both yield no key.
  #
  # (The v1.1 manual's parameter table lists <earfcn> before <pcid>, but its own
  # example — `...,B57DE33,63,1850,3,...` with band 3 — has them the other way
  # round, matching the rest of the Quectel line. Neither is published, so this
  # only matters for the field offsets below.)
  @spec parse_serving_cell([String.t()]) :: VintageNetECM.Modem.network_info()
  def parse_serving_cell(lines) do
    lines
    |> Enum.find_value(fn line ->
      case Regex.run(~r/"servingcell",(.+)$/, line) do
        [_, fields] -> split_fields(fields)
        _ -> nil
      end
    end)
    |> serving_cell_info()
  end

  defp serving_cell_info([
         _state,
         _rat,
         _is_tdd,
         mcc,
         mnc,
         cell_id,
         _pcid,
         _earfcn,
         _freq_band_ind,
         _ul_bandwidth,
         _dl_bandwidth,
         tac,
         rsrp,
         rsrq,
         _rssi,
         sinr | _rest
       ]) do
    %{}
    |> put_string(:mcc, mcc)
    |> put_string(:mnc, mnc)
    |> put_string(:cell_id, cell_id)
    |> put_string(:tac, tac)
    |> put_integer(:rsrp_dbm, rsrp)
    |> put_integer(:rsrq_db, rsrq)
    |> put_integer(:sinr_db, sinr)
  end

  defp serving_cell_info(_fields), do: %{}

  @doc false
  # `+QLTS: "<time>",<dst>` where <time> is "YYYY/MM/DD,hh:mm:ss±zz" — GMT for
  # `AT+QLTS=1` — and ±zz is the *local* offset in quarter hours. <dst> is how many
  # hours of that offset are daylight saving. An empty time string means the modem
  # has not synchronized with the network yet.
  @spec parse_network_time([String.t()]) ::
          {:ok, VintageNetECM.Modem.network_time()} | {:error, term()}
  def parse_network_time(lines) do
    fields =
      Enum.find_value(lines, fn line ->
        Regex.run(
          ~r/\+QLTS:\s*"(\d{4})\/(\d{2})\/(\d{2}),(\d{2}):(\d{2}):(\d{2})([+-]\d+)"(?:,(\d+))?/,
          line,
          capture: :all_but_first
        )
      end)

    case fields do
      [year, month, day, hour, minute, second, quarter_hours | dst] ->
        build_network_time(
          Enum.map([year, month, day, hour, minute, second], &String.to_integer/1),
          String.to_integer(quarter_hours),
          # The `,<dst>` group is optional and comes back as "" when it didn't match.
          dst |> List.first("") |> integer_or_zero()
        )

      nil ->
        {:error, :not_synchronized}
    end
  end

  defp build_network_time([year, month, day, hour, minute, second], quarter_hours, dst_hours) do
    with {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         # "Etc/UTC" never needs a timezone database, so the ambiguous/gap replies
         # DateTime.new/3 allows for can't happen here.
         {:ok, utc} <- unwrap(DateTime.new(date, time, "Etc/UTC")) do
      {:ok, %{utc: utc, utc_offset: quarter_hours * 15 * 60, dst_offset: dst_hours * 60 * 60}}
    end
  end

  defp unwrap({:ok, datetime}), do: {:ok, datetime}
  defp unwrap(_other), do: {:error, :invalid_time}

  defp integer_or_zero(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  # `+QENG`/`+QNWINFO` values never contain commas, so a plain split is enough.
  defp split_fields(fields) do
    fields
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.trim("\"")))
  end

  defp put_string(info, _key, value) when value in ["", "-"], do: info
  defp put_string(info, key, value), do: Map.put(info, key, value)

  defp put_integer(info, key, value) do
    case Integer.parse(value) do
      {integer, ""} -> Map.put(info, key, integer)
      _ -> info
    end
  end
end
