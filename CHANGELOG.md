<!--
SPDX-FileCopyrightText: 2026 Ben Youngblood

SPDX-License-Identifier: Apache-2.0
-->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [v0.2.0]

* Added
  * Report modem/SIM identity, network details, and network time [#2](https://github.com/one-raven/vintage_net_ecm/issues/2)

* Docs
  * Add table with links to other cell modem libraries (@fhunleth) [#1](https://github.com/one-raven/vintage_net_ecm/issues/1)

## [v0.1.0]

* Initial implementation of the `VintageNetECM` technology for USB CDC-ECM
  cellular modems.
* `VintageNetECM.Modem` behaviour separating the vendor-specific AT interactions
  (data-call control, access-technology reporting, default AT tty) from the
  shared 3GPP lifecycle.
* `VintageNetECM.Modem.Quectel` implementation targeting Quectel `usbnet` ECM
  modems such as the EG800Q.
* Modem and SIM identity published under `["interface", ifname, "mobile", ...]`:
  `manufacturer`, `model`, `firmware_version`, `imei`, `serial_number`, `imsi`
  and `iccid`.
* Network details published alongside registration and signal: `operator`,
  `mcc`, `mnc`, `cell_id`, `tac`, `band`, `channel`, `rsrp_dbm`, `rsrq_db` and
  `sinr_db`.
* Network-supplied timezone published as `timezone`, `utc_offset` and
  `dst_offset`, with `VintageNetECM.utc_now/1` and
  `VintageNetECM.network_time/1` for the current time.
