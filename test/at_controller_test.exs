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

  describe "parse_operator/1" do
    test "extracts the operator name" do
      assert ATController.parse_operator(["+COPS: 0,0,\"CHN-UNICOM\",7"]) == "CHN-UNICOM"
    end

    test "nil when no operator is selected" do
      assert ATController.parse_operator(["+COPS: 0"]) == nil
      assert ATController.parse_operator(["+COPS: 0,0,\"\",7"]) == nil
      assert ATController.parse_operator([]) == nil
    end
  end

  describe "parse_serial_number/1" do
    test "extracts the serial number, quoted or not" do
      assert ATController.parse_serial_number(["+CGSN: BA1234567890"]) == "BA1234567890"
      assert ATController.parse_serial_number(["+CGSN: \"BA1234567890\""]) == "BA1234567890"
    end

    test "nil when there is no CGSN line" do
      assert ATController.parse_serial_number(["+CME ERROR: 4"]) == nil
      assert ATController.parse_serial_number([]) == nil
    end
  end

  describe "parse_clock/1" do
    test "converts the local RTC reading to UTC" do
      # 00:19:43 at UTC+2 is 22:19:43 the day before.
      assert ATController.parse_clock(["+CCLK: \"08/01/04,00:19:43+08\""]) ==
               {:ok, %{utc: ~U[2008-01-03 22:19:43Z], utc_offset: 2 * 60 * 60, dst_offset: 0}}
    end

    test "handles a negative offset" do
      assert {:ok, %{utc: ~U[2026-08-09 00:04:31Z], utc_offset: -25_200}} =
               ATController.parse_clock(["+CCLK: \"26/08/08,17:04:31-28\""])
    end

    test "errors when the RTC has not been read" do
      assert ATController.parse_clock(["+CCLK: \"\""]) == {:error, :no_clock}
      assert ATController.parse_clock([]) == {:error, :no_clock}
    end

    test "errors on an impossible timestamp rather than raising" do
      assert {:error, _reason} = ATController.parse_clock(["+CCLK: \"08/13/40,00:19:43+08\""])
    end
  end
end
