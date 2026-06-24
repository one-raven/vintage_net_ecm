# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM.Modem.Quectel do
  @moduledoc """
  `VintageNetECM.Modem` implementation for Quectel `usbnet` ECM modems (e.g. the
  EG800Q).

  Quectel exposes two proprietary commands that this module wraps:

    * `AT+QNETDEVCTL` — bring the ECM data call up/down and query its state, and
    * `AT+QCSQ` — report the radio access technology (system mode).

  Everything else in the `VintageNetECM` lifecycle uses standard 3GPP commands and
  is handled by `VintageNetECM.ATController`.
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
end
