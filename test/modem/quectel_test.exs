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

  describe "parse_iccid/1" do
    test "extracts the unquoted ICCID" do
      assert Quectel.parse_iccid(["+QCCID: 89860025128306012474"]) == "89860025128306012474"
    end

    test "tolerates quotes and a trailing padding nibble" do
      assert Quectel.parse_iccid(["+QCCID: \"8988303000008051950F\""]) == "8988303000008051950F"
    end

    test "nil when there is no QCCID line" do
      assert Quectel.parse_iccid(["+CME ERROR: 13"]) == nil
      assert Quectel.parse_iccid([]) == nil
    end
  end

  describe "parse_nwinfo/1" do
    test "extracts the band and channel" do
      assert Quectel.parse_nwinfo(["+QNWINFO: \"FDD LTE\",46011,\"LTE BAND 3\",1650"]) ==
               %{band: "LTE BAND 3", channel: 1650}
    end

    test "empty when the modem has no service" do
      assert Quectel.parse_nwinfo(["+QNWINFO: No Service"]) == %{}
      assert Quectel.parse_nwinfo([]) == %{}
    end
  end

  describe "parse_serving_cell/1" do
    test "extracts the cell identity and signal quality" do
      lines = [
        "+QENG: \"servingcell\",\"NOCONN\",\"LTE\",\"FDD\",460,01,B57DE33,63,1850,3,5,5,B504,-85,-10,-54,17,38"
      ]

      assert Quectel.parse_serving_cell(lines) == %{
               mcc: "460",
               mnc: "01",
               cell_id: "B57DE33",
               tac: "B504",
               rsrp_dbm: -85,
               rsrq_db: -10,
               sinr_db: 17
             }
    end

    test "empty while the modem is still searching" do
      assert Quectel.parse_serving_cell(["+QENG: \"servingcell\",\"SEARCH\""]) == %{}
    end

    test "omits fields the modem reports as invalid" do
      lines = [
        "+QENG: \"servingcell\",\"LIMSRV\",\"LTE\",\"FDD\",-,-,-,63,1850,3,5,5,-,-85,-10,-54,-,38"
      ]

      assert Quectel.parse_serving_cell(lines) == %{rsrp_dbm: -85, rsrq_db: -10}
    end

    test "empty when there is no QENG line" do
      assert Quectel.parse_serving_cell(["+CSQ: 17,99"]) == %{}
      assert Quectel.parse_serving_cell([]) == %{}
    end
  end

  describe "parse_network_time/1" do
    test "reads the GMT timestamp and the local offset" do
      assert Quectel.parse_network_time(["+QLTS: \"2017/10/13,03:41:22+32\",0"]) ==
               {:ok, %{utc: ~U[2017-10-13 03:41:22Z], utc_offset: 8 * 60 * 60, dst_offset: 0}}
    end

    test "reports the daylight-saving part of the offset" do
      assert {:ok, %{utc_offset: -25_200, dst_offset: 3600}} =
               Quectel.parse_network_time(["+QLTS: \"2026/08/08,17:04:31-28\",1"])
    end

    test "tolerates a missing dst field" do
      assert {:ok, %{dst_offset: 0}} =
               Quectel.parse_network_time(["+QLTS: \"2017/10/13,03:41:22+32\""])
    end

    test "errors when the modem has not synchronized with the network" do
      assert Quectel.parse_network_time(["+QLTS: \"\""]) == {:error, :not_synchronized}
      assert Quectel.parse_network_time([]) == {:error, :not_synchronized}
    end

    test "errors on an impossible timestamp rather than raising" do
      assert {:error, _reason} = Quectel.parse_network_time(["+QLTS: \"2017/13/40,03:41:22+32\""])
    end
  end
end
