<!--
SPDX-FileCopyrightText: 2026 Ben Youngblood

SPDX-License-Identifier: Apache-2.0
-->

# VintageNetECM

[![Hex version](https://img.shields.io/hexpm/v/vintage_net_ecm.svg "Hex version")](https://hex.pm/packages/vintage_net_ecm)
[![API docs](https://img.shields.io/hexpm/v/vintage_net_ecm.svg?label=docs "API docs")](https://hexdocs.pm/vintage_net_ecm)

A [VintageNet](https://hex.pm/packages/vintage_net) technology for cellular
modems whose data plane is a USB CDC-ECM (or RNDIS) network interface — for
example the Quectel EG800Q in `usbnet` ECM mode.

Unlike `VintageNetMobile`, which dials a PPP link over a serial AT port, an
ECM-class modem exposes an ordinary Ethernet-like netdev (`usb0`/`usb1`/`wwan0`)
whose IP/DNS/route are obtained over DHCP once the modem's internal data call is
up. `VintageNetECM` therefore **composes** `VintageNetEthernet` for the IP plane
and adds an AT-control sidecar that brings the modem's data call up and reports
registration and signal.

The vendor-specific AT details live behind the `VintageNetECM.Modem` behaviour.
The default implementation, `VintageNetECM.Modem.Quectel`, targets Quectel
`usbnet` ECM modems.

Before choosing this library, review the other cellular modem libraries:

| Library | Data interface | Protocol | Notes |
| ------- | -------------- | -------  | ----  |
| [`VintageNetECM`](https://hex.pm/packages/vintage_net_ecm) | USB | AT/CDC-ECM | AT commands for the control path and USB CDC-ECM for data. Newer modems are starting to make this the default. |
| [`VintageNetMobile`](https://hex.pm/packages/vintage_net_mobile) | UART (direct or over USB) | AT/PPP | Pretty much ever modem supports this, but it can be hard to use due to the control and data links being shared and vendor-specific commands |
| [`VintageNetQMI`](https://hex.pm/packages/vintage_net_qmi) | USB | QMI | Generic control protocol for modems with a separate data path. Modems generally just work if they support this protocol. |

## Installation

Add `vintage_net_ecm` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:vintage_net_ecm, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can be
found at <https://hexdocs.pm/vintage_net_ecm>.


## Configuration

```elixir
VintageNet.configure("usb1", %{
  type: VintageNetECM,
  vintage_net_ecm: %{
    service_providers: [%{apn: "super"}],
    at_tty: "ttyUSB2",
    context_id: 1
  }
})
```

* `:service_providers` — required, a non-empty list of maps with a string
  `:apn`. The first provider's APN is used.
* `:modem` — the `VintageNetECM.Modem` implementation (defaults to
  `VintageNetECM.Modem.Quectel`).
* `:at_tty` — the AT control tty (defaults to the modem's `default_at_tty/0`).
* `:context_id` — the PDP context id (defaults to `1`).

`:ipv4` defaults to `%{method: :dhcp}` — the only sensible mode for ECM. Other
`VintageNetEthernet` options (`:dhcpd`, static `:ipv4`, `:mac_address`) pass
through to the composed ethernet config.

## Modem, SIM and network information

The AT sidecar publishes what it learns about the modem under
`["interface", ifname, "mobile", ...]`, so it comes back with the rest of
VintageNet's properties:

```elixir
iex> VintageNet.get_by_prefix(["interface", "usb1", "mobile"])
[
  {["interface", "usb1", "mobile", "access_technology"], "LTE"},
  {["interface", "usb1", "mobile", "band"], "LTE BAND 2"},
  {["interface", "usb1", "mobile", "cell_id"], "B57DE33"},
  {["interface", "usb1", "mobile", "channel"], 900},
  {["interface", "usb1", "mobile", "dst_offset"], 3600},
  {["interface", "usb1", "mobile", "firmware_version"], "EG800QEULCR01A03M04"},
  {["interface", "usb1", "mobile", "iccid"], "89014103211118510720"},
  {["interface", "usb1", "mobile", "imei"], "867698041234567"},
  {["interface", "usb1", "mobile", "imsi"], "310410123456789"},
  {["interface", "usb1", "mobile", "manufacturer"], "Quectel"},
  {["interface", "usb1", "mobile", "mcc"], "310"},
  {["interface", "usb1", "mobile", "mnc"], "410"},
  {["interface", "usb1", "mobile", "model"], "EG800Q"},
  {["interface", "usb1", "mobile", "operator"], "AT&T"},
  {["interface", "usb1", "mobile", "registration"], :registered_home},
  {["interface", "usb1", "mobile", "rsrp_dbm"], -85},
  {["interface", "usb1", "mobile", "rsrq_db"], -10},
  {["interface", "usb1", "mobile", "serial_number"], "BA1234567890"},
  {["interface", "usb1", "mobile", "signal_dbm"], -79},
  {["interface", "usb1", "mobile", "sinr_db"], 17},
  {["interface", "usb1", "mobile", "tac"], "B504"},
  {["interface", "usb1", "mobile", "timezone"], "-07:00"},
  {["interface", "usb1", "mobile", "utc_offset"], -25200}
]
```

Identity properties (`imei`, `iccid`, ...) are read once and then retried until
the modem answers; the rest are refreshed every 30 seconds. A property is `nil`
when the modem couldn't answer for it. See `VintageNetECM.ATController` for
which AT command each one comes from.

Note that the ESN and MEID aren't reported: those are 3GPP2 (CDMA)
identifiers, and an LTE-only module like the EG800Q has neither.

## Current time

The time is a live query rather than a property — it would be stale the moment
it was published:

```elixir
iex> VintageNetECM.utc_now("usb1")
{:ok, ~U[2026-08-08 17:04:31Z]}

iex> VintageNetECM.network_time("usb1")
{:ok, %{utc: ~U[2026-08-08 17:04:31Z], utc_offset: -25200, dst_offset: 3600}}
```

This is the time the *network* gave the modem over NITZ, so it needs no NTP
server and no route to the internet. It's only available once the operator has
sent it — expect `{:error, :not_synchronized}` for the first moments after
registering, and on networks that don't send NITZ at all.

## Supporting another modem

Implement the `VintageNetECM.Modem` behaviour and pass it as `:modem`. The
vendor-specific parts are data-call control, access technology, ICCID,
serving-cell details and network time; the rest of the lifecycle uses standard
3GPP commands. Callbacks may return `{:error, :unsupported}` for anything the
modem has no command for.
