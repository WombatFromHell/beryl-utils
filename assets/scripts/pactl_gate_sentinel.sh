#!/usr/bin/env bash
# ponytail: no HUP trap — pactl inside a trap handler while bash is blocked
# on a foreground child ("$@") can fail silently.  --reload does the work
# directly instead.

sink_name=gate_sentinel
lock=/tmp/pactl_gate_sentinel.pid

sink_load() { pactl load-module module-null-sink sink_name="$sink_name" sink_properties=application.process.binary="$sink_name"; }
sink_unload() { [ -n "$1" ] && pactl unload-module "$1"; }

if [ "$1" = --reload ]; then
  read -r pid old_mod <"$lock" 2>/dev/null || {
    echo "gate sentinel not running"
    exit 1
  }
  kill -0 "$pid" 2>/dev/null || {
    echo "gate sentinel not running (stale lock)"
    exit 1
  }
  sink_unload "$old_mod" 2>/dev/null || true
  new_mod=$(sink_load) || {
    echo "failed to load null-sink" >&2
    exit 1
  }
  printf '%s %s\n' "$pid" "$new_mod" >"$lock"
  echo "sentinel reloaded (module $new_mod)"
  exit
fi

sink_id=$(sink_load)
trap 'rm -f "$lock"; sink_unload "$sink_id"' EXIT
printf '%s %s\n' "$$" "$sink_id" >"$lock"
"$@"
