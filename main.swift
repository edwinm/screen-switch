// Entry point. Kept apart from the delegate because Swift only allows top-level
// statements in a file called main.swift, and the app is several files now.

import AppKit

// One instance, whoever started it. Registering the login agent bootstraps the
// job immediately -- RunAtLoad -- so ticking the checkbox in a running app would
// otherwise put a second icon in the menu bar, and having both the agent and
// install-agent's job installed would do the same at login. exit(0) rather than
// a signal, so KeepAlive leaves the loser dead.
if let id = Bundle.main.bundleIdentifier {
    let mine = NSRunningApplication.current.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        .filter { $0.processIdentifier != mine }
    if !others.isEmpty { exit(0) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory: a menu bar extra, no Dock tile, but still allowed windows --
// which is why Info.plist sets LSUIElement and not LSBackgroundOnly.
app.setActivationPolicy(.accessory)
app.run()
