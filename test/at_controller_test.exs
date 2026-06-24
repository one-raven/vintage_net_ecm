# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM.ATControllerTest do
  use ExUnit.Case, async: true

  alias VintageNetECM.ATController

  describe "parse_registered?/1" do
    test "true for home (1) and roaming (5)" do
      assert ATController.parse_registered?(["+CEREG: 2,1"])
      assert ATController.parse_registered?(["+CEREG: 2,5,\"1A2B\",\"00C3D4E5\",7"])
    end

    test "false for searching/denied/not-registered and when absent" do
      refute ATController.parse_registered?(["+CEREG: 2,2"])
      refute ATController.parse_registered?(["+CEREG: 2,0"])
      refute ATController.parse_registered?(["+CSQ: 17,99"])
      refute ATController.parse_registered?([])
    end
  end

  describe "parse_registration/1" do
    test "maps each CEREG stat to an atom" do
      assert ATController.parse_registration(["+CEREG: 2,1"]) == :registered_home
      assert ATController.parse_registration(["+CEREG: 2,5"]) == :registered_roaming
      assert ATController.parse_registration(["+CEREG: 2,2"]) == :searching
      assert ATController.parse_registration(["+CEREG: 2,3"]) == :registration_denied
      assert ATController.parse_registration(["+CEREG: 2,0"]) == :not_registered
    end

    test "treats a missing CEREG line as not registered" do
      assert ATController.parse_registration([]) == :not_registered
      assert ATController.parse_registration(["+CSQ: 17,99"]) == :not_registered
    end
  end

  describe "parse_signal_dbm/1" do
    test "converts the CSQ RSSI index to dBm" do
      # dBm = -113 + 2 * rssi
      assert ATController.parse_signal_dbm(["+CSQ: 0,0"]) == -113
      assert ATController.parse_signal_dbm(["+CSQ: 17,99"]) == -79
      assert ATController.parse_signal_dbm(["+CSQ: 31,7"]) == -51
    end

    test "returns nil for the unknown sentinel (99) and when absent" do
      assert ATController.parse_signal_dbm(["+CSQ: 99,99"]) == nil
      assert ATController.parse_signal_dbm(["+CEREG: 2,1"]) == nil
      assert ATController.parse_signal_dbm([]) == nil
    end
  end
end
