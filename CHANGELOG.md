<!--
SPDX-FileCopyrightText: 2026 Ben Youngblood

SPDX-License-Identifier: Apache-2.0
-->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

- Initial implementation of the `VintageNetECM` technology for USB CDC-ECM
  cellular modems.
- `VintageNetECM.Modem` behaviour separating the vendor-specific AT interactions
  (data-call control, access-technology reporting, default AT tty) from the
  shared 3GPP lifecycle.
- `VintageNetECM.Modem.Quectel` implementation targeting Quectel `usbnet` ECM
  modems such as the EG800Q.
