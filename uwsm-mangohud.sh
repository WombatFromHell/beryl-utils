#!/usr/bin/env bash
set -euo pipefail
/usr/bin/systemctl --user set-environment \
  MANGOHUD=1 \
  "MANGOHUD_CONFIG=read_cfg,fps_limit=70,fps_limit_method=early,vsync=1"
/usr/bin/dbus-update-activation-environment --systemd \
  MANGOHUD \
  MANGOHUD_CONFIG
