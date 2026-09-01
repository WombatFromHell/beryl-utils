#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
start)
  /usr/bin/systemctl --user set-environment \
  MANGOHUD=1 \
  "MANGOHUD_CONFIG=read_cfg,fps_limit=70,fps_limit_method=early,vsync=1"
/usr/bin/dbus-update-activation-environment --systemd \
  MANGOHUD \
  MANGOHUD_CONFIG
  ;;
stop)
  /usr/bin/systemctl --user unset-environment MANGOHUD MANGOHUD_CONFIG
  # ponytail: systemd >= 256 unsets named vars absent from the caller env
  env -u MANGOHUD -u MANGOHUD_CONFIG \
    /usr/bin/dbus-update-activation-environment --systemd MANGOHUD MANGOHUD_CONFIG
  ;;
*)
  echo "usage: $0 {start|stop}" >&2
  exit 1
  ;;
esac
