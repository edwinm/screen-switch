# AGENTS.md

Orientation for a new session picking up this project. Read this before touching
anything — several of the facts below cost a broken display to learn, and one of
them will strand a user's Mac if you rediscover it the hard way.

`README.md` is the user-facing doc. This file is the working context.

## What this is

A Mac and some other machine share one external monitor. Switching the monitor to
the other machine leaves macOS believing the display is still attached, stranding
windows on a screen nobody can see. This project makes the Mac follow the
monitor: a menu bar app that watches which input the monitor is showing and
mirrors or un-mirrors accordingly.

It is Apple-Silicon-only, because `m1ddc` is.

**Nothing about one particular desk belongs in a committed file.** The project is
published for other people; screen ids, monitor models, input numbers and home
directories are all configuration, all detected, all written to
`~/.config/screen-switch/`. If you find yourself adding a UUID or a `/Users/...`
path to a tracked file, that is the bug.

## Layout

```
Screen Switch.app       the menu bar app; build puts the binary inside it
main.swift              entry point (top-level code needs this exact filename)
ScreenSwitch.swift      AppDelegate: status item, menu, edge-triggered watcher
Config.swift            Config/Device models, the bash-subset parser, generator
Displays.swift          Shell, ddcFailed, display detection, layout generation
SettingsWindow.swift    the Settings window
LoginItem.swift         SMAppService wrapper behind the "start at login" checkbox
screen-switch           shell tool doing the real display work; usable alone
lib.sh                  shared shell helpers
build                   swiftc + codesign
install-agent           the command line alternative to the checkbox
org.bitstorm.screen-switch.plist.template   rendered per machine by install-agent
org.bitstorm.screen-switch.login.plist      bundled agent; build copies it into the app
config.example.sh       annotated reference config
devices.example.conf    annotated reference machine list
```

Flow: **app → `screen-switch` → `displayplacer` / `m1ddc`.** The Swift app is UI
only; it shells out for every display change. Keep it that way — the shell tool
must stay independently usable, and duplicating the logic in Swift would give you
two sources of truth that drift.

Dependencies are `displayplacer` and `m1ddc`, both from homebrew-core. `m1ddc`
needs no tap despite what older docs say.

## Configuration

Resolution order in `screen-switch`: `$SCREEN_SWITCH_CONFIG` →
`${XDG_CONFIG_HOME:-~/.config}/screen-switch/config.sh` → `${DIR}/config.sh`
(gitignored, development only). No config at all is a clean error pointing at
Settings…, not a crash.

`config.sh` is bash the shell tool sources and Swift both parses and generates.
`BashConfig` in `Config.swift` handles exactly the subset the generator emits —
scalars, `${NAME:-default}`, and multi-line arrays. Two traps if you touch it:

- Array elements contain `origin:(0,0)`, so "find the closing paren" has to mean
  the first *unquoted* one.
- The generator rewrites the file whole. It reads the old key names
  (`EXTERNAL_ID`, `MAC_LAYOUT`, `FORBIDDEN_INPUTS`, …) so an old config migrates
  on first save, but it does not preserve user comments. That is documented in
  the file's own header; do not quietly change it to a patching writer without
  saying so.

Mode names are `extended` and `mirrored`. `mac` and `work` were the original
names and are still accepted as aliases in `normalize_mode()` and
`Mode(config:)`, because they may be sitting in someone's Shortcut.

## What detection can actually get you

This is why the Settings window can exist, and it is worth not re-deriving:

- `m1ddc display list` prints `[2] DELL U2718Q (3F85B0D8-…)` — the DDC index, the
  marketing name, and the **persistent screen id displayplacer uses**, on one
  line. The built-in prints `(null)` for its name.
- `m1ddc display <uuid>` works as well as `m1ddc display <index>`. Prefer the
  UUID: indices move when a display is plugged or unplugged. `DDC_DISPLAY` holds
  an id for exactly this reason.
- `displayplacer list` gives per display the persistent id, a `Type:` line, the
  current mode, and every available mode; its last line is a ready-made command
  describing the current arrangement, which is what **Capture Current
  Arrangement** stores.
