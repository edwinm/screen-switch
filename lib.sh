# Shared helpers for screen-switch, also used as reference by the Swift app.
# Expects the config to have been sourced first.

# A DDC read failed if it is empty or if m1ddc reported it could not reach the
# display. Match on "could not" as well as error/unable -- m1ddc's failure text
# is "Could not find a suitable external display.", which the narrower patterns
# miss, and treating that as success is how you march past a dead link.
#
# ddcFailed() in Displays.swift mirrors this. Keep the two in sync.
ddc_failed() {
  local out="$1" rc
  shopt -s nocasematch
  [[ -z "$out" || "$out" == *"could not"* || "$out" == *error* || "$out" == *unable* || "$out" == *"not find"* ]]
  rc=$?
  shopt -u nocasematch
  return $rc
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
