# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM do
  @moduledoc """
  A `VintageNet` technology for cellular modems whose data plane is a USB CDC-ECM
  (or RNDIS) network interface — e.g. the Quectel EG800Q in `usbnet` ECM mode.

  Unlike `VintageNetMobile`, which dials a PPP link over a serial AT port, an
  ECM-class modem exposes an ordinary Ethernet-like netdev (`usb0`/`usb1`/`wwan0`)
  whose IP/DNS/route are obtained over DHCP once the modem's internal data call is
  up. `VintageNetECM` therefore **composes** `VintageNetEthernet` for the IP plane and
  adds an AT-control sidecar (`VintageNetECM.ATController`) that:

    * ensures the radio is on (`AT+CFUN=1`), sets the APN (`AT+CGDCONT`), and selects
      the operator automatically (`AT+COPS=0`),
    * waits for the modem to register (`+CEREG` -> 1/5),
    * brings the ECM data call up via the configured `VintageNetECM.Modem` so the
      netdev gets carrier and DHCP can complete,
    * monitors registration/signal and republishes them under
      `["interface", ifname, "mobile", ...]`,
    * deactivates the data call on teardown.

  The vendor-specific AT details live behind the `VintageNetECM.Modem` behaviour. The
  default implementation, `VintageNetECM.Modem.Quectel`, targets Quectel `usbnet` ECM
  modems such as the EG800Q.

  ## Configuration

      VintageNet.configure("usb1", %{
        type: VintageNetECM,
        vintage_net_ecm: %{
          service_providers: [%{apn: "super"}],
          at_tty: "ttyUSB2",
          context_id: 1,
          modem: VintageNetECM.Modem.Quectel
        }
      })

  `:modem` selects the `VintageNetECM.Modem` implementation (defaults to
  `VintageNetECM.Modem.Quectel`). `:at_tty` defaults to that modem's
  `default_at_tty/0`. `:ipv4` defaults to `%{method: :dhcp}` (the only sensible mode
  for ECM). Other `VintageNetEthernet` options (`:dhcpd`, static `:ipv4`,
  `:mac_address`) pass through to the composed ethernet config.
  """

  @behaviour VintageNet.Technology

  alias VintageNet.Interface.RawConfig

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

    normalized_ecm =
      ecm
      |> Map.put(:modem, modem)
      |> Map.put_new(:at_tty, modem.default_at_tty())
      |> Map.put_new(:context_id, @default_context_id)

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

    # Delegate the IP/DHCP plane to VintageNetEthernet. Its normalize/to_raw_config
    # clauses match on `type: VintageNetEthernet`, so swap the type for the call. It
    # only reads :ipv4 / :mac_address / :dhcpd, so the :vintage_net_ecm key is ignored.
    eth_config = Map.put(config, :type, VintageNetEthernet)
    %RawConfig{} = base = VintageNetEthernet.to_raw_config(ifname, eth_config, opts)

    controller =
      {VintageNetECM.ATController,
       [ifname: ifname, tty: at_tty, context_id: context_id, apn: apn, modem: modem]}

    %{
      base
      | # Keep this technology as ours so ioctl/type/persistence dispatch here, and
        # persist our own config (with :vintage_net_ecm) rather than the ethernet one.
        type: __MODULE__,
        source_config: config,
        # Run the AT controller alongside udhcpc + the InternetChecker that
        # VintageNetEthernet already added. `required_ifnames` stays `[ifname]` (the
        # ECM netdev) so VintageNet waits for the modem to enumerate first.
        child_specs: base.child_specs ++ [controller],
        # down_cmds run AFTER the child supervisor is killed, so the AT controller's
        # GenServer is already gone — deactivate_data_call/2 opens its own short-lived
        # UART. Prepend so the data call drops before `ip link set <ifname> down`.
        down_cmds:
          [
            {:fun, VintageNetECM.ATController, :deactivate_data_call,
             [modem, at_tty, context_id]},
            {:fun, PropertyTable, :delete_matches, [VintageNet, ["interface", ifname, "mobile"]]}
          ] ++ base.down_cmds
    }
  end

  @impl VintageNet.Technology
  def ioctl(_ifname, _command, _args), do: {:error, :unsupported}

  @impl VintageNet.Technology
  def check_system(_opts), do: :ok
end
