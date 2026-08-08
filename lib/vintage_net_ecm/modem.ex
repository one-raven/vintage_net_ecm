# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM.Modem do
  @moduledoc """
  Behaviour for the modem-specific AT interactions in `VintageNetECM`.

  `VintageNetECM.ATController` drives the portable, standard-3GPP part of the
  lifecycle itself (echo/error setup, `AT+CFUN`, `AT+CGDCONT`, `AT+COPS`,
  registration polling via `+CEREG`, `+CSQ` signal reporting, and the identity
  commands that every modem supports — `AT+CGMI`, `AT+CGMM`, `AT+CGMR`, `AT+CGSN`,
  `AT+CIMI`). The pieces that differ between modem vendors live behind this
  behaviour:

    * how the ECM/usbnet data call is brought up and torn down,
    * how to tell whether that data call is currently active,
    * how to report the radio access technology,
    * how to read the SIM's ICCID,
    * how to report serving-cell/network details (MCC, MNC, cell ID, band, ...),
    * how to read the network-supplied time and timezone, and
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

  @typedoc """
  Serving-cell and network details reported by `c:network_info/1`.

  Every key is optional — report only what the modem actually returns, and omit
  anything it flags as invalid. `VintageNetECM.ATController` publishes each key
  under `["interface", ifname, "mobile", "<key>"]`, using `nil` for keys that are
  missing.

    * `:mcc` / `:mnc` — mobile country/network code of the serving cell, kept as
      strings so leading zeros and 2- vs 3-digit MNCs survive,
    * `:cell_id` — serving cell ID, as the modem formats it (usually hex),
    * `:tac` — tracking area code, as the modem formats it (usually hex),
    * `:band` — human-readable band name, e.g. `"LTE BAND 3"`,
    * `:channel` — the channel/EARFCN the modem is camped on,
    * `:rsrp_dbm` / `:rsrq_db` / `:sinr_db` — serving-cell signal quality.
  """
  @type network_info :: %{
          optional(:mcc) => String.t(),
          optional(:mnc) => String.t(),
          optional(:cell_id) => String.t(),
          optional(:tac) => String.t(),
          optional(:band) => String.t(),
          optional(:channel) => integer(),
          optional(:rsrp_dbm) => integer(),
          optional(:rsrq_db) => integer(),
          optional(:sinr_db) => integer()
        }

  @typedoc """
  Network-supplied time, as reported by `c:network_time/1`.

    * `:utc` — the current time in UTC,
    * `:utc_offset` — the local timezone's offset from UTC, in seconds,
    * `:dst_offset` — the daylight-saving part of `:utc_offset`, in seconds.
  """
  @type network_time :: %{
          utc: DateTime.t(),
          utc_offset: integer(),
          dst_offset: integer()
        }

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

  @doc """
  Read the ICCID of the installed (U)SIM.

  There is no standard 3GPP command for this — every vendor spells it differently
  (Quectel uses `AT+QCCID`) — so it lives here. Return `{:error, :unsupported}` if
  the modem has no such command.
  """
  @callback iccid(AT.uart()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Report serving-cell and network details.

  Return an empty map when the modem is not camped on a cell or exposes none of
  this. Partial maps are fine — see `t:network_info/0` for the keys.
  """
  @callback network_info(AT.uart()) :: network_info()

  @doc """
  Read the time the modem last synchronized from the network.

  Return `{:error, :unsupported}` if the modem has no vendor command for this;
  `VintageNetECM.ATController` then falls back to the standard `AT+CCLK?` RTC.
  Return `{:error, reason}` if the modem has the command but has not yet
  synchronized with the network.
  """
  @callback network_time(AT.uart()) :: {:ok, network_time()} | {:error, term()}
end
