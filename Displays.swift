// Finding out what is actually attached, so nobody has to type a UUID.
//
// Two command line tools together know everything the config needs, and they
// agree on one join key -- the persistent screen id:
//
//   displayplacer list   ids, kind, current mode, every available mode, and the
//                        command describing the current arrangement
//   m1ddc display list   the DDC index and the monitor's marketing name
//
// CoreGraphics fills in the last gap: the built-in screen has no DDC name, but
// CGDisplayCreateUUIDFromDisplayID returns exactly the id displayplacer prints,
// so NSScreen.localizedName can be matched to a block.

import AppKit

// MARK: - Running things

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> (out: String, ok: Bool) {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return ("", false) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return ("", false) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (out, p.terminationStatus == 0)
    }
}

/// A DDC read failed if it is empty or if m1ddc said it could not reach the
/// display. Mirrors ddc_failed() in lib.sh -- m1ddc's failure text is "Could not
/// find a suitable external display.", which contains neither "error" nor
/// "unable", so a narrower guard treats a dead link as a good read. Keep the two
/// implementations in step.
func ddcFailed(_ s: String) -> Bool {
    let t = s.lowercased()
    return t.isEmpty || t.contains("could not") || t.contains("error")
        || t.contains("unable") || t.contains("not find")
}

// MARK: - Modes

struct DisplayMode: Equatable {
    var width: Int
    var height: Int
    var hz: Int
    var scaling: Bool
    var colorDepth: Int = 8

    var resolution: String { "\(width)x\(height)" }
    var pixels: Int { width * height }
    var label: String { "\(width) × \(height) @ \(hz) Hz" }

    /// Parses the `res:1728x1117 hz:120 ... scaling:on` half of any
    /// displayplacer line, whether it is a `mode N:` line or a full spec.
    init?(spec: String) {
        func field(_ name: String) -> String? {
            for token in spec.split(separator: " ") where token.hasPrefix("\(name):") {
                return String(token.dropFirst(name.count + 1))
            }
            return nil
        }
        guard let res = field("res") else { return nil }
        let wh = res.split(separator: "x")
        guard wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]) else { return nil }
        width = w
        height = h
        hz = field("hz").flatMap { Int($0) } ?? 60
        scaling = (field("scaling") ?? "off") == "on"
        colorDepth = field("color_depth").flatMap { Int($0) } ?? 8
    }

    var specFragment: String {
        "res:\(resolution) hz:\(hz) color_depth:\(colorDepth) enabled:true "
            + "scaling:\(scaling ? "on" : "off")"
    }
}

// MARK: - Displays

struct DisplayInfo {
    var persistentID: String
    var kind: String                 // displayplacer's "Type:" line
    var ddcName: String?             // from m1ddc, nil for the built-in
    var systemName: String?          // NSScreen.localizedName
    var ddcIndex: Int?
    var isBuiltin: Bool
    var current: DisplayMode?
    var modes: [DisplayMode] = []

    /// Best name available, in decreasing order of how much it tells you.
    var name: String {
        if let n = ddcName, !n.isEmpty, n != "(null)" { return n }
        if let n = systemName, !n.isEmpty { return n }
        return kind.isEmpty ? persistentID : kind
    }

    /// Largest unscaled mode -- what the panel actually is, rather than what it
    /// is currently set to.
    var maxMode: DisplayMode? {
        modes.filter { !$0.scaling }.max { $0.pixels < $1.pixels } ?? modes.max { $0.pixels < $1.pixels }
    }

    /// One line for a popup menu: name plus enough detail to tell two identical
    /// monitors apart at a glance.
    var menuLabel: String {
        var parts = [name]
        if let m = maxMode { parts.append("\(m.width) × \(m.height)") }
        if let i = ddcIndex { parts.append("DDC \(i)") }
        return parts.joined(separator: " — ")
    }

