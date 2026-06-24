# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM.ATTest do
  use ExUnit.Case, async: true

  alias VintageNetECM.AT

  describe "parse/1" do
    test "drops the command echo and the trailing OK" do
      raw = "AT+CSQ\r\r\n+CSQ: 17,99\r\n\r\nOK\r\n"
      assert AT.parse(raw) == ["+CSQ: 17,99"]
    end

    test "keeps multiple result lines in order" do
      raw = "AT+FOO\r\r\nline one\r\nline two\r\n\r\nOK\r\n"
      assert AT.parse(raw) == ["line one", "line two"]
    end

    test "a bare OK response parses to an empty list" do
      assert AT.parse("AT\r\r\nOK\r\n") == []
    end

    test "tolerates lone \\r or \\n line endings" do
      assert AT.parse("AT+X\r+X: 1\rOK\r") == ["+X: 1"]
      assert AT.parse("AT+X\n+X: 1\nOK\n") == ["+X: 1"]
    end
  end

  describe "parse_error/1" do
    test "extracts a +CME ERROR detail" do
      assert AT.parse_error("\r\n+CME ERROR: 30\r\n") == {:cme, "30"}
    end

    test "extracts a +CME ERROR with a textual detail" do
      assert AT.parse_error("+CME ERROR: no network service\r\n") ==
               {:cme, "no network service"}
    end

    test "extracts a +CMS ERROR detail" do
      assert AT.parse_error("\r\n+CMS ERROR: 305\r\n") == {:cms, "305"}
    end

    test "falls back to :error for a bare ERROR" do
      assert AT.parse_error("\r\nERROR\r\n") == :error
    end
  end

  describe "open/2" do
    test "returns an error for a tty that does not exist" do
      assert {:error, _reason} = AT.open("/dev/definitely-not-a-real-tty")
    end
  end
end
