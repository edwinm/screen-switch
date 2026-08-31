<p align="center">
  <img src="icons/AppIcon-1024.png" alt="Screen Switch" width="160">
</p>

<h1 align="center">Screen Switch</h1>

<p align="center">
  Two machines, one monitor. Hand the monitor over to the other machine and get
  your Mac's windows back onto its own screen — from the menu bar, a hotkey, or
  automatically when the monitor's input changes.
</p>

---

## The problem

You have a Mac and one other machine — a work laptop, a desktop, a console — and
they share a single external monitor. You switch the monitor over to the other
machine with its buttons, and now half your Mac is invisible: macOS still thinks
the big display is there, so windows sit on a screen nobody can look at. You drag
them back one by one, or you turn on mirroring — which makes your laptop screen
adopt the monitor's resolution and turns everything tiny, so you head into System
Settings to fix *that*. Then you do the whole dance again in reverse when you
switch back.

Screen Switch makes it one click. Pick a machine from the menu bar and the
monitor switches to it while your Mac rearranges itself to match — mirrored onto
your own screen at your own resolution when the monitor is away, back to your
normal arrangement when it returns. Switch inputs at the monitor itself and the
Mac notices and catches up on its own.

**Apple Silicon Macs only.** Screen Switch talks to the monitor over DDC/CI using
`m1ddc`, which does not support Intel Macs.

## Install

### Prerequisites

- An Apple Silicon Mac
- An external monitor that supports DDC/CI input switching (most do)
- [Homebrew](https://brew.sh)
- Xcode command line tools, for the Swift compiler:

  ```bash
  xcode-select --install
  ```

- Two command line tools, both in homebrew-core — no tap needed:

  ```bash
  brew install displayplacer m1ddc
  ```

### Build and install

```bash
git clone https://github.com/edwinm/screen-switch.git
cd screen-switch
./build
open "Screen Switch.app"
```

`build` compiles the menu bar app into `Screen Switch.app` and ad-hoc signs it.
Opening it puts the icon in your menu bar; tick **Settings… → General → Start
Screen Switch at login** to have it come back at every login. If you are changing
anything, `./test` runs the test suite; it needs no monitor.

`./install-agent` is the other way to do that, from the command line, and is
described in [Command line](COMMAND-LINE.md). Use one or the other.

There is no download to grab: the app runs Homebrew binaries and drives DDC,
which the App Sandbox forbids, so it is distributed as source you compile
yourself. See
[It is not sandboxed, and not notarised](TECHNICAL.md#it-is-not-sandboxed-and-not-notarised)
for what that means in practice.

### First-time setup

Open **Settings…** from the menu bar icon. It detects your displays by name and
fills in almost everything. Two things are left for you:

1. **Displays → Capture Current Arrangement.** Arrange your screens in System
   Settings the way you normally want them, with mirroring *off*, then capture.
   That is the layout Screen Switch returns to.
2. **Devices → +.** This Mac is already in the list — the app reads the input the
   monitor is on when it first runs, so if that row is missing or wrong, **Add
   This Mac** re-reads it. Add each *other* machine that shares the monitor:
   switch the monitor to that machine with its own buttons, click **Use
   Monitor's Current Input**, and the input code is read straight off the
   monitor — no probing, no guessing which number your panel uses for which
   port. Name it, choose whether that machine means *Extended* (your
   arrangement — this Mac) or *Mirrored* (everything on your own screen), and
   you are done.

Settings apply as you make them; there is no Save button and nothing needs a
restart. Your configuration lives in `~/.config/screen-switch/`, outside the
checkout, so pulling a new version never touches it.

## Use

### From the menu bar

<p align="center">
  <img src="pics/menu.png" alt="The Screen Switch menu, listing MacBook Pro and Work laptop" width="360">
</p>

Click the icon and you get a menu of your machines, with a checkmark on whichever
one the monitor is currently showing, plus the current display mode. Pick a
machine and the monitor switches to it and the Mac applies the matching layout.
Below that: **About Screen Switch**, **Settings…**, **Open Log**, and **Quit**.

The icon itself shows the state at a glance: extended, mirrored, or monitor
unreachable.

You do not have to use the menu. Switch inputs with the monitor's own buttons and
the app notices within a few seconds and adjusts the Mac to match.

### From the command line

Everything above is also a shell tool you can run directly — `screen-switch
toggle`, a hotkey through Shortcuts, and `install-agent` for the login item
without the app. That is its own page: **[Command line](COMMAND-LINE.md)**.

### Starting, stopping, and removing the app

**Settings… → General → Start Screen Switch at login** is the simple route. It
appears in System Settings → General → Login Items under **Allow in the
Background**, as *Screen Switch.app* with its own icon, where you can also
switch it off. **Quit** in the menu quits it; open the app again to bring it
back.

The registration remembers where the app is, so if you move the checkout, turn
the setting off and on again.

Activity goes to `~/Library/Logs/screen-switch.log`, which is what **Open Log**
in the menu shows.

There is a second route that does the same job from a terminal, `install-agent`,
described in [Command line](COMMAND-LINE.md#install-agent). Use one or the other.

### Why the entry says "Screen Switch.app"

Because Finder is set to show every filename extension — with that on, macOS
appends `.app` to every application's name, and Login Items shows the same
string for all of them. Turning off **Finder → Settings → Advanced → Show all
filename extensions** drops the suffix everywhere, including here. Nothing in
the app can override it.

### If the menu bar icon does not appear

The menu bar has less room than it looks. On a notched MacBook Pro, status items
cannot flow past the notch, so the only usable space is the strip to its *right* —
the wide gap to the left of the notch is not available. When that strip is full,
macOS silently drops new items: the item still reports `isVisible = true` with a
valid button, it simply is not drawn, and there is no error anywhere.

If the icon is missing, remove another menu bar icon to free a slot. That is the
whole fix.

## Known limitation

Window positions are not preserved across a mirror round-trip. macOS squeezes
windows onto the smaller logical desktop and does not put them back afterwards.
Restoring window geometry is a much bigger job and is deliberately not attempted
here.

---

## More

- **[Command line](COMMAND-LINE.md)** — `screen-switch`, a keyboard shortcut
  through Shortcuts, and `install-agent`.
- **[Technical details](TECHNICAL.md)** — how the mirroring trick works, what
  DDC can and cannot tell you, why the watcher is edge-triggered, and the files
  this repository is made of.

## License

MIT — see [LICENSE](LICENSE).