    /// Distinct resolutions, largest first, for the mirror-resolution popup.
    ///
    /// One entry per resolution at its best refresh rate, and scaled ("looks
    /// like") modes where the panel has them -- that is the list System Settings
    /// shows, and it is a menu a person can read. The raw `modes` array has well
    /// over a hundred entries on a Retina panel, which is not a menu.
    var offeredModes: [DisplayMode] {
        let scaled = modes.filter(\.scaling)
        let pool = scaled.isEmpty ? modes : scaled
        var best: [String: DisplayMode] = [:]
        for m in pool where (best[m.resolution]?.hz ?? -1) < m.hz {
            best[m.resolution] = m
        }
        return best.values.sorted { $0.pixels > $1.pixels }
    }

    /// Every refresh rate this panel offers at a given resolution.
    func refreshRates(for resolution: String) -> [DisplayMode] {
        var seen = Set<Int>()
        return modes
            .filter { $0.resolution == resolution && seen.insert($0.hz).inserted }
            .sorted { $0.hz > $1.hz }
    }
}

struct DisplaySnapshot {
    var displays: [DisplayInfo] = []
    /// The `displayplacer "..." "..."` command printed at the bottom of `list`,
    /// split into its arguments. This is the "capture my arrangement" payload.
    var currentArrangement: [String] = []
    var toolsMissing: [String] = []

    var main: DisplayInfo? { displays.first(where: { $0.isBuiltin }) ?? displays.first }
    var shared: DisplayInfo? {
        displays.first(where: { !$0.isBuiltin && $0.ddcIndex != nil })
            ?? displays.first(where: { !$0.isBuiltin })
    }

    func display(id: String) -> DisplayInfo? { displays.first(where: { $0.persistentID == id }) }
}

enum DisplayScanner {

    static func scan(config: Config) -> DisplaySnapshot {
        var snap = DisplaySnapshot()

        let dp = Shell.run(config.displayplacer, ["list"])
        if !dp.ok && dp.out.isEmpty {
            snap.toolsMissing.append("displayplacer")
            return snap
        }
        (snap.displays, snap.currentArrangement) = parseDisplayplacer(dp.out)

        let ddc = Shell.run(config.m1ddc, ["display", "list"])
        if ddc.out.isEmpty { snap.toolsMissing.append("m1ddc") }
        let byID = parseM1ddc(ddc.out)
        let names = systemNames()

        for i in snap.displays.indices {
            let id = snap.displays[i].persistentID
            if let hit = byID[id] {
                snap.displays[i].ddcIndex = hit.index
                snap.displays[i].ddcName = hit.name
            }
            if let n = names[id] { snap.displays[i].systemName = n }
        }
        return snap
    }

    // MARK: displayplacer

    static func parseDisplayplacer(_ text: String) -> ([DisplayInfo], [String]) {
        var displays: [DisplayInfo] = []
        var arrangement: [String] = []
        var headerRes: [Int: String] = [:]
        var headerHz: [Int: Int] = [:]

        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)

            if t.hasPrefix("Persistent screen id:") {
                displays.append(DisplayInfo(
                    persistentID: value(t), kind: "", ddcName: nil, systemName: nil,
                    ddcIndex: nil, isBuiltin: false, current: nil))
                continue
            }
            guard !displays.isEmpty else {
                if t.hasPrefix("displayplacer ") { arrangement = specs(in: t) }
                continue
            }
            let i = displays.count - 1

