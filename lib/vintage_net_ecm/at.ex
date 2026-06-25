# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM.AT do
  @moduledoc """
  Minimal AT-command helper over `Circuits.UART` for `VintageNetECM`.

  Passive, synchronous request/response: open a tty, send `AT...` lines, and read the
  response, draining until a final `OK`/`ERROR` (or timeout). This deliberately avoids
  `vintage_net_mobile`'s `ExChat` so the module stays dependency-free for extraction
  into `vintage_net_ecm`.

  Not for high-throughput or unsolicited-result-code (URC) streaming — it's a probe/
  control channel. Each `command/3` drains stale bytes first, so interleaved URCs are
  tolerated but not delivered to a subscriber.
  """

  @type uart :: pid()

  @default_speed 115_200

  @doc "Open the AT tty in passive mode. Baud is ignored over USB CDC but required by the API."
  @spec open(String.t(), keyword()) :: {:ok, uart()} | {:error, term()}
  def open(tty, opts \\ []) do
    speed = Keyword.get(opts, :speed, @default_speed)

    with {:ok, uart} <- Circuits.UART.start_link(),
         :ok <- Circuits.UART.open(uart, tty, speed: speed, active: false) do
      {:ok, uart}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Close and stop the UART process."
  @spec close(uart()) :: :ok
  def close(uart) do
    _ = Circuits.UART.close(uart)
    _ = Circuits.UART.stop(uart)
    :ok
  end

  @doc """
  Send a single AT command and collect the response.

  Returns `{:ok, lines}` with the command echo and trailing `OK` stripped, or
  `{:error, {:cme, detail}}` / `{:error, {:cms, detail}}` / `{:error, :timeout}` /
  `{:error, reason}`.
  """
  @spec command(uart(), String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def command(uart, cmd, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    # Drop any buffered unsolicited bytes so they don't pollute this command's reply.
    _ = Circuits.UART.read(uart, 0)
    _ = Circuits.UART.write(uart, cmd <> "\r")
    collect(uart, "", timeout, System.monotonic_time(:millisecond))
  end

  defp collect(uart, acc, timeout, started) do
    remaining = timeout - (System.monotonic_time(:millisecond) - started)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case Circuits.UART.read(uart, remaining) do
        {:ok, ""} -> collect(uart, acc, timeout, started)
        {:ok, data} -> handle_chunk(uart, acc <> data, timeout, started)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Decide whether the accumulated response is complete (final OK/ERROR) or needs more.
  defp handle_chunk(uart, acc, timeout, started) do
    cond do
      String.contains?(acc, "ERROR") -> {:error, parse_error(acc)}
      Regex.match?(~r/(^|\r|\n)OK(\r|\n|$)/, acc) -> {:ok, parse(acc)}
      true -> collect(uart, acc, timeout, started)
    end
  end

  @doc false
  # Split a raw response into lines, dropping the command echo and the final `OK`.
  @spec parse(String.t()) :: [String.t()]
  def parse(raw) do
    raw
    |> String.split(~r/\r\n|\r|\n/, trim: true)
    |> Enum.reject(&(&1 == "OK" or String.starts_with?(&1, "AT")))
  end

  @doc false
  # Classify an error response. `+CME`/`+CMS ERROR` carry a detail; bare `ERROR` does not.
  @spec parse_error(String.t()) :: {:cme, String.t()} | {:cms, String.t()} | :error
  def parse_error(raw) do
    cond do
      match = Regex.run(~r/\+CME ERROR:\s*(.+)/, raw) -> {:cme, String.trim(List.last(match))}
      match = Regex.run(~r/\+CMS ERROR:\s*(.+)/, raw) -> {:cms, String.trim(List.last(match))}
      true -> :error
    end
  end
end
