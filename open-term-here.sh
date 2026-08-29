#!/usr/bin/env bash
# open-term-here: open a dir in a terminal, tmux, or zellij.
# Usage:
#   open-term-here.sh <path>                           plain: active muxer session, else default terminal
#   open-term-here.sh --term [<term> [args] --] <path> new terminal window (default: xdg-terminal-exec)
#   open-term-here.sh --tmux <path>                    new tmux window (no GUI spawn)
#   open-term-here.sh --zellij <path>                  new zellij pane (no GUI spawn)
# SESSION env var overrides the default session name.
# ponytail: SESSION defaults to "main"; zellij pane-create verb may vary by version.

SESSION=${SESSION:-main}
err() {
  notify-send Error "$1"
  exit 1
}

# Open DIR in an existing/fresh tmux or zellij session.
muxer_open() {
  local muxer=$1 dir=$2
  if [[ $muxer == tmux ]]; then
    if tmux has-session -t "$SESSION" 2>/dev/null; then
      tmux new-window -c "$dir"
    else
      tmux new-session -A -s "$SESSION" -c "$dir"
    fi
  else
    if zellij ls 2>/dev/null | grep -qx "$SESSION"; then
      # ponytail: zellij pane-create syntax varies by version; try both forms
      zellij -s "$SESSION" action new-pane --cwd "$dir" 2>/dev/null ||
        zellij action --session "$SESSION" new-pane --cwd "$dir"
    else
      cd "$dir" && zellij attach --create "$SESSION"
    fi
  fi
}

# Name of the multiplexer with an active SESSION-named session, or non-zero.
active_muxer() {
  tmux has-session -t "$SESSION" 2>/dev/null && {
    echo tmux
    return
  }
  zellij ls 2>/dev/null | grep -qx "$SESSION" && {
    echo zellij
    return
  }
  return 1
}

# Open DIR in the default terminal (xdg-terminal-exec, else $TERMINAL).
default_term() {
  local dir=$1
  command -v xdg-terminal-exec >/dev/null 2>&1 && exec xdg-terminal-exec --dir="$dir"
  [[ -n ${TERMINAL:-} ]] && { cd "$dir" && exec "$TERMINAL"; }
  err "No terminal (xdg-terminal-exec) available"
}

case ${1:-} in
--term)
  shift
  term=()
  dir=""
  seen=0
  for a in "$@"; do
    if [[ $a == -- ]]; then
      seen=1
      dir=""
      continue
    fi
    ((seen)) && dir=$a || term+=("$a")
  done
  ((seen)) || {
    dir=${!#}
    term=("${@:1:$#-1}")
  }
  [[ -d $dir ]] || err "Invalid dir: $dir"
  ((${#term[@]} == 0)) && default_term "$dir"
  cd "$dir" || exit 1
  nohup "${term[@]}" >/dev/null 2>&1 &
  ;;
--tmux | --zellij)
  muxer=${1#--}
  shift
  dir=${!#}
  [[ -d $dir ]] || err "Invalid dir: $dir"
  muxer_open "$muxer" "$dir"
  ;;
*)
  dir=$1
  [[ -d $dir ]] || err "Invalid dir: $dir"
  if m=$(active_muxer); then
    muxer_open "$m" "$dir"
  else
    default_term "$dir"
  fi
  ;;
esac
