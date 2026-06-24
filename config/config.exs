# SPDX-FileCopyrightText: 2026 Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

import Config

if config_env() == :test do
  # VintageNet's application takes ownership of "/etc/resolv.conf" and a persistence
  # directory on boot. Point both at a throwaway tmp dir so the supervision tree can
  # start during tests (e.g. in CI) without touching the real system.
  #
  # NameResolver writes resolv.conf without creating its parent, so make the dir here
  # (config is evaluated before the application boots).
  tmp_dir = Path.join(System.tmp_dir!(), "vintage_net_ecm_test")
  File.mkdir_p!(tmp_dir)

  config :vintage_net,
    resolvconf: Path.join(tmp_dir, "resolv.conf"),
    persistence_dir: Path.join(tmp_dir, "persistence"),
    config: []
end
