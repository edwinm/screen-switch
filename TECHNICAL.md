# Technical details

How Screen Switch works, and the things about DDC and displayplacer that shaped
it. None of this is needed to use the app; that is the
[README](README.md), and the shell tools have their own page,
[Command line](COMMAND-LINE.md).

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

Going back to extended, the script tries to pull the monitor's input back over
DDC. Whether that works is a property of your monitor: some keep answering DDC
while showing another machine, some drop the channel with the picture. If yours
does not cooperate, press its input button and then run the command, or turn the
attempt off in Settings → General.

## Input codes are per-monitor

The DDC spec assigns VCP `0x60` values to input sources: commonly 15 and 16 for
DisplayPort 1 and 2, 17 and 18 for HDMI 1 and 2, 27 for USB-C. But monitors
disagree, and some accept a value and then quietly ignore it. Nothing here
assumes a numbering: **Use Monitor's Current Input** reads the live value from
your panel, which is right by construction.

The one place a numbering is guessed is *naming*: the input field is a combo box
listing the connectors in use today, each shown with the code it usually carries,
and picking one fills in the Name field's hint. Both are guesses and neither is
binding. The field stays typeable, because the list cannot know your panel;
picking 17 and typing 17 leave the same thing in `devices.conf`, which is the
number.

LG is the one brand worth a table of its own. It ships a second numbering
entirely (208 DisplayPort 1, 144 HDMI 1, and so on: the values behind `m1ddc set
input-alt`), so the app reads the brand off the display's own name and offers
those first, with the standard codes after them for the LGs that answer those
instead. An unrecognised code is left unnamed rather than guessed at.

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
this. DisplayPort and mDP evidently share a link on that panel. HDMI 1 does not;
the mDP link stays up and DDC keeps answering.

If you find such an input on your monitor, put it in **Settings → Advanced →
Never select inputs**. The list is empty by default, because which codes are safe
is a property of your hardware and blocking a number that is a perfectly good
DisplayPort input elsewhere would be worse than useless.

## What DDC cannot tell you

There is no MCCS code for "is there a signal on input X". You can read which
input is *selected*, never which ones are live. With another machine powered and
outputting on a different input, every DDC value reads back byte-identical to
baseline and macOS sees nothing at all.

So the monitor cannot tell you the other machine booted. It can only tell you
which machine currently owns the monitor. That is still the best available signal
for automation, and it needs no software on the other machine, but it follows
the *monitor's* input selection, not any machine's power state.

## Why it is edge-triggered

The app acts only when the input actually *changes*, never on steady state. That
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
monitor fall back to the Mac, and the watcher restores your arrangement, fully
automatic. Connecting it does *not* switch the monitor: Auto Select scans for a
new input only when the current one dies, and a Mac that is always awake never
loses its input, so the arriving machine never wins.

So starting work needs one gesture (the menu, or the monitor's own buttons) and
ending it needs none. That asymmetry is worth knowing about: arrival is a
decision, departure is an event.

## The app and the shell tool

`Screen Switch.app` is a native AppKit menu bar app. It shells out to
`screen-switch` for the actual display work, including every input change, so
the guard against inputs that strand you is in one place. That leaves the shell
script as the single source of truth and the app as the UI in front of it.

Either way of starting it at login ends up as a launchd job, which has one
consequence worth knowing:
[`launchctl kill` does not stop it](COMMAND-LINE.md#launchctl-kill-does-not-stop-it).

## It is not sandboxed, and not notarised

The app runs Homebrew binaries and drives DDC, which the App Sandbox forbids, so
it is distributed as source you compile yourself and `build` signs it ad-hoc.
That is also why there is no download: an ad-hoc signed binary from a stranger is
not something you should run, and a notarised one would need a paid Developer ID
for a utility this small. `Developer Name: (null)` in Login Items is expected.

## Files

```
Screen Switch.app       the menu bar app (build creates the binary inside it)
main.swift              entry point
ScreenSwitch.swift      status item, menu, and the edge-triggered watcher
Config.swift            reading and writing the config
Displays.swift          display detection: displayplacer + m1ddc + CoreGraphics
SettingsWindow.swift    the Settings window
LoginItem.swift         the start-at-login setting (SMAppService)
screen-switch           the shell tool that does the display work; usable alone
lib.sh                  shared shell helpers
build                   swiftc + codesign
test                    ./test -- the test suite, needs no monitor
install-agent           the command line alternative to the checkbox
COMMAND-LINE.md         the shell tools: screen-switch, install-agent
TECHNICAL.md            this page
config.example.sh       an annotated config, if you would rather write one
devices.example.conf    likewise for the machine list
icons/                  app and menu bar icons, plus the script that renders them
```

Your own settings, written by Settings… and read by the shell tool:

```
~/.config/screen-switch/config.sh
~/.config/screen-switch/devices.conf
```

`screen-switch` reads the same two files, and can be pointed elsewhere: see
[Where it reads its configuration](COMMAND-LINE.md#where-it-reads-its-configuration).
