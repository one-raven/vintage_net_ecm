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

## Supporting another modem

Implement the `VintageNetECM.Modem` behaviour and pass it as `:modem`. Only the
data-call control and access-technology reporting are vendor-specific; the rest
of the lifecycle uses standard 3GPP commands.
