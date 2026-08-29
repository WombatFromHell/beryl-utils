#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$SRC_DIR/assets"
PREFERRED_LINK_TARGET="$HOME/.local/bin/scripts"
LOCAL_LINK_TARGET="$HOME/.local/bin"
GLOBAL_LINK_TARGET="/usr/local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# ponytail: manifest is the single source of truth, shared with flake.nix.
# columns: src|role|outname|install_links|home_dest
#   role: bin lib pybin unit desktop
#   install_links: %localbin%/x,%globalbin%/x  (empty = copy only)
#   home_dest: HOME-relative dir for role=desktop symlink target

units=()

check_dir() {
  # ponytail: pure ensure-exists; mkdir -p returns 0 whether or not the dir
  # pre-existed, so no caller needs to guard against a non-zero exit.
  mkdir -p -- "$1"
}

dispatch() {
  local src="$1" role="$2" out="$3" links="$4" home="$5"
  # src is relative to assets/; the install dest is always the basename
  local file="$ASSETS_DIR/$src" dest="${src##*/}"
  case "$role" in
  unit)
    check_dir "$UNIT_DIR"
    cp -vfp -- "$file" "$UNIT_DIR/$dest"
    units+=("$dest")
    ;;
  desktop)
    check_dir "$PREFERRED_LINK_TARGET"
    cp -vfp -- "$file" "$PREFERRED_LINK_TARGET/$dest"
    check_dir "$HOME/$home"
    ln -sf "$PREFERRED_LINK_TARGET/$dest" "$HOME/$home/$out"
    ;;
  *)
    check_dir "$PREFERRED_LINK_TARGET"
    cp -vfp -- "$file" "$PREFERRED_LINK_TARGET/$dest"
    [[ -z $links ]] && return
    check_dir "$LOCAL_LINK_TARGET"
    local IFS=',' link
    for link in $links; do
      link="${link//%localbin%/$LOCAL_LINK_TARGET}"
      link="${link//%globalbin%/$GLOBAL_LINK_TARGET}"
      # ponytail: only the parent dir writability is checked; sudo is used for
      # root-owned dirs like /usr/local/bin. No password caching/retry logic.
      if [[ -w ${link%/*} ]]; then
        ln -sf "$PREFERRED_LINK_TARGET/$dest" "$link"
      else
        sudo ln -sf "$PREFERRED_LINK_TARGET/$dest" "$link"
      fi
    done
    ;;
  esac
}

while IFS='|' read -r src role out links home; do
  [[ -z $src || $src == \#* ]] && continue
  dispatch "$src" "$role" "$out" "$links" "$home"
done <"$ASSETS_DIR/manifest"

if ((${#units[@]})); then
  systemctl --user daemon-reload
  # ponytail: enable-only; start is deferred to the next wayland-session
  # activation via the units' WantedBy targets.
  systemctl --user enable "${units[@]}"
fi
