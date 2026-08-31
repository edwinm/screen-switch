# Screen Switch configuration.
#
# You should not have to edit this by hand: the menu bar app's Settings... window
# detects your displays and writes this file for you, and rewrites it whenever you
# change something there. Comments you add will not survive that rewrite.
#
# It lives at ~/.config/screen-switch/config.sh. Copy this example there to start
# from a hand-written one instead.

# --- Tools -----------------------------------------------------------------
# Absolute paths, because launchd and Shortcuts run with a minimal PATH and will
# not find Homebrew binaries on their own. Apple Silicon puts them in
# /opt/homebrew/bin; a custom Homebrew prefix will differ.
DISPLAYPLACER="/opt/homebrew/bin/displayplacer"
M1DDC="/opt/homebrew/bin/m1ddc"

# --- Displays --------------------------------------------------------------
# Persistent screen ids, as printed by `displayplacer list`. They are stable per
# physical display, so they survive replugging and reboots.
#
# MAIN_DISPLAY_ID   the screen that stays yours when the monitor leaves -- the
#                   built-in one on a laptop. It leads the mirror set (see below).
# SHARED_DISPLAY_ID the monitor that is handed back and forth between machines.
MAIN_DISPLAY_ID=""
SHARED_DISPLAY_ID=""

# --- Extended mode ---------------------------------------------------------
# Your normal arrangement, restored when the monitor comes back to the Mac.
#
# This is the command `displayplacer list` prints at the very bottom, one array
# element per quoted argument. Settings... captures it for you: arrange your
# screens the way you like in System Settings, then click "Capture Current
# Arrangement".
EXTENDED_LAYOUT=(
  "id:<MAIN_DISPLAY_ID> res:1728x1117 hz:120 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0"
  "id:<SHARED_DISPLAY_ID> res:3360x1890 hz:60 color_depth:8 enabled:true scaling:on origin:(1728,0) degree:0"
)

# --- Mirrored mode ---------------------------------------------------------
# Applied when the monitor goes to another machine, so your windows have
# somewhere to land.
#
# MAIN_DISPLAY_ID is listed FIRST on purpose. displayplacer: "The first screenId
# in a mirroring set will be the 'Optimize for' screen... You can only choose
# resolutions for the 'Optimize for' screen." So the mode that gets set is your
# own screen's, and the monitor hardware-scales a copy nobody is looking at.
# Reverse the order and you inherit the monitor's resolution, which is the whole
# problem this project exists to avoid.
#
# Tried in order; the first one that applies cleanly wins.
MIRROR_CANDIDATES=(
  "id:<MAIN_DISPLAY_ID>+<SHARED_DISPLAY_ID> res:1728x1117 hz:120 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0"
  "id:<MAIN_DISPLAY_ID>+<SHARED_DISPLAY_ID> res:1728x1117 hz:60 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0"
)

# --- Monitor input switching (DDC/CI) --------------------------------------
# Which display m1ddc talks to. m1ddc accepts either the index from
# `m1ddc display list` or a persistent screen id -- prefer the id, because
# indices move when you plug or unplug a display and an id never does.
DDC_DISPLAY="<SHARED_DISPLAY_ID>"

# VCP 0x60 input codes for the two ends of the swap. Common values: 15 and 16 for
# DisplayPort 1 and 2, 17 and 18 for HDMI 1 and 2, 27 for USB-C -- but monitors
# disagree, so read yours rather than guessing. The Settings... window's "Use
# Monitor's Current Input" button reads the live value: switch the monitor with
# its own buttons, then click.
#
# THIS_MAC_INPUT  the port this Mac is plugged into
# OTHER_INPUT     where `screen-switch toggle` hands the monitor to
THIS_MAC_INPUT="${THIS_MAC_INPUT:-16}"
OTHER_INPUT="${OTHER_INPUT:-17}"

# --- Safety ----------------------------------------------------------------
# Input codes that must never be selected, whatever asks for them.
#
# Empty by default, because which codes are safe is a property of your monitor.
# Some panels drop the link to the Mac when a particular input is selected: the
# display vanishes from macOS *and* the DDC channel goes with it, so nothing on
# the Mac can undo it and you need the monitor's own buttons to get back. On a
# DELL U2718Q, input 15 does exactly that -- DisplayPort 1 and mDP evidently
# share a link. If you find such an input on yours, list it here.
BLOCKED_INPUTS=()

# Coming back to extended mode, also pull the monitor's input back over DDC.
# Whether that works is monitor-specific: some keep answering DDC while showing
# another machine, some do not. Set to 0 to always switch back by hand.
TRY_INPUT_SWITCH_BACK=1

# --- Menu bar app ----------------------------------------------------------
# Follow the monitor on its own: when the input changes, apply the matching mode.
FOLLOW_MONITOR=1

# Seconds between DDC polls.
POLL_INTERVAL=5
