# Screen Switch from the command line

The menu bar app is the UI in front of a shell tool, not a reimplementation of
it: every display change the app makes is `screen-switch` doing the work. So the
tool is usable on its own, and this is what it does.

Installing — Homebrew dependencies, `./build` — is in the
[README](README.md#install), and the reasoning behind all of this is in
[Technical details](TECHNICAL.md). The app's own settings live in
**Settings…**; `screen-switch` reads the same configuration file.

## screen-switch

```bash
./screen-switch toggle
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

If the shared monitor is not connected at all, every verb is a clean no-op.

`input <code>` is the only supported way to change the monitor's input, and it
is what the app's menu runs too: it refuses anything in **Settings → Advanced →
Never select inputs**, and it verifies the switch by reading the input back
rather than trusting the exit code. See
[Some inputs can strand you](TECHNICAL.md#some-inputs-can-strand-you) for why that
matters.

### Where it reads its configuration

In order: `$SCREEN_SWITCH_CONFIG`, then
`${XDG_CONFIG_HOME:-~/.config}/screen-switch/config.sh`, then a `config.sh` next
to the script itself — the last one is gitignored and handy for testing.

The input codes are written as `${NAME:-value}`, so one run can be pointed at a
different machine without touching the file:

```bash
OTHER_INPUT=17 ./screen-switch mirrored
```

## A keyboard shortcut

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

## install-agent

**Settings… → General → Start Screen Switch at login** is the ordinary way to
have the app come back at login, and it needs no terminal. `install-agent` does
the same job from outside the app, as a launchd job of its own:

```bash
./install-agent            # install as a login item, and start it
./install-agent start      # start it again after using Quit in the menu
./install-agent stop       # stop it until next login
./install-agent status     # running? installed?
./install-agent uninstall  # stop it and remove it from login items
```

Use one or the other. Installing both is harmless — the second copy to start
notices the first and exits — but Login Items then lists two entries.

With the agent installed, **Quit** in the menu stops it until your next login. To
bring it back without logging out, use `install-agent start` (or just open
`Screen Switch.app`).

Activity goes to `~/Library/Logs/screen-switch.log` (the **Open Log** menu item).
On this route, launchd's own stdout/stderr go to
`~/Library/Logs/screen-switch.agent.log` as well; the checkbox's agent sends them
to the unified log instead.

### `launchctl kill` does not stop it

`KeepAlive` is set to `SuccessfulExit: false`, so a signal counts as an
unsuccessful exit and launchd restarts it within seconds. That setting is what
makes the menu's **Quit** work — a clean exit stays quit — so `install-agent
stop` unloads the job with `bootout` instead. The plist stays in place, so it
returns at the next login either way.

### Why its Login Items entry looks like a stray Unix binary

Installed this way, the Login Items row reads **ScreenSwitch** with a generic
executable icon and "part of an unknown developer", rather than *Screen
Switch.app* with its icon. That is the ad-hoc signature: the plist's
`AssociatedBundleIdentifiers` only maps the job back to the app when the two
share a Developer ID team, and an ad-hoc signature has no team, so macOS
describes the program launchd runs instead.

The checkbox in Settings has no such problem — the agent it registers is inside
the app bundle, so the row is the app. If the tidy entry matters to you, use the
checkbox and `./install-agent uninstall` the launchd job.
