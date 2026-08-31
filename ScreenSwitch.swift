// Screen Switch -- menu bar control for which machine owns the shared monitor.
//
// The display logic stays in the shell scripts; this is the UI in front of it.
// Switching a device runs `screen-switch`, so there is one source of truth for
// how mirroring and the extended layout are applied.

import AppKit

// The log is what the "Open Log" menu item shows, and the only record of why the
// displays changed while you were not looking.
func log(_ msg: String) {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(df.string(from: Date()))  \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = Paths.logFile
    if let fh = try? FileHandle(forWritingTo: url) {
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
    } else {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var config = Config()
    var devices: [Device] = []
    var timer: Timer?
    var settings: SettingsWindowController?

    // Edge-triggered, exactly like the shell watcher: act only when the input
    // actually changes, never on steady state. Otherwise a manual mirror gets
    // silently undone a few seconds later.
    var lastInput: String?
    var lastReachable = true
    var pendingValue: String?
    var pendingCount = 0
    /// The last reason the display mode could not be read, so it is logged on
    /// the transition rather than on every poll.
    private var statusFailure: String?
    let debounce = 2
    var busy = false

    func applicationDidFinishLaunching(_ n: Notification) {
        reloadConfig()
        log("Screen Switch started (\(devices.count) devices)")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Screen Switch"
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        poll()
        startTimer()
        rebuildMenu()

        // Nothing works until the displays are known, so say so rather than
        // presenting an empty menu.
        if !config.isConfigured {
            log("no configuration yet -- opening Settings")
            openSettings(nil)
        }
    }

    func reloadConfig() {
        config = Config.load()
        devices = Devices.load()
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        guard config.followMonitor else { timer = nil; return }
        let interval = max(1.0, config.pollInterval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    // MARK: - Talking to the tools

    func readInput() -> String? {
        let r = Shell.run(config.m1ddc, ["display", config.ddcTarget, "get", "input"])
        let first = r.out.components(separatedBy: .newlines).first ?? ""
        return ddcFailed(first) ? nil : first
    }

    /// nil means "could not tell" -- the script did not run, or said something
    /// that is not a mode. Mode(config:) must not be used here: its default is
    /// .mirrored, so a missing shell tool used to read as a confident "mirrored"
    /// in the menu and in poll()'s comparison.
    func currentMode() -> Mode? {
        let r = Shell.run("/bin/bash", [Paths.screenSwitch, "status"])
        let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok, let mode = Mode(exactly: out) else {
            noteStatusFailure(r.ok ? "status said '\(out)'" : shellProblem(r))
            return nil
        }
        statusFailure = nil
        return mode
    }

    /// The script's failures are worth exactly one log line each, not one per
    /// poll: rebuildMenu() runs on every poll and every menu open.
    private func noteStatusFailure(_ reason: String) {
        guard statusFailure != reason else { return }
        statusFailure = reason
        log("cannot read the display mode: \(reason)")
    }

    /// What went wrong, in the order worth checking: a missing script beats
    /// whatever bash printed about it.
    private func shellProblem(_ r: (out: String, ok: Bool)) -> String {
        if !FileManager.default.isExecutableFile(atPath: Paths.screenSwitch) {
            return "screen-switch is not at \(Paths.screenSwitch)"
        }
        let first = r.out.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        return first.isEmpty ? "it exited non-zero without saying why" : first
    }

    /// Runs the shell tool and logs a failure rather than dropping it.
    @discardableResult
    private func runScript(_ args: [String], env: [String: String] = [:],
                           what: String) -> Bool {
        let r = Shell.run("/bin/bash", [Paths.screenSwitch] + args, env: env)
        if !r.ok { log("  \(what) failed: \(shellProblem(r))") }
        return r.ok
    }

    // MARK: - Following the monitor

    func poll() {
        guard !busy, config.isConfigured else { return }
        let value = readInput()
        let reachable = value != nil

        // Debounce: a reading has to repeat before it is believed. Reads taken
        // mid-switch return transients.
        let key = value ?? "<unreachable>"
        if key == pendingValue { pendingCount += 1 } else { pendingValue = key; pendingCount = 1 }
        guard pendingCount == debounce else { return }

        if !reachable && lastReachable { log("DDC unreachable") }

        defer { lastInput = value; lastReachable = reachable; rebuildMenu() }
        guard let v = value else { return }

        // Two edges matter: the input changed, or DDC came back after being
        // unreachable (the monitor may have dropped the Mac's display while it
        // was away, leaving macOS on one screen with the layout to restore).
        let changed = v != lastInput
        let returned = !lastReachable
        guard changed || returned else { return }

        if changed { log("input \(lastInput ?? "?") -> \(v)") }
        else { log("DDC back, input \(v) -- reconciling") }

        if let dev = devices.first(where: { $0.code == v }), dev.mode != currentMode() {
            log("  applying '\(dev.mode.rawValue)' mode")
            apply(mode: dev.mode)
        }
    }

    func apply(mode: Mode) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            self.runScript([mode.rawValue], what: mode.rawValue)
            DispatchQueue.main.async { self.busy = false; self.rebuildMenu() }
        }
    }

    // Selecting a device switches the monitor's input; the poll that follows
    // notices the edge and brings the display side into line.
    @objc func pick(_ sender: NSMenuItem) {
        guard let dev = devices.first(where: { $0.code == sender.representedObject as? String })
        else { return }
        log("menu: selected \(dev.label) (input \(dev.code))")
        busy = true

        // Everything goes through `screen-switch`, never straight to m1ddc.
        // The old code sent `m1ddc set input` from here and then applied the
        // mode, which skipped three things the script does:
        //
        //   - BLOCKED_INPUTS. The guard that exists because one wrong code can
        //     drop a panel's link to the Mac was simply not on this path, which
        //     is the one people actually use.
        //   - verifying the switch by reading back. A monitor returns success
        //     for an input it then declines, so the fixed 2-second sleep that
        //     followed proved nothing.
        //   - the order, which is different in each direction and is the whole
        //     safety story. Setting the input first is right when taking the
        //     monitor *back* and wrong when handing it over.
        //
        // Handing it over is one call: go_mirrored mirrors first -- so the
        // windows have somewhere to land -- and only then switches the input,
        // to OTHER_INPUT, which the environment points at this machine.
        //
        // Taking it back is two, because the input has to move before the
        // extended layout is restored, and go_extended only does that when
        // TRY_INPUT_SWITCH_BACK is on. Picking a machine by hand is an explicit
        // request to move the monitor, so it happens either way; the env keeps
        // the script's own attempt aimed at the same machine rather than at
        // whatever THIS_MAC_INPUT says.
        let mode = dev.mode.rawValue
        DispatchQueue.global(qos: .userInitiated).async {
            if dev.mode == .extended {
                self.runScript(["input", dev.code], what: "input \(dev.code)")
            }
            self.runScript([mode], env: dev.mode == .extended
                                        ? ["THIS_MAC_INPUT": dev.code]
                                        : ["OTHER_INPUT": dev.code],
                           what: "\(mode) for \(dev.label)")
            DispatchQueue.main.async {
                self.busy = false
                self.lastInput = dev.code
                self.rebuildMenu()
            }
        }
    }

    // MARK: - Menu actions

    @objc func openSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsWindowController(app: self) }
        // An accessory app is never the active one, so without this the window
        // opens behind whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
    }

    @objc func openLog() { NSWorkspace.shared.open(Paths.logFile) }

    // Name, icon, version and copyright come off Info.plist; only the byline and
    // the repo link have to be supplied. The panel's text view honours .link, so
    // the URL is clickable rather than something to retype.
    @objc func openAbout() {
        let repo = URL(string: "https://github.com/edwinm/screen-switch")!
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        // Colours are set explicitly: text left without a .foregroundColor is
        // drawn black in the panel's text view, which is unreadable in Dark Mode.
        let credits = NSMutableAttributedString(
            string: "by Edwin Martin\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(
            string: repo.absoluteString,
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.linkColor,
                         .link: repo]))
        credits.addAttribute(.paragraphStyle, value: centred,
                             range: NSRange(location: 0, length: credits.length))

        // Same reason as openSettings: an accessory app is never the active one.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: - The status item icon
    //
    // One screen, split corner to corner: the lit half is whoever holds the
    // monitor. Vector templates in Resources, so macOS tints them for light,
    // dark and the highlighted state -- a non-template icon is invisible in
    // one of them.

    private enum StatusIcon: String {
        case extended = "MenuExtended"
        case mirrored = "MenuMirrored"
        case unreachable = "MenuUnreachable"

        var label: String {
            switch self {
            case .extended: return "Screen Switch — this Mac has the monitor"
            case .mirrored: return "Screen Switch — another machine has the monitor"
            case .unreachable: return "Screen Switch — monitor unreachable"
            }
        }
    }

    private var shownIcon: StatusIcon?

    private func setIcon(_ icon: StatusIcon) {
        guard icon != shownIcon else { return }
        shownIcon = icon
        // Fall back to the system symbol if the bundle was built without its
        // Resources; a menu bar app with no icon at all cannot be clicked.
        let image = NSImage(named: icon.rawValue)
            ?? NSImage(systemSymbolName: "display.2", accessibilityDescription: nil)
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityLabel(icon.label)
    }

    func rebuildMenu() {
        // Not `statusItem.menu!`: a status item macOS declined to draw, or one
        // never made, is a reason to do nothing rather than to crash.
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        if !config.isConfigured {
            setIcon(.unreachable)
            let item = NSMenuItem(title: "Not set up yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
            addSettingsAndQuit(to: menu)
            return
        }

        let live = lastReachable ? (lastInput ?? "?") : nil
        let displayMode = currentMode()
        // An unknown mode gets the unreachable icon too: both mean the app
        // cannot say what the displays are doing.
        setIcon(live == nil || displayMode == nil ? .unreachable
                : (displayMode == .mirrored ? .mirrored : .extended))

        let header = NSMenuItem(
            title: live == nil ? "Monitor unreachable" : "Showing: " + name(for: live!),
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for d in devices {
            let item = NSMenuItem(title: d.label, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.code
            item.state = (d.code == live) ? .on : .off
            item.isEnabled = !busy
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let mode = NSMenuItem(
            title: "Displays: \(displayMode?.displayName ?? "unknown")",
            action: nil, keyEquivalent: "")
        mode.isEnabled = false
        menu.addItem(mode)
        menu.addItem(.separator())

        addSettingsAndQuit(to: menu)
    }

    private func addSettingsAndQuit(to menu: NSMenu) {
        let aboutItem = NSMenuItem(
            title: "About Screen Switch", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        // "Settings...", not "Preferences...": Apple renamed it in macOS 13, and
        // the comma is its reserved shortcut.
        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let logItem = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        // Quit stands alone under a separator, the way every macOS menu ends.
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit Screen Switch", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    func name(for code: String) -> String {
        devices.first(where: { $0.code == code })?.label ?? "input \(code)"
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
}
