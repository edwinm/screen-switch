// Screen Switch -- menu bar control for which machine owns the shared monitor.
//
// The display logic stays in the shell scripts; this is the UI in front of it.
// Switching a device runs `screen-switch`, so there is one source of truth for
// how mirroring and the extended layout are applied.

import AppKit

// The log is what the "Open Log" menu item shows, and the only record of why the
// displays changed while you were not looking.
/// Past this the log is halved, oldest first. A switch is two or three lines,
/// so this is months of them -- but a monitor flapping on and off writes a line
/// every few seconds, and nothing else ever truncates the file.
private let logLimit = 256 * 1024

func log(_ msg: String) {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(df.string(from: Date()))  \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = Paths.logFile
    if let fh = try? FileHandle(forWritingTo: url) {
        defer { try? fh.close() }
        let end = (try? fh.seekToEnd()) ?? 0
        if end > logLimit { trimLog(url) ; _ = try? fh.seekToEnd() }
        try? fh.write(contentsOf: data)
    } else {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}

/// Keeps the newest half, from the first whole line. Rewritten in place rather
/// than rolled over: one log file is what the Open Log menu item points at.
private func trimLog(_ url: URL) {
    guard let data = try? Data(contentsOf: url) else { return }
    var tail = data.suffix(logLimit / 2)
    if let newline = tail.firstIndex(of: 0x0A) { tail = tail[(newline + 1)...] }
    try? Data(tail).write(to: url, options: .atomic)
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
    /// One reading at a time. A poll that is still out when the next tick fires
    /// would otherwise queue up behind it -- and each one runs two subprocesses.
    private var reading = false
    /// What the last reading found, so drawing the menu never has to wait for a
    /// subprocess. Nil means nobody has managed to read it yet.
    private var lastMode: Mode?

    /// Everything one reading learns, gathered off the main thread. Plain data:
    /// the state machine and the logging stay on main, where the state lives.
    private struct Reading {
        var input: String?
        var mode: Mode?
        var modeProblem: String?
    }

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

    func readInput() -> String? { Self.readInput(config: config) }

    private static func readInput(config: Config) -> String? {
        let r = Shell.run(config.m1ddc, ["display", config.ddcTarget, "get", "input"])
        let first = r.out.components(separatedBy: .newlines).first ?? ""
        return ddcFailed(first) ? nil : first
    }

    /// The two subprocesses a tick needs -- a DDC read and the display mode --
    /// about 130ms of them, which is why this never runs on the main thread.
    private static func take(config: Config) -> Reading {
        var r = Reading(input: readInput(config: config))
        let status = Shell.run("/bin/bash", [Paths.screenSwitch, "status"])
        let out = status.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if status.ok, let mode = Mode(exactly: out) {
            r.mode = mode
        } else {
            r.modeProblem = status.ok ? "status said '\(out)'" : shellProblem(status)
        }
        return r
    }

    /// The display mode as of the last reading. Nil means "could not tell" --
    /// the script did not run, or said something that is not a mode. Note what
    /// this is *not*: Mode(config:) defaults unknown text to .mirrored, so
    /// parsing `screen-switch status` with it turned a missing shell tool into a
    /// confident "mirrored" in the menu and in poll()'s comparison.
    func currentMode() -> Mode? { lastMode }

    /// Reads the display mode again and redraws. Used where the answer has to be
    /// fresher than the poll interval -- opening the menu, finishing a switch.
    func refreshMode(then done: (() -> Void)? = nil) {
        let cfg = config
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.take(config: cfg)
            DispatchQueue.main.async {
                self.apply(reading: r, updatingInput: false)
                done?()
            }
        }
    }

    /// The script's failures are worth exactly one log line each, not one per
    /// reading: a tick and every menu opening both take one.
    private func noteStatusFailure(_ reason: String?) {
        guard statusFailure != reason else { return }
        statusFailure = reason
        if let reason { log("cannot read the display mode: \(reason)") }
    }

    /// The script's own account of a failure, a line at a time. A missing script
    /// beats whatever bash printed about it.
    private static func explanation(_ r: (out: String, ok: Bool)) -> [String] {
        if !FileManager.default.isExecutableFile(atPath: Paths.screenSwitch) {
            return ["screen-switch is not at \(Paths.screenSwitch)"]
        }
        let lines = r.out.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? ["it exited non-zero without saying why"] : lines
    }

    /// What went wrong, in the order worth checking.
    private static func shellProblem(_ r: (out: String, ok: Bool)) -> String {
        explanation(r).first ?? "it exited non-zero without saying why"
    }

    /// Runs the shell tool and logs a failure rather than dropping it.
    ///
    /// Every line the script printed goes in, not just the first. A failed
    /// `mirrored` opens with "-> mirrored" -- the half that worked -- and only
    /// names the reason several lines down, so a first-line summary logged the
    /// success and threw the failure away.
    @discardableResult
    private func runScript(_ args: [String], env: [String: String] = [:],
                           what: String) -> (ok: Bool, why: [String]) {
        let r = Shell.run("/bin/bash", [Paths.screenSwitch] + args, env: env)
        guard r.ok else {
            let why = Self.explanation(r)
            log("  \(what) failed")
            for line in why { log("    \(line)") }
            return (false, why)
        }
        return (true, [])
    }

    // MARK: - Following the monitor

    /// Takes a reading off the main thread, then decides on it here. The two
    /// subprocesses behind a reading are ~130ms of blocking on a good day and
    /// unbounded on a bad one -- a monitor that has stopped answering DDC --
    /// which is no business of a thread that has a menu bar to draw.
    func poll() {
        guard !busy, !reading, config.isConfigured else { return }
        reading = true
        let cfg = config
        DispatchQueue.global(qos: .utility).async {
            let r = Self.take(config: cfg)
            DispatchQueue.main.async {
                self.reading = false
                self.apply(reading: r, updatingInput: true)
            }
        }
    }

    /// Everything a reading changes, on the main thread where the state lives.
    /// `updatingInput` is false for the mode-only refreshes, which must not
    /// disturb the edge detector's debounce.
    private func apply(reading r: Reading, updatingInput: Bool) {
        // Every reading ends in a redraw, including the ones the debounce
        // swallows: drawing is cheap now that it reads the cache rather than
        // waiting on `screen-switch status`.
        defer { rebuildMenu() }
        lastMode = r.mode
        noteStatusFailure(r.modeProblem)
        guard updatingInput else { return }

        let value = r.input
        let reachable = value != nil

        // Debounce: a reading has to repeat before it is believed. Reads taken
        // mid-switch return transients.
        let key = value ?? "<unreachable>"
        if key == pendingValue { pendingCount += 1 } else { pendingValue = key; pendingCount = 1 }
        guard pendingCount == debounce else { return }

        if !reachable && lastReachable { log("DDC unreachable") }

        defer { lastInput = value; lastReachable = reachable }
        guard let v = value else { return }

        // Two edges matter: the input changed, or DDC came back after being
        // unreachable (the monitor may have dropped the Mac's display while it
        // was away, leaving macOS on one screen with the layout to restore).
        let changed = v != lastInput
        let returned = !lastReachable
        guard changed || returned else { return }

        if changed { log("input \(lastInput ?? "?") -> \(v)") }
        else { log("DDC back, input \(v) -- reconciling") }

        if let dev = devices.first(where: { $0.code == v }), dev.mode != lastMode {
            log("  applying '\(dev.mode.rawValue)' mode")
            apply(mode: dev.mode, for: dev.code)
        }
    }

    /// Brings the display side into line with a monitor that has already moved.
    ///
    /// `input` is the code the monitor is on right now, and it is passed down
    /// for a reason: `go_mirrored` ends in `set_input "$OTHER_INPUT"`, and with
    /// nothing in the environment that is whatever the config says -- so
    /// following the monitor to a third machine used to answer by shoving the
    /// monitor onto the *second* one's input. Naming the input it is already
    /// showing makes the script's own switch the no-op it should be here.
    func apply(mode: Mode, for input: String) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            self.runScript([mode.rawValue],
                           env: mode == .extended ? ["THIS_MAC_INPUT": input]
                                                  : ["OTHER_INPUT": input],
                           what: mode.rawValue)
            DispatchQueue.main.async {
                self.busy = false
                self.refreshMode()
            }
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
            var why: [String] = []
            if dev.mode == .extended {
                why = self.runScript(["input", dev.code], what: "input \(dev.code)").why
            }
            let r = self.runScript([mode], env: dev.mode == .extended
                                                ? ["THIS_MAC_INPUT": dev.code]
                                                : ["OTHER_INPUT": dev.code],
                                   what: "\(mode) for \(dev.label)")
            if !r.ok { why = r.why }

            DispatchQueue.main.async {
                self.busy = false
                // Only on success. Recording the code the monitor was *asked*
                // for made the menu tick a machine it had not switched to, and
                // then handed the edge detector a change that never happened:
                // the next poll read the old input back and took it for the
                // user moving the monitor by hand.
                if why.isEmpty { self.lastInput = dev.code }
                else { self.report(failedToSelect: dev, why: why) }
                self.refreshMode()
            }
        }
    }

    /// A pick that did not move the monitor has to say so. The automatic paths
    /// stay quiet -- a watcher that opens dialogs is unusable -- but this one is
    /// a button the user just pressed, and a silent one sends the user to the
    /// log to work out why the menu did nothing.
    ///
    /// The last two lines, not the whole transcript: the script opens with what
    /// it is doing and what worked ("-> mirrored", the mode it applied), and
    /// ends with the reason it stopped and what to do about it. The log keeps
    /// every line; a dialog that reads as terminal output does not.
    private func report(failedToSelect dev: Device, why: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The monitor did not switch to \u{201C}\(dev.label)\u{201D}."
        alert.informativeText = why.suffix(2).joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Menu actions

    @objc func openSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsWindowController(app: self) }
        // An accessory app is never the active one, so without this the window
        // opens behind whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
    }

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

        // No "Showing: ..." line: the checkmark in the list below already says
        // which machine has the monitor, and a header repeating it just pushes
        // the list down. Unreachable is the one case the list cannot say by
        // itself -- nothing is ticked then, so the menu has to explain why.
        if live == nil {
            let header = NSMenuItem(title: "Monitor unreachable", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }

        for d in devices {
            let item = NSMenuItem(title: d.label, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.code
            item.state = (d.code == live) ? .on : .off
            item.isEnabled = !busy
            menu.addItem(item)
        }

        // Nor a "Displays: extended" line: the icon carries the mode, which is
        // what it is for. A separator only when there is a list above it to
        // separate -- an empty machine list would otherwise open the menu on a
        // stray rule.
        if !devices.isEmpty { menu.addItem(.separator()) }

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
    /// Draw from the last reading straight away -- a menu must not wait on a
    /// subprocess -- and refresh behind it. The items update in place a moment
    /// later if the answer moved.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        refreshMode()
    }
}
