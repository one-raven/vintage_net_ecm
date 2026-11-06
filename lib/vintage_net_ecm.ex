# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM do
  @moduledoc """
  A VintageNet technology for USB CDC-ECM cellular modems.

  Composes `VintageNetEthernet` for DHCP/IP with a supervised AT channel and
  `VintageNetECM.ATController` for radio initialization, registration, data-call
  management and modem properties. Vendor commands belong to `VintageNetECM.Modem`.

      VintageNet.configure("usb1", %{
        type: VintageNetECM,
        vintage_net_ecm: %{
          service_providers: [%{apn: "super"}],
          at_tty: "ttyUSB2",
          context_id: 1,
          intermediate_responses: ["> "],
          modem: VintageNetECM.Modem.Quectel
        }
      })

  `:modem` defaults to `VintageNetECM.Modem.Quectel`; `:at_tty` defaults to the
  modem's `default_at_tty/0`. `:ipv4` defaults to `%{method: :dhcp}`. Other
  `VintageNetEthernet` options pass through. Intermediate markers are exact byte
  sequences, fixed for the channel lifetime (default `[]`).
  """
  @behaviour VintageNet.Technology
  alias VintageNet.Interface.RawConfig
  alias VintageNetECM.AT

  @default_modem VintageNetECM.Modem.Quectel
  @default_context_id 1

  @impl VintageNet.Technology
  def normalize(%{type: __MODULE__} = config) do
    ecm = Map.get(config, :vintage_net_ecm, %{})
    providers = Map.get(ecm, :service_providers, [])

    unless is_list(providers) and providers != [] and
             Enum.all?(providers, &match?(%{apn: apn} when is_binary(apn), &1)) do
      raise ArgumentError,
            "VintageNetECM requires vintage_net_ecm.service_providers to be a non-empty " <>
              "list of maps with a string :apn, e.g. [%{apn: \"super\"}]"
    end

    modem = Map.get(ecm, :modem, @default_modem)

    unless is_atom(modem) do
      raise ArgumentError,
            "VintageNetECM requires vintage_net_ecm.modem to be a VintageNetECM.Modem " <>
              "module, got: #{inspect(modem)}"
    end

    markers = Map.get(ecm, :intermediate_responses, [])

    unless AT.validate_intermediate_responses(markers) == :ok do
      raise ArgumentError,
            "VintageNetECM requires unambiguous intermediate_responses (at most 32 markers, 1–128 bytes each)"
    end

    normalized_ecm =
      ecm
      |> Map.put(:modem, modem)
      |> Map.put_new(:at_tty, modem.default_at_tty())
      |> Map.put_new(:context_id, @default_context_id)
      |> Map.put_new(:intermediate_responses, [])

    config
    |> Map.put(:vintage_net_ecm, normalized_ecm)
    |> Map.put_new(:ipv4, %{method: :dhcp})
  end

  @impl VintageNet.Technology
  def to_raw_config(ifname, %{type: __MODULE__} = config, opts) do
    config = normalize(config)
    ecm = Map.fetch!(config, :vintage_net_ecm)
    at_tty = Map.fetch!(ecm, :at_tty)
    context_id = Map.fetch!(ecm, :context_id)
    modem = Map.fetch!(ecm, :modem)
    apn = ecm |> Map.fetch!(:service_providers) |> hd() |> Map.fetch!(:apn)
    eth_config = Map.put(config, :type, VintageNetEthernet)
    %RawConfig{} = base = VintageNetEthernet.to_raw_config(ifname, eth_config, opts)

    channel =
      {AT.Channel,
       [
         tty: at_tty,
         name: channel_name(ifname),
         intermediate_responses: Map.fetch!(ecm, :intermediate_responses)
       ]}

    controller =
      {VintageNetECM.ATController,
       [
         ifname: ifname,
         channel: channel_name(ifname),
         context_id: context_id,
         apn: apn,
         modem: modem
       ]}

    %{
      base
      | type: __MODULE__,
        source_config: config,
        child_specs: base.child_specs ++ [channel, controller],
        # VintageNet stops the children before running down_cmds.
        down_cmds:
          [
            {:fun, VintageNetECM.ATController, :deactivate_data_call,
             [modem, at_tty, context_id]},
            {:fun, PropertyTable, :delete_matches, [VintageNet, ["interface", ifname, "mobile"]]}
          ] ++ base.down_cmds
    }
  end

  @doc false
  def channel_name(ifname),
    do: {:via, Registry, {VintageNet.Interface.Registry, {AT.Channel, ifname}}}

  @doc "Ask the modem for the current network time in UTC."
  @spec utc_now(VintageNet.ifname()) :: {:ok, DateTime.t()} | {:error, term()}
  def utc_now(ifname) do
    with {:ok, %{utc: utc}} <- network_time(ifname), do: {:ok, utc}
  end

  @doc "Read live network time, including UTC and daylight-saving offsets in seconds."
  @spec network_time(VintageNet.ifname()) ::
          {:ok, VintageNetECM.Modem.network_time()} | {:error, term()}
  defdelegate network_time(ifname), to: VintageNetECM.ATController

  @doc """
  Send a standard AT command on a configured interface through an exclusive session.

  Echo and final OK are omitted. Modem errors retain their `:error`, `{:cme, detail}`
  or `{:cms, detail}` reason. `:timeout` defaults to 5,000 ms. An unavailable modem
  returns `:not_running` or `:not_ready`; a competing session returns `:busy`.
  See `session/3` and `VintageNetECM.AT` for failure semantics.

  Avoid changing radio/APN/data-call state behind the modem controller's back.
  """
  @spec command(VintageNet.ifname(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def command(ifname, cmd, opts \\ []) do
    session(ifname, &AT.command(&1, cmd, opts), opts)
  end

  @doc """
  Lease a configured interface's AT channel after radio initialization.

      VintageNetECM.session("usb1", fn at ->
        VintageNetECM.AT.command(at, "AT+CGMI")
      end)

  Uses the same `AT.command/3`, `AT.send/2`, and `AT.receive/2` operations as a
  standalone `VintageNetECM.AT.session/3`. Controller operations lease this same
  channel, so polling cannot interrupt interactive commands. Competing sessions
  return `:busy`; background polling defers until the channel is free.

  The callback runs in the calling PID. Its result is preserved, exceptions
  propagate, and handles cannot be transferred or reused. `:timeout` bounds all
  channel access, not arbitrary callback code. Failed or incomplete exchanges
  fence traffic; recovery must be explicit and uncertain writes are never retried.
  See `VintageNetECM.AT.session/3` and `VintageNetECM.AT.Channel`.

  Standalone applications supervise `VintageNetECM.AT.Channel` directly; no
  VintageNet interface configuration or explicit open/close calls are needed.
  """
  @spec session(VintageNet.ifname(), (AT.session() -> term()), keyword()) :: term()
  def session(ifname, callback, opts \\ []) do
    with {:ok, deadline} <- AT.deadline(opts),
         {:ok, channel} <- VintageNetECM.ATController.channel(ifname) do
      remaining = AT.remaining(deadline)

      if remaining > 0,
        do: AT.session(channel, callback, timeout: remaining),
        else: {:error, :timeout}
    end
  end

  @impl VintageNet.Technology
  def ioctl(_ifname, _command, _args), do: {:error, :unsupported}

  @impl VintageNet.Technology
  def check_system(_opts), do: :ok
end
