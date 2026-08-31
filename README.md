# mac-screen-switch

Two machines, one monitor. Hand the monitor over to the other machine and get
your Mac's windows back onto its own screen — from the menu bar, a hotkey, or
automatically when the monitor's input changes.

Apple Silicon only: `m1ddc` talks to the monitor over DDC/CI and does not support
Intel Macs.

## The problem

A Mac and some other machine — a work laptop, a desktop, a console — share one
external monitor. Switching the monitor's input does not tell macOS anything: the
Mac still believes the display is attached, so windows sit on a screen nobody can
see. The usual fix is to turn on mirroring, but mirroring inherits the monitor's
resolution, which is unusable on a laptop screen — so it also means a trip to
System Settings to fix that. Then all of it again in reverse.

## How it works

`displayplacer` sets the mirroring *and* the resolution in one atomic call, so
the wrong resolution never gets a chance to appear.

The trick is which screen leads the mirror set. displayplacer's own note:

> The first screenId in a mirroring set will be the 'Optimize for' screen in the
> system prefs. You can only choose resolutions for the 'Optimize for' screen.

So your own screen is listed first (`id:<yours>+<monitor>`). Its resolution
becomes the mode that gets set, and the monitor hardware-scales a copy that
nobody is looking at. The monitor's own modes never enter into it. Screen Switch
always generates the mirror set in that order, so this is not something you can
get wrong by hand.

`m1ddc` then sends the DDC/CI input-select command (VCP `0x60`) to move the
monitor over to the other machine.

## Setup

```bash
brew install displayplacer m1ddc
./build
./install-agent
```

Both tools are in homebrew-core — no tap needed. `build` compiles the menu bar
app and ad-hoc signs it; `install-agent` installs it as a login item and starts
it.

Then open **Settings…** from the menu bar icon. It detects your displays by name
and fills in almost everything; two things are left for you:

1. **Displays → Capture Current Arrangement.** Arrange your screens in System
   Settings the way you normally want them, with mirroring *off*, then capture.
   That is the layout Screen Switch returns to.
2. **Devices → +.** Add each machine that shares the monitor. Switch the monitor
   to that machine with its own buttons, click **Use Monitor's Current Input**,
   and the input code is read straight off the monitor — no probing, no guessing
   which number your panel uses for which port. Name it, choose whether that
   machine means *Extended* (your arrangement — this Mac) or *Mirrored*
   (everything on your own screen), and you are done.

Settings apply as you make them; there is no Save button and nothing needs a
restart. Your configuration lives in `~/.config/screen-switch/`, outside the
checkout, so pulling a new version never touches it.

## Use

```bash
./screen-switch toggle     # flip whichever way you are not
```

| verb | does |
| --- | --- |
| `toggle` | extended → mirrored, or back. This is what a hotkey would run. |
| `mirrored` | mirror onto your own screen, then hand the monitor over |
| `extended` | restore your captured arrangement |
| `status` | prints `extended` or `mirrored` |
| `input` | prints the monitor's current input code; `input <code>` sets it |
| `discover` | dumps the raw values Settings… reads |

`mac` and `work` still work as aliases for `extended` and `mirrored`.

Going back to extended, the script tries to pull the monitor's input back over
DDC. Whether that works is a property of your monitor: some keep answering DDC
while showing another machine, some drop the channel with the picture. If yours
does not cooperate, press its input button and then run the command — or turn the
attempt off in Settings → General.

If the shared monitor is not connected at all, every verb is a clean no-op.

## Input codes are per-monitor

The DDC spec assigns VCP `0x60` values to input sources — commonly 15 and 16 for
DisplayPort 1 and 2, 17 and 18 for HDMI 1 and 2, 27 for USB-C — but monitors
disagree, and some accept a value and then quietly ignore it. Nothing here
assumes a numbering: **Use Monitor's Current Input** reads the live value from
your panel, which is right by construction.

Two behaviours worth knowing if you do go probing:

- **A successful `set` does not mean the input changed.** Some monitors return
  success and stay where they were. `set_input` verifies by reading the input
  back rather than trusting the exit code.
- **Reads taken right after a set can be transient.** A value read mid-switch may
  be neither the old nor the new one. `set_input` polls for up to six seconds
  rather than reading once.

### Some inputs can strand you

On certain panels, selecting a particular input drops the link to the Mac
entirely: the display vanishes from macOS *and* the DDC channel goes with it, so
nothing running on the Mac can undo it and only the monitor's own buttons bring
it back.

Measured example: on a **DELL U2718Q**, input 15 (DisplayPort 1) does exactly
this — DisplayPort and mDP evidently share a link on that panel. HDMI 1 does not;
the mDP link stays up and DDC keeps answering.

If you find such an input on your monitor, put it in **Settings → Advanced →
Never select inputs**. The list is empty by default, because which codes are safe
is a property of your hardware and blocking a number that is a perfectly good
DisplayPort input elsewhere would be worse than useless.

## What DDC cannot tell you

There is no MCCS code for "is there a signal on input X" — you can read which
input is *selected*, never which ones are live. With another machine powered and
outputting on a different input, every DDC value reads back byte-identical to
baseline and macOS sees nothing at all.