- `CGDisplayCreateUUIDFromDisplayID` returns the same string displayplacer
  prints, so `NSScreen.localizedName` and `CGDisplayIsBuiltin` can be joined onto
  a parsed block. Note `NSScreen.screens` omits a mirrored monitor, so it is a
  name source only, never the enumeration.

A Retina panel offers 130-odd modes. `offeredModes` reduces that to one entry per
resolution at its best refresh rate, preferring scaled modes — a menu a person
can read. Do not put the raw list in a popup.

## Facts that cost something to learn

**Do not re-derive these.**

### Some inputs are destructive, and which ones is per-monitor

On a DELL U2718Q, selecting VCP input 15 makes the panel drop its link to the
Mac's mDP port entirely. The display vanishes from macOS *and* the DDC channel
goes with it, so nothing on the Mac can undo it — it takes a physical press of
the monitor's buttons. DP and mDP evidently share a link there. HDMI 1 does
**not** do this.

The old code hardcoded `FORBIDDEN_INPUTS=(15)`. That is wrong for a published
tool: 15 is a perfectly ordinary DisplayPort input on other panels. It is now
`BLOCKED_INPUTS`, empty by default and editable in Settings → Advanced.

What replaces the hardcoded guard is **not probing at all**: the Add Device sheet
reads the monitor's *current* input, so a user switches the monitor by hand and
the app learns the code. Never add a feature that sweeps input codes to see what
sticks. If you are testing DDC yourself, point `OTHER_INPUT` at the input the Mac
is already on.

### DDC lies in two ways

- **A successful `set input` does not mean the input changed.** Input 18 on the
  Dell returns exit 0 and quietly stays where it was. Always verify by reading
  back.
- **Reads taken right after a set return transients.** Selecting 18 briefly
  reported `32` before settling. Poll, do not read once.

`set_input()` in `screen-switch` handles both. Do not "simplify" it back to a
single read.

### m1ddc's failure string contains neither "error" nor "unable"

It is `Could not find a suitable external display.` A guard matching only
`error`/`unable` treats a dead DDC link as a good read — that is exactly how an
early probe marched past a failure and into input 15. `ddc_failed()` in `lib.sh`
matches `could not` and `not find` too; `ddcFailed()` in `Displays.swift` mirrors
it. Keep them in sync.

### Mirroring: the first screen id wins

displayplacer's own docs: *"The first screenId in a mirroring set will be the
'Optimize for' screen… You can only choose resolutions for the 'Optimize for'
screen."*

So `id:<main>+<shared>` puts the Mac's own screen first, its resolution is the
one that gets set, and the monitor hardware-scales a copy nobody is looking at.
**This is the entire trick** that removes the manual resolution fix from the
original workflow. `LayoutBuilder.mirrorCandidates` enforces the order so a user
cannot get it wrong; reversing it reintroduces the bug.

### There is no VCP for signal presence

MCCS has no code for "is there a signal on input X". You can read which input is
*selected*, never which are live. Measured: with the other machine powered and
outputting, every DDC value read back byte-identical to baseline and macOS saw
nothing.

Consequence: the monitor cannot tell you the other machine booted. Do not promise
that feature.

### Auto Select is loss-triggered only

It scans for a new input when the current one *dies*, and never steals from a
live signal. A Mac that is always awake never loses its input, so an arriving
machine never wins. Departure automates; arrival needs a gesture. That asymmetry
is deliberate and documented — do not "fix" it.

### Status items cannot cross the notch

On a notched MacBook Pro, the only usable menu bar space is the strip to the
*right* of the notch; the wide gap to its left is unavailable. When that strip is
full macOS silently drops new items — the item still reports `isVisible == true`
with a valid button, nothing is drawn, and nothing logs an error. If the icon is
missing, the fix is freeing a slot, not debugging the app. This cost a long
diagnostic detour.

### KeepAlive semantics are load-bearing

`KeepAlive = {SuccessfulExit: false}` means: restart on a *signal* or crash, stay
dead on a clean `exit(0)`. That is what makes the menu's **Quit** work.

