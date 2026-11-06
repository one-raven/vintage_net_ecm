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

  describe "parse_response/2" do
    test "buffers every possible split of a final response" do
      packet = "+CSQ: 17,99\nOK\n"

      for split <- 0..(byte_size(packet) - 1) do
        prefix = binary_part(packet, 0, split)
        assert AT.parse_response(prefix, []) == :more
      end

      assert AT.parse_response(packet, []) == {:ok, {:response, ["+CSQ: 17,99", "OK"]}, ""}
    end

    test "intermediate markers require their complete configured framing" do
      for marker <- ["> ", "DOWNLOAD\r\n"], split <- 0..(byte_size(marker) - 1) do
        assert AT.parse_response(binary_part(marker, 0, split), [marker]) == :more
        assert AT.parse_response(marker, [marker]) == {:ok, {:intermediate, marker}, ""}
      end
    end

    test "consumes lines before a marker and retains bytes after it" do
      assert AT.parse_response("AT+X\r\n \r\n> ERROR\n", ["> "]) ==
               {:ok, {:intermediate, "> "}, "ERROR\n"}

      assert AT.parse_response("OK\n+NOTICE: 1\n", []) ==
               {:ok, {:response, ["OK"]}, "+NOTICE: 1\n"}
    end

    test "markers inside response lines are data, not boundaries" do
      assert AT.parse_response("VALUE: > \nOK\n", ["> "]) ==
               {:ok, {:response, ["VALUE: > ", "OK"]}, ""}

      assert AT.parse_response("> ", []) == :more
    end

    test "recognizes final errors without interpreting their content" do
      for line <- [
            "ERROR",
            "+CME ERROR: 30",
            "+CMS ERROR: 305",
            "NO CARRIER",
            "BUSY",
            "NO ANSWER"
          ] do
        assert AT.parse_response(line <> "\n", []) == {:ok, {:response, [line]}, ""}
      end
    end

    test "retains response data that starts with CONNECT but is not the result code" do
      for line <- ["CONNECTED", "CONNECTIVITY"] do
        assert AT.parse_response(line <> "\r\nOK\r\n", []) ==
                 {:ok, {:response, [line, "OK"]}, "\n"}
      end
    end

    test "rejects data mode and bounds complete and incomplete responses" do
      for line <- ["CONNECT", "CONNECT 115200"] do
        assert AT.parse_response(line <> "\n", []) == {:error, :unsupported_data_mode}
      end

      for bytes <- [String.duplicate("x", 16_385), String.duplicate("x\n", 8_193) <> "OK\n"] do
        assert AT.parse_response(bytes, []) == {:error, :response_too_large}
      end
    end

    test "validates markers once without ambiguous or reserved prefixes" do
      assert AT.validate_intermediate_responses(["> ", "DOWNLOAD\r\n"]) == :ok

      for markers <- [
            nil,
            [:bad],
            [""],
            [" "],
            [">", "> "],
            ["> ", "> "],
            ["OK"],
            ["CONNECT"],
            ["+CMS ERROR:"],
            ["\r\n> "],
            ["A\r\nB"],
            [String.duplicate("x", 129)],
            List.duplicate("> ", 33)
          ] do
        assert AT.validate_intermediate_responses(markers) ==
                 {:error, :invalid_intermediate_responses}
      end
    end
  end
end
