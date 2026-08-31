// LoginItem.swift -- starting at login, owned by the app rather than a script.
//
// Registers the LaunchAgent bundled at Contents/Library/LaunchAgents/, which is
// what puts the item under the *app's* name and icon in System Settings ->
// General -> Login Items. The alternatives were both worse:
//
// - SMAppService.mainApp lists the app under "Open at Login" instead of with
//   the background items, and loginwindow launches it directly, so KeepAlive --
//   and with it crash recovery -- is gone.
// - The launchd job `install-agent` writes lives outside any bundle, so BTM
//   describes the program it runs: a bare executable called "ScreenSwitch"
//   with a generic icon. AssociatedBundleIdentifiers does not fix that without
//   a Team ID to match, and the signature here is ad-hoc. Measured; see
//   AGENTS.md.
//
// The two can coexist without breaking anything -- the second copy to start
// notices the first and exits (see main.swift) -- but the user sees two rows,
// so the Settings pane says so when it finds the other one.
//
// SMAppService registers the bundle by path, so moving the checkout leaves a
// dead entry in Login Items. Re-toggle after a move.

import Foundation
import ServiceManagement

enum LoginItem {

    /// A file name, not a path: SMAppService looks it up inside the bundle.
    /// `build` copies the plist there before signing.
    static let plistName = "org.bitstorm.screen-switch.login.plist"

    private static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    /// False when we are not running from a .app -- the headless test harness
    /// described in AGENTS.md, mainly. There is no bundle to register then, so
    /// the checkbox is shown disabled rather than failing on click.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var status: SMAppService.Status {
        isAvailable ? service.status : .notFound
    }

    /// The job `install-agent` renders. Presence is enough: whether it is
    /// currently loaded does not change what the pane has to say.
    static var legacyAgentInstalled: Bool {
        FileManager.default.fileExists(atPath: legacyAgentPlist.path)
    }

    static var legacyAgentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/org.bitstorm.screen-switch.plist")
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            // Unregistering something already gone throws rather than being a
            // no-op, and there is nothing for the user to do about that.
            do { try service.unregister() }
            catch { if status != .notRegistered { throw error } }
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
