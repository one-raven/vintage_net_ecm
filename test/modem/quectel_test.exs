# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM.Modem.QuectelTest do
  use ExUnit.Case, async: true

  alias VintageNetECM.Modem.Quectel

  test "implements the VintageNetECM.Modem behaviour" do
    behaviours =
      Quectel.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    assert VintageNetECM.Modem in behaviours
  end

  test "default_at_tty/0 is the EG800Q AT port" do
    assert Quectel.default_at_tty() == "ttyUSB2"
  end

  describe "parse_data_call_active/1" do
    test "true when QNETDEVCTL reports state 1" do
      assert Quectel.parse_data_call_active(["+QNETDEVCTL: 1,1,1"])
    end

    test "false when QNETDEVCTL reports state 0" do
      refute Quectel.parse_data_call_active(["+QNETDEVCTL: 0,1,1"])
    end

    test "false when there is no QNETDEVCTL line" do
      refute Quectel.parse_data_call_active(["+CEREG: 2,1"])
      refute Quectel.parse_data_call_active([])
    end
  end

  describe "parse_access_technology/1" do
    test "extracts the quoted system mode" do
      assert Quectel.parse_access_technology(["+QCSQ: \"LTE\",-85,-11,135,-5"]) == "LTE"
    end

    test "reports NOSERVICE when the modem has no service" do
      assert Quectel.parse_access_technology(["+QCSQ: \"NOSERVICE\""]) == "NOSERVICE"
    end

    test "nil when there is no QCSQ line" do
      assert Quectel.parse_access_technology(["+CSQ: 17,99"]) == nil
      assert Quectel.parse_access_technology([]) == nil
    end
  end
end
