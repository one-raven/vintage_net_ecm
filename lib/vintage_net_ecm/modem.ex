# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM.Modem do
  @moduledoc """
  Behaviour for the modem-specific AT interactions in `VintageNetECM`.

  `VintageNetECM.ATController` drives the portable, standard-3GPP part of the
  lifecycle itself (echo/error setup, `AT+CFUN`, `AT+CGDCONT`, `AT+COPS`,
  registration polling via `+CEREG`, and `+CSQ` signal reporting). The pieces that
  differ between modem vendors live behind this behaviour:

    * how the ECM/usbnet data call is brought up and torn down,
    * how to tell whether that data call is currently active,
    * how to report the radio access technology, and
    * which AT control tty the modem exposes by default.

  The default implementation is `VintageNetECM.Modem.Quectel`, which targets
  Quectel `usbnet` ECM modems such as the EG800Q. Select a different modem with
  the `:modem` key under `:vintage_net_ecm`:

      VintageNet.configure("usb1", %{
        type: VintageNetECM,
        vintage_net_ecm: %{
          service_providers: [%{apn: "super"}],
          modem: MyApp.SomeOtherModem
        }
      })
  """

  alias VintageNetECM.AT

  @doc """
  Bring the ECM data call up.

  Called over the controller's open UART once the modem reports registered.
  """
  @callback activate_data_call(AT.uart(), context_id :: pos_integer()) ::
              :ok | {:error, term()}

  @doc """
  Tear the ECM data call down.

  Called on teardown over a fresh, short-lived UART (the controller GenServer is
  already gone by then). Implementations should not assume any prior session
  state and should return `:ok` even if the modem reports nothing to tear down.
  """
  @callback deactivate_data_call(AT.uart(), context_id :: pos_integer()) ::
              :ok | {:error, term()}

  @doc "Whether the ECM data call is currently active."
  @callback data_call_active?(AT.uart()) :: boolean()

  @doc "Current radio access technology (e.g. `\"LTE\"`), or `nil` if unknown."
  @callback access_technology(AT.uart()) :: String.t() | nil

  @doc "Default AT control tty basename for this modem family, e.g. `\"ttyUSB2\"`."
  @callback default_at_tty() :: String.t()
end