Therefore `launchctl kill SIGTERM` does **not** stop the app — launchd restarts
it within seconds. `install-agent stop` uses `bootout` instead. Do not change
`KeepAlive` to `true` without realising it breaks Quit.

### Absolute paths, but not baked ones

launchd and Shortcuts run with a minimal `PATH` and will not find Homebrew
binaries, so the config stores absolute tool paths. That is not licence to
hardcode: `Tools.find()` probes `/opt/homebrew/bin`, `/usr/local/bin` and `which`
for a custom Homebrew prefix, and the launchd plist is a template that
`install-agent` renders with the real app path and `$HOME`. `Paths.scriptDir`
finds the shell tool via `$SCREEN_SWITCH_DIR`, then the bundle's parent directory
(true when the .app sits in its checkout), then `Resources/`.

## Design invariant: edge-triggered, never level-triggered

The app acts only when the monitor's input actually *changes*, plus one extra
edge: DDC returning after being unreachable (the monitor may have dropped the
Mac's display while away, leaving macOS on one screen needing its layout back).

Steady state is deliberately ignored. If you mirror by hand while the monitor
stays on the Mac, there is no edge, so your choice stands. A level-triggered
version would silently undo manual changes seconds later, every time. This was
tested explicitly. Do not regress it.

Readings are debounced over 2 consecutive identical values, because of the
transient described above.

## The Settings window

Programmatic AppKit, no xib, four panes behind a preference-style `NSToolbar`.
The HIG constraints that shaped it, so they do not get undone:

- **Changes apply immediately.** macOS settings do not have Save/Cancel; every
  control commits to disk and calls `app.reloadConfig()`. Text fields commit on
  end-editing after validation.
- "Settings…", not "Preferences…" (renamed in macOS 13; `⌘,` is reserved for it).
- Style mask is `[.titled, .closable]` — a settings window is sized by its
  content and is not a document.
- Panes are `NSGridView`s with system fonts and colours only, so Dark Mode and
  Increase Contrast need no code. There are no hardcoded colours anywhere; keep
  it that way.
- Sheets, not app-modal dialogs. `NSAlert` only for the destructive case
  (removing a machine) and for real failures, always with verb buttons.
- Ellipsis means more UI follows: `Settings…`, `Choose…` have one;
  `Refresh`, `Capture Current Arrangement`, `Open Log` do not.
- The status item image must stay `isTemplate = true` or it disappears in one
  appearance.
- A momentary `NSSegmentedControl` reports `selectedSegment == -1` outside a real
  click; `addOrRemoveDevice` treats that as "nothing asked for" rather than
  letting it fall through to Remove.

First run seeds what it can from detection (main display, shared monitor, mirror
candidates) and opens the window by itself, so the user is never looking at an
empty form. It only fills *empty* fields — a half-finished config stays as it is.

Capturing the arrangement while the screens are mirrored would store the mirror
set as the layout to return to. There is a warning sheet for that; keep it.

## Working safely

**The dangerous operation is putting the Mac into extended mode while the monitor
is showing the other machine.** The Mac's desktop then lives on a screen the user
cannot see — the exact problem this project exists to solve. Check
`m1ddc display <id> get input` before any layout change during testing.

- Test DDC paths with `OTHER_INPUT=<the Mac's own input> ./screen-switch mirrored`
  — exercises the real code path while pointing at the input the Mac is already
  on, so nothing can be stranded.
- Capture the restore command from `displayplacer list` *before* experimenting;
  it is printed at the bottom of the output.
- Never send an input code you have not read off the monitor.
- After any display test, restore with `./screen-switch extended` and verify with
  `system_profiler SPDisplaysDataType | grep -E "UI Looks|Main Display"`.
- Screenshots of the menu bar can mislead. Ask the user what they see.
- The Settings window can be driven headlessly for verification: build the
  sources with a scratch `main.swift`, drive toolbar items via their own
  `target`/`action`, and photograph a single window with
  `screencapture -l <windowNumber>`. Point `XDG_CONFIG_HOME` at a scratch
  directory to exercise the first-run path without touching a real config.

## The app icon is full bleed, and the name in Login Items is not ours

Two findings from making the Login Items row look right, both measured:

- **macOS pads an icon that does not fill its canvas.** The icon used to be the
  glyph on a dark rounded tile, and that tile is what reads as black padding in
  a Login Items row. Removing it does *not* give a bare glyph: the system
  composites anything with transparent margins onto a light rounded tile of its
  own, so black padding becomes grey padding. An icon that fills its canvas is
  masked to the system shape instead, which is the only way to have none. So
  `drawAppIcon` fills the square and lets the mask round it, and the screen's
  white bezel — which would fall outside that mask — is gone. The diagonal is
  what carries over from the menu bar glyph.
- **LaunchServices caches the icon against the bundle's date.** A re-rendered
  `AppIcon.icns` keeps coming back as the previous one, `lsregister -f` or not,
  until the bundle's own timestamp moves. `build` therefore touches the bundle
  before registering it. BTM caches separately again, so a changed icon only
  reaches an existing login item when the item is re-registered — untick and
  re-tick the checkbox.

The row says **Screen Switch.app**, not *Screen Switch*, and nothing in the app
can change that. It is the Finder preference "Show all filename extensions":
with it on, `URLResourceValues.localizedName` appends `.app` to every
application on the machine, and BTM shows that string — every other app row in
that list is the same (`1Password.app`, `Docker.app`, `Spotify.app`).
`LSHasLocalizedDisplayName` with a localized `CFBundleDisplayName` does *not*
override it; that was tried with a deliberately different name on a scratch copy
of the bundle and LaunchServices still returned the file name. Do not add that
key back. The only control is the user's own Finder setting.

## Starting at login

Settings → General → **Start Screen Switch at login** registers the LaunchAgent
bundled at `Contents/Library/LaunchAgents/`, via
`SMAppService.agent(plistName:)`. `install-agent` does the same job from
outside, and the two are alternatives; installing both is harmless but shows two
rows in Login Items, which the pane points out when it finds the other plist.

### Why the bundled agent, and not the other two options

All three were tried on a real machine. The Login Items row is the difference:

- **`SMAppService.agent`** — the item belongs to the app that registered it, so
  System Settings lists it under **Allow in the Background** as "Screen
  Switch.app" with the real icon. `KeepAlive` survives, because it is still a
  launchd job. This is what ships.
- **`SMAppService.mainApp`** — lands under **Open at Login** instead, and
  loginwindow launches the app directly, so there is no `KeepAlive` and no crash
  recovery. Rejected: the row is in the wrong list and it loses a property.
- **`install-agent`'s plist** — lives outside any bundle, so BTM describes the
  program launchd runs: a bare executable named **ScreenSwitch** with the
  generic `exec` icon and "part of an unknown developer". `AssociatedBundleIdentifiers`
  is in that plist and does *not* fix it — the association wants the job's
  program and the bundle to share a Team ID, and an ad-hoc signature has no
  team. `lsregister -f` and a full bootout/bootstrap change nothing; both were
  measured. Do not spend another afternoon on that icon.

### Constraints the bundled plist is under

It is inside the signed bundle, so nothing can be rendered per machine:

- `BundleProgram` holds a path *relative to the app bundle*, which is exactly
  why the key exists. `Program`/`ProgramArguments` would need an absolute path.
- No `StandardOutPath`/`StandardErrorPath`: they would have to name the user's
  home. launchd's stdout/stderr go to the unified log, and
  `~/Library/Logs/screen-switch.agent.log` therefore only exists on the
  `install-agent` route. The app's own log is unaffected.
- `build` copies the plist in **before** `codesign`. SMAppService refuses a
  plist the signature does not cover, the same way the icons have to be in
  `Resources/` first.

### One instance, whoever started it

`main.swift` exits immediately if another instance of the same bundle id is
already running. This is load-bearing, not tidiness: `RunAtLoad` means
*registering* the agent bootstraps it at once, so ticking the checkbox in a
running app would put a second icon in the menu bar. It also makes having both
mechanisms installed harmless. `exit(0)`, not a signal, so `KeepAlive` leaves
the loser dead.

### Other things about the checkbox

- `register()` returns success even when the user has the item switched *off* in
  System Settings; only `status` afterwards reports `.requiresApproval`. Check
  the status, do not trust the call.
- The checkbox is never remembered in config — it is read from the service's
  `status` every `refreshControls()`, which `windowDidBecomeKey` already calls,
  so toggling it in System Settings does not leave a lying checkbox.
- Registration is by bundle path. Moving the checkout leaves a dead Login Items
  entry; re-toggle after a move.
- `LoginItem.isAvailable` is false when not running from a `.app` — the headless
  Settings harness below — and the checkbox is disabled rather than failing.
- **No shell commands in the UI.** When the pane has to mention the other login
  item it says to switch it off in System Settings, where the user already is.
  `install-agent` is documented in the README, not in the app.

Bumping the deployment target below macOS 13 would remove SMAppService.
`Info.plist` says `LSMinimumSystemVersion 13.0`.

## Build and install

```bash
./build          # swiftc -O -swift-version 5 over all the .swift files, then codesign
./install-agent  # renders the plist for this machine, loads it, starts the app
```

**Re-sign after every rebuild** — `build` does it. Login Items keys off the
signature; skipping it reverts the entry to "Unknown Developer".

The bundle exists so System Settings shows a real name. macOS reads it from
`Info.plist`; a LaunchAgent running a bare script through `/bin/bash` is listed
as **bash** under **Unknown Developer**. `LSUIElement` (not `LSBackgroundOnly`)
is required — the latter forbids any UI, including a menu bar item.

Verify the Login Items entry with:

```bash
sfltool dumpbtm | grep -B8 org.bitstorm.screen-switch
```

`Developer Name: (null)` is expected — the bundle is ad-hoc signed. The app is
also deliberately unsandboxed; it runs Homebrew binaries and drives DDC.

## Adding features

- **A new machine on the monitor**: Settings → Devices → +, or one line in
  `devices.conf`. No recompile either way.
- **A different monitor or desk**: Settings → Displays; `./screen-switch discover`
  still prints the raw values if you want to see them.
- **Anything touching DDC**: mirror the guard logic already in `lib.sh`.

## Out of scope, with reasons

- **Restoring window positions across a mirror round-trip.** macOS squeezes
  windows onto the smaller desktop and does not put them back. Genuinely large to
  solve; accepted as a limitation.
- **Detecting the other machine over the network to auto-switch on arrival.**
  Possible (ARP presence), deliberately rejected: a laptop keeps its NIC alive in
  modern standby, so "asleep in a bag" and "sitting down to work" look identical,
  and the failure mode is the monitor yanking itself away mid-task. Arrival is a
  decision, not an event.
- **A helper on the other machine.** Cannot be assumed — the original case was a
  corporate laptop without admin rights. Raise it, do not assume it.
- **Probing input codes to discover them.** See above. Read the current input
  instead.

## Conventions

- **Do not commit or push.** The user handles that. Stage changes and stop.
- Comments explain *why*, especially where a guard encodes something painful that
  was learned. Do not strip them as noise.
- Shell is bash with `set -uo pipefail`; keep verbs and output terse.
- Swift is compiled with `-swift-version 5`; there is no Xcode project and no
  package manifest, just `build`.

## State on disk

```
~/.config/screen-switch/config.sh         settings (Settings… writes this)
~/.config/screen-switch/devices.conf      the machine list
~/Library/Logs/screen-switch.log          app activity (the Open Log menu item)
~/Library/Logs/screen-switch.agent.log    launchd stdout/stderr (install-agent only)
~/Library/LaunchAgents/org.bitstorm.screen-switch.plist   rendered at install
```

The rendered plist has an absolute path to the app, so moving the checkout breaks
it — rerun `./install-agent` after any move. The app itself finds its shell tool
relative to the bundle, so that half needs nothing.
