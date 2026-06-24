# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECMTest do
  use ExUnit.Case, async: true

  alias VintageNet.Interface.RawConfig

  # Characterization tests for the current VintageNetECM technology contract.
  # These pin the observable behavior (config normalization + the RawConfig that
  # VintageNet would run) so the upcoming modem-behaviour refactor can be checked
  # against them.

  defp base_config(extra \\ %{}) do
    %{
      type: VintageNetECM,
      vintage_net_ecm: Map.merge(%{service_providers: [%{apn: "super"}]}, extra)
    }
  end

  describe "normalize/1" do
    test "fills in default modem, at_tty, context_id, and dhcp ipv4" do
      normalized = VintageNetECM.normalize(base_config())

      assert normalized.vintage_net_ecm.modem == VintageNetECM.Modem.Quectel
      assert normalized.vintage_net_ecm.at_tty == "ttyUSB2"
      assert normalized.vintage_net_ecm.context_id == 1
      assert normalized.ipv4 == %{method: :dhcp}
    end

    test "derives the default at_tty from the selected modem" do
      defmodule TtyOnlyModem do
        @behaviour VintageNetECM.Modem
        def default_at_tty, do: "ttyACM9"
        def activate_data_call(_uart, _cid), do: :ok
        def deactivate_data_call(_uart, _cid), do: :ok
        def data_call_active?(_uart), do: true
        def access_technology(_uart), do: nil
      end

      normalized = VintageNetECM.normalize(base_config(%{modem: TtyOnlyModem}))

      assert normalized.vintage_net_ecm.modem == TtyOnlyModem
      assert normalized.vintage_net_ecm.at_tty == "ttyACM9"
    end

    test "an explicit at_tty wins over the modem default" do
      normalized = VintageNetECM.normalize(base_config(%{at_tty: "ttyUSB7"}))
      assert normalized.vintage_net_ecm.at_tty == "ttyUSB7"
    end

    test "raises when modem is not a module" do
      assert_raise ArgumentError, ~r/modem/, fn ->
        VintageNetECM.normalize(base_config(%{modem: "nope"}))
      end
    end

    test "keeps explicitly supplied at_tty and context_id" do
      normalized = VintageNetECM.normalize(base_config(%{at_tty: "ttyUSB3", context_id: 4}))

      assert normalized.vintage_net_ecm.at_tty == "ttyUSB3"
      assert normalized.vintage_net_ecm.context_id == 4
    end

    test "does not override an explicit ipv4 configuration" do
      config =
        base_config()
        |> Map.put(:ipv4, %{method: :static, address: {192, 168, 1, 1}, prefix_length: 24})

      normalized = VintageNetECM.normalize(config)

      assert normalized.ipv4.method == :static
    end

    test "raises when service_providers is missing" do
      config = %{type: VintageNetECM, vintage_net_ecm: %{}}
      assert_raise ArgumentError, ~r/service_providers/, fn -> VintageNetECM.normalize(config) end
    end

    test "raises when service_providers is empty" do
      assert_raise ArgumentError, ~r/service_providers/, fn ->
        VintageNetECM.normalize(base_config(%{service_providers: []}))
      end
    end

    test "raises when a provider has no string apn" do
      assert_raise ArgumentError, ~r/service_providers/, fn ->
        VintageNetECM.normalize(base_config(%{service_providers: [%{foo: "bar"}]}))
      end
    end
  end

  describe "to_raw_config/3" do
    setup do
      opts = Application.get_all_env(:vintage_net)
      raw = VintageNetECM.to_raw_config("usb1", base_config(%{at_tty: "ttyUSB2"}), opts)
      %{raw: raw}
    end

    test "stays a VintageNetECM technology bound to its own ifname", %{raw: raw} do
      assert %RawConfig{} = raw
      assert raw.type == VintageNetECM
      assert raw.required_ifnames == ["usb1"]
    end

    test "persists the ECM source config", %{raw: raw} do
      assert raw.source_config.type == VintageNetECM

      assert get_in(raw.source_config, [:vintage_net_ecm, :service_providers]) == [
               %{apn: "super"}
             ]
    end

    test "appends the AT controller child spec", %{raw: raw} do
      controller =
        Enum.find(raw.child_specs, fn
          {VintageNetECM.ATController, _opts} -> true
          _ -> false
        end)

      assert {VintageNetECM.ATController, controller_opts} = controller
      assert controller_opts[:ifname] == "usb1"
      assert controller_opts[:tty] == "ttyUSB2"
      assert controller_opts[:context_id] == 1
      assert controller_opts[:apn] == "super"
      assert controller_opts[:modem] == VintageNetECM.Modem.Quectel
    end

    test "prepends teardown down_cmds that drop the data call and clear mobile props", %{raw: raw} do
      assert [deactivate, clear | _rest] = raw.down_cmds

      assert {:fun, VintageNetECM.ATController, :deactivate_data_call,
              [VintageNetECM.Modem.Quectel, "ttyUSB2", 1]} = deactivate

      assert {:fun, PropertyTable, :delete_matches, [VintageNet, ["interface", "usb1", "mobile"]]} =
               clear
    end
  end

  describe "technology callbacks" do
    test "ioctl is unsupported" do
      assert VintageNetECM.ioctl("usb1", :anything, []) == {:error, :unsupported}
    end

    test "check_system passes" do
      assert VintageNetECM.check_system([]) == :ok
    end
  end
end