So the monitor cannot tell you the other machine booted. It can only tell you
which machine currently owns the monitor. That is still the best available signal
for automation, and it needs no software on the other machine — but it follows
the *monitor's* input selection, not any machine's power state.

## The menu bar app

`Screen Switch.app` is a native AppKit menu bar app: an icon with a menu of your
machines, a checkmark on whichever one the monitor is currently showing, and the
current display mode. Picking a machine switches the monitor's input and applies
the matching layout.

```bash
./install-agent            # install as a login item, and start it
./install-agent start      # start it again after using Quit in the menu
./install-agent stop       # stop it until next login
./install-agent status     # running? installed?
./install-agent uninstall  # stop it and remove it from login items
```

**Quit** in the menu stops it until your next login. To bring it back without
logging out, use `install-agent start` (or just open `Screen Switch.app`).

Note that `launchctl kill SIGTERM` does *not* stop it: `KeepAlive` is set to
`SuccessfulExit: false`, so a signal counts as an unsuccessful exit and launchd
restarts it within seconds. That setting is what makes the menu's **Quit** work —
a clean exit stays quit — so `stop` unloads the job with `bootout` instead. The
plist stays in place, so it returns at the next login either way.

It shells out to `screen-switch` for the actual display work, so the shell script
stays the single source of truth and the app is only the UI in front of it. It
also follows the monitor on its own: switch inputs at the monitor itself and the
Mac catches up within a few seconds.

Activity goes to `~/Library/Logs/screen-switch.log` (the **Open Log** menu item);
launchd's own stdout/stderr to `~/Library/Logs/screen-switch.agent.log`.

### It is not sandboxed, and not notarised

The app runs Homebrew binaries and drives DDC, which the App Sandbox forbids, so
it is distributed as source you compile yourself and `build` signs it ad-hoc.
That is also why there is no download: an ad-hoc signed binary from a stranger is
not something you should run, and a notarised one would need a paid Developer ID
for a utility this small. `Developer Name: (null)` in Login Items is expected.

### If the icon does not appear

The menu bar has less room than it looks. On a notched MacBook Pro, status items
cannot flow past the notch, so the only usable space is the strip to its *right* —
the wide gap to the left of the notch is not available. When that strip is full,
macOS silently drops new items: the item still reports `isVisible = true` with a
valid button, it simply is not drawn, and there is no error anywhere.

If the icon is missing, remove another menu bar icon to free a slot. That is the
whole fix.

## Why it is edge-triggered

The app acts only when the input actually *changes* — never on steady state. That
is what stops it fighting you: mirror by hand while the monitor stays on the Mac
and there is no edge, so your choice stands. A level-triggered version would
quietly undo it a few seconds later, every time.

Two things count as edges: the input value changed, or DDC came back after being
unreachable (the monitor may have dropped the Mac's display while it was away,
leaving macOS on one screen with the layout still to restore). Values are
debounced over two consecutive identical reads, because reads taken mid-switch
return transients.

## Auto Select only helps in one direction

With the monitor's **Auto Select** on, disconnecting the other machine makes the
monitor fall back to the Mac, and the watcher restores your arrangement — fully
automatic. Connecting it does *not* switch the monitor: Auto Select scans for a
new input only when the current one dies, and a Mac that is always awake never
loses its input, so the arriving machine never wins.

So starting work needs one gesture — the menu, or the monitor's own buttons — and
ending it needs none. That asymmetry is worth knowing about: arrival is a
decision, departure is an event.

## Optional: a keyboard shortcut

The menu bar app covers the clicking. If you also want a key combo, wrap the
script in a Shortcut:

1. Shortcuts → Settings → Advanced → enable **Allow Running Scripts**. Nothing
   runs until this is on.
2. New shortcut named e.g. **Toggle Monitor**, containing a single **Run Shell
   Script** action with the full path to `screen-switch` in this checkout, plus
   `toggle`. Leave the shell as `/bin/bash` and "Pass Input" as *to stdin*.
3. In the shortcut's details pane, set a **keyboard shortcut**.
4. Run it once and approve the permission prompt.

Shortcuts runs scripts with a minimal `PATH`, which is why the config stores
absolute paths to `displayplacer` and `m1ddc` rather than relying on the shell to
find them.

## Files

```
Screen Switch.app       the menu bar app (build creates the binary inside it)
main.swift              entry point
ScreenSwitch.swift      status item, menu, and the edge-triggered watcher
Config.swift            reading and writing the config
Displays.swift          display detection: displayplacer + m1ddc + CoreGraphics
SettingsWindow.swift    the Settings window
screen-switch           the shell tool that does the display work; usable alone
lib.sh                  shared shell helpers
build                   swiftc + codesign
install-agent           login-item wiring
config.example.sh       an annotated config, if you would rather write one
devices.example.conf    likewise for the machine list
```

Your own settings, written by Settings… and read by the shell tool:

```
~/.config/screen-switch/config.sh
~/.config/screen-switch/devices.conf
```

`screen-switch` also accepts `$SCREEN_SWITCH_CONFIG`, and falls back to a
`config.sh` next to itself, which is handy for testing.

## Known limitation

Window positions are not preserved across a mirror round-trip. macOS squeezes
windows onto the smaller logical desktop and does not put them back afterwards.
Restoring window geometry is a much bigger job and is deliberately not attempted
here.

## License

MIT — see [LICENSE](LICENSE).
