# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule VintageNetECM.MixProject do
  use Mix.Project

  @version "0.2.0"
  @description "VintageNet technology for USB CDC-ECM cellular modems (e.g. Quectel EG800Q)"
  @source_url "https://github.com/one-raven/vintage_net_ecm"

  def project do
    [
      app: :vintage_net_ecm,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      description: @description,
      deps: deps(),
      dialyzer: [
        flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling, :underspecs]
      ],
      docs: docs(),
      package: package(),
      aliases: aliases()
    ]
  end

  def cli do
    [
      preferred_envs: %{
        docs: :docs,
        "hex.publish": :docs,
        "hex.build": :docs
      }
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:circuits_uart, "~> 1.5"},
      {:vintage_net, "~> 0.13"},
      {:vintage_net_ethernet, "~> 0.11"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.3", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.29", only: :docs, runtime: false}
    ]
  end

  defp package do
    %{
      files: [
        "lib",
        "mix.exs",
        "README*",
        "CHANGELOG*"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url
      }
    }
  end

  defp docs do
    [
      extras: ["README.md", "CHANGELOG.md"],
      main: "readme",
      source_ref: "v#{@version}",
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp aliases do
    [
      lint: ["format", "deps.unlock --unused", "credo", "dialyzer"]
    ]
  end
end
