// Entry point. Kept apart from the delegate because Swift only allows top-level
// statements in a file called main.swift, and the app is several files now.

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory: a menu bar extra, no Dock tile, but still allowed windows --
// which is why Info.plist sets LSUIElement and not LSBackgroundOnly.
app.setActivationPolicy(.accessory)
app.run()
