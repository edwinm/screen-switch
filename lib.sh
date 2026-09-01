# Shared helpers for screen-switch, also used as reference by the Swift app.
# Expects the config to have been sourced first.

# A DDC read succeeded only if it is a VCP value, which is to say a plain number.
# Everything m1ddc prints when it cannot reach the display is prose, and matching
# that prose is a game you lose: this used to list "could not", "error", "unable"
# and "not find", and still sailed past "The specified display does not exist.",
# treating the sentence as an input code. Recognising the one good shape cannot be
# outrun by the next message.
#
# No range check: a monitor may answer with a code nothing configured expects --
# transients during a switch do -- and that is a reading, not a dead link.
#
# ddcFailed() in Displays.swift mirrors this. Keep the two in sync.
ddc_failed() {
  local out="${1//[[:space:]]/}"
  [[ ! "$out" =~ ^[0-9]+$ ]]
}

ddc_read_input() {
  "$M1DDC" display "$DDC_DISPLAY" get input 2>&1 | head -1
}

# displayplacer has no explicit mirroring field in `list`, but the command it
# prints at the bottom joins mirrored screens with '+'. That is the signal.
current_mode() {
  if "$DISPLAYPLACER" list 2>/dev/null | grep -qE '^displayplacer .*id:[0-9A-Fa-f-]+\+'; then
    echo mirrored
  else
    echo extended
  fi
}

shared_display_connected() {
  [[ -n "${SHARED_DISPLAY_ID:-}" ]] || return 1
  "$DISPLAYPLACER" list 2>/dev/null | grep -q "$SHARED_DISPLAY_ID"
}

# 'mac' and 'work' were the original names for these modes, and may still be
# sitting in someone's Shortcut or devices.conf.
normalize_mode() {
  case "$1" in
    mac)  echo extended ;;
    work) echo mirrored ;;
    *)    echo "$1" ;;
  esac
}