            if t.hasPrefix("Type:") {
                let kind = value(t)
                displays[i].kind = kind
                // displayplacer says "MacBook built in screen" for the internal
                // panel; CGDisplayIsBuiltin confirms it where the string varies.
                displays[i].isBuiltin = kind.lowercased().contains("built in")
            } else if t.hasPrefix("mode ") {
                if let m = DisplayMode(spec: t) {
                    displays[i].modes.append(m)
                    if t.contains("<-- current mode") { displays[i].current = m }
                }
            } else if t.hasPrefix("Resolution:") {
                // Header fallback, for the case where no mode line is marked
                // current. The header splits resolution and hertz over two lines.
                headerRes[i] = value(t)
            } else if t.hasPrefix("Hertz:") {
                headerHz[i] = Int(value(t)) ?? 60
            } else if t.hasPrefix("displayplacer ") {
                arrangement = specs(in: t)
            }
        }

        for (i, res) in headerRes where displays[i].current == nil {
            displays[i].current = DisplayMode(spec: "res:\(res) hz:\(headerHz[i] ?? 60)")
        }

        let builtinIDs = builtinPersistentIDs()
        for i in displays.indices where builtinIDs.contains(displays[i].persistentID) {
            displays[i].isBuiltin = true
        }
        return (displays, arrangement)
    }

    private static func value(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        var v = String(line[line.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        // "Origin: (0,0) - main display", "Rotation: 0 - rotate internal ..."
        if let dash = v.range(of: " - ") { v = String(v[v.startIndex..<dash.lowerBound]) }
        return v
    }

    /// Pulls the quoted arguments out of the `displayplacer "..." "..."` line.
    private static func specs(in line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuote = false
        for ch in line {
            if ch == "\"" {
                if inQuote { out.append(current); current = "" }
                inQuote.toggle()
            } else if inQuote {
                current.append(ch)
            }
        }
        return out
    }

    // MARK: m1ddc

    /// Lines look like `[2] DELL U2718Q (3F85B0D8-EE05-...)`.
    static func parseM1ddc(_ text: String) -> [String: (index: Int, name: String)] {
        var out: [String: (Int, String)] = [:]
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("["), let close = t.firstIndex(of: "]"),
                  let index = Int(t[t.index(after: t.startIndex)..<close]),
                  let open = t.range(of: "(", options: .backwards),
                  t.hasSuffix(")") else { continue }
            let name = String(t[t.index(after: close)..<open.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let id = String(t[open.upperBound..<t.index(before: t.endIndex)])
            out[id] = (index, name)
        }
        return out
    }

    // MARK: CoreGraphics

    private static func uuid(of display: CGDirectDisplayID) -> String? {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, cf) as String?
    }

    /// NSScreen only lists screens macOS is drawing on, so a mirrored monitor is
    /// absent here. That is fine: this only supplies nicer names.
    private static func systemNames() -> [String: String] {
        var out: [String: String] = [:]
        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber, let id = uuid(of: CGDirectDisplayID(num.uint32Value))
            else { continue }
            out[id] = screen.localizedName
        }
        return out
    }

    private static func builtinPersistentIDs() -> Set<String> {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        var out = Set<String>()
        for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) != 0 {
            if let u = uuid(of: id) { out.insert(u) }
        }
        return out
    }
}

// MARK: - Generating layouts

enum LayoutBuilder {
    /// Mirror set with the Mac's own screen FIRST. displayplacer only lets you
    /// choose the resolution of the first screen in a set, so leading with the
    /// Mac's screen is what stops macOS inheriting the monitor's resolution --
    /// the whole point of the project. The order is enforced here rather than
    /// left to whoever edits the config.
    ///
    /// Several candidates because a mirror set can refuse a refresh rate the
    /// panel offers on its own; `screen-switch` tries them in order.
    static func mirrorCandidates(main: String, shared: String, mode: DisplayMode,
                                 from display: DisplayInfo?) -> [String] {
        guard !main.isEmpty, !shared.isEmpty else { return [] }

        var modes: [DisplayMode] = [mode]
        // Same resolution at other refresh rates first, then progressively
        // smaller ones.
        if let d = display {
            modes += d.refreshRates(for: mode.resolution).filter { $0.hz != mode.hz }.prefix(2)
            modes += d.offeredModes.filter { $0.pixels < mode.pixels }.prefix(2)
        }

        var seen = Set<String>()
        return modes
            .filter { seen.insert("\($0.resolution)@\($0.hz)").inserted }
            .map { "id:\(main)+\(shared) \($0.specFragment) origin:(0,0) degree:0" }
    }
}
