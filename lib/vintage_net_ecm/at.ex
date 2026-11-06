# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM.AT do
  @moduledoc """
  Scoped AT conversations with buffered protocol framing.

  Send writes exact bytes. Receive waits for a configured intermediate marker or
  a complete final-result line. Applications choose commands and interpret their
  response data; the supervised channel owns the UART and tracks exchange completion.
  """
  import Kernel, except: [send: 2]
  alias VintageNetECM.AT.Channel

  @enforce_keys [:channel, :ref, :deadline]
  defstruct [:channel, :ref, :deadline]

  @opaque session :: %__MODULE__{channel: pid(), ref: reference(), deadline: integer()}
  @type event :: {:intermediate, binary()} | {:response, [String.t()]}
  @max_response 16_384
  @final_results ["OK", "ERROR", "NO CARRIER", "NO DIALTONE", "NO DIAL TONE", "BUSY", "NO ANSWER"]
  @error_prefixes ["+CME ERROR:", "+CMS ERROR:"]
  @data_mode "CONNECT"

  @doc """
  Exclusively lease a supervised channel for the callback, running in the calling PID.

  Competing sessions return `{:error, :busy}`. The callback result is preserved and
  exceptions propagate. Handles cannot be shared with other PIDs or reused later.
  `:timeout` (default 5,000 ms) bounds acquisition and every UART operation, not
  arbitrary callback code. Per-operation timeouts may shorten, never extend it.

  Incomplete exchanges, I/O failures and response timeouts fence further traffic
  with `{:error, :desynchronized}`. A lost call returns `:outcome_unknown`; never
  automatically retry a write. See `VintageNetECM.AT.Channel.recover/1`.
  """
  @spec session(GenServer.server(), (session() -> term()), keyword()) :: term()
  defdelegate session(channel, callback, opts \\ []), to: Channel

  @doc """
  Write exactly the supplied bytes (1–4096 bytes), without adding a terminator.

  The handle belongs to the callback's PID. Failed writes do not establish that
  no bytes reached the modem; never retry automatically.
  """
  @spec send(session(), binary(), keyword()) :: :ok | {:error, term()}
  def send(%__MODULE__{} = session, bytes, opts \\ []),
    do: Channel.exchange(session, {:send, bytes}, opts)

  @doc """
  Receive a configured intermediate marker or all lines through a final result.

  UART fragments are buffered. Intermediate markers are returned exactly as
  configured, including framing bytes. Response line delimiters and blank lines
  are omitted; echoes and unsolicited lines are retained. Lines preceding an
  intermediate marker are consumed. Notifications are not independently routed.

  A final response completes the exchange, even when its result is an error.
  Intermediate events do not. Unsupported CONNECT/data mode, failed I/O and
  timeouts fence further traffic. Responses are bounded to 16,384 bytes.
  `:timeout` defaults to 5,000 ms and cannot extend the session deadline.
  """
  @spec receive(session(), keyword()) :: {:ok, event()} | {:error, term()}
  def receive(%__MODULE__{} = session, opts \\ []),
    do: Channel.exchange(session, :receive, opts)

  @doc "Send a standard AT command. Echo and OK are omitted; modem errors retain their existing tuples."
  @spec command(session(), String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def command(%__MODULE__{} = session, cmd, opts \\ []) do
    with {:ok, deadline} <- deadline(opts, session.deadline) do
      session = %{session | deadline: deadline}

      with :ok <- Channel.exchange(session, :drain, opts),
           :ok <- send(session, cmd <> "\r", opts),
           {:ok, event} <- __MODULE__.receive(session, opts) do
        command_result(event)
      end
    end
  end

  defp command_result({:intermediate, _}), do: {:error, :unexpected_intermediate}

  defp command_result({:response, lines}) do
    raw = Enum.join(lines, "\r\n")
    if List.last(lines) == "OK", do: {:ok, parse(raw)}, else: {:error, parse_error(raw)}
  end

  @doc false
  def validate_intermediate_responses(markers) when is_list(markers) and length(markers) <= 32 do
    reserved = @final_results ++ @error_prefixes ++ [@data_mode]

    if Enum.all?(markers, &valid_marker?(&1, markers ++ reserved)),
      do: :ok,
      else: {:error, :invalid_intermediate_responses}
  end

  def validate_intermediate_responses(_), do: {:error, :invalid_intermediate_responses}

  defp valid_marker?(marker, all) when is_binary(marker) and byte_size(marker) in 1..128 do
    body = String.trim_trailing(marker, "\n") |> String.trim_trailing("\r")

    not String.contains?(body, ["\r", "\n"]) and String.trim(body) != "" and
      Enum.count(all, fn other ->
        is_binary(other) and
          (String.starts_with?(other, marker) or String.starts_with?(marker, other))
      end) == 1
  end

  defp valid_marker?(_, _), do: false

  @doc false
  def parse_response(buffer, markers) when byte_size(buffer) <= @max_response,
    do: parse_response(buffer, markers, [])

  def parse_response(_buffer, _markers), do: {:error, :response_too_large}

  defp parse_response(buffer, markers, lines) do
    case frame(buffer, markers) do
      {:intermediate, marker, rest} ->
        {:ok, {:intermediate, marker}, rest}

      {:line, line, rest} ->
        cond do
          line == @data_mode or String.starts_with?(line, @data_mode <> " ") ->
            {:error, :unsupported_data_mode}

          line in @final_results or String.starts_with?(line, @error_prefixes) ->
            {:ok, {:response, Enum.reverse([line | lines])}, rest}

          true ->
            parse_response(rest, markers, [line | lines])
        end

      {:more, _partial} ->
        :more
    end
  end

  defp frame(<<delimiter, rest::binary>>, markers) when delimiter in [?\r, ?\n],
    do: frame(rest, markers)

  defp frame(buffer, markers) do
    case Enum.find(markers, &String.starts_with?(buffer, &1)) do
      nil ->
        if Enum.any?(markers, &String.starts_with?(&1, buffer)),
          do: {:more, buffer},
          else: frame_line(buffer, markers)

      marker ->
        rest = binary_part(buffer, byte_size(marker), byte_size(buffer) - byte_size(marker))
        {:intermediate, marker, rest}
    end
  end

  defp frame_line(buffer, markers) do
    case :binary.match(buffer, ["\r", "\n"]) do
      {position, 1} ->
        line = binary_part(buffer, 0, position)
        rest = binary_part(buffer, position + 1, byte_size(buffer) - position - 1)
        if String.trim(line) == "", do: frame(rest, markers), else: {:line, line, rest}

      :nomatch ->
        {:more, buffer}
    end
  end

  @doc false
  def deadline(opts, limit \\ nil) do
    with {:ok, options} <- Keyword.validate(opts, timeout: 5_000),
         timeout when is_integer(timeout) and timeout > 0 <- options[:timeout] do
      deadline = System.monotonic_time(:millisecond) + timeout
      {:ok, if(limit, do: min(deadline, limit), else: deadline)}
    else
      _ -> {:error, :invalid_options}
    end
  end

  @doc false
  def remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @doc false
  def validate_bytes(bytes) when is_binary(bytes) and byte_size(bytes) in 1..4_096, do: :ok
  def validate_bytes(_), do: {:error, :invalid_data}

  @doc false
  @spec parse(String.t()) :: [String.t()]
  def parse(raw) do
    raw
    |> String.split(~r/\r\n|\r|\n/, trim: true)
    |> Enum.reject(&(&1 == "OK" or String.starts_with?(&1, "AT")))
  end

  @doc false
  @spec parse_error(String.t()) :: {:cme, String.t()} | {:cms, String.t()} | :error
  def parse_error(raw) do
    cond do
      match = Regex.run(~r/\+CME ERROR:\s*(.+)/, raw) -> {:cme, String.trim(List.last(match))}
      match = Regex.run(~r/\+CMS ERROR:\s*(.+)/, raw) -> {:cms, String.trim(List.last(match))}
      true -> :error
    end
  end
end
